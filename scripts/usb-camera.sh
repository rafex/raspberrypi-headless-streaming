#!/usr/bin/env bash
# Captura o transmite video desde una cámara USB (UVC) usando ffmpeg + v4l2.
# A diferencia de capture.sh y stream.sh (que usan libcamera-vid para el módulo CSI),
# este script usa el driver v4l2 del kernel para cámaras USB estándar.
#
# Uso:
#   ./usb-camera.sh [opciones]
#
# Modos:
#   --capture      Guardar video en archivo local (default si no se pasa -u)
#   --stream URL   Transmitir a RTMP (equivalente a -u URL)
#
# Opciones de cámara:
#   --dev DEV      Dispositivo v4l2 (default: detección automática, ej: /dev/video0)
#   --list         Listar cámaras USB disponibles y salir
#
# Opciones de video:
#   -w WIDTH       Ancho (default: 1280)
#   -h HEIGHT      Alto (default: 720)
#   -f FPS         Frames por segundo (default: 30)
#   -b BITRATE     Bitrate de salida en bits/s (default: 2500000)
#   -t SECONDS     Duración en segundos, 0 = indefinido (default: 0)
#   -o FILE        Archivo de salida (modo capture, default: usb_YYYYMMDD_HHMMSS.mp4)
#   -u URL         URL RTMP destino (activa modo stream)
#   -k KEY         Stream key (se concatena a la URL)
#
# Opciones de audio:
#   --audio-dev D  Dispositivo ALSA del micrófono (default: detección automática)
#   --audio-rate N Sample rate en Hz (default: 44100)
#   --audio-ch N   Canales 1=mono 2=stereo (default: 1)
#   --no-audio     Deshabilitar audio
#
# Otras:
#   --help         Mostrar esta ayuda
#
# Variables de entorno:
#   RTMP_URL       URL RTMP completa (alternativa a -u)
#   STREAM_KEY     Stream key (alternativa a -k)
#   AUDIO_DEVICE   Dispositivo ALSA del micrófono (alternativa a --audio-dev)
#   USB_CAM_DEV    Dispositivo v4l2 (alternativa a --dev)
#
# Ejemplos:
#   ./usb-camera.sh --list
#   ./usb-camera.sh --capture -t 30
#   ./usb-camera.sh --capture --dev /dev/video0 -w 1920 -h 1080 -t 60
#   ./usb-camera.sh --stream rtmp://a.rtmp.youtube.com/live2/KEY
#   ./usb-camera.sh -u rtmp://localhost/live/test --dev /dev/video0 --no-audio
#   ./usb-camera.sh -u rtmp://localhost/live/test --audio-dev plughw:1,0
#
# Diferencia con capture.sh / stream.sh:
#   capture.sh y stream.sh usan libcamera-vid (módulo CSI oficial de Raspberry Pi).
#   Este script usa ffmpeg -f v4l2 para cámaras USB UVC estándar.
#   No requiere raspi-config ni habilitar ningún módulo — plug & play.

set -euo pipefail

# --- Valores por defecto ---
WIDTH=1280
HEIGHT=720
FPS=30
BITRATE=2500000
DURATION=0
OUTPUT=""
CAM_DEV="${USB_CAM_DEV:-}"
URL="${RTMP_URL:-}"
KEY="${STREAM_KEY:-}"
AUDIO_DEV="${AUDIO_DEVICE:-}"
AUDIO_RATE=44100
AUDIO_CH=1
NO_AUDIO=false
MODE=""    # capture | stream
LIST=false

usage() {
    grep '^#' "$0" | grep -v '#!/' | sed 's/^# \{0,1\}//'
    exit 0
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

# --- Detectar primera cámara USB disponible ---
detect_usb_camera() {
    # Buscar dispositivos v4l2 que sean cámaras reales (no metadata/subdev)
    for dev in /dev/video0 /dev/video1 /dev/video2 /dev/video3; do
        if [[ -e "$dev" ]]; then
            # Verificar que sea una cámara que capture video (no solo metadata)
            if v4l2-ctl --device="$dev" --list-formats 2>/dev/null | grep -q "MJPEG\|YUYV\|H264\|NV12\|YUV"; then
                echo "$dev"
                return 0
            fi
        fi
    done
    return 1
}

# --- Detectar primer micrófono USB disponible ---
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

# --- Parsear argumentos ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --capture)     MODE="capture"; shift ;;
        --stream)      MODE="stream"; URL="$2"; shift 2 ;;
        --list)        LIST=true; shift ;;
        --dev)         CAM_DEV="$2"; shift 2 ;;
        -w)            WIDTH="$2"; shift 2 ;;
        -h)            HEIGHT="$2"; shift 2 ;;
        -f)            FPS="$2"; shift 2 ;;
        -b)            BITRATE="$2"; shift 2 ;;
        -t)            DURATION="$2"; shift 2 ;;
        -o)            OUTPUT="$2"; shift 2 ;;
        -u)            URL="$2"; MODE="stream"; shift 2 ;;
        -k)            KEY="$2"; shift 2 ;;
        --audio-dev)   AUDIO_DEV="$2"; shift 2 ;;
        --audio-rate)  AUDIO_RATE="$2"; shift 2 ;;
        --audio-ch)    AUDIO_CH="$2"; shift 2 ;;
        --no-audio)    NO_AUDIO=true; shift ;;
        --help)        usage ;;
        *) die "Opción desconocida: $1. Usa --help para ver las opciones." ;;
    esac
done

command -v ffmpeg >/dev/null 2>&1 || die "ffmpeg no encontrado. Instalar con: sudo apt install ffmpeg"

# ---------------------------------------------------------------------------
# Modo: listar cámaras
# ---------------------------------------------------------------------------
if [[ "$LIST" == true ]]; then
    echo "=== Cámaras USB disponibles ==="
    echo ""

    if ! command -v v4l2-ctl >/dev/null 2>&1; then
        echo "AVISO: v4l2-ctl no instalado. Instalar con: sudo apt install v4l-utils"
        echo ""
        echo "Dispositivos /dev/video* presentes:"
        ls /dev/video* 2>/dev/null || echo "  (ninguno)"
        exit 0
    fi

    FOUND=false
    for dev in /dev/video*; do
        [[ -e "$dev" ]] || continue
        NAME=$(v4l2-ctl --device="$dev" --info 2>/dev/null | grep "Card type" | sed 's/.*: //' || echo "desconocido")
        FORMATS=$(v4l2-ctl --device="$dev" --list-formats 2>/dev/null | grep -E "MJPEG|YUYV|H264|NV12|YUV" | tr '\n' ' ' || echo "")
        if [[ -n "$FORMATS" ]]; then
            echo "  $dev — $NAME"
            echo "         Formatos: $FORMATS"
            FOUND=true
        fi
    done

    if [[ "$FOUND" == false ]]; then
        echo "  No se encontraron cámaras USB."
        echo "  Conectar la cámara USB y ejecutar de nuevo."
    fi

    echo ""
    echo "=== Resoluciones disponibles (para el dispositivo detectado) ==="
    echo ""
    FIRST_DEV=$(detect_usb_camera 2>/dev/null || true)
    if [[ -n "$FIRST_DEV" ]]; then
        echo "Dispositivo: $FIRST_DEV"
        v4l2-ctl --device="$FIRST_DEV" --list-formats-ext 2>/dev/null \
            | grep -E "Size|MJPEG|YUYV|H264" \
            | head -30 || true
    fi

    exit 0
fi

# ---------------------------------------------------------------------------
# Determinar modo si no se especificó
# ---------------------------------------------------------------------------
if [[ -z "$MODE" ]]; then
    if [[ -n "$URL" ]]; then
        MODE="stream"
    else
        MODE="capture"
    fi
fi

# ---------------------------------------------------------------------------
# Validaciones
# ---------------------------------------------------------------------------
[[ "$WIDTH" =~ ^[0-9]+$ ]]    || die "Ancho inválido: $WIDTH"
[[ "$HEIGHT" =~ ^[0-9]+$ ]]   || die "Alto inválido: $HEIGHT"
[[ "$FPS" =~ ^[0-9]+$ ]]      || die "FPS inválido: $FPS"
[[ "$BITRATE" =~ ^[0-9]+$ ]]  || die "Bitrate inválido: $BITRATE"
[[ "$DURATION" =~ ^[0-9]+$ ]] || die "Duración inválida: $DURATION"

if [[ "$MODE" == "stream" ]]; then
    [[ -n "$KEY" ]] && URL="${URL%/}/${KEY}"
    [[ -n "$URL" ]] || die "URL RTMP requerida. Usar -u URL o variable RTMP_URL."
fi

# --- Resolver cámara ---
if [[ -z "$CAM_DEV" ]]; then
    if ! command -v v4l2-ctl >/dev/null 2>&1; then
        # Sin v4l2-ctl, intentar /dev/video0 directamente
        CAM_DEV="/dev/video0"
        echo "AVISO: v4l2-ctl no instalado. Asumiendo ${CAM_DEV}."
        echo "       Instalar v4l-utils para detección automática: sudo apt install v4l-utils"
    else
        CAM_DEV=$(detect_usb_camera || true)
        if [[ -z "$CAM_DEV" ]]; then
            die "No se detectó ninguna cámara USB. Conectar la cámara y ejecutar de nuevo.\n       Ver dispositivos disponibles: $0 --list"
        fi
        echo "Cámara USB detectada: ${CAM_DEV}"
    fi
fi

[[ -e "$CAM_DEV" ]] || die "Dispositivo no encontrado: ${CAM_DEV}. Ver cámaras disponibles: $0 --list"

# --- Resolver audio ---
AUDIO_ARGS=()
if [[ "$NO_AUDIO" == false ]]; then
    if [[ -z "$AUDIO_DEV" ]]; then
        AUDIO_DEV=$(detect_usb_mic)
        if [[ -n "$AUDIO_DEV" ]]; then
            echo "Micrófono USB detectado: ${AUDIO_DEV}"
        else
            echo "AVISO: No se detectó micrófono USB. Capturando sin audio."
            echo "       Especificar con --audio-dev plughw:N,N o usar --no-audio."
            NO_AUDIO=true
        fi
    fi
fi

if [[ "$NO_AUDIO" == false ]]; then
    AUDIO_ARGS=(
        -thread_queue_size 8192
        -f alsa
        -ar "$AUDIO_RATE" -ac "$AUDIO_CH" -i "$AUDIO_DEV"
        -acodec aac -b:a 128k
        -af "aresample=async=1:min_hard_comp=0.100000:first_pts=0,volume=2.0"
    )
else
    AUDIO_ARGS=(-an)
fi

# --- Duración ---
DURATION_ARGS=()
[[ "$DURATION" -gt 0 ]] && DURATION_ARGS=(-t "$DURATION")

# ---------------------------------------------------------------------------
# Modo: captura local
# ---------------------------------------------------------------------------
if [[ "$MODE" == "capture" ]]; then
    if [[ -z "$OUTPUT" ]]; then
        TIMESTAMP=$(date +%Y%m%d_%H%M%S)
        OUTPUT="usb_${TIMESTAMP}.mp4"
    fi

    echo "=== Captura USB ==="
    echo "  Cámara     : ${CAM_DEV}"
    echo "  Resolución : ${WIDTH}x${HEIGHT} @ ${FPS}fps"
    echo "  Bitrate    : ${BITRATE} bps ($(( BITRATE / 1000 )) kbps)"
    if [[ "$NO_AUDIO" == true ]]; then
        echo "  Audio      : deshabilitado"
    else
        echo "  Audio      : ${AUDIO_DEV} — ${AUDIO_RATE}Hz ${AUDIO_CH}ch"
    fi
    if [[ "$DURATION" -eq 0 ]]; then
        echo "  Duración   : indefinida (Ctrl+C para detener)"
    else
        echo "  Duración   : ${DURATION}s"
    fi
    echo "  Salida     : ${OUTPUT}"
    echo "===================="
    echo ""

    ffmpeg \
        -hide_banner \
        -loglevel warning \
        -thread_queue_size 8192 \
        -f v4l2 \
        -input_format mjpeg \
        -video_size "${WIDTH}x${HEIGHT}" \
        -framerate "$FPS" \
        -i "$CAM_DEV" \
        "${AUDIO_ARGS[@]}" \
        "${DURATION_ARGS[@]}" \
        -vcodec libx264 \
        -preset ultrafast \
        -b:v "$BITRATE" \
        -fps_mode cfr \
        -movflags +faststart \
        "$OUTPUT"

    echo ""
    echo "Captura finalizada: ${OUTPUT}"
    if [[ -f "$OUTPUT" ]]; then
        SIZE=$(du -sh "$OUTPUT" | cut -f1)
        echo "Tamaño del archivo: ${SIZE}"
    fi
fi

# ---------------------------------------------------------------------------
# Modo: stream RTMP
# ---------------------------------------------------------------------------
if [[ "$MODE" == "stream" ]]; then
    echo "=== Stream USB → RTMP ==="
    echo "  Cámara     : ${CAM_DEV}"
    echo "  Resolución : ${WIDTH}x${HEIGHT} @ ${FPS}fps"
    echo "  Bitrate    : ${BITRATE} bps ($(( BITRATE / 1000 )) kbps)"
    if [[ "$NO_AUDIO" == true ]]; then
        echo "  Audio      : deshabilitado"
    else
        echo "  Audio      : ${AUDIO_DEV} — ${AUDIO_RATE}Hz ${AUDIO_CH}ch"
    fi
    if [[ "$DURATION" -eq 0 ]]; then
        echo "  Duración   : indefinida (Ctrl+C para detener)"
    else
        echo "  Duración   : ${DURATION}s"
    fi
    echo "  Destino    : ${URL}"
    echo "========================="
    echo ""

    ffmpeg \
        -hide_banner \
        -loglevel warning \
        -thread_queue_size 8192 \
        -f v4l2 \
        -input_format mjpeg \
        -video_size "${WIDTH}x${HEIGHT}" \
        -framerate "$FPS" \
        -i "$CAM_DEV" \
        "${AUDIO_ARGS[@]}" \
        "${DURATION_ARGS[@]}" \
        -vcodec libx264 \
        -preset ultrafast \
        -b:v "$BITRATE" \
        -fps_mode cfr \
        -f flv \
        "$URL"
fi
