#!/usr/bin/env bash
# Graba video desde la cámara a un archivo local en formato H264 o MP4.
# A diferencia de capture.sh, permite elegir el contenedor de salida
# y opcionalmente segmentar la grabación en archivos de duración fija.
#
# Uso:
#   ./record.sh [opciones]
#
# Opciones:
#   -o FILE        Archivo de salida (default: record_YYYYMMDD_HHMMSS.mp4)
#   -t SECONDS     Duración total en segundos, 0 = indefinido (default: 0)
#   -w WIDTH       Ancho de video (default: 1920)
#   -h HEIGHT      Alto de video (default: 1080)
#   -f FPS         Frames por segundo (default: 30)
#   -b BITRATE     Bitrate de video en bits/s (default: 4500000)
#   --mp4          Empaquetar en MP4 via ffmpeg (default)
#   --h264         Guardar H264 crudo sin contenedor (más ligero)
#   --segment N    Segmentar en archivos de N segundos (implica --mp4)
#   --help         Mostrar esta ayuda
#
# Ejemplos:
#   ./record.sh
#   ./record.sh -t 300 -o conferencia.mp4
#   ./record.sh --h264 -t 60
#   ./record.sh --segment 600 -o grabacion_%03d.mp4
#
# Uso de disco estimado (H264 hardware, 4.5 Mbps):
#   1 minuto  1080p30  ~34 MB
#   1 hora    1080p30  ~2.0 GB
#   24 horas  1080p30  ~49 GB

set -euo pipefail

WIDTH=1920
HEIGHT=1080
FPS=30
BITRATE=4500000
DURATION=0
OUTPUT=""
FORMAT="mp4"
SEGMENT=0

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
        -o)        OUTPUT="$2"; shift 2 ;;
        -t)        DURATION="$2"; shift 2 ;;
        -w)        WIDTH="$2"; shift 2 ;;
        -h)        HEIGHT="$2"; shift 2 ;;
        -f)        FPS="$2"; shift 2 ;;
        -b)        BITRATE="$2"; shift 2 ;;
        --mp4)     FORMAT="mp4"; shift ;;
        --h264)    FORMAT="h264"; shift ;;
        --segment) SEGMENT="$2"; shift 2 ;;
        --help)    usage ;;
        *) die "Opción desconocida: $1. Usa --help para ver las opciones." ;;
    esac
done

command -v libcamera-vid >/dev/null 2>&1 || die "libcamera-vid no encontrado. Instalar con: sudo apt install libcamera-apps"

[[ "$WIDTH" =~ ^[0-9]+$ ]]    || die "Ancho inválido: $WIDTH"
[[ "$HEIGHT" =~ ^[0-9]+$ ]]   || die "Alto inválido: $HEIGHT"
[[ "$FPS" =~ ^[0-9]+$ ]]      || die "FPS inválido: $FPS"
[[ "$BITRATE" =~ ^[0-9]+$ ]]  || die "Bitrate inválido: $BITRATE"
[[ "$DURATION" =~ ^[0-9]+$ ]] || die "Duración inválida: $DURATION"
[[ "$SEGMENT" =~ ^[0-9]+$ ]]  || die "Segmento inválido: $SEGMENT"

if [[ "$SEGMENT" -gt 0 ]]; then
    FORMAT="mp4"
fi

if [[ -z "$OUTPUT" ]]; then
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    if [[ "$SEGMENT" -gt 0 ]]; then
        OUTPUT="record_${TIMESTAMP}_%03d.mp4"
    elif [[ "$FORMAT" == "mp4" ]]; then
        OUTPUT="record_${TIMESTAMP}.mp4"
    else
        OUTPUT="record_${TIMESTAMP}.h264"
    fi
fi

DURATION_MS=$(( DURATION * 1000 ))

# Estimación de uso de disco
BITRATE_MBPS=$(echo "scale=1; $BITRATE / 1000000" | bc 2>/dev/null || echo "~$(( BITRATE / 1000000 ))")
if [[ "$DURATION" -gt 0 ]]; then
    SIZE_MB=$(echo "scale=0; $BITRATE * $DURATION / 8 / 1024 / 1024" | bc 2>/dev/null || echo "?")
    SIZE_INFO="${SIZE_MB} MB estimados"
else
    PER_MIN=$(echo "scale=0; $BITRATE * 60 / 8 / 1024 / 1024" | bc 2>/dev/null || echo "~$(( BITRATE * 60 / 8 / 1024 / 1024 ))")
    SIZE_INFO="${PER_MIN} MB/min estimados"
fi

echo "=== Grabación de video ==="
echo "  Resolución  : ${WIDTH}x${HEIGHT}"
echo "  FPS         : ${FPS}"
echo "  Bitrate     : ${BITRATE} bps (${BITRATE_MBPS} Mbps)"
echo "  Formato     : ${FORMAT}"
[[ "$SEGMENT" -gt 0 ]] && echo "  Segmentos   : ${SEGMENT}s por archivo"
if [[ "$DURATION" -eq 0 ]]; then
    echo "  Duración    : indefinida (Ctrl+C para detener)"
else
    echo "  Duración    : ${DURATION}s"
fi
echo "  Salida      : ${OUTPUT}"
echo "  Disco       : ${SIZE_INFO}"
echo "=========================="
echo ""

if [[ "$FORMAT" == "h264" ]]; then
    # H264 crudo directo desde libcamera-vid
    libcamera-vid \
        --width "$WIDTH" \
        --height "$HEIGHT" \
        --framerate "$FPS" \
        --bitrate "$BITRATE" \
        --codec h264 \
        --timeout "$DURATION_MS" \
        --output "$OUTPUT"
elif [[ "$SEGMENT" -gt 0 ]]; then
    # MP4 segmentado: libcamera-vid → ffmpeg con segment muxer
    command -v ffmpeg >/dev/null 2>&1 || die "ffmpeg requerido para MP4. Instalar con: sudo apt install ffmpeg"
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
        -vcodec copy \
        -f segment \
        -segment_time "$SEGMENT" \
        -reset_timestamps 1 \
        "$OUTPUT"
else
    # MP4 simple: libcamera-vid → ffmpeg
    command -v ffmpeg >/dev/null 2>&1 || die "ffmpeg requerido para MP4. Instalar con: sudo apt install ffmpeg"
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
        -i - \
        -vcodec copy \
        "$OUTPUT"
fi

echo ""
echo "Grabación finalizada: ${OUTPUT}"

if [[ "$SEGMENT" -eq 0 && -f "$OUTPUT" ]]; then
    SIZE=$(du -sh "$OUTPUT" | cut -f1)
    echo "Tamaño del archivo: ${SIZE}"
fi
