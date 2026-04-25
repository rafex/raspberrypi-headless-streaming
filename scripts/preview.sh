#!/usr/bin/env bash
# Vista previa local de cámara + audio + overlays — ver en VLC antes del stream real.
# Transmite por TCP (Pi escucha, VLC conecta) o UDP (Pi empuja al Mac).
# Usa exactamente el mismo pipeline de video que stream-tui.sh:
# mismo codec, mismo logo, mismo banner — lo que ves es lo que transmites.
#
# Uso:
#   ./preview.sh
#
# Requisitos:
#   ffmpeg  v4l2-ctl  arecord
#   VLC en tu Mac (o cualquier cliente MPEG-TS)
#
# Ejemplo de conexión desde el Mac:
#   TCP (Pi escucha):  vlc tcp://IP_DE_LA_PI:1234
#   UDP (Pi empuja):   vlc udp://@:1234

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# ---------------------------------------------------------------------------
# Variables globales — sobreescritas por los pasos del TUI
# ---------------------------------------------------------------------------
WIDTH=1280; HEIGHT=720; FPS=30; BITRATE=1500000
CAM_DEV=""; CAM_NAME=""
INPUT_FORMAT="mjpeg"; INPUT_FORMAT_LABEL="MJPEG"
MIC_DEV=""; MIC_NAME=""; MIC_RATE=44100; MIC_CH=1; NO_AUDIO=false
OVERLAY_LOGO=""; OVERLAY_LOGO_POS="br"; OVERLAY_LOGO_PAD=20; OVERLAY_LOGO_W=120
OVERLAY_BANNER=""; OVERLAY_BANNER_POS="footer"
PROTO="tcp"
PORT=1234
MAC_IP=""

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
clear
echo ""
echo -e "${C_CYAN}${C_BOLD}╔══════════════════════════════════════════════════════╗${C_RESET}"
echo -e "${C_CYAN}${C_BOLD}║       preview — Vista previa local  (VLC)            ║${C_RESET}"
echo -e "${C_CYAN}${C_BOLD}╚══════════════════════════════════════════════════════╝${C_RESET}"
echo ""
info "Prueba cámara, audio y overlays antes de ir en vivo."
info "El pipeline es idéntico al del stream real."

# ---------------------------------------------------------------------------
# PASO 1 — Cámara + resolución
# ---------------------------------------------------------------------------
header "1 / 5  Cámara USB"
tui_camera_resolution

# ---------------------------------------------------------------------------
# PASO 2 — Micrófono + canales
# ---------------------------------------------------------------------------
header "2 / 5  Micrófono"
tui_mic_channels

# ---------------------------------------------------------------------------
# PASO 3 — Calidad de preview
# ---------------------------------------------------------------------------
header "3 / 5  Calidad de preview"

info "Bitrate más bajo = menor CPU en la Pi, suficiente para verificar calidad visual."
echo ""
_BR_OPTS=(
    "1500 kbps  (recomendado para preview local)"
    "2500 kbps  (igual que el stream real)"
    "800  kbps  (mínimo — Pi 3B con carga alta)"
)
pick _IDX "Bitrate de preview:" "${_BR_OPTS[@]}"
case "$_IDX" in
    0) BITRATE=1500000 ;;
    1) BITRATE=2500000 ;;
    2) BITRATE=800000  ;;
esac
ok "Bitrate: $((BITRATE / 1000)) kbps"
ok "Formato de entrada: $INPUT_FORMAT_LABEL"

# ---------------------------------------------------------------------------
# PASO 4 — Overlays (logo + banner)
# ---------------------------------------------------------------------------
header "4 / 5  Overlays"
overlay_tui

# ---------------------------------------------------------------------------
# PASO 5 — Transporte (TCP / UDP)
# ---------------------------------------------------------------------------
header "5 / 5  Transporte"

echo ""
info "TCP: la Pi espera la conexión de VLC — más simple, no necesitas la IP del Mac."
info "UDP: la Pi envía al Mac de inmediato — menor latencia, necesitas la IP del Mac."
echo ""

_TRANS_OPTS=(
    "TCP — Pi escucha, VLC conecta  (recomendado)"
    "UDP — Pi empuja al Mac         (menor latencia)"
)
pick _IDX "Protocolo:" "${_TRANS_OPTS[@]}"
case "$_IDX" in
    0) PROTO="tcp" ;;
    1) PROTO="udp" ;;
esac

ask "Puerto" PORT "1234"

if [[ "$PROTO" == "udp" ]]; then
    echo ""
    info "Para encontrar la IP de tu Mac: ifconfig | grep 'inet ' | grep -v 127"
    ask "IP de tu Mac en la red local" MAC_IP
    [[ -n "$MAC_IP" ]] || die "IP del Mac requerida para modo UDP."
fi
ok "Protocolo: ${PROTO^^}  puerto ${PORT}"

# ---------------------------------------------------------------------------
# Detectar IP de la Raspberry Pi
# ---------------------------------------------------------------------------
PI_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
if [[ -z "$PI_IP" ]]; then
    PI_IP=$(ip route get 1 2>/dev/null | grep -oE 'src [^ ]+' | awk '{print $2}' || true)
fi
if [[ -z "$PI_IP" ]]; then
    PI_IP="<IP_DE_LA_PI>"
    warn "No se pudo detectar la IP automáticamente."
    warn "Buscarla con: hostname -I | awk '{print \$1}'"
fi

# ---------------------------------------------------------------------------
# RESUMEN FINAL
# ---------------------------------------------------------------------------
echo ""
echo -e "${C_CYAN}${C_BOLD}╔══════════════════════════════════════════════════════╗${C_RESET}"
echo -e "${C_CYAN}${C_BOLD}║                  Resumen de preview                  ║${C_RESET}"
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
echo -e "  Transporte : ${C_BOLD}${PROTO^^}${C_RESET}  puerto ${PORT}"
echo ""

# Comando VLC a copiar
echo -e "${C_CYAN}${C_BOLD}╔══════════════════════════════════════════════════════╗${C_RESET}"
echo -e "${C_CYAN}${C_BOLD}║  Comando VLC para tu Mac                             ║${C_RESET}"
echo -e "${C_CYAN}${C_BOLD}╚══════════════════════════════════════════════════════╝${C_RESET}"
echo ""
if [[ "$PROTO" == "tcp" ]]; then
    echo -e "  ${C_BOLD}${C_GREEN}vlc tcp://${PI_IP}:${PORT}${C_RESET}"
    echo ""
    info "Abre VLC en tu Mac DESPUÉS de que aparezca 'Esperando conexión...'"
    info "TCP necesita que ffmpeg esté escuchando antes de que VLC conecte."
else
    echo -e "  ${C_BOLD}${C_GREEN}vlc udp://@:${PORT}${C_RESET}"
    echo ""
    info "Abre VLC en tu Mac ANTES de iniciar el preview."
    info "UDP empuja el stream sin esperar — si VLC no está listo lo pierde."
fi
echo ""

if ! confirm "¿Iniciar preview?"; then
    echo ""
    info "Preview cancelado."
    echo ""
    exit 0
fi

# ---------------------------------------------------------------------------
# LANZAR PREVIEW
# ---------------------------------------------------------------------------
echo ""

build_overlay_args
build_audio_ffmpeg_args

if [[ "$PROTO" == "tcp" ]]; then
    _output_args=(-f mpegts "tcp://0.0.0.0:${PORT}?listen=1")
    echo -e "  ${C_GREEN}${C_BOLD}Esperando conexión de VLC...${C_RESET}"
    echo ""
    echo -e "  En tu Mac:"
    echo -e "  ${C_BOLD}${C_CYAN}vlc tcp://${PI_IP}:${PORT}${C_RESET}"
else
    _output_args=(-f mpegts "udp://${MAC_IP}:${PORT}")
    echo -e "  ${C_GREEN}${C_BOLD}Iniciando preview UDP → ${MAC_IP}:${PORT}...${C_RESET}"
    echo -e "  Ctrl+C para detener."
fi
echo ""

ffmpeg \
    -hide_banner \
    -loglevel warning \
    -stats \
    -thread_queue_size 8192 \
    -f v4l2 \
    -input_format "$INPUT_FORMAT" \
    -video_size "${WIDTH}x${HEIGHT}" \
    -framerate "$FPS" \
    -i "$CAM_DEV" \
    "${_LOGO_INPUTS[@]}" \
    "${_AUDIO_FFMPEG_ARGS[@]}" \
    "${_FILTER_ARGS[@]}" \
    "${_AUDIO_MAP_ARGS[@]}" \
    -vcodec libx264 \
    -preset ultrafast \
    -tune zerolatency \
    -g "$FPS" \
    -keyint_min "$FPS" \
    -sc_threshold 0 \
    -b:v "$BITRATE" \
    -fps_mode cfr \
    -muxdelay 0 \
    -muxpreload 0 \
    -flush_packets 1 \
    "${_output_args[@]}"
