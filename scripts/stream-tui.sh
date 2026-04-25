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
header "1 / 4  Cámara USB"

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
    CAM_LABELS+=("${entry##*|}  ${C_DIM}(${entry%%|*})${C_RESET}")
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
header "2 / 4  Micrófono"

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
        MIC_LABELS+=("${entry##*|}  ${C_DIM}(${entry%%|*})${C_RESET}")
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
header "3 / 4  Plataforma de streaming"

_PLAT_OPTS=("YouTube Live" "Facebook / Meta Live" "URL personalizada")
pick _IDX "Plataforma:" "${_PLAT_OPTS[@]}"
PLATFORM="${_PLAT_OPTS[$_IDX]}"

RTMP_URL=""
STREAM_KEY=""

case "$PLATFORM" in

    "YouTube Live")
        RTMP_BASE="rtmp://a.rtmp.youtube.com/live2"
        echo ""
        # Buscar en variable de entorno
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
esac

ok "Destino: ${RTMP_URL:0:40}..."

# ---------------------------------------------------------------------------
# PASO 4 — Opciones adicionales
# ---------------------------------------------------------------------------
header "4 / 4  Opciones de video"

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
echo -e "  Destino    : ${C_DIM}${RTMP_URL:0:54}${C_RESET}"
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

# Construir argumentos de audio
AUDIO_ARGS=()
if [[ "$NO_AUDIO" == false ]]; then
    AUDIO_ARGS=(--audio-dev "$MIC_DEV" --audio-rate "$MIC_RATE" --audio-ch "$MIC_CH")
else
    AUDIO_ARGS=(--no-audio)
fi

# Llamar a usb-camera.sh con los parámetros elegidos
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

"${SCRIPT_DIR}/usb-camera.sh" \
    --dev "$CAM_DEV" \
    "${AUDIO_ARGS[@]}" \
    -w "$WIDTH" \
    -h "$HEIGHT" \
    -b "$BITRATE" \
    -u "$RTMP_URL"
