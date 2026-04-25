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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# ---------------------------------------------------------------------------
# Variables globales — sobreescritas por los pasos del TUI
# ---------------------------------------------------------------------------
WIDTH=1280; HEIGHT=720; FPS=30; BITRATE=2500000
CAM_DEV=""; CAM_NAME=""
INPUT_FORMAT="mjpeg"; INPUT_FORMAT_LABEL="MJPEG"
MIC_DEV=""; MIC_NAME=""; MIC_RATE=44100; MIC_CH=1; NO_AUDIO=false
OVERLAY_LOGO=""; OVERLAY_LOGO_POS="br"; OVERLAY_LOGO_PAD=20; OVERLAY_LOGO_W=120
OVERLAY_BANNER=""; OVERLAY_BANNER_POS="footer"

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
DUAL_STREAM=false
YT_URL=""; META_URL=""

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

_BR_OPTS=(
    "4500 kbps  (alta calidad — requiere buena subida)"
    "2500 kbps  (balance — recomendado)"
    "1500 kbps  (bajo ancho de banda)"
    "800  kbps  (mínimo)"
)
pick _IDX "Bitrate de video:" "${_BR_OPTS[@]}"
case "$_IDX" in
    0) BITRATE=4500000 ;;
    1) BITRATE=2500000 ;;
    2) BITRATE=1500000 ;;
    3) BITRATE=800000  ;;
esac
ok "Bitrate: $((BITRATE / 1000)) kbps"
ok "Formato de entrada: $INPUT_FORMAT_LABEL"

# ---------------------------------------------------------------------------
# PASO 5 — Overlays (logo + banner)
# ---------------------------------------------------------------------------
header "5 / 5  Overlays"
overlay_tui

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

build_overlay_args
build_audio_ffmpeg_args

# Sin overlays y sin dual stream: delegar en usb-camera.sh (ruta simple)
if [[ "$DUAL_STREAM" == false && "$_HAS_OVERLAY" == false ]]; then
    _audio_pass=()
    if [[ "$NO_AUDIO" == false ]]; then
        _audio_pass=(--audio-dev "$MIC_DEV" --audio-rate "$MIC_RATE" --audio-ch "$MIC_CH")
    else
        _audio_pass=(--no-audio)
    fi
    "${SCRIPT_DIR}/usb-camera.sh" \
        --dev "$CAM_DEV" \
        "${_audio_pass[@]}" \
        -w "$WIDTH" -h "$HEIGHT" -b "$BITRATE" \
        -u "$RTMP_URL"
    exit 0
fi

[[ "$DUAL_STREAM" == true ]] && echo -e "  ${C_YELLOW}[experimental]${C_RESET} Dual stream activo" && echo ""

if [[ "$DUAL_STREAM" == true ]]; then
    _output_args=(-f tee "[f=flv:onfail=ignore]${YT_URL}|[f=flv:onfail=ignore]${META_URL}")
else
    _output_args=(-f flv "$RTMP_URL")
fi

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
    -b:v "$BITRATE" \
    -fps_mode cfr \
    "${_output_args[@]}"
