#!/usr/bin/env bash
# Extrae frames JPEG desde la cámara o desde un stream RTSP a intervalos regulares.
# Diseñado para alimentar un pipeline de análisis con IA (Pi 4B / LLM).
#
# Modos de operación:
#   --camera   Captura directamente desde la cámara (default)
#   --rtsp URL Extrae frames desde un stream RTSP existente
#
# Uso:
#   ./frame-extract.sh [opciones]
#
# Opciones:
#   --camera         Capturar desde cámara directamente (default)
#   --rtsp URL       Extraer desde stream RTSP
#   --interval N     Segundos entre frames (default: 5)
#   --output DIR     Directorio de salida (default: /tmp/frames)
#   --keep N         Mantener solo los últimos N frames (0 = todos, default: 10)
#   --width N        Ancho del frame (default: 1280)
#   --height N       Alto del frame (default: 720)
#   --quality N      Calidad JPEG 1-100 (default: 85)
#   --on-frame CMD   Comando a ejecutar con cada frame (se pasa la ruta como $1)
#   --count N        Extraer solo N frames y salir (0 = indefinido, default: 0)
#   --help           Mostrar esta ayuda
#
# Ejemplos:
#   # Extraer un frame cada 5s desde la cámara
#   ./frame-extract.sh
#
#   # Extraer desde RTSP y enviar a Pi 4B
#   ./frame-extract.sh --rtsp rtsp://localhost:8554/cam \
#       --on-frame "scripts/send-event.sh --frame"
#
#   # Extraer 1 frame inmediato y salir (útil para scripts)
#   ./frame-extract.sh --count 1 --output /tmp

set -euo pipefail

MODE="camera"
RTSP_URL=""
INTERVAL=5
OUTPUT_DIR="/tmp/frames"
KEEP=10
FRAME_WIDTH=1280
FRAME_HEIGHT=720
QUALITY=85
ON_FRAME_CMD=""
COUNT=0

usage() {
    grep '^#' "$0" | grep -v '#!/' | sed 's/^# \{0,1\}//'
    exit 0
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --camera)    MODE="camera"; shift ;;
        --rtsp)      MODE="rtsp"; RTSP_URL="$2"; shift 2 ;;
        --interval)  INTERVAL="$2"; shift 2 ;;
        --output)    OUTPUT_DIR="$2"; shift 2 ;;
        --keep)      KEEP="$2"; shift 2 ;;
        --width)     FRAME_WIDTH="$2"; shift 2 ;;
        --height)    FRAME_HEIGHT="$2"; shift 2 ;;
        --quality)   QUALITY="$2"; shift 2 ;;
        --on-frame)  ON_FRAME_CMD="$2"; shift 2 ;;
        --count)     COUNT="$2"; shift 2 ;;
        --help)      usage ;;
        *) die "Opción desconocida: $1. Usa --help para ver las opciones." ;;
    esac
done

command -v ffmpeg >/dev/null 2>&1 || die "ffmpeg no encontrado. Instalar con: sudo apt install ffmpeg"

if [[ "$MODE" == "camera" ]]; then
    if command -v libcamera-jpeg >/dev/null 2>&1; then
        CAM_CMD="libcamera-jpeg"
    elif command -v libcamera-still >/dev/null 2>&1; then
        CAM_CMD="libcamera-still"
    else
        die "libcamera-jpeg/libcamera-still no encontrado. Instalar con: sudo apt install libcamera-apps"
    fi
fi

if [[ "$MODE" == "rtsp" ]]; then
    [[ -n "$RTSP_URL" ]] || die "URL RTSP requerida con --rtsp."
fi

mkdir -p "$OUTPUT_DIR"

echo "=== Extracción de frames ==="
echo "  Modo        : ${MODE}"
[[ "$MODE" == "rtsp" ]] && echo "  RTSP URL    : ${RTSP_URL}"
echo "  Intervalo   : ${INTERVAL}s"
echo "  Resolución  : ${FRAME_WIDTH}x${FRAME_HEIGHT}"
echo "  Calidad     : ${QUALITY}%"
echo "  Salida      : ${OUTPUT_DIR}"
[[ "$KEEP" -gt 0 ]] && echo "  Retención   : últimos ${KEEP} frames"
[[ "$COUNT" -gt 0 ]] && echo "  Límite      : ${COUNT} frames"
[[ -n "$ON_FRAME_CMD" ]] && echo "  Por frame   : ${ON_FRAME_CMD}"
echo "==========================="
echo ""

# --- Limpiar frames antiguos ---
rotate_frames() {
    if [[ "$KEEP" -gt 0 ]]; then
        local total
        total=$(find "$OUTPUT_DIR" -name "frame_*.jpg" | wc -l)
        if [[ "$total" -gt "$KEEP" ]]; then
            find "$OUTPUT_DIR" -name "frame_*.jpg" \
                | sort \
                | head -n $(( total - KEEP )) \
                | xargs rm -f
        fi
    fi
}

# --- Capturar un frame desde la cámara ---
capture_from_camera() {
    local output="$1"
    $CAM_CMD \
        --width "$FRAME_WIDTH" \
        --height "$FRAME_HEIGHT" \
        --quality "$QUALITY" \
        --nopreview \
        --timeout 500 \
        --output "$output" \
        2>/dev/null
}

# --- Extraer un frame desde stream RTSP ---
capture_from_rtsp() {
    local output="$1"
    ffmpeg \
        -hide_banner \
        -loglevel warning \
        -rtsp_transport tcp \
        -i "$RTSP_URL" \
        -frames:v 1 \
        -vf "scale=${FRAME_WIDTH}:${FRAME_HEIGHT}" \
        -q:v "$(( (100 - QUALITY) * 31 / 100 + 1 ))" \
        -y "$output" \
        2>/dev/null
}

FRAME_IDX=0

while true; do
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    FRAME_PATH="${OUTPUT_DIR}/frame_${TIMESTAMP}.jpg"

    if [[ "$MODE" == "camera" ]]; then
        if ! capture_from_camera "$FRAME_PATH"; then
            echo "[$(date '+%H:%M:%S')] AVISO: fallo en captura, reintentando..."
            sleep 1
            continue
        fi
    else
        if ! capture_from_rtsp "$FRAME_PATH"; then
            echo "[$(date '+%H:%M:%S')] AVISO: fallo al extraer frame de RTSP, reintentando..."
            sleep 1
            continue
        fi
    fi

    SIZE=$(du -sh "$FRAME_PATH" 2>/dev/null | cut -f1 || echo "?")
    echo "[$(date '+%H:%M:%S')] Frame: ${FRAME_PATH} (${SIZE})"

    # Ejecutar comando por frame si se especificó
    if [[ -n "$ON_FRAME_CMD" ]]; then
        eval "$ON_FRAME_CMD \"$FRAME_PATH\"" &
    fi

    rotate_frames

    (( FRAME_IDX++ )) || true

    if [[ "$COUNT" -gt 0 && "$FRAME_IDX" -ge "$COUNT" ]]; then
        echo "Límite de ${COUNT} frame(s) alcanzado."
        break
    fi

    sleep "$INTERVAL"
done
