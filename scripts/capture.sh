#!/usr/bin/env bash
# Captura video desde la cámara de Raspberry Pi a un archivo local.
# Usa encoding H264 por hardware del Video Core IV.
#
# Uso:
#   ./capture.sh [opciones]
#
# Opciones:
#   -o FILE      Archivo de salida (default: capture_YYYYMMDD_HHMMSS.h264)
#   -t SECONDS   Duración en segundos, 0 = indefinido (default: 0)
#   -w WIDTH     Ancho de video (default: 1920)
#   -h HEIGHT    Alto de video (default: 1080)
#   -f FPS       Frames por segundo (default: 30)
#   -b BITRATE   Bitrate en bits/s (default: 4500000)
#   --help       Mostrar esta ayuda
#
# Ejemplos:
#   ./capture.sh
#   ./capture.sh -t 60 -o mi_video.h264
#   ./capture.sh -w 1280 -h 720 -f 30 -t 120

set -euo pipefail

# --- Valores por defecto ---
WIDTH=1920
HEIGHT=1080
FPS=30
BITRATE=4500000
DURATION=0
OUTPUT=""

usage() {
    grep '^#' "$0" | grep -v '#!/' | sed 's/^# \{0,1\}//'
    exit 0
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

# --- Parseo de argumentos ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) OUTPUT="$2"; shift 2 ;;
        -t) DURATION="$2"; shift 2 ;;
        -w) WIDTH="$2"; shift 2 ;;
        -h) HEIGHT="$2"; shift 2 ;;
        -f) FPS="$2"; shift 2 ;;
        -b) BITRATE="$2"; shift 2 ;;
        --help) usage ;;
        *) die "Opción desconocida: $1. Usa --help para ver las opciones." ;;
    esac
done

# --- Validaciones ---
command -v libcamera-vid >/dev/null 2>&1 || die "libcamera-vid no encontrado. Instalar con: sudo apt install libcamera-apps"

[[ "$WIDTH" =~ ^[0-9]+$ ]]    || die "Ancho inválido: $WIDTH"
[[ "$HEIGHT" =~ ^[0-9]+$ ]]   || die "Alto inválido: $HEIGHT"
[[ "$FPS" =~ ^[0-9]+$ ]]      || die "FPS inválido: $FPS"
[[ "$BITRATE" =~ ^[0-9]+$ ]]  || die "Bitrate inválido: $BITRATE"
[[ "$DURATION" =~ ^[0-9]+$ ]] || die "Duración inválida: $DURATION"

# --- Nombre de archivo automático si no se especificó ---
if [[ -z "$OUTPUT" ]]; then
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    OUTPUT="capture_${TIMESTAMP}.h264"
fi

# Duración en milisegundos para libcamera (0 = indefinido)
DURATION_MS=$(( DURATION * 1000 ))

# --- Información antes de grabar ---
echo "=== Captura de video ==="
echo "  Resolución : ${WIDTH}x${HEIGHT}"
echo "  FPS        : ${FPS}"
echo "  Bitrate    : ${BITRATE} bps ($(( BITRATE / 1000 )) kbps)"
if [[ "$DURATION" -eq 0 ]]; then
    echo "  Duración   : indefinida (Ctrl+C para detener)"
else
    echo "  Duración   : ${DURATION}s"
fi
echo "  Salida     : ${OUTPUT}"
echo "========================"
echo ""

# --- Captura ---
libcamera-vid \
    --width "$WIDTH" \
    --height "$HEIGHT" \
    --framerate "$FPS" \
    --bitrate "$BITRATE" \
    --codec h264 \
    --timeout "$DURATION_MS" \
    --output "$OUTPUT"

echo ""
echo "Captura finalizada: ${OUTPUT}"

if [[ -f "$OUTPUT" ]]; then
    SIZE=$(du -sh "$OUTPUT" | cut -f1)
    echo "Tamaño del archivo: ${SIZE}"
fi
