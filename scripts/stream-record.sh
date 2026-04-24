#!/usr/bin/env bash
# Graba y transmite video simultáneamente usando un pipe con tee.
# El stream H264 del hardware se divide sin overhead adicional de CPU:
# una copia se guarda en disco y otra se envía a ffmpeg para RTMP.
#
# Pipeline:
#   libcamera-vid → tee → archivo .h264
#                      └→ ffmpeg → RTMP
#
# Uso:
#   ./stream-record.sh [opciones] -u RTMP_URL
#
# Opciones de destino:
#   -u URL         URL RTMP destino (requerido, o variable RTMP_URL)
#   -k KEY         Stream key (se concatena a la URL)
#
# Opciones de video:
#   -w WIDTH       Ancho (default: 1920)
#   -h HEIGHT      Alto (default: 1080)
#   -f FPS         Frames por segundo (default: 30)
#   -b BITRATE     Bitrate en bits/s (default: 4500000)
#
# Opciones de grabación:
#   -o FILE        Archivo local de salida (default: record_YYYYMMDD_HHMMSS.h264)
#   --mp4          Convertir grabación a MP4 al finalizar (requiere ffmpeg)
#   --keep-h264    Mantener el H264 original al usar --mp4 (default: se elimina)
#
# Opciones de audio:
#   -a ABITRATE    Bitrate de audio en bits/s (default: 128000)
#   --no-audio     Deshabilitar audio en el stream RTMP
#
# Otras:
#   -t SECONDS     Duración en segundos, 0 = indefinido (default: 0)
#   --help         Mostrar esta ayuda
#
# Variables de entorno:
#   RTMP_URL       URL RTMP completa
#   STREAM_KEY     Stream key
#
# Ejemplos:
#   ./stream-record.sh -u rtmp://a.rtmp.youtube.com/live2/KEY
#   ./stream-record.sh -u rtmp://localhost/live/test -o sesion.h264 --mp4
#   ./stream-record.sh -u rtmp://localhost/live/test -t 3600 --no-audio
#
# Uso de disco estimado (4.5 Mbps):
#   1 minuto  ~34 MB
#   1 hora    ~2.0 GB

set -euo pipefail

WIDTH=1920
HEIGHT=1080
FPS=30
BITRATE=4500000
AUDIO_BITRATE=128000
DURATION=0
OUTPUT=""
URL="${RTMP_URL:-}"
KEY="${STREAM_KEY:-}"
NO_AUDIO=false
CONVERT_MP4=false
KEEP_H264=false

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
        -u)           URL="$2"; shift 2 ;;
        -k)           KEY="$2"; shift 2 ;;
        -w)           WIDTH="$2"; shift 2 ;;
        -h)           HEIGHT="$2"; shift 2 ;;
        -f)           FPS="$2"; shift 2 ;;
        -b)           BITRATE="$2"; shift 2 ;;
        -a)           AUDIO_BITRATE="$2"; shift 2 ;;
        -t)           DURATION="$2"; shift 2 ;;
        -o)           OUTPUT="$2"; shift 2 ;;
        --mp4)        CONVERT_MP4=true; shift ;;
        --keep-h264)  KEEP_H264=true; shift ;;
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

if [[ -z "$OUTPUT" ]]; then
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    OUTPUT="record_${TIMESTAMP}.h264"
fi

# El archivo MP4 final usa el mismo nombre base
MP4_OUTPUT="${OUTPUT%.h264}.mp4"

DURATION_MS=$(( DURATION * 1000 ))

PER_MIN=$(( BITRATE * 60 / 8 / 1024 / 1024 ))

if [[ "$NO_AUDIO" == true ]]; then
    AUDIO_ARGS=(-an)
else
    AUDIO_ARGS=(-f alsa -i hw:0 -acodec aac -b:a "${AUDIO_BITRATE}")
fi

echo "=== Stream + Grabación simultánea ==="
echo "  Resolución  : ${WIDTH}x${HEIGHT}"
echo "  FPS         : ${FPS}"
echo "  Bitrate     : ${BITRATE} bps ($(( BITRATE / 1000 )) kbps)"
if [[ "$NO_AUDIO" == true ]]; then
    echo "  Audio       : deshabilitado"
else
    echo "  Audio RTMP  : AAC ${AUDIO_BITRATE} bps"
fi
if [[ "$DURATION" -eq 0 ]]; then
    echo "  Duración    : indefinida (Ctrl+C para detener)"
else
    echo "  Duración    : ${DURATION}s"
fi
echo "  Grabación   : ${OUTPUT}"
[[ "$CONVERT_MP4" == true ]] && echo "  Convertir   : MP4 al finalizar → ${MP4_OUTPUT}"
echo "  Disco       : ~${PER_MIN} MB/min"
echo "  Destino     : ${URL}"
echo "======================================"
echo ""

# Limpiar al salir (si el proceso se interrumpe con Ctrl+C)
cleanup() {
    echo ""
    echo "Stream detenido."

    if [[ -f "$OUTPUT" ]]; then
        SIZE=$(du -sh "$OUTPUT" | cut -f1)
        echo "Grabación guardada: ${OUTPUT} (${SIZE})"

        if [[ "$CONVERT_MP4" == true ]]; then
            echo "Convirtiendo a MP4..."
            ffmpeg \
                -hide_banner \
                -loglevel warning \
                -i "$OUTPUT" \
                -vcodec copy \
                "$MP4_OUTPUT" \
            && echo "MP4 generado: ${MP4_OUTPUT}" \
            || echo "ERROR: falló la conversión a MP4"

            if [[ "$KEEP_H264" == false && -f "$MP4_OUTPUT" ]]; then
                rm "$OUTPUT"
                echo "H264 original eliminado."
            fi
        fi
    fi
}

trap cleanup EXIT

# --- Pipeline principal ---
# tee escribe el stream H264 al archivo Y lo pasa por stdout a ffmpeg
libcamera-vid \
    --width "$WIDTH" \
    --height "$HEIGHT" \
    --framerate "$FPS" \
    --bitrate "$BITRATE" \
    --codec h264 \
    --inline \
    --timeout "$DURATION_MS" \
    --output - \
| tee "$OUTPUT" \
| ffmpeg \
    -hide_banner \
    -loglevel warning \
    -re \
    -i - \
    "${AUDIO_ARGS[@]}" \
    -vcodec copy \
    -f flv \
    "$URL"
