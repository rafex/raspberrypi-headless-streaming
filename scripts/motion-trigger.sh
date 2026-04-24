#!/usr/bin/env bash
# Activa el stream de video automáticamente al detectar movimiento.
# Detiene el stream cuando no hay movimiento por un tiempo configurable.
#
# Pipeline:
#   libcamera-jpeg (baja res, análisis) → frame-diff
#       movimiento detectado → libcamera-vid (1080p) → ffmpeg → RTMP/RTSP
#       movimiento cesa      → stream se detiene
#
# Uso:
#   ./motion-trigger.sh [opciones] -u URL
#
# Opciones de detección:
#   --threshold N    Umbral de cambio entre frames 0.0–1.0 (default: 0.15)
#   --interval N     Segundos entre capturas de análisis (default: 2)
#   --cooldown N     Segundos mínimos entre activaciones (default: 10)
#   --stop-after N   Segundos sin movimiento para detener el stream (default: 30)
#
# Opciones de stream:
#   -u URL           URL RTMP o RTSP destino
#   -k KEY           Stream key
#   --rtsp           Usar modo RTSP (mediamtx) en lugar de RTMP
#   --rtsp-host H    Host mediamtx (default: localhost)
#   --rtsp-port P    Puerto RTSP (default: 8554)
#   --rtsp-name N    Nombre del path RTSP (default: cam)
#   -w WIDTH         Ancho del stream (default: 1920)
#   -h HEIGHT        Alto del stream (default: 1080)
#   -f FPS           FPS del stream (default: 30)
#   -b BITRATE       Bitrate en bits/s (default: 4500000)
#   --no-audio       Deshabilitar audio
#
# Opciones de notificación:
#   --webhook URL    URL HTTP para notificar eventos de movimiento
#   --log FILE       Archivo de log (default: stdout)
#
# Variables de entorno:
#   RTMP_URL         URL RTMP completa
#   STREAM_KEY       Stream key
#
# Ejemplos:
#   # Stream RTMP a YouTube al detectar movimiento
#   ./motion-trigger.sh -u rtmp://a.rtmp.youtube.com/live2/KEY
#
#   # Stream RTSP local con notificación webhook
#   ./motion-trigger.sh --rtsp --webhook http://192.168.1.100:8080/motion
#
#   # Alta sensibilidad, detener stream a los 60s sin movimiento
#   ./motion-trigger.sh -u rtmp://localhost/live/cam --threshold 0.05 --stop-after 60

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Detección ---
THRESHOLD=0.15
INTERVAL=2
COOLDOWN=10
STOP_AFTER=30

# --- Stream ---
RTMP_URL_ARG="${RTMP_URL:-}"
STREAM_KEY_ARG="${STREAM_KEY:-}"
USE_RTSP=false
RTSP_HOST="localhost"
RTSP_PORT=8554
RTSP_NAME="cam"
WIDTH=1920
HEIGHT=1080
FPS=30
BITRATE=4500000
NO_AUDIO=false

# --- Notificación ---
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
        --cooldown)   COOLDOWN="$2"; shift 2 ;;
        --stop-after) STOP_AFTER="$2"; shift 2 ;;
        -u)           RTMP_URL_ARG="$2"; shift 2 ;;
        -k)           STREAM_KEY_ARG="$2"; shift 2 ;;
        --rtsp)       USE_RTSP=true; shift ;;
        --rtsp-host)  RTSP_HOST="$2"; shift 2 ;;
        --rtsp-port)  RTSP_PORT="$2"; shift 2 ;;
        --rtsp-name)  RTSP_NAME="$2"; shift 2 ;;
        -w)           WIDTH="$2"; shift 2 ;;
        -h)           HEIGHT="$2"; shift 2 ;;
        -f)           FPS="$2"; shift 2 ;;
        -b)           BITRATE="$2"; shift 2 ;;
        --no-audio)   NO_AUDIO=true; shift ;;
        --webhook)    WEBHOOK_URL="$2"; shift 2 ;;
        --log)        LOG_FILE="$2"; shift 2 ;;
        --help)       usage ;;
        *) die "Opción desconocida: $1. Usa --help para ver las opciones." ;;
    esac
done

# --- Validaciones ---
command -v ffmpeg >/dev/null 2>&1 || die "ffmpeg no encontrado. Instalar con: sudo apt install ffmpeg"
command -v bc >/dev/null 2>&1     || die "bc no encontrado. Instalar con: sudo apt install bc"

if command -v libcamera-jpeg >/dev/null 2>&1; then
    CAM_STILL="libcamera-jpeg"
elif command -v libcamera-still >/dev/null 2>&1; then
    CAM_STILL="libcamera-still"
else
    die "libcamera-jpeg/libcamera-still no encontrado. Instalar con: sudo apt install libcamera-apps"
fi

command -v libcamera-vid >/dev/null 2>&1 || die "libcamera-vid no encontrado."

# Construir URL de destino
if [[ "$USE_RTSP" == true ]]; then
    STREAM_URL="rtsp://${RTSP_HOST}:${RTSP_PORT}/${RTSP_NAME}"
    STREAM_FORMAT="rtsp"
    STREAM_TRANSPORT="-rtsp_transport tcp"
else
    [[ -n "$STREAM_KEY_ARG" ]] && RTMP_URL_ARG="${RTMP_URL_ARG%/}/${STREAM_KEY_ARG}"
    [[ -n "$RTMP_URL_ARG" ]] || die "URL requerida. Usar -u URL, --rtsp, o variable RTMP_URL."
    STREAM_URL="$RTMP_URL_ARG"
    STREAM_FORMAT="flv"
    STREAM_TRANSPORT=""
fi

# --- Variables de estado ---
TMPDIR_MOTION=$(mktemp -d)
trap "cleanup_all" EXIT INT TERM

STREAM_PID_FILE="${TMPDIR_MOTION}/stream.pid"
PREV_FRAME="${TMPDIR_MOTION}/prev.jpg"
CURR_FRAME="${TMPDIR_MOTION}/curr.jpg"

STREAM_ACTIVE=false
LAST_MOTION_TIME=0
LAST_ACTIVATION_TIME=0

# --- Limpieza al salir ---
cleanup_all() {
    log "Deteniendo motion-trigger..."
    stop_stream
    rm -rf "$TMPDIR_MOTION"
}

# --- Captura de frame de análisis (baja resolución) ---
capture_analysis_frame() {
    $CAM_STILL \
        --width 320 --height 240 \
        --nopreview \
        --timeout 200 \
        --output "$1" \
        2>/dev/null
}

# --- Diferencia entre frames ---
frame_diff() {
    local score
    score=$(ffmpeg \
        -hide_banner -loglevel quiet \
        -i "$1" -i "$2" \
        -filter_complex "[0:v][1:v]blend=all_mode=difference,blackframe=98:32" \
        -f null - 2>&1 \
        | grep "blackframe" \
        | awk '{for(i=1;i<=NF;i++) if($i~/^pblack/) {split($i,a,":");print 1-a[2]/100; exit}}')
    echo "${score:-0}"
}

# --- Iniciar stream en background ---
start_stream() {
    if [[ "$STREAM_ACTIVE" == true ]]; then
        return
    fi

    log "Iniciando stream → ${STREAM_URL}"

    local audio_args=()
    if [[ "$NO_AUDIO" == true ]]; then
        audio_args=(-an)
    else
        audio_args=(-f alsa -i hw:0 -acodec aac -b:a 128000)
    fi

    libcamera-vid \
        --width "$WIDTH" \
        --height "$HEIGHT" \
        --framerate "$FPS" \
        --bitrate "$BITRATE" \
        --codec h264 \
        --inline \
        --timeout 0 \
        --output - \
    | ffmpeg \
        -hide_banner -loglevel warning \
        -re -i - \
        "${audio_args[@]}" \
        -vcodec copy \
        -f "$STREAM_FORMAT" \
        $STREAM_TRANSPORT \
        "$STREAM_URL" &

    # Guardar PID del grupo de procesos del pipeline
    echo "$!" > "$STREAM_PID_FILE"
    STREAM_ACTIVE=true

    notify_event "stream_start"
    log "Stream activo (PID: $!)"
}

# --- Detener stream ---
stop_stream() {
    if [[ "$STREAM_ACTIVE" == false ]]; then
        return
    fi

    if [[ -f "$STREAM_PID_FILE" ]]; then
        local pid
        pid=$(cat "$STREAM_PID_FILE")
        # Matar el grupo de procesos (libcamera-vid + ffmpeg en el pipeline)
        kill "$pid" 2>/dev/null || true
        # También matar libcamera-vid que puede quedar huérfano
        pkill -f "libcamera-vid" 2>/dev/null || true
        rm -f "$STREAM_PID_FILE"
    fi

    STREAM_ACTIVE=false
    notify_event "stream_stop"
    log "Stream detenido."
}

# --- Notificación webhook ---
notify_event() {
    local event="$1"
    if [[ -n "$WEBHOOK_URL" ]]; then
        curl -s -X POST "$WEBHOOK_URL" \
            -H "Content-Type: application/json" \
            -d "{\"event\":\"${event}\",\"timestamp\":\"$(date -Iseconds)\",\"source\":\"motion-trigger\"}" \
            >/dev/null 2>&1 &
    fi
}

# --- Resumen de configuración ---
log "=== motion-trigger iniciado ==="
log "  Umbral      : ${THRESHOLD}"
log "  Intervalo   : ${INTERVAL}s"
log "  Cooldown    : ${COOLDOWN}s mínimo entre activaciones"
log "  Stop after  : ${STOP_AFTER}s sin movimiento"
log "  Stream      : ${STREAM_URL}"
log "  Resolución  : ${WIDTH}x${HEIGHT} @ ${FPS}fps"
[[ -n "$WEBHOOK_URL" ]] && log "  Webhook     : ${WEBHOOK_URL}"
log "==============================="

# Captura inicial de referencia
log "Capturando frame inicial..."
capture_analysis_frame "$PREV_FRAME" || die "No se pudo capturar frame inicial. Verificar cámara."
log "Listo. Monitoreando movimiento..."

# --- Bucle principal ---
while true; do
    sleep "$INTERVAL"

    if ! capture_analysis_frame "$CURR_FRAME" 2>/dev/null; then
        log "AVISO: fallo en captura, reintentando..."
        continue
    fi

    SCORE=$(frame_diff "$PREV_FRAME" "$CURR_FRAME")
    DETECTED=$(echo "$SCORE > $THRESHOLD" | bc -l 2>/dev/null || echo "0")
    NOW=$(date +%s)

    if [[ "$DETECTED" == "1" ]]; then
        LAST_MOTION_TIME="$NOW"
        SINCE_LAST=$(( NOW - LAST_ACTIVATION_TIME ))

        if [[ "$STREAM_ACTIVE" == false && "$SINCE_LAST" -ge "$COOLDOWN" ]]; then
            log "Movimiento detectado (score: ${SCORE}) — activando stream"
            LAST_ACTIVATION_TIME="$NOW"
            start_stream
        elif [[ "$STREAM_ACTIVE" == false ]]; then
            log "Movimiento detectado (score: ${SCORE}) — cooldown activo (${SINCE_LAST}s < ${COOLDOWN}s)"
        fi
    else
        if [[ "$STREAM_ACTIVE" == true ]]; then
            ELAPSED=$(( NOW - LAST_MOTION_TIME ))
            if [[ "$ELAPSED" -ge "$STOP_AFTER" ]]; then
                log "Sin movimiento por ${ELAPSED}s — deteniendo stream"
                stop_stream
            fi
        fi
    fi

    cp "$CURR_FRAME" "$PREV_FRAME"
done
