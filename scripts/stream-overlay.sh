#!/usr/bin/env bash
# Transmite video en vivo con overlays aplicados: logo, marco, texto y timestamp.
# Puede usar el encoder de hardware h264_v4l2m2m (VideoCore) cuando GPU_ENCODER=true,
# con o sin overlays activos (cámara USB v4l2; libcamera CSI siempre usa libx264).
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
# Opciones de overlays (combinables, cada uno con su propio toggle *_ENABLED
# vía variable de entorno — ver más abajo):
#   --logo FILE    Ruta a PNG del logo (default: assets/logo.png si existe)
#   --logo-pos P   Posición del logo: tl, tr, bl, br, center (default: br)
#   --logo-pad N   Padding en px desde el borde (default: 20)
#   --frame FILE   Ruta a PNG del marco fullscreen (default: assets/frame.png si existe)
#   --text TEXT    Texto estático a mostrar en pantalla
#   --text-pos P   Posición del texto: tl, tr, bl, br, center (default: bl)
#   --timestamp    Mostrar timestamp en tiempo real
#   --timestamp-pos P  Posición del timestamp: tl, tr, bl, br, center (default: tl)
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
#   PREVIEW_OVERLAY  false (con PREVIEW_MODE=true) ignora logo/marco/texto/
#                    timestamp/banner configurados — preview sin overlays
#   OVERLAY_LOGO_ENABLED    false oculta el logo sin borrar OVERLAY_LOGO_FILE
#   OVERLAY_BANNER_ENABLED  false oculta el banner sin borrar OVERLAY_BANNER
#   OVERLAY_TEXT_ENABLED    false oculta el texto libre sin borrar OVERLAY_TEXT
#                           (los tres default true; --logo/--banner/--text por
#                           CLI siempre ganan, sin importar el toggle)
#
# Ejemplos:
#   ./stream-overlay.sh -u rtmp://a.rtmp.youtube.com/live2/KEY --logo assets/logo.png
#   ./stream-overlay.sh -u rtmp://localhost/live/test --logo assets/logo.png --logo-pos tr --timestamp
#   ./stream-overlay.sh -u rtmp://localhost/live/test --frame assets/frame.png --text "Demo en vivo"
#   ./stream-overlay.sh -u rtmp://localhost/live/test --logo assets/logo.png --frame assets/frame.png --timestamp --text "Raspi 3B"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ASSETS_DIR="${SCRIPT_DIR}/../assets"

# Importar detect_hw_encoder y helpers compartidos.
# die() local se define más abajo y sobreescribe la de common.sh.
_COMMON="${SCRIPT_DIR}/lib/common.sh"
if [[ -f "$_COMMON" ]]; then
    # shellcheck source=lib/common.sh
    source "$_COMMON"
else
    detect_hw_encoder() { echo ""; }
fi

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

# Cada overlay tiene su propio toggle *_ENABLED (default true — así los usos
# manuales del script por CLI, sin estas variables definidas, no cambian de
# comportamiento). El valor del overlay se guarda siempre en streaming.env
# aunque esté deshabilitado; solo el toggle decide si se usa en el pipeline.
LOGO_ENABLED=true
[[ "${OVERLAY_LOGO_ENABLED:-true}" != "true" ]] && LOGO_ENABLED=false
LOGO_FILE="${OVERLAY_LOGO_FILE:-}"
LOGO_POS="${OVERLAY_LOGO_POS:-tl}"
LOGO_PAD="${OVERLAY_LOGO_PAD:-20}"
LOGO_W="${OVERLAY_LOGO_W:-150}"
FRAME_FILE=""
TEXT_ENABLED=true
[[ "${OVERLAY_TEXT_ENABLED:-true}" != "true" ]] && TEXT_ENABLED=false
TEXT_CONTENT="${OVERLAY_TEXT:-}"
TEXT_POS="${OVERLAY_TEXT_POS:-bl}"
USE_TIMESTAMP=false
[[ "${OVERLAY_TIMESTAMP:-true}" == "true" ]] && USE_TIMESTAMP=true
TIMESTAMP_POS="${OVERLAY_TIMESTAMP_POS:-tl}"
BANNER_ENABLED=true
[[ "${OVERLAY_BANNER_ENABLED:-true}" != "true" ]] && BANNER_ENABLED=false
BANNER_TEXT="${OVERLAY_BANNER:-}"
BANNER_POS="${OVERLAY_BANNER_POS:-footer}"
# Marcan si --logo/--banner/--text llegaron por CLI (deben ganar siempre,
# sin importar lo que digan los toggles *_ENABLED del entorno).
_LOGO_FROM_CLI=false
_BANNER_FROM_CLI=false
_TEXT_FROM_CLI=false
DUAL_URL="${RTMP_URL_SECONDARY:-}"
AUDIO_BOOST=false
[[ "${STREAM_AUDIO_BOOST:-false}" == "true" ]] && AUDIO_BOOST=true
VIDEO_DEV="${VIDEO_DEVICE:-}"

TRANSPORT="${PREVIEW_TRANSPORT:-rtmp}"
PORT="${PREVIEW_PORT:-1935}"
CLIENT_IP="${PREVIEW_CLIENT_IP:-}"
RTMP_NAME="${PREVIEW_RTMP_NAME:-preview}"
PREVIEW_OVERLAY="${PREVIEW_OVERLAY:-true}"
GPU_ENCODER="${GPU_ENCODER:-false}"
VIDEO_SOURCE="${VIDEO_SOURCE:-auto}"
AUDIO_SOURCE="${AUDIO_SOURCE:-auto}"
VIDEO_INPUT_FORMAT="${VIDEO_INPUT_FORMAT:-}"
VIDEO_INPUT_WIDTH="${VIDEO_INPUT_WIDTH:-}"
VIDEO_INPUT_HEIGHT="${VIDEO_INPUT_HEIGHT:-}"
VIDEO_INPUT_FPS="${VIDEO_INPUT_FPS:-}"

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
# Orden obligatorio: \ primero, luego ' % y :, para no doble-escapar.
#   \  →  \\   (carácter de escape de ffmpeg)
#   '  →  \'   (cierra la comilla que rodea el valor)
#   %  →  %%   (prefijo de expresiones dinámicas %{...})
#   :  →  \:   (separador de opciones del filtergraph; las comillas simples
#              no lo protegen, p. ej. una URL "https://..." rompe el parser)
escape_drawtext() {
    printf '%s' "$1" \
        | sed 's/\\/\\\\/g' \
        | sed "s/'/\\\\'/g" \
        | sed 's/%/%%/g' \
        | sed 's/:/\\:/g'
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
        --logo)       LOGO_FILE="$2"; _LOGO_FROM_CLI=true; shift 2 ;;
        --logo-pos)   LOGO_POS="$2"; shift 2 ;;
        --logo-pad)   LOGO_PAD="$2"; shift 2 ;;
        --frame)      FRAME_FILE="$2"; shift 2 ;;
        --text)       TEXT_CONTENT="$2"; _TEXT_FROM_CLI=true; shift 2 ;;
        --text-pos)   TEXT_POS="$2"; shift 2 ;;
        --timestamp)  USE_TIMESTAMP=true; shift ;;
        --timestamp-pos) TIMESTAMP_POS="$2"; shift 2 ;;
        --no-audio)   NO_AUDIO=true; shift ;;
        --banner)       BANNER_TEXT="$2"; _BANNER_FROM_CLI=true; shift 2 ;;
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

# --- Detección de fuente de video y audio ---
command -v ffmpeg >/dev/null 2>&1 || die "ffmpeg no encontrado. Instalar con: sudo apt install ffmpeg"

MEDIA_SCRIPT="${SCRIPT_DIR}/media_autoconfig.py"
[[ -f "$MEDIA_SCRIPT" ]] || die "No se encuentra el resolvedor de medios: $MEDIA_SCRIPT"
MEDIA_ARGS=(--env /etc/streaming.env --shell-env --video-source "$VIDEO_SOURCE" --audio-source "$AUDIO_SOURCE")
[[ -n "$VIDEO_DEV" ]] && MEDIA_ARGS+=(--video-device "$VIDEO_DEV")
[[ -n "$AUDIO_DEV" ]] && MEDIA_ARGS+=(--audio-device "$AUDIO_DEV")
if ! MEDIA_ENV=$(python3 "$MEDIA_SCRIPT" "${MEDIA_ARGS[@]}" 2>/dev/null); then
    die "No se pudo autodetectar video/audio"
fi
eval "$MEDIA_ENV"

CAPTURE_MODE="$VIDEO_BACKEND"
if [[ "$CAPTURE_MODE" == "v4l2" ]]; then
    VIDEO_DEV="$VIDEO_DEVICE_RESOLVED"
    [[ -n "$VIDEO_DEV" && -e "$VIDEO_DEV" ]] || die "Dispositivo V4L2 no encontrado: $VIDEO_DEV"
    [[ "$VIDEO_INPUT_WIDTH" =~ ^[0-9]+$ && "$VIDEO_INPUT_HEIGHT" =~ ^[0-9]+$ ]] || die "Formato V4L2 inválido detectado"
    [[ "$VIDEO_INPUT_FPS" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "FPS V4L2 inválido detectado"
elif [[ "$CAPTURE_MODE" == "libcamera" ]]; then
    command -v libcamera-vid >/dev/null 2>&1 || die "libcamera-vid no encontrado y no hay captura V4L2 válida"
else
    die "No se detectó una fuente de video válida"
fi

[[ "$WIDTH" =~ ^[0-9]+$ ]]         || die "Ancho inválido: $WIDTH"
[[ "$HEIGHT" =~ ^[0-9]+$ ]]        || die "Alto inválido: $HEIGHT"
[[ "$FPS" =~ ^[0-9]+$ ]]           || die "FPS inválido: $FPS"
[[ "$BITRATE" =~ ^[0-9]+$ ]]       || die "Bitrate inválido: $BITRATE"
[[ "$AUDIO_BITRATE" =~ ^[0-9]+$ ]] || die "Bitrate de audio inválido: $AUDIO_BITRATE"
[[ "$DURATION" =~ ^[0-9]+$ ]]      || die "Duración inválida: $DURATION"

# Usar assets por defecto solo si el usuario NO definió la variable en el entorno.
# Si OVERLAY_LOGO_FILE está definida (aunque vacía) significa "sin logo" — no forzar el default.
if [[ -z "$LOGO_FILE" && "${OVERLAY_LOGO_FILE+set}" != "set" && -f "${ASSETS_DIR}/logo.png" ]]; then
    LOGO_FILE="${ASSETS_DIR}/logo.png"
fi
if [[ -z "$FRAME_FILE" && "${OVERLAY_FRAME_FILE+set}" != "set" && -f "${ASSETS_DIR}/frame.png" ]]; then
    FRAME_FILE="${ASSETS_DIR}/frame.png"
fi

# Aplicar el toggle *_ENABLED de cada overlay: si está apagado (y no vino por
# CLI explícito), su contenido no se usa, aunque siga guardado en streaming.env.
[[ "$LOGO_ENABLED"   != true && "$_LOGO_FROM_CLI"   == false ]] && LOGO_FILE=""
[[ "$BANNER_ENABLED" != true && "$_BANNER_FROM_CLI" == false ]] && BANNER_TEXT=""
[[ "$TEXT_ENABLED"   != true && "$_TEXT_FROM_CLI"   == false ]] && TEXT_CONTENT=""

if [[ "$PREVIEW_MODE" == "true" ]]; then
    # Nunca usar el destino real, sin importar -u/-k/RTMP_URL/STREAM_KEY/dual.
    URL=""; KEY=""; DUAL_URL=""

    if [[ "$PREVIEW_OVERLAY" != "true" ]]; then
        # Toggle "con overlay" del preview apagado: ignorar todo lo configurado.
        LOGO_FILE=""; FRAME_FILE=""; TEXT_CONTENT=""; USE_TIMESTAMP=false; BANNER_TEXT=""
    fi
fi

# Verificar archivos de assets si se especificaron
[[ -z "$LOGO_FILE"  || -f "$LOGO_FILE"  ]] || die "Logo no encontrado: $LOGO_FILE"
[[ -z "$FRAME_FILE" || -f "$FRAME_FILE" ]] || die "Marco no encontrado: $FRAME_FILE"

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


# --- Construir argumentos de audio ---
if [[ "$NO_AUDIO" == true ]]; then
    # YouTube Live requiere audio; usar fuente silenciosa en lugar de -an
    AUDIO_ARGS=(-f lavfi -i "anullsrc=r=44100:cl=stereo" -acodec aac -b:a 32k)
    AUDIO_INFO="silencio (AAC 32k — sin micrófono)"
else
    AUDIO_DEV="${AUDIO_DEVICE_RESOLVED:-$AUDIO_DEV}"
    if [[ -z "$AUDIO_DEV" ]]; then
        NO_AUDIO=true
        AUDIO_ARGS=(-f lavfi -i "anullsrc=r=44100:cl=stereo" -acodec aac -b:a 32k)
        AUDIO_INFO="silencio (AAC 32k — no hay entrada ALSA válida)"
    else
        echo "Audio seleccionado: ${AUDIO_DEV} (${AUDIO_KIND}) — ${AUDIO_DETECTION_REASON}"
        AUDIO_CH="${AUDIO_CHANNELS_RESOLVED:-$AUDIO_CH}"
        AUDIO_ARGS=(-thread_queue_size 8192 -f alsa -ar "$AUDIO_RATE_RESOLVED" -ac "$AUDIO_CH" -i "$AUDIO_DEV")
        AUDIO_RATE="$AUDIO_RATE_RESOLVED"
        if [[ "$AUDIO_BOOST" == true ]]; then
            AUDIO_ARGS+=(-af "aresample=async=1:min_hard_comp=0.100000:first_pts=0,volume=2.0")
        fi
        AUDIO_FILTER="highpass=f=20,aresample=async=1:min_hard_comp=0.100000:first_pts=0"
        [[ "$AUDIO_BOOST" == true ]] && AUDIO_FILTER+=",volume=2.0"
        AUDIO_ARGS+=(-af "$AUDIO_FILTER" -acodec aac -b:a "${AUDIO_BITRATE}")
        BOOST_LABEL=""; [[ "$AUDIO_BOOST" == true ]] && BOOST_LABEL=" +boost×2"
        AUDIO_INFO="${AUDIO_DEV} — AAC ${AUDIO_BITRATE} bps — ${AUDIO_RATE}Hz ${AUDIO_CH}ch${BOOST_LABEL}"
    fi
fi

# --- Determinar si hay overlays activos ---
HAS_OVERLAY=false
[[ -n "$LOGO_FILE" || -n "$FRAME_FILE" || -n "$TEXT_CONTENT" || "$USE_TIMESTAMP" == true || -n "$BANNER_TEXT" ]] && HAS_OVERLAY=true

# --- Detectar encoder GPU una sola vez ---
# h264_v4l2m2m acepta frames ya filtrados (overlay/drawtext) sin hwupload/hwdownload,
# así que puede usarse con o sin overlays activos (solo cámara USB v4l2, no libcamera).
_HW_ENC=""
if [[ "$GPU_ENCODER" == "true" && "$CAPTURE_MODE" != "libcamera" ]]; then
    _HW_ENC=$(detect_hw_encoder)
fi

# --- Información antes de transmitir ---
echo "=== Stream con overlays ==="
echo "  Resolución  : ${WIDTH}x${HEIGHT}"
echo "  FPS         : ${FPS}"
echo "  Entrada     : ${CAPTURE_MODE} ${VIDEO_DEV:-libcamera-vid} ${VIDEO_INPUT_FORMAT:-H264} ${VIDEO_INPUT_WIDTH:-$WIDTH}x${VIDEO_INPUT_HEIGHT:-$HEIGHT}@${VIDEO_INPUT_FPS:-$FPS}"
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
if [[ "$HAS_OVERLAY" == true && "$_HW_ENC" != "h264_v4l2m2m" ]]; then
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

if [[ "$CAPTURE_MODE" == "v4l2" ]]; then
    V4L2_INPUT_ARGS=(-thread_queue_size 8192 -f v4l2 -input_format "$VIDEO_INPUT_FORMAT" -framerate "$VIDEO_INPUT_FPS" -video_size "${VIDEO_INPUT_WIDTH}x${VIDEO_INPUT_HEIGHT}" -i "$VIDEO_DEV")
    VIDEO_SCALE_FILTER="scale=${WIDTH}:${HEIGHT}:force_original_aspect_ratio=decrease,pad=${WIDTH}:${HEIGHT}:(ow-iw)/2:(oh-ih)/2:color=black,format=yuv420p"
    FILTER_PARTS+=("${CURRENT}${VIDEO_SCALE_FILTER}[vscaled]")
    CURRENT="[vscaled]"
fi

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
    TSPOS=$(text_position "$TIMESTAMP_POS")
    FILTER_PARTS+=("${CURRENT}drawtext=text='%{localtime\\:%F %T}':fontcolor=white:fontsize=20:${TSPOS}:box=1:boxcolor=black@0.5:boxborderw=5[vts]")
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

# h264_v4l2m2m requiere 4:2:0; las imágenes de overlay (logo/frame PNG) suelen
# dejar el frame en un formato con alpha (yuva420p/rgba). Forzar conversión final.
if [[ "$HAS_OVERLAY" == true && "$_HW_ENC" == "h264_v4l2m2m" ]]; then
    FILTER_PARTS+=("${CURRENT}format=yuv420p[vgpu]")
    CURRENT="[vgpu]"
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

# h264_v4l2m2m no rellena el extradata (SPS/PPS) que el muxer FLV necesita
# ANTES de abrir la conexión RTMP. Servidores tolerantes (YouTube, Facebook)
# lo aceptan igual; servidores estrictos (mediamtx, usado en preview local)
# lo rechazan con "unable to parse H264 config: EOF" apenas conectan.
# Fix: codificar a MPEG-TS (no requiere extradata previo — el demuxer TS
# extrae el SPS/PPS del propio stream) y remuxear con -c copy a FLV/RTMP en
# un segundo proceso. tcp/udp ya usan mpegts directamente y no lo necesitan.
run_ffmpeg_pipeline() {
    if [[ "$_HW_ENC" == "h264_v4l2m2m" && "$TRANSPORT" == "rtmp" ]]; then
        ffmpeg -hide_banner -loglevel error "$@" -f mpegts - \
            | ffmpeg -hide_banner -loglevel warning -f mpegts -i - -c copy "${OUTPUT_ARGS[@]}"
    else
        ffmpeg -hide_banner -loglevel warning "$@" "${OUTPUT_ARGS[@]}"
    fi
}

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
        if [[ "$_HW_ENC" == "h264_v4l2m2m" ]]; then
            echo "Encoder: h264_v4l2m2m  (GPU VideoCore — menor uso de CPU)"
            echo ""
            run_ffmpeg_pipeline \
                "${V4L2_INPUT_ARGS[@]}" \
                "${AUDIO_ARGS[@]}" \
                "${DURATION_ARGS[@]}" \
                -vf "$VIDEO_SCALE_FILTER" \
                -vcodec h264_v4l2m2m -b:v "$BITRATE"
        else
            run_ffmpeg_pipeline \
                "${V4L2_INPUT_ARGS[@]}" \
                "${AUDIO_ARGS[@]}" \
                "${DURATION_ARGS[@]}" \
                -vf "$VIDEO_SCALE_FILTER" \
                -vcodec libx264 -preset "$PRESET" -b:v "$BITRATE"
        fi
    else
        FILTER_COMPLEX=$(IFS=","; echo "${FILTER_PARTS[*]}")
        if [[ "$_HW_ENC" == "h264_v4l2m2m" ]]; then
            echo "Encoder: h264_v4l2m2m  (GPU VideoCore — con overlays)"
            echo ""
            run_ffmpeg_pipeline \
                "${V4L2_INPUT_ARGS[@]}" \
                "${EXTRA_INPUTS[@]}" "${AUDIO_ARGS[@]}" \
                "${DURATION_ARGS[@]}" \
                -filter_complex "$FILTER_COMPLEX" \
                -map "$CURRENT" "${AUDIO_MAP_ARGS[@]}" \
                -vcodec h264_v4l2m2m -b:v "$BITRATE"
        else
            run_ffmpeg_pipeline \
                "${V4L2_INPUT_ARGS[@]}" \
                "${EXTRA_INPUTS[@]}" "${AUDIO_ARGS[@]}" \
                "${DURATION_ARGS[@]}" \
                -filter_complex "$FILTER_COMPLEX" \
                -map "$CURRENT" "${AUDIO_MAP_ARGS[@]}" \
                -vcodec libx264 -preset "$PRESET" -b:v "$BITRATE"
        fi
    fi
fi
