#!/usr/bin/env bash
# Detecta y muestra en una sola vista todos los dispositivos conectados:
# cámaras USB, micrófonos ALSA y módulos CSI. Al final genera los comandos
# listos para copiar y pegar con los dispositivos detectados.
#
# Uso:
#   ./check-devices.sh [opciones]
#
# Opciones:
#   --resolutions  Mostrar todas las resoluciones de cada cámara USB
#   --help         Mostrar esta ayuda
#
# Ejemplos:
#   ./check-devices.sh
#   ./check-devices.sh --resolutions

set -euo pipefail

SHOW_RESOLUTIONS=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --resolutions) SHOW_RESOLUTIONS=true; shift ;;
        --help)
            grep '^#' "$0" | grep -v '#!/' | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "ERROR: Opción desconocida: $1. Usa --help." >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
ok()   { echo "  [✓] $*"; }
warn() { echo "  [!] $*"; }
info() { echo "      $*"; }
sep()  { echo ""; echo "─────────────────────────────────────────────────────"; echo ""; }

HAS_V4L2=false
HAS_ARECORD=false
HAS_LIBCAMERA=false

command -v v4l2-ctl    >/dev/null 2>&1 && HAS_V4L2=true
command -v arecord     >/dev/null 2>&1 && HAS_ARECORD=true
command -v libcamera-hello >/dev/null 2>&1 && HAS_LIBCAMERA=true

# Resultados para el resumen final
CAMERAS=()       # "/dev/videoN|Nombre del dispositivo|mejor resolución"
MICS=()          # "plughw:N,0|Nombre del dispositivo"
CSI_CAMERAS=()   # "índice|nombre"

# ---------------------------------------------------------------------------
# Cabecera
# ---------------------------------------------------------------------------
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║           check-devices — Raspberry Pi               ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ---------------------------------------------------------------------------
# SECCIÓN 1: Cámaras USB (v4l2)
# ---------------------------------------------------------------------------
echo "┌─ CÁMARAS USB (/dev/video*)"
echo ""

if [[ "$HAS_V4L2" == false ]]; then
    warn "v4l2-ctl no instalado. Instalar con: sudo apt install v4l-utils"
    echo ""
elif ! ls /dev/video* >/dev/null 2>&1; then
    warn "No se encontraron dispositivos /dev/video*"
    warn "Conectar la webcam USB y ejecutar de nuevo."
    echo ""
else
    FOUND_CAM=false
    for dev in /dev/video*; do
        [[ -e "$dev" ]] || continue

        # Verificar que capture video real (no solo metadata)
        FORMATS=$(v4l2-ctl --device="$dev" --list-formats 2>/dev/null \
            | grep -oP "'\w+'" | tr -d "'" | tr '\n' ' ' || true)
        [[ -z "$FORMATS" ]] && continue

        # Filtrar formatos de video reales (no metadata ni output-only)
        VIDEO_FORMATS=$(echo "$FORMATS" | grep -wE "MJPG|MJPEG|YUYV|H264|NV12|YUV2|RGB3|BGR3" || true)
        [[ -z "$VIDEO_FORMATS" ]] && continue

        NAME=$(v4l2-ctl --device="$dev" --info 2>/dev/null \
            | grep "Card type" | sed 's/.*: //' | xargs || echo "Cámara USB")
        DRIVER=$(v4l2-ctl --device="$dev" --info 2>/dev/null \
            | grep "Driver name" | sed 's/.*: //' | xargs || echo "?")

        # Obtener mejor resolución disponible (mayor área)
        BEST_RES=$(v4l2-ctl --device="$dev" --list-formats-ext 2>/dev/null \
            | grep "Size: Discrete" \
            | awk '{
                split($3, r, "x");
                area = r[1] * r[2];
                if (area > max) { max = area; best = $3 }
              }
              END { print best }' || echo "?")

        ok "$dev — $NAME"
        info "Driver   : $driver"
        info "Formatos : $VIDEO_FORMATS"
        info "Mejor res: $BEST_RES"

        if [[ "$SHOW_RESOLUTIONS" == true ]]; then
            echo ""
            info "Resoluciones disponibles:"
            v4l2-ctl --device="$dev" --list-formats-ext 2>/dev/null \
                | grep "Size: Discrete" \
                | awk '{printf "        %s\n", $3}' \
                | sort -t'x' -k1,1rn | uniq
        fi

        echo ""
        CAMERAS+=("$dev|$NAME|$BEST_RES|$VIDEO_FORMATS")
        FOUND_CAM=true
    done

    if [[ "$FOUND_CAM" == false ]]; then
        warn "Dispositivos /dev/video* presentes pero ninguno captura video."
        warn "Reconectar la cámara o verificar con: dmesg | grep -i uvc"
        echo ""
    fi
fi

# ---------------------------------------------------------------------------
# SECCIÓN 2: Módulo CSI (libcamera)
# ---------------------------------------------------------------------------
echo "┌─ MÓDULO CSI (libcamera)"
echo ""

if [[ "$HAS_LIBCAMERA" == false ]]; then
    info "libcamera-apps no instalado (solo necesario para el módulo CSI oficial)."
    info "Instalar con: sudo apt install libcamera-apps"
    echo ""
else
    CSI_OUTPUT=$(libcamera-hello --list-cameras 2>&1 || true)
    if echo "$CSI_OUTPUT" | grep -q "Available cameras"; then
        while IFS= read -r line; do
            if [[ "$line" =~ ^[[:space:]]*([0-9]+)[[:space:]]*: ]]; then
                IDX="${BASH_REMATCH[1]}"
                CAM_NAME=$(echo "$line" | sed 's/^[[:space:]]*//' | cut -d: -f2- | xargs)
                ok "Cámara CSI $IDX — $CAM_NAME"
                CSI_CAMERAS+=("$IDX|$CAM_NAME")
            fi
        done <<< "$CSI_OUTPUT"
    else
        warn "libcamera instalado pero no se detectó ningún módulo CSI."
        info "Activar en: sudo raspi-config → Interface Options → Camera → Enable"
        info "            sudo reboot"
    fi
    echo ""
fi

# ---------------------------------------------------------------------------
# SECCIÓN 3: Micrófonos ALSA
# ---------------------------------------------------------------------------
echo "┌─ MICRÓFONOS (ALSA)"
echo ""

if [[ "$HAS_ARECORD" == false ]]; then
    warn "arecord no instalado. Instalar con: sudo apt install alsa-utils"
    echo ""
else
    ALSA_RAW=$(arecord -l 2>/dev/null || true)

    if echo "$ALSA_RAW" | grep -q "^card"; then
        while IFS= read -r line; do
            [[ "$line" =~ ^card ]] || continue

            CARD_NUM=$(echo "$line" | grep -oP 'card \K[0-9]+')
            CARD_ID=$(echo "$line" | grep -oP 'card [0-9]+: \K[^\s]+')
            CARD_NAME=$(echo "$line" | grep -oP '\[.*?\]' | head -1 | tr -d '[]')
            DEV_NUM=$(echo "$line" | grep -oP 'device \K[0-9]+')
            DEV_NAME=$(echo "$line" | grep -oP '\[.*?\]' | tail -1 | tr -d '[]')

            DEVICE_STR="plughw:${CARD_NUM},${DEV_NUM}"

            # Detectar tipo de dispositivo por nombre
            TYPE="Micrófono USB"
            if echo "$CARD_NAME $CARD_ID" | grep -qi "boyalink\|boya"; then
                TYPE="BOYA LINK CC (inalámbrico 48kHz)"
            elif echo "$CARD_NAME $CARD_ID" | grep -qi "focusrite\|scarlett"; then
                TYPE="Focusrite Scarlett (UAC2)"
            elif echo "$CARD_NAME $CARD_ID" | grep -qi "c920\|c922\|c910\|logitech"; then
                TYPE="Webcam (micrófono integrado)"
            elif echo "$CARD_NAME $CARD_ID" | grep -qi "bcm\|hdmi\|snd_rpi"; then
                TYPE="Audio interno Pi (HDMI/analógico)"
            fi

            ok "card $CARD_NUM — $CARD_NAME [$DEV_NAME]"
            info "Dispositivo ALSA : $DEVICE_STR"
            info "Tipo detectado   : $TYPE"
            echo ""

            # Solo agregar micrófonos externos al resumen (no audio interno Pi)
            if ! echo "$CARD_NAME $CARD_ID" | grep -qi "bcm\|hdmi\|snd_rpi"; then
                MICS+=("$DEVICE_STR|$CARD_NAME|$TYPE|$CARD_NUM")
            fi
        done <<< "$ALSA_RAW"
    else
        warn "No se detectaron dispositivos de audio."
        warn "Conectar el micrófono USB y ejecutar de nuevo."
        echo ""
    fi
fi

# ---------------------------------------------------------------------------
# SECCIÓN 4: RESUMEN Y COMANDOS LISTOS
# ---------------------------------------------------------------------------
sep
echo "┌─ RESUMEN Y COMANDOS LISTOS PARA USAR"
echo ""

TOTAL_CAMS="${#CAMERAS[@]}"
TOTAL_CSI="${#CSI_CAMERAS[@]}"
TOTAL_MICS="${#MICS[@]}"

ok "Cámaras USB detectadas : $TOTAL_CAMS"
ok "Módulos CSI detectados : $TOTAL_CSI"
ok "Micrófonos detectados  : $TOTAL_MICS"
echo ""

# --- Mejor cámara USB ---
PRIMARY_CAM_DEV=""
PRIMARY_CAM_NAME=""
PRIMARY_CAM_RES=""
if [[ "${#CAMERAS[@]}" -gt 0 ]]; then
    IFS='|' read -r PRIMARY_CAM_DEV PRIMARY_CAM_NAME PRIMARY_CAM_RES _ <<< "${CAMERAS[0]}"
fi

# --- Mejor micrófono (preferir BOYA sobre webcam) ---
PRIMARY_MIC_DEV=""
PRIMARY_MIC_NAME=""
PRIMARY_MIC_RATE="44100"
PRIMARY_MIC_CARD=""

for mic_entry in "${MICS[@]}"; do
    IFS='|' read -r mic_dev mic_name mic_type mic_card <<< "$mic_entry"
    if [[ -z "$PRIMARY_MIC_DEV" ]]; then
        PRIMARY_MIC_DEV="$mic_dev"
        PRIMARY_MIC_NAME="$mic_name"
        PRIMARY_MIC_CARD="$mic_card"
    fi
    # Preferir BOYA sobre webcam integrada
    if echo "$mic_type" | grep -qi "boya\|inalámbrico"; then
        PRIMARY_MIC_DEV="$mic_dev"
        PRIMARY_MIC_NAME="$mic_name"
        PRIMARY_MIC_RATE="48000"
        PRIMARY_MIC_CARD="$mic_card"
    fi
    # Preferir Focusrite sobre webcam integrada
    if echo "$mic_type" | grep -qi "focusrite\|scarlett"; then
        PRIMARY_MIC_DEV="$mic_dev"
        PRIMARY_MIC_NAME="$mic_name"
        PRIMARY_MIC_RATE="48000"
        PRIMARY_MIC_CARD="$mic_card"
    fi
done

# ---------------------------------------------------------------------------
# Comandos para cámara USB
# ---------------------------------------------------------------------------
if [[ -n "$PRIMARY_CAM_DEV" ]]; then
    echo "── Cámara USB: $PRIMARY_CAM_NAME ($PRIMARY_CAM_DEV)"
    echo ""

    MIC_ARGS=""
    if [[ -n "$PRIMARY_MIC_DEV" ]]; then
        MIC_ARGS="--audio-dev $PRIMARY_MIC_DEV --audio-rate $PRIMARY_MIC_RATE"
    else
        MIC_ARGS="--no-audio"
    fi

    echo "  # Listar resoluciones"
    echo "  scripts/usb-camera.sh --list"
    echo ""
    echo "  # Captura local (30 segundos)"
    echo "  scripts/usb-camera.sh --capture \\"
    echo "      --dev $PRIMARY_CAM_DEV \\"
    if [[ -n "$PRIMARY_MIC_DEV" ]]; then
        echo "      --audio-dev $PRIMARY_MIC_DEV \\"
        echo "      --audio-rate $PRIMARY_MIC_RATE \\"
    fi
    echo "      -w 1280 -h 720 -t 30"
    echo ""
    echo "  # Stream RTMP"
    echo "  scripts/usb-camera.sh \\"
    echo "      --dev $PRIMARY_CAM_DEV \\"
    if [[ -n "$PRIMARY_MIC_DEV" ]]; then
        echo "      --audio-dev $PRIMARY_MIC_DEV \\"
        echo "      --audio-rate $PRIMARY_MIC_RATE \\"
    fi
    echo "      -w 1280 -h 720 \\"
    echo "      -u rtmp://TU_URL/TU_STREAM_KEY"
    echo ""
fi

# ---------------------------------------------------------------------------
# Comandos para módulo CSI
# ---------------------------------------------------------------------------
if [[ "${#CSI_CAMERAS[@]}" -gt 0 ]]; then
    IFS='|' read -r CSI_IDX CSI_NAME <<< "${CSI_CAMERAS[0]}"
    echo "── Módulo CSI: $CSI_NAME"
    echo ""

    echo "  # Captura local (30 segundos)"
    if [[ -n "$PRIMARY_MIC_DEV" ]]; then
        echo "  scripts/capture.sh --audio \\"
        echo "      --audio-dev $PRIMARY_MIC_DEV \\"
        echo "      --audio-rate $PRIMARY_MIC_RATE \\"
        echo "      -t 30"
    else
        echo "  scripts/capture.sh -t 30"
    fi
    echo ""
    echo "  # Stream RTMP"
    if [[ -n "$PRIMARY_MIC_DEV" ]]; then
        echo "  scripts/stream.sh \\"
        echo "      --audio-dev $PRIMARY_MIC_DEV \\"
        echo "      --audio-rate $PRIMARY_MIC_RATE \\"
        echo "      -u rtmp://TU_URL/TU_STREAM_KEY"
    else
        echo "  scripts/stream.sh --no-audio -u rtmp://TU_URL/TU_STREAM_KEY"
    fi
    echo ""
fi

# ---------------------------------------------------------------------------
# Comandos de audio
# ---------------------------------------------------------------------------
if [[ "${#MICS[@]}" -gt 0 ]]; then
    echo "── Audio: $PRIMARY_MIC_NAME ($PRIMARY_MIC_DEV — ${PRIMARY_MIC_RATE}Hz)"
    echo ""
    echo "  # Ver nivel de señal en tiempo real"
    echo "  scripts/audio-check.sh --level $PRIMARY_MIC_DEV"
    echo ""
    echo "  # Prueba de grabación (3 segundos)"
    echo "  scripts/audio-check.sh --test $PRIMARY_MIC_DEV"
    echo ""

    # Mostrar micrófonos secundarios si hay más de uno
    if [[ "${#MICS[@]}" -gt 1 ]]; then
        echo "── Otros micrófonos detectados"
        echo ""
        for mic_entry in "${MICS[@]}"; do
            IFS='|' read -r mic_dev mic_name mic_type mic_card <<< "$mic_entry"
            [[ "$mic_dev" == "$PRIMARY_MIC_DEV" ]] && continue
            info "$mic_name → $mic_dev"
            info "Probar: scripts/audio-check.sh --level $mic_dev"
            echo ""
        done
    fi
fi

# ---------------------------------------------------------------------------
# Advertencias importantes
# ---------------------------------------------------------------------------
SHOW_WARNINGS=false

# Boya detectado → recordar 48kHz
for mic_entry in "${MICS[@]}"; do
    IFS='|' read -r mic_dev mic_name mic_type mic_card <<< "$mic_entry"
    if echo "$mic_name $mic_type" | grep -qi "boya\|boyalink"; then
        SHOW_WARNINGS=true
        sep
        echo "┌─ NOTAS IMPORTANTES"
        echo ""
        warn "BOYA LINK CC detectado: usar siempre --audio-rate 48000"
        warn "El receptor opera a 48kHz obligatoriamente."
        echo ""
        break
    fi
done

# Focusrite detectado → recordar fix Pi 3B
for mic_entry in "${MICS[@]}"; do
    IFS='|' read -r mic_dev mic_name mic_type mic_card <<< "$mic_entry"
    if echo "$mic_name $mic_type" | grep -qi "focusrite\|scarlett"; then
        [[ "$SHOW_WARNINGS" == false ]] && { sep; echo "┌─ NOTAS IMPORTANTES"; echo ""; SHOW_WARNINGS=true; }
        warn "Focusrite Scarlett detectada."
        warn "Verificar fix Pi 3B: scripts/scarlett-pi3b-fix.sh --check"
        echo ""
        break
    fi
done

# Webcam con micrófono integrado separado del externo
if [[ "${#MICS[@]}" -ge 2 ]]; then
    [[ "$SHOW_WARNINGS" == false ]] && { sep; echo "┌─ NOTAS IMPORTANTES"; echo ""; SHOW_WARNINGS=true; }
    warn "Se detectaron ${#MICS[@]} micrófonos. El recomendado es: $PRIMARY_MIC_DEV ($PRIMARY_MIC_NAME)"
    warn "Especificar siempre --audio-dev para evitar capturar el incorrecto."
    echo ""
fi

echo "─────────────────────────────────────────────────────"
echo ""
