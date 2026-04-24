#!/usr/bin/env bash
# Detecta movimiento comparando frames consecutivos de la cámara.
# Usa ffmpeg con el filtro "scene" sobre capturas de baja resolución
# para minimizar el uso de CPU en la Pi 3B.
#
# Cuando se detecta movimiento ejecuta un comando o script configurable.
# Diseñado para ser usado por motion-trigger.sh o de forma independiente.
#
# Uso:
#   ./motion-detect.sh [opciones]
#
# Opciones:
#   --threshold N    Umbral de cambio entre frames 0.0–1.0 (default: 0.15)
#                    0.05 = muy sensible | 0.15 = normal | 0.30 = poco sensible
#   --interval N     Segundos entre capturas de análisis (default: 2)
#   --width N        Ancho de captura para análisis (default: 320, bajo para ahorrar CPU)
#   --height N       Alto de captura para análisis (default: 240)
#   --on-motion CMD  Comando a ejecutar al detectar movimiento
#   --on-stop CMD    Comando a ejecutar cuando el movimiento cesa
#   --timeout N      Segundos sin movimiento para considerar que cesó (default: 10)
#   --webhook URL    URL HTTP a notificar con POST al detectar movimiento
#   --log FILE       Archivo de log de eventos (default: stdout)
#   --help           Mostrar esta ayuda
#
# Ejemplos:
#   ./motion-detect.sh --threshold 0.1 --on-motion "echo MOVIMIENTO DETECTADO"
#   ./motion-detect.sh --webhook http://192.168.1.100:8080/motion
#   ./motion-detect.sh --on-motion "scripts/stream-rtsp.sh -n cam &" --timeout 30
#
# Umbrales recomendados según escenario:
#   Interior con luz constante  : 0.05–0.10
#   Interior con cambios de luz : 0.15–0.20
#   Exterior (viento, nubes)    : 0.20–0.35

set -euo pipefail

THRESHOLD=0.15
INTERVAL=2
CAP_WIDTH=320
CAP_HEIGHT=240
ON_MOTION_CMD=""
ON_STOP_CMD=""
STOP_TIMEOUT=10
WEBHOOK_URL=""
LOG_FILE=""

usage() {
    grep '^#' "$0" | grep -v '#!/' | sed 's/^# \{0,1\}//'
    exit 0
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    if [[ -n "$LOG_FILE" ]]; then
        echo "$msg" | tee -a "$LOG_FILE"
    else
        echo "$msg"
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --threshold)  THRESHOLD="$2"; shift 2 ;;
        --interval)   INTERVAL="$2"; shift 2 ;;
        --width)      CAP_WIDTH="$2"; shift 2 ;;
        --height)     CAP_HEIGHT="$2"; shift 2 ;;
        --on-motion)  ON_MOTION_CMD="$2"; shift 2 ;;
        --on-stop)    ON_STOP_CMD="$2"; shift 2 ;;
        --timeout)    STOP_TIMEOUT="$2"; shift 2 ;;
        --webhook)    WEBHOOK_URL="$2"; shift 2 ;;
        --log)        LOG_FILE="$2"; shift 2 ;;
        --help)       usage ;;
        *) die "Opción desconocida: $1. Usa --help para ver las opciones." ;;
    esac
done

command -v libcamera-jpeg >/dev/null 2>&1 \
    || command -v libcamera-still >/dev/null 2>&1 \
    || die "libcamera-jpeg/libcamera-still no encontrado. Instalar con: sudo apt install libcamera-apps"
command -v ffmpeg >/dev/null 2>&1 || die "ffmpeg no encontrado. Instalar con: sudo apt install ffmpeg"

# Detectar el comando disponible para captura de frames estáticos
if command -v libcamera-jpeg >/dev/null 2>&1; then
    CAM_CMD="libcamera-jpeg"
else
    CAM_CMD="libcamera-still"
fi

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

PREV_FRAME="${TMPDIR}/prev.jpg"
CURR_FRAME="${TMPDIR}/curr.jpg"
STATE_FILE="${TMPDIR}/state"  # "idle" o "active"
LAST_MOTION_FILE="${TMPDIR}/last_motion"

echo "idle" > "$STATE_FILE"
echo "0" > "$LAST_MOTION_FILE"

# --- Capturar un frame de análisis ---
capture_frame() {
    local output="$1"
    $CAM_CMD \
        --width "$CAP_WIDTH" \
        --height "$CAP_HEIGHT" \
        --nopreview \
        --timeout 200 \
        --output "$output" \
        2>/dev/null
}

# --- Calcular diferencia entre dos frames usando ffmpeg SSIM/PSNR ---
# Devuelve el score de cambio como número 0.0–1.0
frame_diff() {
    local f1="$1"
    local f2="$2"

    # ffmpeg scene filter: compara frames y devuelve score de cambio
    # Un score > threshold indica movimiento significativo
    local score
    score=$(ffmpeg \
        -hide_banner \
        -loglevel quiet \
        -i "$f1" \
        -i "$f2" \
        -filter_complex "[0:v][1:v]blend=all_mode=difference,blackframe=98:32" \
        -f null - 2>&1 \
        | grep "blackframe" \
        | awk '{for(i=1;i<=NF;i++) if($i~/^pblack/) {split($i,a,":");print 1-a[2]/100; exit}}')

    echo "${score:-0}"
}

# --- Notificar via webhook ---
notify_webhook() {
    local event="$1"
    local score="$2"
    if [[ -n "$WEBHOOK_URL" ]]; then
        curl -s -X POST "$WEBHOOK_URL" \
            -H "Content-Type: application/json" \
            -d "{\"event\":\"${event}\",\"score\":${score},\"timestamp\":\"$(date -Iseconds)\"}" \
            >/dev/null 2>&1 &
    fi
}

log "=== Detección de movimiento iniciada ==="
log "  Umbral      : ${THRESHOLD}"
log "  Intervalo   : ${INTERVAL}s"
log "  Resolución  : ${CAP_WIDTH}x${CAP_HEIGHT}"
log "  Timeout     : ${STOP_TIMEOUT}s sin movimiento para cesar"
[[ -n "$WEBHOOK_URL"    ]] && log "  Webhook     : ${WEBHOOK_URL}"
[[ -n "$ON_MOTION_CMD"  ]] && log "  Al detectar : ${ON_MOTION_CMD}"
[[ -n "$ON_STOP_CMD"    ]] && log "  Al cesar    : ${ON_STOP_CMD}"
log "========================================="

# Captura inicial de referencia
log "Capturando frame inicial de referencia..."
capture_frame "$PREV_FRAME" || die "No se pudo capturar frame inicial. Verificar cámara."
log "Listo. Monitoreando..."

MOTION_ACTIVE=false
LAST_MOTION_TIME=0

while true; do
    sleep "$INTERVAL"

    # Capturar frame actual
    if ! capture_frame "$CURR_FRAME" 2>/dev/null; then
        log "AVISO: fallo en captura de frame, reintentando..."
        continue
    fi

    # Calcular diferencia
    SCORE=$(frame_diff "$PREV_FRAME" "$CURR_FRAME")

    # Comparar con umbral usando bc
    DETECTED=$(echo "$SCORE > $THRESHOLD" | bc -l 2>/dev/null || echo "0")

    NOW=$(date +%s)

    if [[ "$DETECTED" == "1" ]]; then
        LAST_MOTION_TIME="$NOW"

        if [[ "$MOTION_ACTIVE" == false ]]; then
            MOTION_ACTIVE=true
            log "MOVIMIENTO DETECTADO (score: ${SCORE})"
            notify_webhook "motion_start" "$SCORE"

            if [[ -n "$ON_MOTION_CMD" ]]; then
                log "Ejecutando: ${ON_MOTION_CMD}"
                eval "$ON_MOTION_CMD" &
            fi
        fi
    else
        # Verificar si el timeout de inactividad expiró
        if [[ "$MOTION_ACTIVE" == true ]]; then
            ELAPSED=$(( NOW - LAST_MOTION_TIME ))
            if [[ "$ELAPSED" -ge "$STOP_TIMEOUT" ]]; then
                MOTION_ACTIVE=false
                log "Movimiento cesado (${ELAPSED}s sin actividad)"
                notify_webhook "motion_stop" "0"

                if [[ -n "$ON_STOP_CMD" ]]; then
                    log "Ejecutando: ${ON_STOP_CMD}"
                    eval "$ON_STOP_CMD" &
                fi
            fi
        fi
    fi

    # El frame actual se convierte en el frame de referencia
    cp "$CURR_FRAME" "$PREV_FRAME"
done
