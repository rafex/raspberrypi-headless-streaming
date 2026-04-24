#!/usr/bin/env bash
# Transmite video en vivo hacia un servidor RTSP local (mediamtx).
# Útil para consumo interno en red local sin depender de plataformas externas.
# Otros dispositivos en la misma red pueden ver el stream con cualquier cliente RTSP.
#
# Requiere: mediamtx corriendo en el mismo host o en la red local.
# Instalar: scripts/mediamtx-install.sh
#
# Uso:
#   ./stream-rtsp.sh [opciones]
#
# Opciones:
#   -s HOST      Host del servidor RTSP (default: localhost)
#   -p PORT      Puerto RTSP (default: 8554)
#   -n NAME      Nombre del stream/path (default: cam)
#   -w WIDTH     Ancho de video (default: 1920)
#   -h HEIGHT    Alto de video (default: 1080)
#   -f FPS       Frames por segundo (default: 30)
#   -b BITRATE   Bitrate en bits/s (default: 4500000)
#   -t SECONDS   Duración en segundos, 0 = indefinido (default: 0)
#   --no-audio   Deshabilitar audio
#   --help       Mostrar esta ayuda
#
# Variables de entorno:
#   RTSP_HOST    Host del servidor (default: localhost)
#   RTSP_PORT    Puerto RTSP (default: 8554)
#   RTSP_NAME    Nombre del path (default: cam)
#
# Ejemplos:
#   ./stream-rtsp.sh
#   ./stream-rtsp.sh -n entrada -s 192.168.1.100
#   ./stream-rtsp.sh -n cam1 -w 1280 -h 720 -f 25
#   RTSP_NAME=sala ./stream-rtsp.sh
#
# Consumir el stream desde otro dispositivo:
#   vlc rtsp://IP_DE_LA_PI:8554/cam
#   ffplay rtsp://IP_DE_LA_PI:8554/cam
#   mpv rtsp://IP_DE_LA_PI:8554/cam

set -euo pipefail

HOST="${RTSP_HOST:-localhost}"
PORT="${RTSP_PORT:-8554}"
NAME="${RTSP_NAME:-cam}"
WIDTH=1920
HEIGHT=1080
FPS=30
BITRATE=4500000
DURATION=0
NO_AUDIO=false

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
        -s)        HOST="$2"; shift 2 ;;
        -p)        PORT="$2"; shift 2 ;;
        -n)        NAME="$2"; shift 2 ;;
        -w)        WIDTH="$2"; shift 2 ;;
        -h)        HEIGHT="$2"; shift 2 ;;
        -f)        FPS="$2"; shift 2 ;;
        -b)        BITRATE="$2"; shift 2 ;;
        -t)        DURATION="$2"; shift 2 ;;
        --no-audio) NO_AUDIO=true; shift ;;
        --help)    usage ;;
        *) die "Opción desconocida: $1. Usa --help para ver las opciones." ;;
    esac
done

command -v libcamera-vid >/dev/null 2>&1 || die "libcamera-vid no encontrado. Instalar con: sudo apt install libcamera-apps"
command -v ffmpeg >/dev/null 2>&1         || die "ffmpeg no encontrado. Instalar con: sudo apt install ffmpeg"

[[ "$WIDTH" =~ ^[0-9]+$ ]]    || die "Ancho inválido: $WIDTH"
[[ "$HEIGHT" =~ ^[0-9]+$ ]]   || die "Alto inválido: $HEIGHT"
[[ "$FPS" =~ ^[0-9]+$ ]]      || die "FPS inválido: $FPS"
[[ "$BITRATE" =~ ^[0-9]+$ ]]  || die "Bitrate inválido: $BITRATE"
[[ "$DURATION" =~ ^[0-9]+$ ]] || die "Duración inválida: $DURATION"
[[ "$PORT" =~ ^[0-9]+$ ]]     || die "Puerto inválido: $PORT"

RTSP_URL="rtsp://${HOST}:${PORT}/${NAME}"
DURATION_MS=$(( DURATION * 1000 ))

if [[ "$NO_AUDIO" == true ]]; then
    AUDIO_ARGS=(-an)
else
    AUDIO_ARGS=(-f alsa -i hw:0 -acodec aac -b:a 128000)
fi

# Verificar que mediamtx está accesible
if ! nc -z "$HOST" "$PORT" 2>/dev/null; then
    echo "AVISO: No se puede conectar a ${HOST}:${PORT}"
    echo "       Asegurarse de que mediamtx está corriendo:"
    echo "         scripts/control.sh start mediamtx"
    echo "         o: sudo systemctl start mediamtx"
    echo ""
fi

echo "=== Stream RTSP ==="
echo "  Resolución  : ${WIDTH}x${HEIGHT}"
echo "  FPS         : ${FPS}"
echo "  Bitrate     : ${BITRATE} bps ($(( BITRATE / 1000 )) kbps)"
if [[ "$NO_AUDIO" == true ]]; then
    echo "  Audio       : deshabilitado"
else
    echo "  Audio       : AAC 128kbps"
fi
if [[ "$DURATION" -eq 0 ]]; then
    echo "  Duración    : indefinida (Ctrl+C para detener)"
else
    echo "  Duración    : ${DURATION}s"
fi
echo "  Servidor    : ${HOST}:${PORT}"
echo "  URL         : ${RTSP_URL}"
echo "==================="
echo ""
echo "Para ver el stream desde otro dispositivo:"
echo "  vlc ${RTSP_URL}"
echo "  ffplay ${RTSP_URL}"
echo ""

# --- Pipeline: libcamera-vid → ffmpeg → RTSP ---
libcamera-vid \
    --width "$WIDTH" \
    --height "$HEIGHT" \
    --framerate "$FPS" \
    --bitrate "$BITRATE" \
    --codec h264 \
    --inline \
    --timeout "$DURATION_MS" \
    --output - \
| ffmpeg \
    -hide_banner \
    -loglevel warning \
    -re \
    -i - \
    "${AUDIO_ARGS[@]}" \
    -vcodec copy \
    -f rtsp \
    -rtsp_transport tcp \
    "$RTSP_URL"
