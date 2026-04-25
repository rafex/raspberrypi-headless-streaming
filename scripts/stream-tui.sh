#!/usr/bin/env bash
# TUI interactivo para configurar y lanzar un stream RTMP desde cámara USB.
# Permite elegir cámara, micrófono, plataforma (YouTube / Facebook / Custom)
# y stream key — con soporte de variables de entorno.
#
# Variables de entorno (opcionales):
#   YOUTUBE_STREAM_KEY   Stream key de YouTube Live
#   META_STREAM_KEY      Stream key de Facebook Live / Meta
#
# Uso:
#   ./stream-tui.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Variables globales de configuración (se rellenan en los pasos del TUI)
# ---------------------------------------------------------------------------
WIDTH=1280
HEIGHT=720
FPS=30
BITRATE=2500000

# ---------------------------------------------------------------------------
# Colores y helpers visuales
# ---------------------------------------------------------------------------
C_RESET='\033[0m'
C_BOLD='\033[1m'
C_CYAN='\033[1;36m'
C_GREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[1;31m'
C_DIM='\033[2m'

header() {
    echo ""
    echo -e "${C_CYAN}${C_BOLD}$*${C_RESET}"
    echo -e "${C_DIM}$(printf '─%.0s' {1..54})${C_RESET}"
}

ok()   { echo -e "  ${C_GREEN}[✓]${C_RESET} $*"; }
warn() { echo -e "  ${C_YELLOW}[!]${C_RESET} $*"; }
err()  { echo -e "  ${C_RED}[✗]${C_RESET} $*"; }
info() { echo -e "  ${C_DIM}$*${C_RESET}"; }

die() { err "$*"; exit 1; }

ask() {
    # ask "Pregunta" variable_destino [valor_default]
    local prompt="$1"
    local default="${3:-}"
    local hint=""
    [[ -n "$default" ]] && hint=" ${C_DIM}[${default}]${C_RESET}"
    echo -ne "  ${C_BOLD}${prompt}${C_RESET}${hint}: "
    read -r "$2"
    # Aplicar default si vacío
    if [[ -z "${!2}" && -n "$default" ]]; then
        printf -v "$2" '%s' "$default"
    fi
}

confirm() {
    # confirm "Pregunta" → retorna 0=sí, 1=no
    echo -ne "  ${C_BOLD}$1${C_RESET} ${C_DIM}[S/n]${C_RESET}: "
    read -r _ans
    [[ -z "$_ans" || "$_ans" =~ ^[SsYy]$ ]]
}

pick() {
    # pick IDX_VAR "Título" opción1 opción2 ...
    # Escribe toda la UI en stderr; guarda el índice elegido (0-based) en IDX_VAR
    local _var="$1"; shift
    local title="$1"; shift
    local options=("$@")
    local i

    echo "" >&2
    echo -e "  ${C_BOLD}${title}${C_RESET}" >&2
    echo "" >&2
    for i in "${!options[@]}"; do
        printf "    ${C_CYAN}%d)${C_RESET} %s\n" "$((i+1))" "${options[$i]}" >&2
    done
    echo "" >&2

    local _n
    while true; do
        echo -ne "  Elige [1-${#options[@]}]: " >&2
        read -r _n
        if [[ "$_n" =~ ^[0-9]+$ ]] \
           && [[ "$_n" -ge 1 ]] \
           && [[ "$_n" -le "${#options[@]}" ]]; then
            printf -v "$_var" '%d' "$((_n - 1))"
            return
        fi
        warn "Opción inválida. Elige un número entre 1 y ${#options[@]}." >&2
    done
}

# ---------------------------------------------------------------------------
# Detectar dispositivos
# ---------------------------------------------------------------------------
detect_cameras() {
    command -v v4l2-ctl >/dev/null 2>&1 || return
    for dev in /dev/video*; do
        [[ -e "$dev" ]] || continue
        if v4l2-ctl --device="$dev" --list-formats 2>/dev/null \
                | grep -qE "MJPG|MJPEG|YUYV|H264"; then
            local name
            name=$(v4l2-ctl --device="$dev" --info 2>/dev/null \
                | grep "Card type" | sed 's/.*: //' | xargs || echo "$dev")
            echo "${dev}|${name}"
        fi
    done
}

detect_mics() {
    command -v arecord >/dev/null 2>&1 || return
    arecord -l 2>/dev/null | grep "^card" | while IFS= read -r line; do
        local card_num dev_num card_name
        card_num=$(echo "$line" | grep -oE 'card [0-9]+' | grep -oE '[0-9]+')
        dev_num=$(echo  "$line" | grep -oE 'device [0-9]+' | grep -oE '[0-9]+')
        card_name=$(echo "$line" | grep -oE '\[[^]]+\]' | head -1 | tr -d '[]')
        echo "plughw:${card_num},${dev_num}|${card_name}"
    done
}

# Descarga un logo desde una URL (http/https) a /tmp si es necesario.
# Devuelve la ruta local del archivo descargado (o la original si ya es local).
logo_download_if_url() {
    local src="$1"
    if [[ "$src" =~ ^https?:// ]]; then
        local dest="/tmp/stream_logo_$$.png"
        echo "" >&2
        echo -e "  ${C_DIM}Descargando logo desde URL...${C_RESET}" >&2
        if command -v wget >/dev/null 2>&1; then
            wget -q -O "$dest" "$src" \
                && echo -e "  ${C_GREEN}[✓]${C_RESET} Descargado con wget → $dest" >&2 \
                || { echo -e "  ${C_RED}[✗]${C_RESET} Error al descargar con wget." >&2; echo ""; return; }
        elif command -v curl >/dev/null 2>&1; then
            curl -sL -o "$dest" "$src" \
                && echo -e "  ${C_GREEN}[✓]${C_RESET} Descargado con curl → $dest" >&2 \
                || { echo -e "  ${C_RED}[✗]${C_RESET} Error al descargar con curl." >&2; echo ""; return; }
        else
            echo -e "  ${C_RED}[✗]${C_RESET} wget ni curl encontrados. Instalar con: sudo apt install wget" >&2
            echo ""; return
        fi
        # Verificar que sea realmente una imagen
        if ! file "$dest" 2>/dev/null | grep -qiE "PNG|JPEG|image"; then
            echo -e "  ${C_YELLOW}[!]${C_RESET} El archivo descargado no parece ser una imagen PNG." >&2
        fi
        echo "$dest"
    else
        echo "$src"
    fi
}

# Redimensiona una imagen al ancho indicado conservando la proporción.
# Genera /tmp/stream_logo_resized_PID.png y devuelve su ruta.
# Usa ffmpeg (siempre disponible) o convert (ImageMagick) como alternativa.
# Si ambos fallan, devuelve la ruta original sin modificar.
logo_resize() {
    local src="$1"
    local width="$2"
    local dest="/tmp/stream_logo_resized_$$.png"

    echo "" >&2
    echo -e "  ${C_DIM}Redimensionando logo a ${width}px de ancho...${C_RESET}" >&2

    # ffmpeg: -vf scale=W:-1  (-1 = altura proporcional, redondea a par)
    if ffmpeg -hide_banner -loglevel error \
              -i "$src" -vf "scale=${width}:-2" -frames:v 1 \
              -y "$dest" 2>/dev/null; then
        echo -e "  ${C_GREEN}[✓]${C_RESET} Redimensionado con ffmpeg → $dest" >&2
        echo "$dest"
        return
    fi

    # Fallback: convert (ImageMagick)
    if command -v convert >/dev/null 2>&1; then
        if convert "$src" -resize "${width}x" "$dest" 2>/dev/null; then
            echo -e "  ${C_GREEN}[✓]${C_RESET} Redimensionado con convert → $dest" >&2
            echo "$dest"
            return
        fi
    fi

    # Sin resize: usar original
    echo -e "  ${C_YELLOW}[!]${C_RESET} No se pudo redimensionar — se usará la imagen original." >&2
    echo "$src"
}

supports_mjpeg() {
    v4l2-ctl --device="$1" --list-formats 2>/dev/null | grep -qE "MJPG|MJPEG"
}

mic_default_rate() {
    # Devuelve 48000 para BOYA/Focusrite, 44100 para el resto
    local name="$1"
    echo "$name" | grep -qi "boya\|boyalink\|focusrite\|scarlett" \
        && echo "48000" || echo "44100"
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
clear
echo ""
echo -e "${C_CYAN}${C_BOLD}╔══════════════════════════════════════════════════════╗${C_RESET}"
echo -e "${C_CYAN}${C_BOLD}║          stream-tui — Raspberry Pi Streaming         ║${C_RESET}"
echo -e "${C_CYAN}${C_BOLD}╚══════════════════════════════════════════════════════╝${C_RESET}"
echo ""

# ---------------------------------------------------------------------------
# PASO 1 — Cámara
# ---------------------------------------------------------------------------
header "1 / 5  Cámara USB"

mapfile -t CAM_RAW < <(detect_cameras)

if [[ "${#CAM_RAW[@]}" -eq 0 ]]; then
    die "No se detectó ninguna cámara USB. Conectar la cámara y reintentar."
fi

CAM_LABELS=()
CAM_DEVS=()
CAM_NAMES=()
for entry in "${CAM_RAW[@]}"; do
    CAM_DEVS+=("${entry%%|*}")
    CAM_NAMES+=("${entry##*|}")
    CAM_LABELS+=("${entry##*|}  (${entry%%|*})")
done

if [[ "${#CAM_RAW[@]}" -eq 1 ]]; then
    CAM_DEV="${CAM_DEVS[0]}"
    CAM_NAME="${CAM_NAMES[0]}"
    ok "Cámara detectada: $CAM_NAME ($CAM_DEV)"
else
    pick _IDX "Selecciona la cámara:" "${CAM_NAMES[@]}"
    CAM_DEV="${CAM_DEVS[$_IDX]}"
    CAM_NAME="${CAM_NAMES[$_IDX]}"
    ok "Cámara seleccionada: $CAM_NAME ($CAM_DEV)"
fi

# Resolución
_RES_OPTS=("1920x1080  (Full HD)" "1280x720   (HD — recomendado Pi 3B)" "854x480    (480p — menor CPU)" "640x360    (360p — mínimo uso de CPU)")
pick _IDX "Resolución:" "${_RES_OPTS[@]}"
case "$_IDX" in
    0) WIDTH=1920; HEIGHT=1080 ;;
    1) WIDTH=1280; HEIGHT=720  ;;
    2) WIDTH=854;  HEIGHT=480  ;;
    3) WIDTH=640;  HEIGHT=360  ;;
esac
ok "Resolución: ${WIDTH}x${HEIGHT}"

# ---------------------------------------------------------------------------
# PASO 2 — Micrófono
# ---------------------------------------------------------------------------
header "2 / 5  Micrófono"

mapfile -t MIC_RAW < <(detect_mics)

MIC_DEV=""
MIC_RATE=44100
MIC_CH=1

if [[ "${#MIC_RAW[@]}" -eq 0 ]]; then
    warn "No se detectó ningún micrófono."
    if confirm "¿Continuar sin audio?"; then
        NO_AUDIO=true
    else
        die "Conectar un micrófono y reintentar."
    fi
else
    NO_AUDIO=false
    MIC_LABELS=()
    MIC_DEVS=()
    MIC_NAMES=()
    for entry in "${MIC_RAW[@]}"; do
        MIC_DEVS+=("${entry%%|*}")
        MIC_NAMES+=("${entry##*|}")
        MIC_LABELS+=("${entry##*|}  (${entry%%|*})")
    done
    MIC_LABELS+=("Sin audio")

    if [[ "${#MIC_RAW[@]}" -eq 1 ]]; then
        MIC_DEV="${MIC_DEVS[0]}"
        MIC_NAME="${MIC_NAMES[0]}"
        MIC_RATE=$(mic_default_rate "$MIC_NAME")
        ok "Micrófono detectado: $MIC_NAME ($MIC_DEV — ${MIC_RATE}Hz)"
    else
        pick _IDX "Selecciona el micrófono:" "${MIC_LABELS[@]}"
        local_last="${#MIC_RAW[@]}"   # índice de "Sin audio"
        if [[ "$_IDX" -eq "$local_last" ]]; then
            NO_AUDIO=true
            ok "Sin audio"
        else
            MIC_DEV="${MIC_DEVS[$_IDX]}"
            MIC_NAME="${MIC_NAMES[$_IDX]}"
            MIC_RATE=$(mic_default_rate "$MIC_NAME")
            ok "Micrófono: $MIC_NAME ($MIC_DEV — ${MIC_RATE}Hz)"
        fi
    fi

    # Canales de audio (solo si hay micrófono)
    if [[ "$NO_AUDIO" == false ]]; then
        _CH_OPTS=("Mono   — 1 canal  (recomendado: BOYA, voz, menor CPU)" "Stereo — 2 canales (música, ambiente, webcam integrada)")
        pick _IDX "Canales de audio:" "${_CH_OPTS[@]}"
        case "$_IDX" in
            0) MIC_CH=1; ok "Audio: mono"   ;;
            1) MIC_CH=2; ok "Audio: stereo" ;;
        esac
    fi
fi

# ---------------------------------------------------------------------------
# PASO 3 — Plataforma y Stream Key
# ---------------------------------------------------------------------------
header "3 / 5  Plataforma de streaming"

_PLAT_OPTS=(
    "YouTube Live"
    "Facebook / Meta Live"
    "URL personalizada"
    "★ Dual stream — YouTube + Facebook  [experimental]"
)
pick _IDX "Plataforma:" "${_PLAT_OPTS[@]}"
PLATFORM="${_PLAT_OPTS[$_IDX]}"

RTMP_URL=""
STREAM_KEY=""
DUAL_STREAM=false   # flag para el modo dual
YT_URL=""
META_URL=""

case "$PLATFORM" in

    "YouTube Live")
        RTMP_BASE="rtmp://a.rtmp.youtube.com/live2"
        echo ""
        if [[ -n "${YOUTUBE_STREAM_KEY:-}" ]]; then
            STREAM_KEY="$YOUTUBE_STREAM_KEY"
            ok "Stream key leída de \$YOUTUBE_STREAM_KEY"
            info "${STREAM_KEY:0:4}****${STREAM_KEY: -4}"
        else
            warn "\$YOUTUBE_STREAM_KEY no definida."
            echo ""
            ask "Stream key de YouTube" STREAM_KEY
        fi
        [[ -n "$STREAM_KEY" ]] || die "Stream key requerida para YouTube."
        RTMP_URL="${RTMP_BASE}/${STREAM_KEY}"
        ;;

    "Facebook / Meta Live")
        RTMP_BASE="rtmps://live-api-s.facebook.com:443/rtmp"
        echo ""
        if [[ -n "${META_STREAM_KEY:-}" ]]; then
            STREAM_KEY="$META_STREAM_KEY"
            ok "Stream key leída de \$META_STREAM_KEY"
            info "${STREAM_KEY:0:4}****${STREAM_KEY: -4}"
        else
            warn "\$META_STREAM_KEY no definida."
            echo ""
            ask "Stream key de Facebook/Meta" STREAM_KEY
        fi
        [[ -n "$STREAM_KEY" ]] || die "Stream key requerida para Facebook/Meta."
        RTMP_URL="${RTMP_BASE}/${STREAM_KEY}"
        ;;

    "URL personalizada")
        echo ""
        ask "URL RTMP completa (incluyendo stream key)" RTMP_URL
        [[ -n "$RTMP_URL" ]] || die "URL requerida."
        ;;

    *"Dual stream"*)
        DUAL_STREAM=true
        echo ""
        warn "Modo experimental: ambas plataformas reciben el mismo stream."
        warn "Si una falla, la otra continúa (onfail=ignore)."
        echo ""

        # YouTube
        if [[ -n "${YOUTUBE_STREAM_KEY:-}" ]]; then
            YT_KEY="$YOUTUBE_STREAM_KEY"
            ok "YouTube key leída de \$YOUTUBE_STREAM_KEY"
            info "${YT_KEY:0:4}****${YT_KEY: -4}"
        else
            warn "\$YOUTUBE_STREAM_KEY no definida."
            ask "Stream key de YouTube" YT_KEY
        fi
        [[ -n "$YT_KEY" ]] || die "Stream key de YouTube requerida."
        YT_URL="rtmp://a.rtmp.youtube.com/live2/${YT_KEY}"

        echo ""

        # Facebook / Meta
        if [[ -n "${META_STREAM_KEY:-}" ]]; then
            META_KEY="$META_STREAM_KEY"
            ok "Facebook key leída de \$META_STREAM_KEY"
            info "${META_KEY:0:4}****${META_KEY: -4}"
        else
            warn "\$META_STREAM_KEY no definida."
            ask "Stream key de Facebook/Meta" META_KEY
        fi
        [[ -n "$META_KEY" ]] || die "Stream key de Facebook requerida."
        META_URL="rtmps://live-api-s.facebook.com:443/rtmp/${META_KEY}"

        # URL de display (no se usa para enviar, solo para el resumen)
        RTMP_URL="$YT_URL"
        ;;
esac

if [[ "$DUAL_STREAM" == false ]]; then
    ok "Destino: ${RTMP_URL:0:40}..."
else
    ok "YouTube : ${YT_URL:0:45}..."
    ok "Facebook: ${META_URL:0:45}..."
fi

# ---------------------------------------------------------------------------
# PASO 4 — Bitrate de video
# ---------------------------------------------------------------------------
header "4 / 5  Opciones de video"

_BR_OPTS=("4500 kbps  (alta calidad — requiere buena subida)" "2500 kbps  (balance — recomendado)" "1500 kbps  (bajo ancho de banda)" "800  kbps  (mínimo)")
pick _IDX "Bitrate de video:" "${_BR_OPTS[@]}"
case "$_IDX" in
    0) BITRATE=4500000 ;;
    1) BITRATE=2500000 ;;
    2) BITRATE=1500000 ;;
    3) BITRATE=800000  ;;
esac
ok "Bitrate: $((BITRATE / 1000)) kbps"

# Formato de entrada (MJPEG si disponible)
if supports_mjpeg "$CAM_DEV"; then
    INPUT_FORMAT="mjpeg"
    INPUT_FORMAT_LABEL="MJPEG"
else
    INPUT_FORMAT="yuyv422"
    INPUT_FORMAT_LABEL="YUYV"
fi

# ---------------------------------------------------------------------------
# PASO 5 — Overlays (logo + banner)
# ---------------------------------------------------------------------------
header "5 / 5  Overlays"

OVERLAY_LOGO=""
OVERLAY_LOGO_POS="br"   # tl tr bl br
OVERLAY_LOGO_PAD=20
OVERLAY_LOGO_W=120      # ancho en px — ffmpeg escala la imagen al iniciarse
OVERLAY_BANNER=""
OVERLAY_BANNER_POS="footer"  # header | footer

echo ""
if confirm "¿Agregar logo PNG en una esquina?"; then
    echo ""
    info "Puedes indicar una ruta local o una URL (http/https)."
    info "Tamaños recomendados según resolución:"
    info "  360p / 480p  →  60 – 80 px de ancho"
    info "  720p  (HD)   →  100 – 150 px de ancho  ← tu resolución actual si elegiste 720p"
    info "  1080p (FHD)  →  120 – 200 px de ancho"
    info "Formato ideal: PNG con fondo transparente (canal alfa)."
    info "Si no tienes PNG transparente, cualquier JPEG/PNG funciona también."
    echo ""
    ask "Ruta local o URL del logo" OVERLAY_LOGO

    if [[ -n "$OVERLAY_LOGO" ]]; then
        # Descargar si es URL
        OVERLAY_LOGO=$(logo_download_if_url "$OVERLAY_LOGO")

        if [[ -z "$OVERLAY_LOGO" || ! -f "$OVERLAY_LOGO" ]]; then
            warn "No se pudo obtener el logo — se omitirá."
            OVERLAY_LOGO=""
        else
            # Tamaño de visualización (el script escala la imagen en ffmpeg)
            # Calcular sugerencia según resolución
            if   [[ "$HEIGHT" -ge 1080 ]]; then _W_SUGG=150
            elif [[ "$HEIGHT" -ge  720 ]]; then _W_SUGG=120
            elif [[ "$HEIGHT" -ge  480 ]]; then _W_SUGG=90
            else                                _W_SUGG=70
            fi

            _W_OPTS=(
                "Automático — usar imagen tal como está (sin escalar)"
                "${_W_SUGG} px  — recomendado para ${HEIGHT}p"
                "80 px  — pequeño"
                "100 px — mediano"
                "150 px — grande"
                "200 px — muy grande"
                "Personalizado — ingresar valor"
            )
            pick _IDX "Ancho del logo en el video:" "${_W_OPTS[@]}"
            case "$_IDX" in
                0) OVERLAY_LOGO_W=0 ;;          # 0 = sin scale
                1) OVERLAY_LOGO_W="$_W_SUGG" ;;
                2) OVERLAY_LOGO_W=80  ;;
                3) OVERLAY_LOGO_W=100 ;;
                4) OVERLAY_LOGO_W=150 ;;
                5) OVERLAY_LOGO_W=200 ;;
                6) ask "Ancho en píxeles" OVERLAY_LOGO_W "$_W_SUGG" ;;
            esac

            _POS_OPTS=("br — inferior derecha (default)" "bl — inferior izquierda" "tr — superior derecha" "tl — superior izquierda")
            pick _IDX "Posición del logo:" "${_POS_OPTS[@]}"
            case "$_IDX" in
                0) OVERLAY_LOGO_POS="br" ;;
                1) OVERLAY_LOGO_POS="bl" ;;
                2) OVERLAY_LOGO_POS="tr" ;;
                3) OVERLAY_LOGO_POS="tl" ;;
            esac
            ask "Margen en píxeles desde el borde" OVERLAY_LOGO_PAD "20"

            # Resize previo al stream (una sola vez, menos CPU durante la transmisión)
            if [[ "$OVERLAY_LOGO_W" -gt 0 ]]; then
                OVERLAY_LOGO=$(logo_resize "$OVERLAY_LOGO" "$OVERLAY_LOGO_W")
                ok "Logo: $(basename "$OVERLAY_LOGO") — ${OVERLAY_LOGO_W}px — posición $OVERLAY_LOGO_POS (pad ${OVERLAY_LOGO_PAD}px)"
            else
                ok "Logo: $(basename "$OVERLAY_LOGO") — tamaño original — posición $OVERLAY_LOGO_POS (pad ${OVERLAY_LOGO_PAD}px)"
            fi
        fi
    else
        ok "Sin logo"
    fi
else
    ok "Sin logo"
fi

echo ""
if confirm "¿Agregar banner de texto (título / evento)?"; then
    ask "Texto del banner" OVERLAY_BANNER
    if [[ -n "$OVERLAY_BANNER" ]]; then
        _BP_OPTS=("footer — barra inferior (default)" "header — barra superior")
        pick _IDX "Posición del banner:" "${_BP_OPTS[@]}"
        case "$_IDX" in
            0) OVERLAY_BANNER_POS="footer" ;;
            1) OVERLAY_BANNER_POS="header" ;;
        esac
        ok "Banner: \"$OVERLAY_BANNER\" — $OVERLAY_BANNER_POS"
    fi
else
    ok "Sin banner"
fi

# ---------------------------------------------------------------------------
# RESUMEN FINAL
# ---------------------------------------------------------------------------
echo ""
echo -e "${C_CYAN}${C_BOLD}╔══════════════════════════════════════════════════════╗${C_RESET}"
echo -e "${C_CYAN}${C_BOLD}║                   Resumen del stream                 ║${C_RESET}"
echo -e "${C_CYAN}${C_BOLD}╚══════════════════════════════════════════════════════╝${C_RESET}"
echo ""
echo -e "  Cámara     : ${C_BOLD}$CAM_NAME${C_RESET} ($CAM_DEV)"
echo -e "  Resolución : ${C_BOLD}${WIDTH}x${HEIGHT}${C_RESET}"
echo -e "  Formato    : ${INPUT_FORMAT_LABEL}"
echo -e "  Bitrate    : ${C_BOLD}$((BITRATE / 1000)) kbps${C_RESET}"
if [[ "$NO_AUDIO" == true ]]; then
    echo -e "  Audio      : ${C_DIM}deshabilitado${C_RESET}"
else
    CH_LABEL="mono"; [[ "$MIC_CH" -eq 2 ]] && CH_LABEL="stereo"
    echo -e "  Audio      : ${C_BOLD}$MIC_NAME${C_RESET} ($MIC_DEV — ${MIC_RATE}Hz ${CH_LABEL})"
fi
echo -e "  Plataforma : ${C_BOLD}$PLATFORM${C_RESET}"
if [[ "$DUAL_STREAM" == true ]]; then
    echo -e "  YouTube    : ${C_DIM}${YT_URL:0:54}${C_RESET}"
    echo -e "  Facebook   : ${C_DIM}${META_URL:0:54}${C_RESET}"
else
    echo -e "  Destino    : ${C_DIM}${RTMP_URL:0:54}${C_RESET}"
fi
if [[ -n "$OVERLAY_LOGO" ]]; then
    if [[ "$OVERLAY_LOGO_W" -gt 0 ]]; then
        echo -e "  Logo       : ${C_BOLD}$(basename "$OVERLAY_LOGO")${C_RESET} — ${OVERLAY_LOGO_W}px — ${OVERLAY_LOGO_POS} (pad ${OVERLAY_LOGO_PAD}px)"
    else
        echo -e "  Logo       : ${C_BOLD}$(basename "$OVERLAY_LOGO")${C_RESET} — tamaño original — ${OVERLAY_LOGO_POS} (pad ${OVERLAY_LOGO_PAD}px)"
    fi
fi
if [[ -n "$OVERLAY_BANNER" ]]; then
    echo -e "  Banner     : ${C_BOLD}\"$OVERLAY_BANNER\"${C_RESET} — $OVERLAY_BANNER_POS"
fi
echo ""

if ! confirm "¿Iniciar stream?"; then
    echo ""
    info "Stream cancelado."
    echo ""
    exit 0
fi

# ---------------------------------------------------------------------------
# LANZAR STREAM
# ---------------------------------------------------------------------------
echo ""
echo -e "  ${C_GREEN}${C_BOLD}Iniciando stream... Ctrl+C para detener.${C_RESET}"
echo ""

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
_INPUT_FMT="$INPUT_FORMAT"

# -----------------------------------------------------------------------
# Buscar fuente de texto disponible para drawtext
# -----------------------------------------------------------------------
_FONT=""
for _f in \
    /usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf \
    /usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf \
    /usr/share/fonts/truetype/freefont/FreeSansBold.ttf \
    /usr/share/fonts/truetype/noto/NotoSans-Bold.ttf; do
    if [[ -f "$_f" ]]; then _FONT="fontfile=${_f}:"; break; fi
done

# -----------------------------------------------------------------------
# Construir filter_complex o -vf según overlays activos
# -----------------------------------------------------------------------
# Entradas ffmpeg:
#   [0]   cámara  (siempre)
#   [1]   logo PNG (solo si OVERLAY_LOGO no está vacío)
#   [N]   audio ALSA (índice = 1 sin logo, 2 con logo)
#
_LOGO_INPUTS=()
_AUDIO_IDX=1
_HAS_OVERLAY=false

[[ -n "$OVERLAY_LOGO" || -n "$OVERLAY_BANNER" ]] && _HAS_OVERLAY=true

if [[ -n "$OVERLAY_LOGO" ]]; then
    _LOGO_INPUTS=(-i "$OVERLAY_LOGO")
    _AUDIO_IDX=2
fi

# Calcular coordenadas del logo
_PAD="$OVERLAY_LOGO_PAD"
case "$OVERLAY_LOGO_POS" in
    tl) _LOGO_X="$_PAD";         _LOGO_Y="$_PAD" ;;
    tr) _LOGO_X="W-w-$_PAD";     _LOGO_Y="$_PAD" ;;
    bl) _LOGO_X="$_PAD";         _LOGO_Y="H-h-$_PAD" ;;
    br) _LOGO_X="W-w-$_PAD";     _LOGO_Y="H-h-$_PAD" ;;
esac

# Calcular posición Y del banner
_BAR_H=46   # altura de la barra en píxeles
_FONT_SIZE=26
case "$OVERLAY_BANNER_POS" in
    header)
        _BAR_Y="0"
        _TEXT_Y="$(( (_BAR_H - _FONT_SIZE) / 2 ))"
        ;;
    footer)
        _BAR_Y="h-${_BAR_H}"
        _TEXT_Y="h-${_BAR_H}+$(( (_BAR_H - _FONT_SIZE) / 2 ))"
        ;;
esac

# Escapar caracteres especiales del texto para drawtext
_BANNER_ESC="${OVERLAY_BANNER//:/\\:}"
_BANNER_ESC="${_BANNER_ESC//\'/\\'}"

# Construir el filtro de video
_VF_FILTER=""
_VIDEO_MAP=()
if [[ -n "$OVERLAY_BANNER" && -n "$OVERLAY_LOGO" ]]; then
    # Banner + logo: imagen ya redimensionada en /tmp — no hace falta scale en filtro
    _VF_FILTER="[0:v]drawbox=x=0:y=${_BAR_Y}:w=iw:h=${_BAR_H}:color=black@0.72:t=fill,\
drawtext=${_FONT}text='${_BANNER_ESC}':fontcolor=white:fontsize=${_FONT_SIZE}:\
x=(w-text_w)/2:y=${_TEXT_Y}[_txt];\
[_txt][1:v]overlay=x=${_LOGO_X}:y=${_LOGO_Y}[outv]"
    _VIDEO_MAP=(-map "[outv]")
elif [[ -n "$OVERLAY_BANNER" ]]; then
    # Solo banner: -vf directo (sin logo input)
    _VF_FILTER="drawbox=x=0:y=${_BAR_Y}:w=iw:h=${_BAR_H}:color=black@0.72:t=fill,\
drawtext=${_FONT}text='${_BANNER_ESC}':fontcolor=white:fontsize=${_FONT_SIZE}:\
x=(w-text_w)/2:y=${_TEXT_Y}"
    _VIDEO_MAP=()
elif [[ -n "$OVERLAY_LOGO" ]]; then
    # Solo logo: imagen ya redimensionada en /tmp
    _VF_FILTER="[0:v][1:v]overlay=x=${_LOGO_X}:y=${_LOGO_Y}[outv]"
    _VIDEO_MAP=(-map "[outv]")
fi

# Argumentos de filtro para ffmpeg
_FILTER_ARGS=()
if [[ -n "$OVERLAY_LOGO" ]]; then
    _FILTER_ARGS=(-filter_complex "$_VF_FILTER" "${_VIDEO_MAP[@]}")
elif [[ -n "$OVERLAY_BANNER" ]]; then
    _FILTER_ARGS=(-vf "$_VF_FILTER")
fi

# Argumentos de audio
_AUDIO_FFMPEG_ARGS=()
_AUDIO_MAP_ARGS=()
if [[ "$NO_AUDIO" == false ]]; then
    _AUDIO_FFMPEG_ARGS=(
        -thread_queue_size 8192
        -f alsa -ar "$MIC_RATE" -ac "$MIC_CH" -i "$MIC_DEV"
        -acodec aac -b:a 128k
        -af "aresample=async=1:min_hard_comp=0.100000:first_pts=0,volume=2.0"
    )
    # Con filter_complex hay que mapear el audio explícitamente
    [[ "${#_VIDEO_MAP[@]}" -gt 0 ]] && _AUDIO_MAP_ARGS=(-map "${_AUDIO_IDX}:a")
else
    _AUDIO_FFMPEG_ARGS=(-an)
fi

# -----------------------------------------------------------------------
# Modo normal (sin overlays, sin dual): delegar en usb-camera.sh
# -----------------------------------------------------------------------
if [[ "$DUAL_STREAM" == false && "$_HAS_OVERLAY" == false ]]; then
    _AUDIO_ARGS=()
    if [[ "$NO_AUDIO" == false ]]; then
        _AUDIO_ARGS=(--audio-dev "$MIC_DEV" --audio-rate "$MIC_RATE" --audio-ch "$MIC_CH")
    else
        _AUDIO_ARGS=(--no-audio)
    fi

    "${SCRIPT_DIR}/usb-camera.sh" \
        --dev "$CAM_DEV" \
        "${_AUDIO_ARGS[@]}" \
        -w "$WIDTH" \
        -h "$HEIGHT" \
        -b "$BITRATE" \
        -u "$RTMP_URL"
    exit 0
fi

# -----------------------------------------------------------------------
# Todos los demás modos usan ffmpeg directo (overlays y/o dual stream)
# -----------------------------------------------------------------------
[[ "$DUAL_STREAM" == true ]] && \
    echo -e "  ${C_YELLOW}[experimental]${C_RESET} Dual stream activo" && echo ""

# Destino de salida
if [[ "$DUAL_STREAM" == true ]]; then
    _OUTPUT_ARGS=(-f tee "[f=flv:onfail=ignore]${YT_URL}|[f=flv:onfail=ignore]${META_URL}")
else
    _OUTPUT_ARGS=(-f flv "$RTMP_URL")
fi

ffmpeg \
    -hide_banner \
    -loglevel warning \
    -stats \
    -thread_queue_size 8192 \
    -f v4l2 \
    -input_format "$_INPUT_FMT" \
    -video_size "${WIDTH}x${HEIGHT}" \
    -framerate "$FPS" \
    -i "$CAM_DEV" \
    "${_LOGO_INPUTS[@]}" \
    "${_AUDIO_FFMPEG_ARGS[@]}" \
    "${_FILTER_ARGS[@]}" \
    "${_AUDIO_MAP_ARGS[@]}" \
    -vcodec libx264 \
    -preset ultrafast \
    -b:v "$BITRATE" \
    -fps_mode cfr \
    "${_OUTPUT_ARGS[@]}"
