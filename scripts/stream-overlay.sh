#!/usr/bin/env bash
# Transmite video en vivo con overlays aplicados: logo, marco, texto y timestamp.
# Los overlays requieren re-encoding por CPU (libx264) ya que ffmpeg debe decodificar
# el H264 del hardware para aplicar filtros antes de re-codificar.
#
# Uso:
#   ./stream-overlay.sh [opciones] -u RTMP_URL
#
# Opciones de destino:
#   -u URL         URL RTMP destino (requerido, o variable RTMP_URL)
#   -k KEY         Stream key (se concatena a la URL)
#
# Opciones de video:
#   -w WIDTH       Ancho (default: 1920)
#   -h HEIGHT      Alto (default: 1080)
#   -f FPS         Frames por segundo (default: 30)
#   -b BITRATE     Bitrate de video en bits/s (default: 4500000)
#   --preset P     Preset libx264: ultrafast, superfast, veryfast, faster, fast
#                  (default: veryfast — recomendado para Pi 3B)
#
# Opciones de overlays (combinables):
#   --logo FILE    Ruta a PNG del logo (default: assets/logo.png si existe)
#   --logo-pos P   Posición del logo: tl, tr, bl, br, center (default: br)
#   --logo-pad N   Padding en px desde el borde (default: 20)
#   --frame FILE   Ruta a PNG del marco fullscreen (default: assets/frame.png si existe)
#   --text TEXT    Texto estático a mostrar en pantalla
#   --text-pos P   Posición del texto: tl, tr, bl, br, center (default: bl)
#   --timestamp    Mostrar timestamp en tiempo real
#
# Opciones de audio:
#   -a ABITRATE    Bitrate de audio en bits/s (default: 128000)
#   --audio-dev D  Dispositivo ALSA del micrófono (default: detección automática)
#   --audio-rate N Sample rate en Hz (default: 44100)
#   --audio-ch N   Canales 1=mono 2=stereo (default: 1)
#   --no-audio     Deshabilitar audio
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
#   ./stream-overlay.sh -u rtmp://a.rtmp.youtube.com/live2/KEY --logo assets/logo.png
#   ./stream-overlay.sh -u rtmp://localhost/live/test --logo assets/logo.png --logo-pos tr --timestamp
#   ./stream-overlay.sh -u rtmp://localhost/live/test --frame assets/frame.png --text "Demo en vivo"
#   ./stream-overlay.sh -u rtmp://localhost/live/test --logo assets/logo.png --frame assets/frame.png --timestamp --text "Raspi 3B"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ASSETS_DIR="${SCRIPT_DIR}/../assets"

# --- Valores por defecto ---
WIDTH=1920
HEIGHT=1080
FPS=30
BITRATE=4500000
AUDIO_BITRATE=128000
AUDIO_RATE=44100
AUDIO_CH=1
DURATION=0
PRESET="veryfast"
URL="${RTMP_URL:-}"
KEY="${STREAM_KEY:-}"
AUDIO_DEV="${AUDIO_DEVICE:-}"
NO_AUDIO=false

LOGO_FILE=""
LOGO_POS="br"
LOGO_PAD=20
FRAME_FILE=""
TEXT_CONTENT=""
TEXT_POS="bl"
USE_TIMESTAMP=false

usage() {
    grep '^#' "$0" | grep -v '#!/' | sed 's/^# \{0,1\}//'
    exit 0
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

# --- Calcular posición de overlay ---
# Recibe posición (tl/tr/bl/br/center) y padding, devuelve x:y para ffmpeg
overlay_position() {
    local pos="$1"
    local pad="$2"
    case "$pos" in
        tl)     echo "${pad}:${pad}" ;;
        tr)     echo "W-w-${pad}:${pad}" ;;
        bl)     echo "${pad}:H-h-${pad}" ;;
        br)     echo "W-w-${pad}:H-h-${pad}" ;;
        center) echo "(W-w)/2:(H-h)/2" ;;
        *)      die "Posición desconocida: $pos. Usar: tl, tr, bl, br, center" ;;
    esac
}

# --- Calcular posición de texto ---
text_position() {
    local pos="$1"
    local pad=20
    case "$pos" in
        tl)     echo "x=${pad}:y=${pad}" ;;
        tr)     echo "x=w-text_w-${pad}:y=${pad}" ;;
        bl)     echo "x=${pad}:y=h-text_h-${pad}" ;;
        br)     echo "x=w-text_w-${pad}:y=h-text_h-${pad}" ;;
        center) echo "x=(w-text_w)/2:y=(h-text_h)/2" ;;
        *)      die "Posición de texto desconocida: $pos. Usar: tl, tr, bl, br, center" ;;
    esac
}

# --- Parseo de argumentos ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        -u)          URL="$2"; shift 2 ;;
        -k)          KEY="$2"; shift 2 ;;
        -w)          WIDTH="$2"; shift 2 ;;
        -h)          HEIGHT="$2"; shift 2 ;;
        -f)          FPS="$2"; shift 2 ;;
        -b)          BITRATE="$2"; shift 2 ;;
        -a)           AUDIO_BITRATE="$2"; shift 2 ;;
        --audio-dev)  AUDIO_DEV="$2"; shift 2 ;;
        --audio-rate) AUDIO_RATE="$2"; shift 2 ;;
        --audio-ch)   AUDIO_CH="$2"; shift 2 ;;
        -t)           DURATION="$2"; shift 2 ;;
        --preset)     PRESET="$2"; shift 2 ;;
        --logo)       LOGO_FILE="$2"; shift 2 ;;
        --logo-pos)   LOGO_POS="$2"; shift 2 ;;
        --logo-pad)   LOGO_PAD="$2"; shift 2 ;;
        --frame)      FRAME_FILE="$2"; shift 2 ;;
        --text)       TEXT_CONTENT="$2"; shift 2 ;;
        --text-pos)   TEXT_POS="$2"; shift 2 ;;
        --timestamp)  USE_TIMESTAMP=true; shift ;;
        --no-audio)   NO_AUDIO=true; shift ;;
        --help)      usage ;;
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

# Usar assets por defecto si existen y no se especificaron explícitamente
if [[ -z "$LOGO_FILE" && -f "${ASSETS_DIR}/logo.png" ]]; then
    LOGO_FILE="${ASSETS_DIR}/logo.png"
fi
if [[ -z "$FRAME_FILE" && -f "${ASSETS_DIR}/frame.png" ]]; then
    FRAME_FILE="${ASSETS_DIR}/frame.png"
fi

# Verificar archivos de assets si se especificaron
[[ -z "$LOGO_FILE"  || -f "$LOGO_FILE"  ]] || die "Logo no encontrado: $LOGO_FILE"
[[ -z "$FRAME_FILE" || -f "$FRAME_FILE" ]] || die "Marco no encontrado: $FRAME_FILE"

if [[ -n "$KEY" ]]; then
    URL="${URL%/}/${KEY}"
fi
[[ -n "$URL" ]] || die "URL RTMP requerida. Usar -u URL o variable de entorno RTMP_URL."

DURATION_MS=$(( DURATION * 1000 ))

# --- Construir filter_complex dinámicamente ---
# Cada overlay se encadena al anterior usando etiquetas [vN]
build_filter_complex() {
    local filters=()
    local input_count=1  # entrada 0 = video principal
    local current_label="[0:v]"
    local next_label
    local input_args=()

    # Índice para entradas adicionales (logo, frame son inputs separados en ffmpeg)
    local extra_idx=1

    # --- Frame (se aplica primero, debajo del logo) ---
    if [[ -n "$FRAME_FILE" ]]; then
        next_label="[vframe]"
        filters+=("${current_label}[${extra_idx}:v]overlay=0:0${next_label}")
        input_args+=(-i "$FRAME_FILE")
        (( extra_idx++ ))
        current_label="$next_label"
    fi

    # --- Logo ---
    if [[ -n "$LOGO_FILE" ]]; then
        local pos
        pos=$(overlay_position "$LOGO_POS" "$LOGO_PAD")
        next_label="[vlogo]"
        filters+=("${current_label}[${extra_idx}:v]overlay=${pos}${next_label}")
        input_args+=(-i "$LOGO_FILE")
        (( extra_idx++ ))
        current_label="$next_label"
    fi

    # --- Texto estático ---
    if [[ -n "$TEXT_CONTENT" ]]; then
        local tpos
        tpos=$(text_position "$TEXT_POS")
        local safe_text
        safe_text=$(echo "$TEXT_CONTENT" | sed "s/'/\\\\'/g")
        next_label="[vtext]"
        filters+=("${current_label}drawtext=text='${safe_text}':fontcolor=white:fontsize=24:${tpos}:box=1:boxcolor=black@0.5:boxborderw=6${next_label}")
        current_label="$next_label"
    fi

    # --- Timestamp dinámico ---
    if [[ "$USE_TIMESTAMP" == true ]]; then
        next_label="[vts]"
        filters+=("${current_label}drawtext=text='%{localtime\\:%Y-%m-%d %H\\\\:%M\\\\:%S}':fontcolor=white:fontsize=20:x=10:y=10:box=1:boxcolor=black@0.5:boxborderw=5${next_label}")
        current_label="$next_label"
    fi

    # Si no se aplicó ningún overlay, no hay filter_complex
    if [[ ${#filters[@]} -eq 0 ]]; then
        echo ""
        return
    fi

    # Unir todos los filtros con coma
    local filter_str
    filter_str=$(IFS=","; echo "${filters[*]}")

    # Devolver: primero los -i adicionales, luego el filter_complex y el mapa de salida
    echo "${input_args[@]:-} -filter_complex \"${filter_str}\" -map \"${current_label}\""
}

# --- Detectar automáticamente micrófono USB ---
detect_usb_mic() {
    arecord -l 2>/dev/null \
        | grep -i "usb\|microphone\|mic\|webcam" \
        | grep "^card" \
        | head -1 \
        | awk '{
            match($0, /card ([0-9]+).*device ([0-9]+)/, arr);
            if (arr[1] != "" && arr[2] != "")
                print "plughw:" arr[1] "," arr[2]
        }' || true
}

# --- Construir argumentos de audio ---
if [[ "$NO_AUDIO" == true ]]; then
    AUDIO_ARGS=(-an)
    AUDIO_INFO="deshabilitado"
else
    if [[ -z "$AUDIO_DEV" ]]; then
        AUDIO_DEV=$(detect_usb_mic)
        if [[ -n "$AUDIO_DEV" ]]; then
            echo "Micrófono USB detectado: ${AUDIO_DEV}"
        else
            echo "AVISO: No se detectó micrófono USB. Usando audio interno (hw:0)."
            AUDIO_DEV="hw:0"
        fi
    fi
    AUDIO_ARGS=(-f alsa -ar "$AUDIO_RATE" -ac "$AUDIO_CH" -i "$AUDIO_DEV" -acodec aac -b:a "${AUDIO_BITRATE}")
    AUDIO_INFO="${AUDIO_DEV} — AAC ${AUDIO_BITRATE} bps — ${AUDIO_RATE}Hz ${AUDIO_CH}ch"
fi

# --- Determinar si hay overlays activos ---
HAS_OVERLAY=false
[[ -n "$LOGO_FILE" || -n "$FRAME_FILE" || -n "$TEXT_CONTENT" || "$USE_TIMESTAMP" == true ]] && HAS_OVERLAY=true

# --- Información antes de transmitir ---
echo "=== Stream con overlays ==="
echo "  Resolución  : ${WIDTH}x${HEIGHT}"
echo "  FPS         : ${FPS}"
echo "  Bitrate     : ${BITRATE} bps ($(( BITRATE / 1000 )) kbps)"
echo "  Preset      : ${PRESET}"
echo "  Audio       : ${AUDIO_INFO}"
echo "  Overlays activos:"
[[ -n "$LOGO_FILE"    ]] && echo "    - Logo      : ${LOGO_FILE} (posición: ${LOGO_POS})"
[[ -n "$FRAME_FILE"   ]] && echo "    - Marco     : ${FRAME_FILE}"
[[ -n "$TEXT_CONTENT" ]] && echo "    - Texto     : \"${TEXT_CONTENT}\" (posición: ${TEXT_POS})"
[[ "$USE_TIMESTAMP" == true ]] && echo "    - Timestamp : activado"
[[ "$HAS_OVERLAY" == false ]] && echo "    (ninguno — usando vcodec copy)"
if [[ "$DURATION" -eq 0 ]]; then
    echo "  Duración    : indefinida (Ctrl+C para detener)"
else
    echo "  Duración    : ${DURATION}s"
fi
echo "  Destino     : ${URL}"
echo "==========================="
echo ""

# --- Advertencia de CPU para Pi 3B ---
if [[ "$HAS_OVERLAY" == true ]]; then
    echo "AVISO: Los overlays requieren re-encoding por CPU (libx264)."
    echo "       En Pi 3B monitorear temperatura y uso de CPU."
    echo ""
fi

# --- Pipeline ---
if [[ "$HAS_OVERLAY" == false ]]; then
    # Sin overlays: vcodec copy (hardware H264, sin re-encoding)
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
else
    # Con overlays: decode + filtros + re-encode libx264
    EXTRA_INPUTS=()
    FILTER_PARTS=()
    CURRENT="[0:v]"
    EXTRA_IDX=1

    # Frame
    if [[ -n "$FRAME_FILE" ]]; then
        EXTRA_INPUTS+=(-i "$FRAME_FILE")
        FILTER_PARTS+=("${CURRENT}[${EXTRA_IDX}:v]overlay=0:0[vframe]")
        CURRENT="[vframe]"
        (( EXTRA_IDX++ ))
    fi

    # Logo
    if [[ -n "$LOGO_FILE" ]]; then
        POS=$(overlay_position "$LOGO_POS" "$LOGO_PAD")
        EXTRA_INPUTS+=(-i "$LOGO_FILE")
        FILTER_PARTS+=("${CURRENT}[${EXTRA_IDX}:v]overlay=${POS}[vlogo]")
        CURRENT="[vlogo]"
        (( EXTRA_IDX++ ))
    fi

    # Texto estático
    if [[ -n "$TEXT_CONTENT" ]]; then
        TPOS=$(text_position "$TEXT_POS")
        SAFE_TEXT=$(echo "$TEXT_CONTENT" | sed "s/'/\\\\'/g")
        FILTER_PARTS+=("${CURRENT}drawtext=text='${SAFE_TEXT}':fontcolor=white:fontsize=24:${TPOS}:box=1:boxcolor=black@0.5:boxborderw=6[vtext]")
        CURRENT="[vtext]"
    fi

    # Timestamp
    if [[ "$USE_TIMESTAMP" == true ]]; then
        FILTER_PARTS+=("${CURRENT}drawtext=text='%{localtime\\:%Y-%m-%d %H\\\\:%M\\\\:%S}':fontcolor=white:fontsize=20:x=10:y=10:box=1:boxcolor=black@0.5:boxborderw=5[vts]")
        CURRENT="[vts]"
    fi

    FILTER_COMPLEX=$(IFS=","; echo "${FILTER_PARTS[*]}")

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
        "${EXTRA_INPUTS[@]}" \
        "${AUDIO_ARGS[@]}" \
        -filter_complex "$FILTER_COMPLEX" \
        -map "$CURRENT" \
        -vcodec libx264 \
        -preset "$PRESET" \
        -b:v "$BITRATE" \
        -f flv \
        "$URL"
fi
