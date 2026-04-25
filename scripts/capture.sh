#!/usr/bin/env bash
# Captura video desde la cámara de Raspberry Pi a un archivo local.
# Usa encoding H264 por hardware del Video Core IV.
# Con --audio captura también audio desde un micrófono USB y genera MP4.
#
# Uso:
#   ./capture.sh [opciones]
#
# Opciones:
#   -o FILE        Archivo de salida (default: capture_YYYYMMDD_HHMMSS.h264 o .mp4)
#   -t SECONDS     Duración en segundos, 0 = indefinido (default: 0)
#   -w WIDTH       Ancho de video (default: 1920)
#   -h HEIGHT      Alto de video (default: 1080)
#   -f FPS         Frames por segundo (default: 30)
#   -b BITRATE     Bitrate en bits/s (default: 4500000)
#   --audio        Capturar audio USB y guardar en MP4 (requiere ffmpeg)
#   --audio-dev D  Dispositivo ALSA del micrófono (default: detección automática)
#   --audio-rate N Sample rate de audio en Hz (default: 44100)
#   --audio-ch N   Canales de audio 1=mono 2=stereo (default: 1)
#   --help         Mostrar esta ayuda
#
# Ejemplos:
#   ./capture.sh
#   ./capture.sh -t 60 -o mi_video.h264
#   ./capture.sh --audio -t 120 -o conferencia.mp4
#   ./capture.sh --audio --audio-dev hw:1,0 -t 60
#
# Para detectar el dispositivo ALSA del micrófono USB:
#   ./audio-check.sh

set -euo pipefail

WIDTH=1920
HEIGHT=1080
FPS=30
BITRATE=4500000
DURATION=0
OUTPUT=""
AUDIO=false
AUDIO_DEV=""
AUDIO_RATE=44100
AUDIO_CH=1

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
        -o)          OUTPUT="$2"; shift 2 ;;
        -t)          DURATION="$2"; shift 2 ;;
        -w)          WIDTH="$2"; shift 2 ;;
        -h)          HEIGHT="$2"; shift 2 ;;
        -f)          FPS="$2"; shift 2 ;;
        -b)          BITRATE="$2"; shift 2 ;;
        --audio)     AUDIO=true; shift ;;
        --audio-dev) AUDIO_DEV="$2"; shift 2 ;;
        --audio-rate) AUDIO_RATE="$2"; shift 2 ;;
        --audio-ch)  AUDIO_CH="$2"; shift 2 ;;
        --help)      usage ;;
        *) die "Opción desconocida: $1. Usa --help para ver las opciones." ;;
    esac
done

command -v libcamera-vid >/dev/null 2>&1 || die "libcamera-vid no encontrado. Instalar con: sudo apt install libcamera-apps"

[[ "$WIDTH" =~ ^[0-9]+$ ]]    || die "Ancho inválido: $WIDTH"
[[ "$HEIGHT" =~ ^[0-9]+$ ]]   || die "Alto inválido: $HEIGHT"
[[ "$FPS" =~ ^[0-9]+$ ]]      || die "FPS inválido: $FPS"
[[ "$BITRATE" =~ ^[0-9]+$ ]]  || die "Bitrate inválido: $BITRATE"
[[ "$DURATION" =~ ^[0-9]+$ ]] || die "Duración inválida: $DURATION"

# --- Validaciones de audio ---
if [[ "$AUDIO" == true ]]; then
    command -v ffmpeg >/dev/null 2>&1   || die "ffmpeg requerido para audio. Instalar con: sudo apt install ffmpeg"
    command -v arecord >/dev/null 2>&1  || die "arecord requerido. Instalar con: sudo apt install alsa-utils"

    if [[ -z "$AUDIO_DEV" ]]; then
        AUDIO_DEV=$(detect_usb_mic)
        if [[ -z "$AUDIO_DEV" ]]; then
            die "No se detectó micrófono USB. Especificar con --audio-dev hw:N,N o ver ./audio-check.sh"
        fi
        echo "Micrófono USB detectado automáticamente: ${AUDIO_DEV}"
    fi
fi

# --- Nombre de archivo de salida ---
if [[ -z "$OUTPUT" ]]; then
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    if [[ "$AUDIO" == true ]]; then
        OUTPUT="capture_${TIMESTAMP}.mp4"
    else
        OUTPUT="capture_${TIMESTAMP}.h264"
    fi
fi

DURATION_MS=$(( DURATION * 1000 ))

# --- Información antes de grabar ---
echo "=== Captura de video ==="
echo "  Resolución : ${WIDTH}x${HEIGHT}"
echo "  FPS        : ${FPS}"
echo "  Bitrate    : ${BITRATE} bps ($(( BITRATE / 1000 )) kbps)"
if [[ "$AUDIO" == true ]]; then
    echo "  Audio      : ${AUDIO_DEV} — ${AUDIO_RATE}Hz ${AUDIO_CH}ch"
else
    echo "  Audio      : deshabilitado (usar --audio para capturar)"
fi
if [[ "$DURATION" -eq 0 ]]; then
    echo "  Duración   : indefinida (Ctrl+C para detener)"
else
    echo "  Duración   : ${DURATION}s"
fi
echo "  Salida     : ${OUTPUT}"
echo "========================"
echo ""

# --- Captura ---
if [[ "$AUDIO" == false ]]; then
    # Solo video H264 crudo — ruta rápida sin ffmpeg
    libcamera-vid \
        --width "$WIDTH" \
        --height "$HEIGHT" \
        --framerate "$FPS" \
        --bitrate "$BITRATE" \
        --codec h264 \
        --timeout "$DURATION_MS" \
        --output "$OUTPUT"
else
    # Video + audio USB → MP4 via ffmpeg
    # libcamera-vid produce H264 por hardware hacia stdout
    # ffmpeg captura audio ALSA en paralelo y muxea todo en MP4
    FFMPEG_DURATION_ARGS=()
    if [[ "$DURATION" -gt 0 ]]; then
        FFMPEG_DURATION_ARGS=(-t "$DURATION")
    fi

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
        -f alsa \
        -ar "$AUDIO_RATE" \
        -ac "$AUDIO_CH" \
        -i "$AUDIO_DEV" \
        "${FFMPEG_DURATION_ARGS[@]}" \
        -vcodec copy \
        -acodec aac \
        -b:a 128k \
        -movflags +faststart \
        "$OUTPUT"
fi

echo ""
echo "Captura finalizada: ${OUTPUT}"

if [[ -f "$OUTPUT" ]]; then
    SIZE=$(du -sh "$OUTPUT" | cut -f1)
    echo "Tamaño del archivo: ${SIZE}"
fi
