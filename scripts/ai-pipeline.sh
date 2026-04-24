#!/usr/bin/env bash
# Orquestador completo: detección de movimiento → extracción de frame → análisis LLM.
# Integra motion-detect.sh, frame-extract.sh y send-event.sh en un único pipeline.
#
# Pipeline:
#   libcamera-jpeg (baja res) → frame-diff
#       movimiento → libcamera-jpeg (alta res) → base64 → POST /analyze (Pi 4B)
#                 → stream RTSP/RTMP (opcional, simultáneo)
#       respuesta LLM → log local + webhook
#
# Uso:
#   ./ai-pipeline.sh [opciones]
#
# Opciones de servidor IA:
#   --ai-host H      Host del servidor IA en Pi 4B (requerido, o variable AI_HOST)
#   --ai-port P      Puerto del servidor IA (default: 8080)
#   --ai-path PATH   Ruta del endpoint de análisis (default: /analyze)
#
# Opciones de detección:
#   --threshold N    Umbral de cambio entre frames (default: 0.15)
#   --interval N     Segundos entre capturas de análisis (default: 2)
#   --cooldown N     Segundos mínimos entre análisis LLM (default: 15)
#
# Opciones de frame para IA:
#   --frame-width N  Ancho del frame enviado al LLM (default: 1280)
#   --frame-height N Alto del frame enviado al LLM (default: 720)
#   --frame-quality N Calidad JPEG 1-100 (default: 85)
#
# Opciones de stream (opcional):
#   --stream         Activar stream RTSP simultáneo al detectar movimiento
#   --rtsp-host H    Host mediamtx (default: localhost)
#   --rtsp-port P    Puerto RTSP (default: 8554)
#   --rtsp-name N    Nombre del path (default: cam)
#   --stop-after N   Segundos sin movimiento para detener stream (default: 30)
#
# Otras:
#   --log FILE       Archivo de log (default: stdout)
#   --help           Mostrar esta ayuda
#
# Variables de entorno:
#   AI_HOST          Host del servidor IA
#   AI_PORT          Puerto
#   AI_PATH          Ruta del endpoint
#
# Ejemplos:
#   ./ai-pipeline.sh --ai-host 192.168.1.100
#   ./ai-pipeline.sh --ai-host 192.168.1.100 --stream --threshold 0.10
#   AI_HOST=192.168.1.100 ./ai-pipeline.sh --log /var/log/ai-pipeline.log

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Servidor IA ---
AI_HOST="${AI_HOST:-}"
AI_PORT="${AI_PORT:-8080}"
AI_PATH="${AI_PATH:-/analyze}"

# --- Detección ---
THRESHOLD=0.15
INTERVAL=2
COOLDOWN=15

# --- Frame para IA ---
FRAME_WIDTH=1280
FRAME_HEIGHT=720
FRAME_QUALITY=85

# --- Stream ---
ENABLE_STREAM=false
RTSP_HOST="localhost"
RTSP_PORT=8554
RTSP_NAME="cam"
STOP_AFTER=30

# --- General ---
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
        --ai-host)      AI_HOST="$2"; shift 2 ;;
        --ai-port)      AI_PORT="$2"; shift 2 ;;
        --ai-path)      AI_PATH="$2"; shift 2 ;;
        --threshold)    THRESHOLD="$2"; shift 2 ;;
        --interval)     INTERVAL="$2"; shift 2 ;;
        --cooldown)     COOLDOWN="$2"; shift 2 ;;
        --frame-width)  FRAME_WIDTH="$2"; shift 2 ;;
        --frame-height) FRAME_HEIGHT="$2"; shift 2 ;;
        --frame-quality) FRAME_QUALITY="$2"; shift 2 ;;
        --stream)       ENABLE_STREAM=true; shift ;;
        --rtsp-host)    RTSP_HOST="$2"; shift 2 ;;
        --rtsp-port)    RTSP_PORT="$2"; shift 2 ;;
        --rtsp-name)    RTSP_NAME="$2"; shift 2 ;;
        --stop-after)   STOP_AFTER="$2"; shift 2 ;;
        --log)          LOG_FILE="$2"; shift 2 ;;
        --help)         usage ;;
        *) die "Opción desconocida: $1. Usa --help para ver las opciones." ;;
    esac
done

# --- Validaciones ---
[[ -n "$AI_HOST" ]] || die "Host del servidor IA requerido. Usar --ai-host o variable AI_HOST."

command -v ffmpeg >/dev/null 2>&1  || die "ffmpeg no encontrado. Instalar con: sudo apt install ffmpeg"
command -v curl >/dev/null 2>&1    || die "curl no encontrado. Instalar con: sudo apt install curl"
command -v base64 >/dev/null 2>&1  || die "base64 no encontrado."
command -v bc >/dev/null 2>&1      || die "bc no encontrado. Instalar con: sudo apt install bc"

if command -v libcamera-jpeg >/dev/null 2>&1; then
    CAM_STILL="libcamera-jpeg"
elif command -v libcamera-still >/dev/null 2>&1; then
    CAM_STILL="libcamera-still"
else
    die "libcamera-jpeg/libcamera-still no encontrado. Instalar con: sudo apt install libcamera-apps"
fi

# --- Temporales ---
TMPDIR_AI=$(mktemp -d)
trap "cleanup_ai" EXIT INT TERM

PREV_FRAME="${TMPDIR_AI}/prev.jpg"
CURR_FRAME="${TMPDIR_AI}/curr.jpg"
ANALYSIS_FRAME="${TMPDIR_AI}/analysis.jpg"
STREAM_PID_FILE="${TMPDIR_AI}/stream.pid"

STREAM_ACTIVE=false
LAST_ANALYSIS_TIME=0
LAST_MOTION_TIME=0

cleanup_ai() {
    stop_stream_if_active
    rm -rf "$TMPDIR_AI"
}

# --- Captura de frame de análisis (baja res, rápido) ---
capture_detection_frame() {
    $CAM_STILL \
        --width 320 --height 240 \
        --nopreview --timeout 200 \
        --output "$1" 2>/dev/null
}

# --- Captura de frame de alta calidad para LLM ---
capture_analysis_frame() {
    $CAM_STILL \
        --width "$FRAME_WIDTH" \
        --height "$FRAME_HEIGHT" \
        --quality "$FRAME_QUALITY" \
        --nopreview --timeout 500 \
        --output "$1" 2>/dev/null
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

# --- Enviar frame al LLM ---
send_to_llm() {
    local frame_path="$1"
    local context="$2"
    local frame_b64

    frame_b64=$(base64 -w 0 "$frame_path" 2>/dev/null || base64 "$frame_path")
    local timestamp
    timestamp=$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')
    local safe_context
    safe_context=$(echo "$context" | sed 's/\\/\\\\/g; s/"/\\"/g')

    local payload
    payload=$(cat <<EOF
{
  "event": "motion_analysis",
  "source": "$(hostname 2>/dev/null || echo raspi-3b)",
  "timestamp": "${timestamp}",
  "context": "${safe_context}",
  "frame": "${frame_b64}"
}
EOF
)

    local response
    response=$(curl \
        --silent \
        --max-time 30 \
        --connect-timeout 5 \
        --retry 2 \
        --retry-delay 2 \
        -X POST "http://${AI_HOST}:${AI_PORT}${AI_PATH}" \
        -H "Content-Type: application/json" \
        -d "$payload" 2>&1) || {
        log "AVISO: sin respuesta del servidor IA (${AI_HOST}:${AI_PORT})"
        return
    }

    local analysis
    analysis=$(echo "$response" \
        | grep -o '"analysis"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | sed 's/"analysis"[[:space:]]*:[[:space:]]*"\(.*\)"/\1/' \
        || echo "")

    if [[ -n "$analysis" ]]; then
        log "[LLM] ${analysis}"
    else
        log "[LLM] ${response}"
    fi
}

# --- Stream RTSP ---
start_stream_if_inactive() {
    [[ "$ENABLE_STREAM" == false ]] && return
    [[ "$STREAM_ACTIVE" == true ]] && return

    log "Activando stream RTSP → rtsp://${RTSP_HOST}:${RTSP_PORT}/${RTSP_NAME}"

    libcamera-vid \
        --width 1920 --height 1080 \
        --framerate 30 \
        --codec h264 --inline \
        --timeout 0 --output - \
    | ffmpeg \
        -hide_banner -loglevel warning \
        -re -i - -an \
        -vcodec copy -f rtsp -rtsp_transport tcp \
        "rtsp://${RTSP_HOST}:${RTSP_PORT}/${RTSP_NAME}" &

    echo "$!" > "$STREAM_PID_FILE"
    STREAM_ACTIVE=true
}

stop_stream_if_active() {
    [[ "$STREAM_ACTIVE" == false ]] && return

    if [[ -f "$STREAM_PID_FILE" ]]; then
        local pid
        pid=$(cat "$STREAM_PID_FILE")
        kill "$pid" 2>/dev/null || true
        pkill -f "libcamera-vid" 2>/dev/null || true
        rm -f "$STREAM_PID_FILE"
    fi

    STREAM_ACTIVE=false
    log "Stream RTSP detenido."
}

# --- Resumen ---
log "=== AI Pipeline iniciado ==="
log "  Servidor IA : ${AI_HOST}:${AI_PORT}${AI_PATH}"
log "  Umbral      : ${THRESHOLD}"
log "  Intervalo   : ${INTERVAL}s"
log "  Cooldown IA : ${COOLDOWN}s entre análisis"
log "  Frame IA    : ${FRAME_WIDTH}x${FRAME_HEIGHT} Q${FRAME_QUALITY}"
if [[ "$ENABLE_STREAM" == true ]]; then
    log "  Stream RTSP : rtsp://${RTSP_HOST}:${RTSP_PORT}/${RTSP_NAME}"
    log "  Stop after  : ${STOP_AFTER}s sin movimiento"
fi
log "============================"

# Frame inicial de referencia
log "Capturando frame inicial..."
capture_detection_frame "$PREV_FRAME" || die "No se pudo capturar frame. Verificar cámara."
log "Listo. Monitoreando..."

# --- Bucle principal ---
while true; do
    sleep "$INTERVAL"

    if ! capture_detection_frame "$CURR_FRAME" 2>/dev/null; then
        log "AVISO: fallo en captura, reintentando..."
        continue
    fi

    SCORE=$(frame_diff "$PREV_FRAME" "$CURR_FRAME")
    DETECTED=$(echo "$SCORE > $THRESHOLD" | bc -l 2>/dev/null || echo "0")
    NOW=$(date +%s)

    if [[ "$DETECTED" == "1" ]]; then
        LAST_MOTION_TIME="$NOW"
        SINCE_LAST_ANALYSIS=$(( NOW - LAST_ANALYSIS_TIME ))

        log "Movimiento detectado (score: ${SCORE})"

        # Activar stream si está configurado
        start_stream_if_inactive

        # Enviar frame al LLM respetando cooldown
        if [[ "$SINCE_LAST_ANALYSIS" -ge "$COOLDOWN" ]]; then
            log "Capturando frame para análisis LLM..."
            if capture_analysis_frame "$ANALYSIS_FRAME"; then
                LAST_ANALYSIS_TIME="$NOW"
                send_to_llm "$ANALYSIS_FRAME" "Movimiento detectado (score: ${SCORE})" &
            fi
        else
            log "Cooldown IA activo (${SINCE_LAST_ANALYSIS}s / ${COOLDOWN}s)"
        fi
    else
        # Detener stream si no hay movimiento por STOP_AFTER segundos
        if [[ "$STREAM_ACTIVE" == true && "$LAST_MOTION_TIME" -gt 0 ]]; then
            ELAPSED=$(( NOW - LAST_MOTION_TIME ))
            if [[ "$ELAPSED" -ge "$STOP_AFTER" ]]; then
                log "Sin movimiento por ${ELAPSED}s"
                stop_stream_if_active
            fi
        fi
    fi

    cp "$CURR_FRAME" "$PREV_FRAME"
done
