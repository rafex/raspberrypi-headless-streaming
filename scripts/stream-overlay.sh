#!/usr/bin/env bash
# Transmite video en vivo con overlays aplicados: logo, marco, texto y timestamp.
# Los overlays requieren re-encoding por CPU (libx264) ya que ffmpeg debe decodificar
# el H264 del hardware para aplicar filtros antes de re-codificar.
#
# Uso:
#   ./stream-overlay.sh [opciones] -u RTMP_URL
#
# Opciones de destino:
#   -u URL           URL RTMP destino (o variable RTMP_URL). Si se omite y el
#                    transporte es rtmp, se usa rtmp://localhost:1935/<rtmp-name>
#                    (requiere mediamtx — ver scripts/mediamtx-install.sh).
#   -k KEY           Stream key (se concatena a la URL)
#   --transport T    rtmp (default) | tcp | udp — o variable PREVIEW_TRANSPORT
#   --port N         Puerto para tcp/udp, o RTMP local (default 1935) —
#                    o variable PREVIEW_PORT
#   --client-ip IP   IP destino para transporte udp — o variable PREVIEW_CLIENT_IP
#   --rtmp-name N    Path del stream RTMP local cuando no se pasa -u (default
#                    "preview") — o variable PREVIEW_RTMP_NAME
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
#   PREVIEW_MODE   true fuerza URL/KEY/destino-dual vacíos sin importar lo
#                  anterior (usado por systemd/preview.service para
#                  garantizar que el preview nunca salga a la plataforma real)
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
AUDIO_RATE="${AUDIO_RATE:-44100}"
AUDIO_CH="${AUDIO_CHANNELS:-1}"
DURATION=0
PRESET="veryfast"
URL="${RTMP_URL:-}"
KEY="${STREAM_KEY:-}"
AUDIO_DEV="${AUDIO_DEVICE:-}"
NO_AUDIO=false
[[ "${STREAM_NO_AUDIO:-false}" == "true" ]] && NO_AUDIO=true

LOGO_FILE="${OVERLAY_LOGO_FILE:-}"
LOGO_POS="${OVERLAY_LOGO_POS:-br}"
LOGO_PAD="${OVERLAY_LOGO_PAD:-20}"
LOGO_W="${OVERLAY_LOGO_W:-0}"
FRAME_FILE=""
TEXT_CONTENT="${OVERLAY_TEXT:-}"
TEXT_POS="${OVERLAY_TEXT_POS:-bl}"
USE_TIMESTAMP=false
[[ "${OVERLAY_TIMESTAMP:-false}" == "true" ]] && USE_TIMESTAMP=true
BANNER_TEXT="${OVERLAY_BANNER:-}"
BANNER_POS="${OVERLAY_BANNER_POS:-footer}"
DUAL_URL="${RTMP_URL_SECONDARY:-}"
AUDIO_BOOST=false
[[ "${STREAM_AUDIO_BOOST:-false}" == "true" ]] && AUDIO_BOOST=true
VIDEO_DEV="${VIDEO_DEVICE:-}"

TRANSPORT="${PREVIEW_TRANSPORT:-rtmp}"
PORT="${PREVIEW_PORT:-1935}"
CLIENT_IP="${PREVIEW_CLIENT_IP:-}"
RTMP_NAME="${PREVIEW_RTMP_NAME:-preview}"

# PREVIEW_MODE=true (solo systemd/preview.service la define) garantiza que
# este proceso NUNCA pueda salir hacia la plataforma real, sin depender del
# orden de mezcla de Environment=/EnvironmentFile= de systemd: se fuerza
# acá, incondicionalmente, después de leer todo lo demás.
PREVIEW_MODE="${PREVIEW_MODE:-false}"

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

# --- Escapar texto para filtro drawtext de ffmpeg ---
# Orden obligatorio: \ primero, luego ' y %, para no doble-escapar.
#   \  →  \\   (carácter de escape de ffmpeg)
#   '  →  \'   (cierra la comilla que rodea el valor)
#   %  →  %%   (prefijo de expresiones dinámicas %{...})
escape_drawtext() {
    printf '%s' "$1" \
        | sed 's/\\/\\\\/g' \
        | sed "s/'/\\\\'/g" \
        | sed 's/%/%%/g'
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
        --banner)       BANNER_TEXT="$2"; shift 2 ;;
        --banner-pos)   BANNER_POS="$2"; shift 2 ;;
        --dual)         DUAL_URL="$2"; shift 2 ;;
        --audio-boost)  AUDIO_BOOST=true; shift ;;
        --device)     VIDEO_DEV="$2"; shift 2 ;;
        --transport)  TRANSPORT="$2"; shift 2 ;;
        --port)       PORT="$2"; shift 2 ;;
        --client-ip)  CLIENT_IP="$2"; shift 2 ;;
        --rtmp-name)  RTMP_NAME="$2"; shift 2 ;;
        --help)      usage ;;
        *) die "Opción desconocida: $1. Usa --help para ver las opciones." ;;
    esac
done

# --- Detección de fuente de video ---
command -v ffmpeg >/dev/null 2>&1 || die "ffmpeg no encontrado. Instalar con: sudo apt install ffmpeg"

if command -v libcamera-vid >/dev/null 2>&1; then
    CAPTURE_MODE="libcamera"
else
    CAPTURE_MODE="v4l2"
    if [[ -z "$VIDEO_DEV" ]]; then
        VIDEO_DEV=$(v4l2-ctl --list-devices 2>/dev/null \
            | grep "/dev/video" | head -1 | tr -d ' \t' || true)
        VIDEO_DEV="${VIDEO_DEV:-/dev/video0}"
    fi
    [[ -e "$VIDEO_DEV" ]] || die "Dispositivo de video no encontrado: $VIDEO_DEV. Usar --device /dev/videoN"
fi

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

if [[ "$PREVIEW_MODE" == "true" ]]; then
    # Nunca usar el destino real, sin importar -u/-k/RTMP_URL/STREAM_KEY/dual.
    URL=""; KEY=""; DUAL_URL=""
fi

if [[ -n "$KEY" ]]; then
    URL="${URL%/}/${KEY}"
fi

case "$TRANSPORT" in
    rtmp)
        # Si no se indicó destino, transmitir a un mediamtx local (preview LAN).
        [[ -z "$URL" ]] && URL="rtmp://localhost:1935/${RTMP_NAME}"
        ;;
    tcp)
        [[ "$PORT" =~ ^[0-9]+$ ]] || die "Puerto inválido: $PORT"
        ;;
    udp)
        [[ "$PORT" =~ ^[0-9]+$ ]] || die "Puerto inválido: $PORT"
        [[ -n "$CLIENT_IP" ]] || die "Transporte udp requiere --client-ip o la variable PREVIEW_CLIENT_IP"
        ;;
    *) die "Transporte desconocido: $TRANSPORT. Usar: rtmp, tcp, udp" ;;
esac

DURATION_MS=$(( DURATION * 1000 ))


# --- Detectar automáticamente micrófono USB ---
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

# --- Construir argumentos de audio ---
if [[ "$NO_AUDIO" == true ]]; then
    # YouTube Live requiere audio; usar fuente silenciosa en lugar de -an
    AUDIO_ARGS=(-f lavfi -i "anullsrc=r=44100:cl=stereo" -acodec aac -b:a 32k)
    AUDIO_INFO="silencio (AAC 32k — sin micrófono)"
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
    AUDIO_ARGS=(-f alsa -ar "$AUDIO_RATE" -ac "$AUDIO_CH" -i "$AUDIO_DEV")
    if [[ "$AUDIO_BOOST" == true ]]; then
        AUDIO_ARGS+=(-af "aresample=async=1:min_hard_comp=0.100000:first_pts=0,volume=2.0")
    fi
    AUDIO_ARGS+=(-acodec aac -b:a "${AUDIO_BITRATE}")
    BOOST_LABEL=""; [[ "$AUDIO_BOOST" == true ]] && BOOST_LABEL=" +boost×2"
    AUDIO_INFO="${AUDIO_DEV} — AAC ${AUDIO_BITRATE} bps — ${AUDIO_RATE}Hz ${AUDIO_CH}ch${BOOST_LABEL}"
fi

# --- Determinar si hay overlays activos ---
HAS_OVERLAY=false
[[ -n "$LOGO_FILE" || -n "$FRAME_FILE" || -n "$TEXT_CONTENT" || "$USE_TIMESTAMP" == true || -n "$BANNER_TEXT" ]] && HAS_OVERLAY=true

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
case "$TRANSPORT" in
    rtmp) echo "  Destino     : ${URL}" ;;
    tcp)  echo "  Destino     : tcp://0.0.0.0:${PORT} (esperando conexión VLC)" ;;
    udp)  echo "  Destino     : udp://${CLIENT_IP}:${PORT}" ;;
esac
echo "==========================="
echo ""
case "$TRANSPORT" in
    rtmp) echo "Ver con VLC: vlc ${URL}" ;;
    tcp)  echo "Ver con VLC (después de iniciar): vlc tcp://<ip-de-esta-pi>:${PORT}" ;;
    udp)  echo "Ver con VLC en el cliente: vlc udp://@:${PORT}" ;;
esac
echo ""

# --- Advertencia de CPU para Pi 3B ---
if [[ "$HAS_OVERLAY" == true ]]; then
    echo "AVISO: Los overlays requieren re-encoding por CPU (libx264)."
    echo "       En Pi 3B monitorear temperatura y uso de CPU."
    echo ""
fi

# --- Pipeline ---
# Construir filter_complex e inputs extra (logo, frame)
EXTRA_INPUTS=()
FILTER_PARTS=()
CURRENT="[0:v]"
EXTRA_IDX=1

if [[ -n "$FRAME_FILE" ]]; then
    EXTRA_INPUTS+=(-i "$FRAME_FILE")
    FILTER_PARTS+=("${CURRENT}[${EXTRA_IDX}:v]overlay=0:0[vframe]")
    CURRENT="[vframe]"; (( EXTRA_IDX++ ))
fi
if [[ -n "$LOGO_FILE" ]]; then
    POS=$(overlay_position "$LOGO_POS" "$LOGO_PAD")
    EXTRA_INPUTS+=(-i "$LOGO_FILE")
    if [[ "$LOGO_W" -gt 0 ]]; then
        FILTER_PARTS+=("[${EXTRA_IDX}:v]scale=${LOGO_W}:-1[logo_s]")
        FILTER_PARTS+=("${CURRENT}[logo_s]overlay=${POS}[vlogo]")
    else
        FILTER_PARTS+=("${CURRENT}[${EXTRA_IDX}:v]overlay=${POS}[vlogo]")
    fi
    CURRENT="[vlogo]"; (( EXTRA_IDX++ ))
fi
if [[ -n "$TEXT_CONTENT" ]]; then
    TPOS=$(text_position "$TEXT_POS")
    SAFE_TEXT=$(escape_drawtext "$TEXT_CONTENT")
    FILTER_PARTS+=("${CURRENT}drawtext=text='${SAFE_TEXT}':fontcolor=white:fontsize=24:${TPOS}:box=1:boxcolor=black@0.5:boxborderw=6[vtext]")
    CURRENT="[vtext]"
fi
if [[ "$USE_TIMESTAMP" == true ]]; then
    FILTER_PARTS+=("${CURRENT}drawtext=text='%{localtime\\:%F %T}':fontcolor=white:fontsize=20:x=10:y=10:box=1:boxcolor=black@0.5:boxborderw=5[vts]")
    CURRENT="[vts]"
fi
if [[ -n "$BANNER_TEXT" ]]; then
    SAFE_BANNER=$(escape_drawtext "$BANNER_TEXT")
    if [[ "$BANNER_POS" == "header" ]]; then
        BANNER_BAR_Y=0; BANNER_TEXT_Y=10
    else
        BANNER_BAR_Y="h-46"; BANNER_TEXT_Y="h-36"
    fi
    FILTER_PARTS+=("${CURRENT}drawbox=x=0:y=${BANNER_BAR_Y}:w=iw:h=46:color=black@0.72:t=fill,drawtext=text='${SAFE_BANNER}':fontcolor=white:fontsize=26:x=(w-text_w)/2:y=${BANNER_TEXT_Y}[vbanner]")
    CURRENT="[vbanner]"
fi

# --- Salida según transporte: rtmp (único o dual), tcp o udp (mpegts) ---
case "$TRANSPORT" in
    rtmp)
        if [[ -n "$DUAL_URL" ]]; then
            OUTPUT_ARGS=(-f tee "[f=flv:onfail=ignore]${URL}|[f=flv:onfail=ignore]${DUAL_URL}")
        else
            OUTPUT_ARGS=(-f flv "$URL")
        fi
        ;;
    tcp) OUTPUT_ARGS=(-f mpegts "tcp://0.0.0.0:${PORT}?listen=1") ;;
    udp) OUTPUT_ARGS=(-f mpegts "udp://${CLIENT_IP}:${PORT}") ;;
esac

AUDIO_MAP_ARGS=(-map "${EXTRA_IDX}:a:0")

if [[ "$CAPTURE_MODE" == "libcamera" ]]; then
    # --- CSI camera: libcamera-vid → pipe → ffmpeg ---
    if [[ "$HAS_OVERLAY" == false ]]; then
        libcamera-vid \
            --width "$WIDTH" --height "$HEIGHT" --framerate "$FPS" \
            --bitrate "$BITRATE" --codec h264 --inline \
            --timeout "$DURATION_MS" --output - \
        | ffmpeg -hide_banner -loglevel warning -re -i - \
            "${AUDIO_ARGS[@]}" \
            -vcodec copy "${OUTPUT_ARGS[@]}"
    else
        FILTER_COMPLEX=$(IFS=","; echo "${FILTER_PARTS[*]}")
        libcamera-vid \
            --width "$WIDTH" --height "$HEIGHT" --framerate "$FPS" \
            --bitrate "$BITRATE" --codec h264 --inline \
            --timeout "$DURATION_MS" --output - \
        | ffmpeg -hide_banner -loglevel warning -re -i - \
            "${EXTRA_INPUTS[@]}" "${AUDIO_ARGS[@]}" \
            -filter_complex "$FILTER_COMPLEX" \
            -map "$CURRENT" "${AUDIO_MAP_ARGS[@]}" \
            -vcodec libx264 -preset "$PRESET" -b:v "$BITRATE" \
            "${OUTPUT_ARGS[@]}"
    fi
else
    # --- USB camera: ffmpeg v4l2 directo ---
    DURATION_ARGS=()
    [[ "$DURATION" -gt 0 ]] && DURATION_ARGS=(-t "$DURATION")

    if [[ "$HAS_OVERLAY" == false ]]; then
        ffmpeg -hide_banner -loglevel warning \
            -f v4l2 -framerate "$FPS" -video_size "${WIDTH}x${HEIGHT}" -i "$VIDEO_DEV" \
            "${AUDIO_ARGS[@]}" \
            "${DURATION_ARGS[@]}" \
            -vcodec libx264 -preset "$PRESET" -b:v "$BITRATE" \
            "${OUTPUT_ARGS[@]}"
    else
        FILTER_COMPLEX=$(IFS=","; echo "${FILTER_PARTS[*]}")
        ffmpeg -hide_banner -loglevel warning \
            -f v4l2 -framerate "$FPS" -video_size "${WIDTH}x${HEIGHT}" -i "$VIDEO_DEV" \
            "${EXTRA_INPUTS[@]}" "${AUDIO_ARGS[@]}" \
            "${DURATION_ARGS[@]}" \
            -filter_complex "$FILTER_COMPLEX" \
            -map "$CURRENT" "${AUDIO_MAP_ARGS[@]}" \
            -vcodec libx264 -preset "$PRESET" -b:v "$BITRATE" \
            "${OUTPUT_ARGS[@]}"
    fi
fi
