#!/usr/bin/env bash
# Transmite video en vivo desde la cámara de Raspberry Pi hacia un servidor RTMP.
# Usa encoding H264 por hardware (libcamera-vid) y ffmpeg para empaquetar el stream.
# Detecta automáticamente el micrófono USB si está conectado.
#
# Uso:
#   ./stream.sh [opciones] -u RTMP_URL
#
# Opciones de destino:
#   -u URL         URL RTMP destino (requerido, o variable RTMP_URL)
#   -k KEY         Stream key (se concatena a la URL si se pasa por separado)
#
# Opciones de video:
#   -w WIDTH       Ancho de video (default: 1920)
#   -h HEIGHT      Alto de video (default: 1080)
#   -f FPS         Frames por segundo (default: 30)
#   -b BITRATE     Bitrate de video en bits/s (default: 4500000)
#   -t SECONDS     Duración en segundos, 0 = indefinido (default: 0)
#
# Opciones de audio:
#   -a ABITRATE    Bitrate de audio en bits/s (default: 128000)
#   --audio-dev D  Dispositivo ALSA del micrófono (default: detección automática)
#   --audio-rate N Sample rate en Hz (default: 44100)
#   --audio-ch N   Canales 1=mono 2=stereo (default: 1)
#   --no-audio     Deshabilitar audio completamente
#
# Otras:
#   --help         Mostrar esta ayuda
#
# Variables de entorno:
#   RTMP_URL       URL RTMP completa (alternativa a -u)
#   STREAM_KEY     Stream key (alternativa a -k)
#   AUDIO_DEVICE   Dispositivo ALSA del micrófono (alternativa a --audio-dev)
#
# Ejemplos:
#   ./stream.sh -u rtmp://a.rtmp.youtube.com/live2/xxxx-xxxx-xxxx
#   ./stream.sh -u rtmp://a.rtmp.youtube.com/live2 -k xxxx-xxxx-xxxx
#   ./stream.sh -u rtmp://localhost/live/test --no-audio
#   ./stream.sh -u rtmp://localhost/live/test --audio-dev hw:1,0
#   RTMP_URL=rtmp://a.rtmp.youtube.com/live2/xxxx ./stream.sh
#
# Plataformas RTMP conocidas:
#   YouTube Live  : rtmp://a.rtmp.youtube.com/live2/<STREAM_KEY>
#   Facebook Live : rtmps://live-api-s.facebook.com:443/rtmp/<STREAM_KEY>
#   Servidor local: rtmp://localhost/live/<NOMBRE>
#
# Para detectar el dispositivo del micrófono USB:
#   ./audio-check.sh

set -euo pipefail

WIDTH=1920
HEIGHT=1080
FPS=30
BITRATE=4500000
AUDIO_BITRATE=128000
AUDIO_RATE=44100
AUDIO_CH=1
DURATION=0
URL="${RTMP_URL:-}"
KEY="${STREAM_KEY:-}"
AUDIO_DEV="${AUDIO_DEVICE:-}"
NO_AUDIO=false

usage() {
    grep '^#' "$0" | grep -v '#!/' | sed 's/^# \{0,1\}//'
    exit 0
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

# --- Detectar automáticamente el primer micrófono USB disponible ---
# Busca por palabras clave comunes de micrófonos USB y marcas conocidas (BOYA, etc.)
detect_usb_mic() {
    arecord -l 2>/dev/null \
        | grep -i "usb\|microphone\|mic\|webcam\|boya\|boyalink\|lavalier\|wireless\|focusrite\|scarlett" \
        | grep "^card" \
        | head -1 \
        | awk '{
            match($0, /card ([0-9]+).*device ([0-9]+)/, arr);
            if (arr[1] != "" && arr[2] != "")
                print "plughw:" arr[1] "," arr[2]
        }' || true
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -u)           URL="$2"; shift 2 ;;
        -k)           KEY="$2"; shift 2 ;;
        -w)           WIDTH="$2"; shift 2 ;;
        -h)           HEIGHT="$2"; shift 2 ;;
        -f)           FPS="$2"; shift 2 ;;
        -b)           BITRATE="$2"; shift 2 ;;
        -a)           AUDIO_BITRATE="$2"; shift 2 ;;
        --audio-dev)  AUDIO_DEV="$2"; shift 2 ;;
        --audio-rate) AUDIO_RATE="$2"; shift 2 ;;
        --audio-ch)   AUDIO_CH="$2"; shift 2 ;;
        -t)           DURATION="$2"; shift 2 ;;
        --no-audio)   NO_AUDIO=true; shift ;;
        --help)       usage ;;
        *) die "Opción desconocida: $1. Usa --help para ver las opciones." ;;
    esac
done

command -v libcamera-vid >/dev/null 2>&1 || die "libcamera-vid no encontrado. Instalar con: sudo apt install libcamera-apps"
command -v ffmpeg >/dev/null 2>&1         || die "ffmpeg no encontrado. Instalar con: sudo apt install ffmpeg"

[[ "$WIDTH" =~ ^[0-9]+$ ]]         || die "Ancho inválido: $WIDTH"
[[ "$HEIGHT" =~ ^[0-9]+$ ]]        || die "Alto inválido: $HEIGHT"
[[ "$FPS" =~ ^[0-9]+$ ]]           || die "FPS inválido: $FPS"
[[ "$BITRATE" =~ ^[0-9]+$ ]]       || die "Bitrate inválido: $BITRATE"
[[ "$AUDIO_BITRATE" =~ ^[0-9]+$ ]] || die "Bitrate de audio inválido: $AUDIO_BITRATE"
[[ "$DURATION" =~ ^[0-9]+$ ]]      || die "Duración inválida: $DURATION"

if [[ -n "$KEY" ]]; then
    URL="${URL%/}/${KEY}"
fi
[[ -n "$URL" ]] || die "URL RTMP requerida. Usar -u URL o variable de entorno RTMP_URL."

DURATION_MS=$(( DURATION * 1000 ))

# --- Resolver dispositivo de audio ---
if [[ "$NO_AUDIO" == false ]]; then
    if [[ -z "$AUDIO_DEV" ]]; then
        AUDIO_DEV=$(detect_usb_mic)
        if [[ -n "$AUDIO_DEV" ]]; then
            echo "Micrófono USB detectado: ${AUDIO_DEV}"
        else
            echo "AVISO: No se detectó micrófono USB. Usando audio interno (hw:0)."
            echo "       Si no hay audio interno, usar --no-audio."
            AUDIO_DEV="hw:0"
        fi
    fi
    AUDIO_ARGS=(-f alsa -ar "$AUDIO_RATE" -ac "$AUDIO_CH" -i "$AUDIO_DEV" -acodec aac -b:a "${AUDIO_BITRATE}")
else
    AUDIO_ARGS=(-an)
fi

echo "=== Stream RTMP ==="
echo "  Resolución  : ${WIDTH}x${HEIGHT}"
echo "  FPS         : ${FPS}"
echo "  Bitrate     : ${BITRATE} bps ($(( BITRATE / 1000 )) kbps)"
if [[ "$NO_AUDIO" == true ]]; then
    echo "  Audio       : deshabilitado"
else
    echo "  Audio       : ${AUDIO_DEV} — AAC ${AUDIO_BITRATE} bps — ${AUDIO_RATE}Hz ${AUDIO_CH}ch"
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
