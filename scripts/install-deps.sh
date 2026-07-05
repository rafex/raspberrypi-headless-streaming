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
#   --wifi-bootstrap Instalar dependencias para WiFi bootstrap + hotspot/AP
#   --ai-server     Instalar dependencias del servidor IA (Python, Flask, openai)
#   --web-api       Instalar dependencias de web-api (age, sops, uv, openssl)
#   --full          Instalar todo (ambas cámaras + servidor IA + web-api)
#   --dry-run       Mostrar qué se instalaría sin instalar nada
#   --help          Mostrar esta ayuda
#
# Sin opciones instala el núcleo mínimo + soporte cámara USB.
#
# Ejemplos:
#   sudo ./install-deps.sh
#   sudo ./install-deps.sh --usb-camera
#   sudo ./install-deps.sh --csi-camera
#   sudo ./install-deps.sh --web-api
#   sudo ./install-deps.sh --full
#   sudo ./install-deps.sh --dry-run

set -euo pipefail

# ---------------------------------------------------------------------------
# Opciones
# ---------------------------------------------------------------------------
OPT_USB_CAMERA=true
OPT_CSI_CAMERA=false
OPT_WIFI_BOOTSTRAP=false
OPT_AI_SERVER=false
OPT_WEB_API=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --usb-camera)   OPT_USB_CAMERA=true;  OPT_CSI_CAMERA=false; shift ;;
        --csi-camera)   OPT_CSI_CAMERA=true;  OPT_USB_CAMERA=false; shift ;;
        --all-cameras)  OPT_USB_CAMERA=true;  OPT_CSI_CAMERA=true;  shift ;;
        --wifi-bootstrap) OPT_WIFI_BOOTSTRAP=true; shift ;;
        --ai-server)    OPT_AI_SERVER=true;   shift ;;
        --web-api)      OPT_WEB_API=true;     shift ;;
        --full)         OPT_USB_CAMERA=true;  OPT_CSI_CAMERA=true; OPT_WIFI_BOOTSTRAP=true; OPT_AI_SERVER=true; OPT_WEB_API=true; shift ;;
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

# Paquetes apt pendientes de instalar: array de "pkg|desc"
APT_PENDING=()

ok()      { echo "  [✓] $*"; }
info()    { echo "  [-] $*"; }
warn()    { echo "  [!] $*"; }
header()  { echo ""; echo "=== $* ==="; echo ""; }

# Verifica si el paquete apt ya está instalado; si no, lo encola.
# La instalación real ocurre en apt_flush() para hacer una sola pasada.
apt_install() {
    local pkg="$1"
    local desc="${2:-$1}"

    if dpkg -s "$pkg" >/dev/null 2>&1; then
        ok "$desc (ya instalado)"
        SKIPPED+=("$pkg")
    elif [[ "$DRY_RUN" == true ]]; then
        info "$desc (se instalaría)"
        APT_PENDING+=("${pkg}|${desc}")
    else
        info "$desc (pendiente)"
        APT_PENDING+=("${pkg}|${desc}")
    fi
}

# Instala todos los paquetes encolados en una sola llamada apt-get.
# Llama apt-get update solo si hay algo que instalar.
apt_flush() {
    [[ "${#APT_PENDING[@]}" -eq 0 ]] && return 0
    [[ "$DRY_RUN" == true ]] && return 0

    local pkgs=()
    for entry in "${APT_PENDING[@]}"; do
        pkgs+=("${entry%%|*}")
    done

    echo ""
    echo -n "  Actualizando índice apt... "
    apt-get update -qq && echo "OK" || { echo "FALLO"; warn "apt-get update falló — los paquetes pueden estar desactualizados."; }

    echo -n "  Instalando: ${pkgs[*]}... "
    if apt-get install -y -qq "${pkgs[@]}" >/dev/null 2>&1; then
        echo "OK"
        for entry in "${APT_PENDING[@]}"; do
            local pkg="${entry%%|*}"
            local desc="${entry#*|}"
            ok "$desc"
            INSTALLED+=("$pkg")
        done
    else
        echo "FALLO"
        # Re-intentar uno por uno para identificar cuál falló
        for entry in "${APT_PENDING[@]}"; do
            local pkg="${entry%%|*}"
            local desc="${entry#*|}"
            if apt-get install -y -qq "$pkg" >/dev/null 2>&1; then
                ok "$desc"
                INSTALLED+=("$pkg")
            else
                warn "$desc — fallo al instalar"
                FAILED+=("$pkg")
            fi
        done
    fi

    APT_PENDING=()
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

# Instalar paquetes apt encolados (base + cámaras) si ningún bloque posterior
# va a llamar apt_flush por su cuenta: CSI lo hace internamente (porque la
# verificación de cámara necesita libcamera instalado), ai-server también
# (pip necesita python3-venv), y web-api también (antes de sops/uv).
if [[ "$OPT_CSI_CAMERA" == false && "$OPT_WIFI_BOOTSTRAP" == false && "$OPT_AI_SERVER" == false && "$OPT_WEB_API" == false ]]; then
    apt_flush
fi

# ---------------------------------------------------------------------------
# WiFi bootstrap + hotspot/AP
# ---------------------------------------------------------------------------
if [[ "$OPT_WIFI_BOOTSTRAP" == true ]]; then
    header "WiFi bootstrap + hotspot/AP"

    apt_install "python3" "python3 — wifi-bootstrap.py"
    apt_install "python3-tomli" "python3-tomli — fallback TOML para Python < 3.11"
    apt_install "wpasupplicant" "wpASupplicant — cliente WiFi"
    apt_install "wireless-tools" "wireless-tools — diagnostico WiFi"
    apt_install "iw" "iw — diagnostico WiFi moderno"
    apt_install "iproute2" "iproute2 — ip addr/link/route"
    apt_install "isc-dhcp-client" "dhclient — obtener IP por DHCP"
    apt_install "hostapd" "hostapd — modo hotspot/AP"
    apt_install "dnsmasq" "dnsmasq — DHCP/DNS para hotspot"
    apt_install "rfkill" "rfkill — desbloquear WiFi"
    apt_flush
fi

# ---------------------------------------------------------------------------
# Módulo CSI (libcamera)
# ---------------------------------------------------------------------------
if [[ "$OPT_CSI_CAMERA" == true ]]; then
    header "Módulo CSI oficial (libcamera) — capture.sh, stream.sh, stream-overlay.sh"

    apt_install "libcamera-apps" "libcamera-apps — libcamera-vid, libcamera-still, libcamera-jpeg"
    apt_flush

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

    apt_flush

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
# Web API (control de la transmisión desde el celular)
# ---------------------------------------------------------------------------
if [[ "$OPT_WEB_API" == true ]]; then
    header "Web API — control remoto (ver docs/web-api.md)"

    apt_install "openssl" "openssl — certificado TLS autofirmado"
    apt_install "python3" "python3 — intérprete Python"
    apt_install "age"     "age — cifrado de secretos (age-keygen)"
    apt_install "python3-yaml" "python3-yaml — PyYAML para scripts/manage-users.sh"

    apt_flush

    # sops no siempre está en los repos de Debian según la versión; si falla
    # la instalación por apt, se descarga el .deb de la última release oficial
    # de GitHub para la arquitectura detectada (solo hay builds para amd64/arm64).
    if dpkg -s sops >/dev/null 2>&1 || command -v sops >/dev/null 2>&1; then
        ok "sops — cifrado de secretos (ya instalado)"
        SKIPPED+=("sops")
    elif [[ "$DRY_RUN" == true ]]; then
        info "sops — cifrado de secretos (se instalaría por apt, o el .deb de GitHub si no está en los repos)"
    elif apt-get install -y -qq sops >/dev/null 2>&1; then
        ok "sops — cifrado de secretos"
        INSTALLED+=("sops")
    else
        DEB_ARCH="$(dpkg --print-architecture)"
        if [[ "$DEB_ARCH" != "amd64" && "$DEB_ARCH" != "arm64" ]]; then
            warn "sops no está en los repos y GitHub no publica .deb para '${DEB_ARCH}' (solo amd64/arm64)."
            warn "Instalar manualmente desde https://github.com/getsops/sops/releases"
            FAILED+=("sops")
        else
            echo "  sops no está en los repos, buscando el .deb de la última release para ${DEB_ARCH}..."
            SOPS_DEB_URL="$(curl -fsSL https://api.github.com/repos/getsops/sops/releases/latest 2>/dev/null \
                | grep -o "https://github.com/getsops/sops/releases/download/[^\"]*_${DEB_ARCH}\.deb" \
                | head -n1)"

            if [[ -z "$SOPS_DEB_URL" ]]; then
                warn "sops — no se pudo determinar la URL del .deb más reciente."
                warn "Instalar manualmente desde https://github.com/getsops/sops/releases"
                FAILED+=("sops")
            else
                SOPS_DEB_TMP="$(mktemp --suffix=.deb)"
                echo -n "  Descargando $(basename "$SOPS_DEB_URL")... "
                if curl -fsSL "$SOPS_DEB_URL" -o "$SOPS_DEB_TMP" 2>/dev/null; then
                    echo "OK"
                    echo -n "  Instalando sops... "
                    if dpkg -i "$SOPS_DEB_TMP" >/dev/null 2>&1; then
                        echo "OK"
                        ok "sops — cifrado de secretos"
                        INSTALLED+=("sops")
                    else
                        echo "FALLO"
                        warn "sops — fallo al instalar el .deb descargado (${SOPS_DEB_URL})"
                        FAILED+=("sops")
                    fi
                else
                    echo "FALLO"
                    warn "sops — fallo al descargar ${SOPS_DEB_URL}"
                    FAILED+=("sops")
                fi
                rm -f "$SOPS_DEB_TMP"
            fi
        fi
    fi

    # uv no está empaquetado en apt; se instala con el script oficial de Astral.
    if command -v uv >/dev/null 2>&1; then
        ok "uv — gestor de entornos Python (ya instalado)"
        SKIPPED+=("uv")
    elif [[ "$DRY_RUN" == true ]]; then
        info "uv — gestor de entornos Python (se instalaría con el instalador oficial)"
    else
        echo -n "  Instalando uv — gestor de entornos Python... "
        if curl -LsSf https://astral.sh/uv/install.sh 2>/dev/null \
            | env UV_INSTALL_DIR=/usr/local/bin sh >/dev/null 2>&1; then
            echo "OK"
            ok "uv — gestor de entornos Python"
            INSTALLED+=("uv")
        else
            echo "FALLO"
            warn "uv — fallo al instalar. Ver https://docs.astral.sh/uv/getting-started/installation/"
            FAILED+=("uv")
        fi
    fi
fi

if [[ "$OPT_WIFI_BOOTSTRAP" == true ]]; then
    echo ""
    check_cmd "python3" "python3" "python3"
    check_cmd "wpa_supplicant" "wpasupplicant" "wpa_supplicant"
    check_cmd "wpa_passphrase" "wpasupplicant" "wpa_passphrase"
    check_cmd "hostapd" "hostapd" "hostapd"
    check_cmd "dnsmasq" "dnsmasq" "dnsmasq"
    check_cmd "dhclient" "isc-dhcp-client" "dhclient"
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
        shopt -s nullglob
        video_devs=(/dev/video*)
        shopt -u nullglob
        CAMS="${#video_devs[@]}"
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

if [[ "$OPT_WEB_API" == true ]]; then
    echo ""
    check_cmd "openssl"    "openssl" "openssl"
    check_cmd "age-keygen" "age"     "age-keygen"
    if command -v sops >/dev/null 2>&1; then
        ok "sops"
    else
        warn "sops — no encontrado. Instalar manualmente: https://github.com/getsops/sops/releases"
    fi
    if command -v uv >/dev/null 2>&1; then
        ok "uv"
    else
        warn "uv — no encontrado. Ver https://docs.astral.sh/uv/getting-started/installation/"
    fi
fi

# Ver si hay micrófono USB conectado
if [[ "$DRY_RUN" == false ]] && command -v arecord >/dev/null 2>&1; then
    echo ""
    MIC_COUNT="$(arecord -l 2>/dev/null | grep -c "^card" || true)"
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

    if [[ "$OPT_WEB_API" == true ]]; then
        echo ""
        echo "  Web API (control desde el celular):"
        echo "       Ver docs/web-api.md para el flujo completo (age key,"
        echo "       .sops.yaml, primer usuario, make web-api)."
    fi

    echo ""
fi
