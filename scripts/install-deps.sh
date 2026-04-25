#!/usr/bin/env bash
# Instala todas las dependencias necesarias para operar los scripts del proyecto.
#
# Uso:
#   sudo ./install-deps.sh [opciones]
#
# Opciones:
#   --usb-camera    Instalar soporte para cámara USB (v4l2) — default si no se elige cámara
#   --csi-camera    Instalar soporte para módulo CSI oficial (libcamera)
#   --all-cameras   Instalar soporte para ambos tipos de cámara
#   --ai-server     Instalar dependencias del servidor IA (Python, Flask, openai)
#   --full          Instalar todo (ambas cámaras + servidor IA)
#   --dry-run       Mostrar qué se instalaría sin instalar nada
#   --help          Mostrar esta ayuda
#
# Sin opciones instala el núcleo mínimo + soporte cámara USB.
#
# Ejemplos:
#   sudo ./install-deps.sh
#   sudo ./install-deps.sh --usb-camera
#   sudo ./install-deps.sh --csi-camera
#   sudo ./install-deps.sh --full
#   sudo ./install-deps.sh --dry-run

set -euo pipefail

# ---------------------------------------------------------------------------
# Opciones
# ---------------------------------------------------------------------------
OPT_USB_CAMERA=true
OPT_CSI_CAMERA=false
OPT_AI_SERVER=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --usb-camera)   OPT_USB_CAMERA=true;  OPT_CSI_CAMERA=false; shift ;;
        --csi-camera)   OPT_CSI_CAMERA=true;  OPT_USB_CAMERA=false; shift ;;
        --all-cameras)  OPT_USB_CAMERA=true;  OPT_CSI_CAMERA=true;  shift ;;
        --ai-server)    OPT_AI_SERVER=true;   shift ;;
        --full)         OPT_USB_CAMERA=true;  OPT_CSI_CAMERA=true; OPT_AI_SERVER=true; shift ;;
        --dry-run)      DRY_RUN=true;         shift ;;
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
INSTALLED=()
SKIPPED=()
FAILED=()

ok()      { echo "  [✓] $*"; }
info()    { echo "  [-] $*"; }
warn()    { echo "  [!] $*"; }
header()  { echo ""; echo "=== $* ==="; echo ""; }

apt_install() {
    local pkg="$1"
    local desc="${2:-$1}"

    if dpkg -s "$pkg" >/dev/null 2>&1; then
        ok "$desc (ya instalado)"
        SKIPPED+=("$pkg")
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        info "$desc (se instalaría)"
        INSTALLED+=("$pkg")
        return 0
    fi

    echo -n "  Instalando $desc... "
    if apt-get install -y -qq "$pkg" >/dev/null 2>&1; then
        echo "OK"
        ok "$desc"
        INSTALLED+=("$pkg")
    else
        echo "FALLO"
        warn "$desc — fallo al instalar"
        FAILED+=("$pkg")
    fi
}

check_cmd() {
    local cmd="$1"
    local pkg="$2"
    local desc="${3:-$cmd}"

    if command -v "$cmd" >/dev/null 2>&1; then
        ok "$desc"
    else
        warn "$desc — no encontrado (instalar: sudo apt install $pkg)"
    fi
}

# ---------------------------------------------------------------------------
# Verificar root
# ---------------------------------------------------------------------------
if [[ "$DRY_RUN" == false ]]; then
    [[ "$EUID" -eq 0 ]] || {
        echo "ERROR: Este script requiere permisos de root."
        echo "       Ejecutar con: sudo $0 $*"
        exit 1
    }
fi

# ---------------------------------------------------------------------------
# Detectar sistema operativo
# ---------------------------------------------------------------------------
header "Sistema"

PI_MODEL=""
if [[ -f /proc/device-tree/model ]]; then
    PI_MODEL=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || true)
fi

OS_NAME=""
if [[ -f /etc/os-release ]]; then
    OS_NAME=$(grep ^PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')
fi

[[ -n "$PI_MODEL" ]] && info "Hardware : $PI_MODEL" || info "Hardware : no detectado (¿no es una Raspberry Pi?)"
[[ -n "$OS_NAME"  ]] && info "Sistema  : $OS_NAME"  || info "Sistema  : desconocido"
info "Modo     : $([ "$DRY_RUN" == true ] && echo 'simulación (--dry-run)' || echo 'instalación real')"

# Advertir si no parece ser Raspberry Pi
if [[ -z "$PI_MODEL" ]]; then
    warn "No se pudo detectar el modelo de Raspberry Pi."
    warn "Continuando de todos modos — los paquetes son estándar en Debian/Ubuntu."
fi

# ---------------------------------------------------------------------------
# Actualizar índice de paquetes
# ---------------------------------------------------------------------------
header "Actualizar repositorios"

if [[ "$DRY_RUN" == false ]]; then
    echo -n "  Ejecutando apt-get update... "
    apt-get update -qq && echo "OK" || { echo "FALLO"; warn "apt-get update falló — los paquetes pueden estar desactualizados."; }
else
    info "apt-get update (omitido en --dry-run)"
fi

# ---------------------------------------------------------------------------
# Paquetes base — necesarios para TODOS los scripts
# ---------------------------------------------------------------------------
header "Dependencias base (todos los scripts)"

apt_install "ffmpeg"      "ffmpeg — encoding, streaming RTMP, overlays, audio"
apt_install "alsa-utils"  "alsa-utils — arecord, aplay, alsamixer (audio USB)"
apt_install "curl"        "curl — descargas, webhooks, send-event.sh"
apt_install "bc"          "bc — cálculos de tiempo en motion-detect.sh"
apt_install "coreutils"   "coreutils — base64, date, etc."
apt_install "git"         "git — clonar y actualizar el repositorio"

# ---------------------------------------------------------------------------
# Cámara USB (v4l2)
# ---------------------------------------------------------------------------
if [[ "$OPT_USB_CAMERA" == true ]]; then
    header "Cámara USB (v4l2) — usb-camera.sh"

    apt_install "v4l-utils"   "v4l-utils — v4l2-ctl, detección de cámaras USB"
    apt_install "usbutils"    "usbutils — lsusb, diagnóstico USB"
fi

# ---------------------------------------------------------------------------
# Módulo CSI (libcamera)
# ---------------------------------------------------------------------------
if [[ "$OPT_CSI_CAMERA" == true ]]; then
    header "Módulo CSI oficial (libcamera) — capture.sh, stream.sh, stream-overlay.sh"

    apt_install "libcamera-apps" "libcamera-apps — libcamera-vid, libcamera-still, libcamera-jpeg"

    # Verificar que la cámara CSI esté habilitada
    if [[ "$DRY_RUN" == false ]]; then
        echo ""
        if command -v libcamera-hello >/dev/null 2>&1; then
            if libcamera-hello --list-cameras 2>/dev/null | grep -q "Available cameras"; then
                ok "Cámara CSI detectada y operativa."
            else
                warn "libcamera-apps instalado pero no se detectó ninguna cámara CSI."
                warn "Si usas Raspberry Pi OS: sudo raspi-config → Interface Options → Camera → Enable"
                warn "Si usas DietPi: sudo dietpi-config → Advanced Options → Camera → Enable"
                warn "Reiniciar después de habilitar la cámara."
            fi
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Servidor IA (Python + Flask + openai)
# ---------------------------------------------------------------------------
if [[ "$OPT_AI_SERVER" == true ]]; then
    header "Servidor IA — server/analyze-server.py"

    apt_install "python3"       "python3 — intérprete Python"
    apt_install "python3-pip"   "python3-pip — gestor de paquetes Python"
    apt_install "python3-venv"  "python3-venv — entornos virtuales Python"

    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    REQUIREMENTS="${SCRIPT_DIR}/../server/requirements.txt"

    if [[ -f "$REQUIREMENTS" ]]; then
        if [[ "$DRY_RUN" == false ]]; then
            echo ""
            echo "  Instalando dependencias Python (Flask, openai)..."
            VENV_DIR="${SCRIPT_DIR}/../server/.venv"
            python3 -m venv "$VENV_DIR"
            "$VENV_DIR/bin/pip" install --quiet --upgrade pip
            "$VENV_DIR/bin/pip" install --quiet -r "$REQUIREMENTS"
            ok "Flask y openai instalados en server/.venv"
        else
            info "pip install flask openai (se instalaría en server/.venv)"
        fi
    else
        warn "No se encontró server/requirements.txt — omitiendo dependencias Python."
    fi
fi

# ---------------------------------------------------------------------------
# Verificación final
# ---------------------------------------------------------------------------
header "Verificación del entorno"

check_cmd "ffmpeg"   "ffmpeg"        "ffmpeg"
check_cmd "arecord"  "alsa-utils"    "arecord (audio USB)"
check_cmd "aplay"    "alsa-utils"    "aplay"
check_cmd "alsamixer" "alsa-utils"   "alsamixer"
check_cmd "curl"     "curl"          "curl"
check_cmd "bc"       "bc"            "bc"
check_cmd "git"      "git"           "git"

if [[ "$OPT_USB_CAMERA" == true ]]; then
    echo ""
    check_cmd "v4l2-ctl" "v4l-utils"  "v4l2-ctl (cámara USB)"
    check_cmd "lsusb"    "usbutils"   "lsusb"

    # Ver si hay cámaras USB conectadas ahora
    if [[ "$DRY_RUN" == false ]] && command -v v4l2-ctl >/dev/null 2>&1; then
        echo ""
        CAMS=$(ls /dev/video* 2>/dev/null | wc -l || echo 0)
        if [[ "$CAMS" -gt 0 ]]; then
            ok "Dispositivos /dev/video* encontrados: $CAMS"
            for dev in /dev/video*; do
                NAME=$(v4l2-ctl --device="$dev" --info 2>/dev/null \
                    | grep "Card type" | sed 's/.*: //' || echo "?")
                info "  $dev — $NAME"
            done
        else
            warn "No se detectó ninguna cámara USB en /dev/video*"
            warn "Conectar la webcam y verificar con: scripts/usb-camera.sh --list"
        fi
    fi
fi

if [[ "$OPT_CSI_CAMERA" == true ]]; then
    echo ""
    check_cmd "libcamera-vid"   "libcamera-apps"  "libcamera-vid"
    check_cmd "libcamera-still" "libcamera-apps"  "libcamera-still"
fi

if [[ "$OPT_AI_SERVER" == true ]]; then
    echo ""
    check_cmd "python3"  "python3"  "python3"
fi

# Ver si hay micrófono USB conectado
if [[ "$DRY_RUN" == false ]] && command -v arecord >/dev/null 2>&1; then
    echo ""
    MIC_COUNT=$(arecord -l 2>/dev/null | grep "^card" | wc -l || echo 0)
    if [[ "$MIC_COUNT" -gt 0 ]]; then
        ok "Dispositivos de audio encontrados: $MIC_COUNT"
        arecord -l 2>/dev/null | grep "^card" | while read -r line; do
            info "  $line"
        done
    else
        warn "No se detectó ningún dispositivo de audio"
        warn "Conectar el micrófono USB y verificar con: scripts/audio-check.sh"
    fi
fi

# ---------------------------------------------------------------------------
# Resumen
# ---------------------------------------------------------------------------
header "Resumen"

if [[ "$DRY_RUN" == true ]]; then
    info "Modo simulación — no se instaló nada."
    info "Ejecutar sin --dry-run para instalar: sudo $0"
else
    [[ "${#INSTALLED[@]}" -gt 0 ]] && ok "Instalados  : ${#INSTALLED[@]} paquetes — ${INSTALLED[*]}"
    [[ "${#SKIPPED[@]}"   -gt 0 ]] && ok "Ya presentes: ${#SKIPPED[@]} paquetes — ${SKIPPED[*]}"
    [[ "${#FAILED[@]}"    -gt 0 ]] && warn "Fallidos    : ${#FAILED[@]} paquetes — ${FAILED[*]}"
fi

echo ""

# ---------------------------------------------------------------------------
# Próximos pasos
# ---------------------------------------------------------------------------
if [[ "$DRY_RUN" == false && "${#FAILED[@]}" -eq 0 ]]; then
    echo "Instalación completada. Próximos pasos:"
    echo ""

    if [[ "$OPT_USB_CAMERA" == true ]]; then
        echo "  1. Verificar webcam USB:"
        echo "       scripts/usb-camera.sh --list"
        echo ""
        echo "  2. Verificar micrófono USB (BOYA):"
        echo "       scripts/audio-check.sh"
        echo ""
        echo "  3. Prueba de captura (10 segundos):"
        echo "       scripts/usb-camera.sh --capture -t 10"
        echo ""
        echo "  4. Primer stream RTMP:"
        echo "       scripts/usb-camera.sh -u rtmp://TU_URL/TU_KEY"
    fi

    if [[ "$OPT_CSI_CAMERA" == true ]]; then
        echo "  1. Activar módulo CSI (si no está habilitado):"
        echo "       sudo raspi-config  →  Interface Options → Camera → Enable"
        echo "       sudo reboot"
        echo ""
        echo "  2. Verificar cámara CSI:"
        echo "       libcamera-hello --list-cameras"
        echo ""
        echo "  3. Prueba de captura:"
        echo "       scripts/capture.sh -t 10"
    fi

    if [[ "$OPT_AI_SERVER" == true ]]; then
        echo ""
        echo "  Servidor IA:"
        echo "       Editar server/server.env con tu API key"
        echo "       sudo scripts/ai-server-install.sh"
    fi

    echo ""
fi
