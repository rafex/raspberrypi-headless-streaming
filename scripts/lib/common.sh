#!/usr/bin/env bash
# Funciones compartidas entre stream-tui.sh y preview-tui.sh.
# No ejecutar directamente — cargar con:
#   source "$(dirname "$0")/lib/common.sh"

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
die()  { err "$*"; exit 1; }

ask() {
    # ask "Pregunta" VARIABLE [default]
    local prompt="$1"
    local default="${3:-}"
    local hint=""
    [[ -n "$default" ]] && hint=" ${C_DIM}[${default}]${C_RESET}"
    echo -ne "  ${C_BOLD}${prompt}${C_RESET}${hint}: "
    read -r "$2"
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
    # Escribe la UI en stderr; guarda índice 0-based en IDX_VAR.
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
# Detección de dispositivos
# ---------------------------------------------------------------------------
detect_cameras() {
    command -v v4l2-ctl >/dev/null 2>&1 || return
    local dev name
    for dev in /dev/video*; do
        [[ -e "$dev" ]] || continue
        if v4l2-ctl --device="$dev" --list-formats 2>/dev/null \
                | grep -qE "MJPG|MJPEG|YUYV|H264"; then
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
        card_num=$(echo "$line" | grep -oE 'card [0-9]+'  | grep -oE '[0-9]+')
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
# Logo: descarga desde URL y resize previo al stream
# ---------------------------------------------------------------------------
logo_download_if_url() {
    # Descarga src a /tmp si es http/https. Devuelve ruta local resultante.
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
            echo -e "  ${C_RED}[✗]${C_RESET} wget ni curl encontrados. Instalar: sudo apt install wget" >&2
            echo ""; return
        fi
        if ! file "$dest" 2>/dev/null | grep -qiE "PNG|JPEG|image"; then
            echo -e "  ${C_YELLOW}[!]${C_RESET} El archivo descargado no parece ser una imagen PNG." >&2
        fi
        echo "$dest"
    else
        echo "$src"
    fi
}

logo_resize() {
    # Redimensiona src al ancho dado. Devuelve ruta de imagen resultante en /tmp.
    local src="$1"
    local width="$2"
    local dest="/tmp/stream_logo_resized_$$.png"

    echo "" >&2
    echo -e "  ${C_DIM}Redimensionando logo a ${width}px de ancho...${C_RESET}" >&2

    if ffmpeg -hide_banner -loglevel error \
              -i "$src" -vf "scale=${width}:-2" -frames:v 1 \
              -y "$dest" 2>/dev/null; then
        echo -e "  ${C_GREEN}[✓]${C_RESET} Redimensionado con ffmpeg → $dest" >&2
        echo "$dest"; return
    fi

    if command -v convert >/dev/null 2>&1; then
        if convert "$src" -resize "${width}x" "$dest" 2>/dev/null; then
            echo -e "  ${C_GREEN}[✓]${C_RESET} Redimensionado con convert → $dest" >&2
            echo "$dest"; return
        fi
    fi

    echo -e "  ${C_YELLOW}[!]${C_RESET} No se pudo redimensionar — se usará la imagen original." >&2
    echo "$src"
}

# ---------------------------------------------------------------------------
# find_font
# Detecta una fuente TTF disponible y establece la variable global _FONT.
# Formato: "fontfile=/ruta/fuente.ttf:"  (incluye el separador ":" de ffmpeg)
# Vacío si no hay ninguna fuente instalada.
# ---------------------------------------------------------------------------
find_font() {
    _FONT=""
    local _f
    for _f in \
        /usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf \
        /usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf \
        /usr/share/fonts/truetype/freefont/FreeSansBold.ttf \
        /usr/share/fonts/truetype/noto/NotoSans-Bold.ttf; do
        if [[ -f "$_f" ]]; then
            _FONT="fontfile=${_f}:"
            return
        fi
    done
}

# ---------------------------------------------------------------------------
# overlay_tui
# Paso interactivo completo de overlays: logo + banner + fecha/hora.
# Lee HEIGHT (global) para recomendaciones de tamaño de logo.
# Establece las variables globales:
#   OVERLAY_LOGO  OVERLAY_LOGO_POS  OVERLAY_LOGO_PAD  OVERLAY_LOGO_W
#   OVERLAY_BANNER  OVERLAY_BANNER_POS
#   OVERLAY_TIMESTAMP  OVERLAY_TIMESTAMP_POS
# ---------------------------------------------------------------------------
overlay_tui() {
    OVERLAY_LOGO=""
    OVERLAY_LOGO_POS="br"
    OVERLAY_LOGO_PAD=20
    OVERLAY_LOGO_W=120
    OVERLAY_BANNER=""
    OVERLAY_BANNER_POS="footer"
    OVERLAY_TIMESTAMP=false
    OVERLAY_TIMESTAMP_POS="tl"

    echo ""
    if confirm "¿Agregar logo PNG en una esquina?"; then
        echo ""
        info "Puedes indicar una ruta local o una URL (http/https)."
        info "Tamaños recomendados según resolución:"
        info "  360p / 480p  →  60 – 80 px de ancho"
        info "  720p  (HD)   →  100 – 150 px de ancho"
        info "  1080p (FHD)  →  120 – 200 px de ancho"
        info "Formato ideal: PNG con fondo transparente (canal alfa)."
        echo ""
        ask "Ruta local o URL del logo" OVERLAY_LOGO

        if [[ -n "$OVERLAY_LOGO" ]]; then
            OVERLAY_LOGO=$(logo_download_if_url "$OVERLAY_LOGO")

            if [[ -z "$OVERLAY_LOGO" || ! -f "$OVERLAY_LOGO" ]]; then
                warn "No se pudo obtener el logo — se omitirá."
                OVERLAY_LOGO=""
            else
                local _h="${HEIGHT:-720}"
                local _W_SUGG
                if   [[ "$_h" -ge 1080 ]]; then _W_SUGG=150
                elif [[ "$_h" -ge  720 ]]; then _W_SUGG=120
                elif [[ "$_h" -ge  480 ]]; then _W_SUGG=90
                else                            _W_SUGG=70
                fi

                local _W_OPTS=(
                    "Automático — usar imagen tal como está (sin escalar)"
                    "${_W_SUGG} px  — recomendado para ${_h}p"
                    "80 px  — pequeño"
                    "100 px — mediano"
                    "150 px — grande"
                    "200 px — muy grande"
                    "Personalizado — ingresar valor"
                )
                pick _IDX "Ancho del logo en el video:" "${_W_OPTS[@]}"
                case "$_IDX" in
                    0) OVERLAY_LOGO_W=0 ;;
                    1) OVERLAY_LOGO_W="$_W_SUGG" ;;
                    2) OVERLAY_LOGO_W=80  ;;
                    3) OVERLAY_LOGO_W=100 ;;
                    4) OVERLAY_LOGO_W=150 ;;
                    5) OVERLAY_LOGO_W=200 ;;
                    6) ask "Ancho en píxeles" OVERLAY_LOGO_W "$_W_SUGG" ;;
                esac

                local _POS_OPTS=(
                    "br — inferior derecha (default)"
                    "bl — inferior izquierda"
                    "tr — superior derecha"
                    "tl — superior izquierda"
                )
                pick _IDX "Posición del logo:" "${_POS_OPTS[@]}"
                case "$_IDX" in
                    0) OVERLAY_LOGO_POS="br" ;;
                    1) OVERLAY_LOGO_POS="bl" ;;
                    2) OVERLAY_LOGO_POS="tr" ;;
                    3) OVERLAY_LOGO_POS="tl" ;;
                esac
                ask "Margen en píxeles desde el borde" OVERLAY_LOGO_PAD "20"

                if [[ "$OVERLAY_LOGO_W" -gt 0 ]]; then
                    OVERLAY_LOGO=$(logo_resize "$OVERLAY_LOGO" "$OVERLAY_LOGO_W")
                    ok "Logo: $(basename "$OVERLAY_LOGO") — ${OVERLAY_LOGO_W}px — $OVERLAY_LOGO_POS (pad ${OVERLAY_LOGO_PAD}px)"
                else
                    ok "Logo: $(basename "$OVERLAY_LOGO") — tamaño original — $OVERLAY_LOGO_POS (pad ${OVERLAY_LOGO_PAD}px)"
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
            local _BP_OPTS=("footer — barra inferior (default)" "header — barra superior")
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

    echo ""
    if confirm "¿Agregar fecha y hora actual?"; then
        OVERLAY_TIMESTAMP=true
        local _TP_OPTS=(
            "tl — superior izquierda (default)"
            "tr — superior derecha"
            "bl — inferior izquierda"
            "br — inferior derecha"
        )
        pick _IDX "Posición de fecha/hora:" "${_TP_OPTS[@]}"
        case "$_IDX" in
            0) OVERLAY_TIMESTAMP_POS="tl" ;;
            1) OVERLAY_TIMESTAMP_POS="tr" ;;
            2) OVERLAY_TIMESTAMP_POS="bl" ;;
            3) OVERLAY_TIMESTAMP_POS="br" ;;
        esac
        ok "Fecha/hora: activada — $OVERLAY_TIMESTAMP_POS"
    else
        ok "Sin fecha/hora"
    fi
}

# ---------------------------------------------------------------------------
# build_overlay_args
# Construye los argumentos ffmpeg para logo + banner + fecha/hora a partir de
# las variables OVERLAY_* establecidas por overlay_tui (o manualmente).
# Encadena los overlays activos (cualquier combinación) sobre un único
# filter_complex: banner → fecha/hora → logo.
#
# Establece las variables globales (arrays y strings):
#   _LOGO_INPUTS    array  — (-i logo.png) o vacío
#   _AUDIO_IDX      int    — 1 sin logo, 2 con logo (índice de input de audio)
#   _HAS_OVERLAY    bool   — true si hay al menos un overlay activo
#   _FILTER_ARGS    array  — args de filtro completos para ffmpeg
#   _AUDIO_MAP_ARGS array  — (-map N:a) cuando hace falta mapear audio, o vacío
#   _BANNER_FILE    str    — ruta a /tmp/stream_banner_PID.txt o ""
# ---------------------------------------------------------------------------
build_overlay_args() {
    _LOGO_INPUTS=()
    _AUDIO_IDX=1
    _HAS_OVERLAY=false
    _FILTER_ARGS=()
    _AUDIO_MAP_ARGS=()
    _BANNER_FILE=""

    [[ -n "${OVERLAY_LOGO:-}" || -n "${OVERLAY_BANNER:-}" || "${OVERLAY_TIMESTAMP:-false}" == true ]] \
        && _HAS_OVERLAY=true

    if [[ -n "${OVERLAY_LOGO:-}" ]]; then
        _LOGO_INPUTS=(-i "$OVERLAY_LOGO")
        _AUDIO_IDX=2
    fi

    find_font  # establece _FONT global

    # Coordenadas del logo según posición elegida
    local _pad="${OVERLAY_LOGO_PAD:-20}"
    local _logo_x="" _logo_y=""
    case "${OVERLAY_LOGO_POS:-br}" in
        tl) _logo_x="$_pad";       _logo_y="$_pad" ;;
        tr) _logo_x="W-w-$_pad";   _logo_y="$_pad" ;;
        bl) _logo_x="$_pad";       _logo_y="H-h-$_pad" ;;
        br) _logo_x="W-w-$_pad";   _logo_y="H-h-$_pad" ;;
    esac

    # Posición Y del banner según header/footer
    local _bar_h=46 _font_size=26
    local _bar_y="" _text_y=""
    case "${OVERLAY_BANNER_POS:-footer}" in
        header)
            _bar_y="0"
            _text_y="$(( (_bar_h - _font_size) / 2 ))"
            ;;
        footer)
            _bar_y="h-${_bar_h}"
            _text_y="h-${_bar_h}+$(( (_bar_h - _font_size) / 2 ))"
            ;;
    esac

    # Texto del banner → archivo temporal (evita todos los problemas de quoting)
    if [[ -n "${OVERLAY_BANNER:-}" ]]; then
        _BANNER_FILE="/tmp/stream_banner_$$.txt"
        printf '%s' "$OVERLAY_BANNER" > "$_BANNER_FILE"
    fi

    # Posición de la fecha/hora (drawtext: w/h = frame, text_w/text_h = texto)
    local _ts_pos=""
    case "${OVERLAY_TIMESTAMP_POS:-tl}" in
        tl) _ts_pos="x=10:y=10" ;;
        tr) _ts_pos="x=w-text_w-10:y=10" ;;
        bl) _ts_pos="x=10:y=h-text_h-10" ;;
        br) _ts_pos="x=w-text_w-10:y=h-text_h-10" ;;
    esac

    # Encadena cada overlay activo sobre la salida del anterior, siempre vía
    # filter_complex para soportar cualquier combinación de logo/banner/fecha.
    local _chain="" _label="0:v" _next=""

    if [[ -n "${OVERLAY_BANNER:-}" ]]; then
        _next="vbanner"
        _chain+="[${_label}]drawbox=x=0:y=${_bar_y}:w=iw:h=${_bar_h}:color=black@0.72:t=fill,drawtext=${_FONT}textfile=${_BANNER_FILE}:fontcolor=white:fontsize=${_font_size}:x=(w-text_w)/2:y=${_text_y}[${_next}];"
        _label="$_next"
    fi

    if [[ "${OVERLAY_TIMESTAMP:-false}" == true ]]; then
        _next="vts"
        _chain+="[${_label}]drawtext=${_FONT}text='%{localtime\\:%F %T}':fontcolor=white:fontsize=20:${_ts_pos}:box=1:boxcolor=black@0.5:boxborderw=5[${_next}];"
        _label="$_next"
    fi

    if [[ -n "${OVERLAY_LOGO:-}" ]]; then
        _next="outv"
        _chain+="[${_label}][1:v]overlay=x=${_logo_x}:y=${_logo_y}[${_next}];"
        _label="$_next"
    fi

    _chain="${_chain%;}"

    if [[ -n "$_chain" ]]; then
        _FILTER_ARGS=(-filter_complex "$_chain" -map "[${_label}]")
        # Solo mapear audio si realmente hay un input de audio (NO_AUDIO=true
        # implica -an, sin stream de audio que mapear).
        [[ "${NO_AUDIO:-false}" == false ]] && _AUDIO_MAP_ARGS=(-map "${_AUDIO_IDX}:a")
    fi

    return 0
}

# ---------------------------------------------------------------------------
# build_audio_ffmpeg_args
# Construye _AUDIO_FFMPEG_ARGS según NO_AUDIO, MIC_DEV, MIC_RATE, MIC_CH.
# Incluye sync + volumen x2 para compensar bajo nivel del BOYA.
# ---------------------------------------------------------------------------
build_audio_ffmpeg_args() {
    _AUDIO_FFMPEG_ARGS=()
    if [[ "${NO_AUDIO:-false}" == false ]]; then
        _AUDIO_FFMPEG_ARGS=(
            -thread_queue_size 8192
            -f alsa
            -ar "${MIC_RATE:-44100}"
            -ac "${MIC_CH:-1}"
            -i  "${MIC_DEV}"
            -acodec aac
            -b:a 128k
            -af "aresample=async=1:min_hard_comp=0.100000:first_pts=0,volume=2.0"
        )
    else
        _AUDIO_FFMPEG_ARGS=(-an)
    fi
}

# ---------------------------------------------------------------------------
# tui_camera_resolution
# Paso interactivo: detecta cámaras USB + selecciona resolución.
# Establece las variables globales:
#   CAM_DEV  CAM_NAME  WIDTH  HEIGHT  INPUT_FORMAT  INPUT_FORMAT_LABEL
# ---------------------------------------------------------------------------
tui_camera_resolution() {
    local -a _cam_raw=()
    mapfile -t _cam_raw < <(detect_cameras)

    if [[ "${#_cam_raw[@]}" -eq 0 ]]; then
        die "No se detectó ninguna cámara USB. Conectar la cámara y reintentar."
    fi

    local -a _cam_devs=() _cam_names=()
    local _entry
    for _entry in "${_cam_raw[@]}"; do
        _cam_devs+=("${_entry%%|*}")
        _cam_names+=("${_entry##*|}")
    done

    if [[ "${#_cam_raw[@]}" -eq 1 ]]; then
        CAM_DEV="${_cam_devs[0]}"
        CAM_NAME="${_cam_names[0]}"
        ok "Cámara detectada: $CAM_NAME ($CAM_DEV)"
    else
        pick _IDX "Selecciona la cámara:" "${_cam_names[@]}"
        CAM_DEV="${_cam_devs[$_IDX]}"
        CAM_NAME="${_cam_names[$_IDX]}"
        ok "Cámara seleccionada: $CAM_NAME ($CAM_DEV)"
    fi

    local -a _res_opts=(
        "1920x1080  (Full HD)"
        "1280x720   (HD — recomendado Pi 3B)"
        "854x480    (480p — menor CPU)"
        "640x360    (360p — mínimo uso de CPU)"
    )
    pick _IDX "Resolución:" "${_res_opts[@]}"
    case "$_IDX" in
        0) WIDTH=1920; HEIGHT=1080 ;;
        1) WIDTH=1280; HEIGHT=720  ;;
        2) WIDTH=854;  HEIGHT=480  ;;
        3) WIDTH=640;  HEIGHT=360  ;;
    esac
    ok "Resolución: ${WIDTH}x${HEIGHT}"

    if supports_mjpeg "$CAM_DEV"; then
        INPUT_FORMAT="mjpeg";   INPUT_FORMAT_LABEL="MJPEG"
    else
        INPUT_FORMAT="yuyv422"; INPUT_FORMAT_LABEL="YUYV"
    fi
}

# ---------------------------------------------------------------------------
# tui_mic_channels
# Paso interactivo: detecta micrófonos + selecciona canales mono/stereo.
# Establece las variables globales:
#   MIC_DEV  MIC_NAME  MIC_RATE  MIC_CH  NO_AUDIO
# ---------------------------------------------------------------------------
tui_mic_channels() {
    local -a _mic_raw=()
    mapfile -t _mic_raw < <(detect_mics)

    MIC_DEV=""; MIC_RATE=44100; MIC_CH=1

    if [[ "${#_mic_raw[@]}" -eq 0 ]]; then
        warn "No se detectó ningún micrófono."
        if confirm "¿Continuar sin audio?"; then
            NO_AUDIO=true
        else
            die "Conectar un micrófono y reintentar."
        fi
        return
    fi

    NO_AUDIO=false
    local -a _mic_devs=() _mic_names=() _mic_labels=()
    local _entry
    for _entry in "${_mic_raw[@]}"; do
        _mic_devs+=("${_entry%%|*}")
        _mic_names+=("${_entry##*|}")
        _mic_labels+=("${_entry##*|}  (${_entry%%|*})")
    done
    _mic_labels+=("Sin audio")

    if [[ "${#_mic_raw[@]}" -eq 1 ]]; then
        MIC_DEV="${_mic_devs[0]}"
        MIC_NAME="${_mic_names[0]}"
        MIC_RATE=$(mic_default_rate "$MIC_NAME")
        ok "Micrófono detectado: $MIC_NAME ($MIC_DEV — ${MIC_RATE}Hz)"
    else
        local _last="${#_mic_raw[@]}"   # índice de "Sin audio"
        pick _IDX "Selecciona el micrófono:" "${_mic_labels[@]}"
        if [[ "$_IDX" -eq "$_last" ]]; then
            NO_AUDIO=true
            ok "Sin audio"
        else
            MIC_DEV="${_mic_devs[$_IDX]}"
            MIC_NAME="${_mic_names[$_IDX]}"
            MIC_RATE=$(mic_default_rate "$MIC_NAME")
            ok "Micrófono: $MIC_NAME ($MIC_DEV — ${MIC_RATE}Hz)"
        fi
    fi

    if [[ "$NO_AUDIO" == false ]]; then
        local -a _ch_opts=(
            "Mono   — 1 canal  (recomendado: BOYA, voz, menor CPU)"
            "Stereo — 2 canales (música, ambiente, webcam integrada)"
        )
        pick _IDX "Canales de audio:" "${_ch_opts[@]}"
        case "$_IDX" in
            0) MIC_CH=1; ok "Audio: mono"   ;;
            1) MIC_CH=2; ok "Audio: stereo" ;;
        esac
    fi
}

# ---------------------------------------------------------------------------
# tui_bitrate
# Paso interactivo genérico de selección de bitrate. Recibe pares
# "etiqueta|valor_bps" — cada TUI define sus propias etiquetas/opciones
# pero comparten el mismo flujo de selección.
# Uso:
#   tui_bitrate BITRATE \
#       "4500 kbps  (alta calidad)|4500000" \
#       "2500 kbps  (balance)|2500000"
# ---------------------------------------------------------------------------
tui_bitrate() {
    local _var="$1"; shift
    local -a _labels=() _values=()
    local _entry
    for _entry in "$@"; do
        _labels+=("${_entry%%|*}")
        _values+=("${_entry##*|}")
    done
    pick _IDX "Bitrate de video:" "${_labels[@]}"
    printf -v "$_var" '%s' "${_values[$_IDX]}"
}

# ---------------------------------------------------------------------------
# print_summary_capture
# Imprime las líneas de resumen comunes a cualquier captura: cámara,
# resolución, formato de entrada, bitrate y audio. Lee las variables
# globales establecidas por tui_camera_resolution, tui_mic_channels y
# tui_bitrate (o equivalentes).
# ---------------------------------------------------------------------------
print_summary_capture() {
    echo -e "  Cámara     : ${C_BOLD}$CAM_NAME${C_RESET} ($CAM_DEV)"
    echo -e "  Resolución : ${C_BOLD}${WIDTH}x${HEIGHT}${C_RESET}"
    echo -e "  Formato    : ${INPUT_FORMAT_LABEL}"
    echo -e "  Bitrate    : ${C_BOLD}$((BITRATE / 1000)) kbps${C_RESET}"
    if [[ "${NO_AUDIO:-false}" == true ]]; then
        echo -e "  Audio      : ${C_DIM}deshabilitado${C_RESET}"
    else
        local _ch_label="mono"; [[ "${MIC_CH:-1}" -eq 2 ]] && _ch_label="stereo"
        echo -e "  Audio      : ${C_BOLD}$MIC_NAME${C_RESET} ($MIC_DEV — ${MIC_RATE}Hz ${_ch_label})"
    fi
}

# ---------------------------------------------------------------------------
# print_summary_overlays
# Imprime las líneas de resumen de logo y banner cuando están activos.
# Lee las variables globales OVERLAY_* establecidas por overlay_tui.
# ---------------------------------------------------------------------------
print_summary_overlays() {
    if [[ -n "${OVERLAY_LOGO:-}" ]]; then
        if [[ "$OVERLAY_LOGO_W" -gt 0 ]]; then
            echo -e "  Logo       : ${C_BOLD}$(basename "$OVERLAY_LOGO")${C_RESET} — ${OVERLAY_LOGO_W}px — ${OVERLAY_LOGO_POS} (pad ${OVERLAY_LOGO_PAD}px)"
        else
            echo -e "  Logo       : ${C_BOLD}$(basename "$OVERLAY_LOGO")${C_RESET} — tamaño original — ${OVERLAY_LOGO_POS} (pad ${OVERLAY_LOGO_PAD}px)"
        fi
    fi
    if [[ -n "${OVERLAY_BANNER:-}" ]]; then
        echo -e "  Banner     : ${C_BOLD}\"$OVERLAY_BANNER\"${C_RESET} — $OVERLAY_BANNER_POS"
    fi
    if [[ "${OVERLAY_TIMESTAMP:-false}" == true ]]; then
        echo -e "  Fecha/hora : ${C_BOLD}activada${C_RESET} — ${OVERLAY_TIMESTAMP_POS:-tl}"
    fi
}

# ---------------------------------------------------------------------------
# build_capture_args
# Construye el tramo de ffmpeg común a todo pipeline de captura (flags
# generales + entrada v4l2 + logo + audio + filtros de overlay). Cada TUI
# agrega después sus propias opciones de codificación/salida.
# Requiere haber llamado antes build_overlay_args y build_audio_ffmpeg_args.
# Establece la variable global (array): _CAPTURE_ARGS
# ---------------------------------------------------------------------------
build_capture_args() {
    _CAPTURE_ARGS=(
        -hide_banner
        -loglevel warning
        -stats
        -thread_queue_size 8192
        -f v4l2
        -input_format "$INPUT_FORMAT"
        -video_size "${WIDTH}x${HEIGHT}"
        -framerate "$FPS"
        -i "$CAM_DEV"
        "${_LOGO_INPUTS[@]}"
        "${_AUDIO_FFMPEG_ARGS[@]}"
        "${_FILTER_ARGS[@]}"
        "${_AUDIO_MAP_ARGS[@]}"
    )
}
