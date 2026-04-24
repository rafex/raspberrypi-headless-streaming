#!/usr/bin/env bash
# Transmite video en vivo desde la cámara de Raspberry Pi hacia un servidor RTMP.
# Usa encoding H264 por hardware (libcamera-vid) y ffmpeg para empaquetar el stream.
#
# Uso:
#   ./stream.sh [opciones] -u RTMP_URL
#
# Opciones:
#   -u URL       URL RTMP destino (requerido, o variable RTMP_URL)
#   -k KEY       Stream key (se concatena a la URL si se pasa por separado)
#   -w WIDTH     Ancho de video (default: 1920)
#   -h HEIGHT    Alto de video (default: 1080)
#   -f FPS       Frames por segundo (default: 30)
#   -b BITRATE   Bitrate de video en bits/s (default: 4500000)
#   -a ABITRATE  Bitrate de audio en bits/s (default: 128000)
#   -t SECONDS   Duración en segundos, 0 = indefinido (default: 0)
#   --no-audio   Deshabilitar audio (útil si no hay micrófono)
#   --help       Mostrar esta ayuda
#
# Variables de entorno:
#   RTMP_URL     URL RTMP completa (alternativa a -u)
#   STREAM_KEY   Stream key (alternativa a -k)
#
# Ejemplos:
#   ./stream.sh -u rtmp://a.rtmp.youtube.com/live2/xxxx-xxxx-xxxx
#   ./stream.sh -u rtmp://a.rtmp.youtube.com/live2 -k xxxx-xxxx-xxxx
#   ./stream.sh -u rtmp://localhost/live/test --no-audio
#   RTMP_URL=rtmp://a.rtmp.youtube.com/live2/xxxx ./stream.sh
#
# Plataformas RTMP conocidas:
#   YouTube Live  : rtmp://a.rtmp.youtube.com/live2/<STREAM_KEY>
#   Facebook Live : rtmps://live-api-s.facebook.com:443/rtmp/<STREAM_KEY>
#   Servidor local: rtmp://localhost/live/<NOMBRE>

set -euo pipefail

# --- Valores por defecto ---
WIDTH=1920
HEIGHT=1080
FPS=30
BITRATE=4500000
AUDIO_BITRATE=128000
DURATION=0
URL="${RTMP_URL:-}"
KEY="${STREAM_KEY:-}"
NO_AUDIO=false

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
        -u) URL="$2"; shift 2 ;;
        -k) KEY="$2"; shift 2 ;;
        -w) WIDTH="$2"; shift 2 ;;
        -h) HEIGHT="$2"; shift 2 ;;
        -f) FPS="$2"; shift 2 ;;
        -b) BITRATE="$2"; shift 2 ;;
        -a) AUDIO_BITRATE="$2"; shift 2 ;;
        -t) DURATION="$2"; shift 2 ;;
        --no-audio) NO_AUDIO=true; shift ;;
        --help) usage ;;
        *) die "Opción desconocida: $1. Usa --help para ver las opciones." ;;
    esac
done

# --- Validaciones ---
command -v libcamera-vid >/dev/null 2>&1 || die "libcamera-vid no encontrado. Instalar con: sudo apt install libcamera-apps"
command -v ffmpeg >/dev/null 2>&1         || die "ffmpeg no encontrado. Instalar con: sudo apt install ffmpeg"

[[ "$WIDTH" =~ ^[0-9]+$ ]]         || die "Ancho inválido: $WIDTH"
[[ "$HEIGHT" =~ ^[0-9]+$ ]]        || die "Alto inválido: $HEIGHT"
[[ "$FPS" =~ ^[0-9]+$ ]]           || die "FPS inválido: $FPS"
[[ "$BITRATE" =~ ^[0-9]+$ ]]       || die "Bitrate inválido: $BITRATE"
[[ "$AUDIO_BITRATE" =~ ^[0-9]+$ ]] || die "Bitrate de audio inválido: $AUDIO_BITRATE"
[[ "$DURATION" =~ ^[0-9]+$ ]]      || die "Duración inválida: $DURATION"

# Concatenar key a URL si se pasó por separado
if [[ -n "$KEY" ]]; then
    URL="${URL%/}/${KEY}"
fi

[[ -n "$URL" ]] || die "URL RTMP requerida. Usar -u URL o variable de entorno RTMP_URL."

# Duración en milisegundos para libcamera (0 = indefinido)
DURATION_MS=$(( DURATION * 1000 ))

# --- Construir argumentos de audio para ffmpeg ---
if [[ "$NO_AUDIO" == true ]]; then
    AUDIO_ARGS=(-an)
else
    AUDIO_ARGS=(-f alsa -i hw:0 -acodec aac -b:a "${AUDIO_BITRATE}")
fi

# --- Información antes de transmitir ---
echo "=== Stream RTMP ==="
echo "  Resolución  : ${WIDTH}x${HEIGHT}"
echo "  FPS         : ${FPS}"
echo "  Bitrate     : ${BITRATE} bps ($(( BITRATE / 1000 )) kbps)"
if [[ "$NO_AUDIO" == true ]]; then
    echo "  Audio       : deshabilitado"
else
    echo "  Audio       : AAC ${AUDIO_BITRATE} bps"
fi
if [[ "$DURATION" -eq 0 ]]; then
    echo "  Duración    : indefinida (Ctrl+C para detener)"
else
    echo "  Duración    : ${DURATION}s"
fi
echo "  Destino     : ${URL}"
echo "==================="
echo ""

# --- Pipeline: libcamera-vid → ffmpeg → RTMP ---
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
    -f flv \
    "$URL"
