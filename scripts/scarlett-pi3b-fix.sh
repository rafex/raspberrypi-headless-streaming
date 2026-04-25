#!/usr/bin/env bash
# Aplica el fix del controlador USB dwc_otg para Focusrite Scarlett en Raspberry Pi 3B.
#
# El controlador USB dwc_otg de la Pi 3B tiene un bug con dispositivos UAC2
# (USB Audio Class 2.0) como la Focusrite Scarlett: produce ruido, dropout o
# fallos de grabación aunque el dispositivo aparezca en arecord -l.
#
# Solución: deshabilitar la FSQ (Finite State Queue) del controlador dwc_otg
# agregando dwc_otg.fiq_fsm_enable=0 a /boot/cmdline.txt.
#
# Uso:
#   sudo ./scarlett-pi3b-fix.sh [opciones]
#
# Opciones:
#   --check      Verificar si el fix ya está aplicado (sin modificar nada)
#   --apply      Aplicar el fix y reiniciar (default si se ejecuta sin opciones)
#   --revert     Revertir el fix (eliminar el parámetro de /boot/cmdline.txt)
#   --no-reboot  Aplicar sin reiniciar (el fix no tiene efecto hasta el próximo reinicio)
#   --help       Mostrar esta ayuda
#
# Requisitos:
#   - Ejecutar como root (sudo)
#   - Raspberry Pi 3B / 3B+ (en Pi 4 no es necesario, tiene controlador xhci)
#   - /boot/cmdline.txt debe existir
#
# Ejemplos:
#   sudo ./scarlett-pi3b-fix.sh
#   sudo ./scarlett-pi3b-fix.sh --check
#   sudo ./scarlett-pi3b-fix.sh --apply --no-reboot
#   sudo ./scarlett-pi3b-fix.sh --revert

set -euo pipefail

CMDLINE="/boot/cmdline.txt"
PARAM="dwc_otg.fiq_fsm_enable=0"
MODE="apply"
NO_REBOOT=false

usage() {
    grep '^#' "$0" | grep -v '#!/' | sed 's/^# \{0,1\}//'
    exit 0
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

info()    { echo "  $*"; }
ok()      { echo "  [OK] $*"; }
warn()    { echo "  [AVISO] $*"; }
changed() { echo "  [CAMBIO] $*"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)     MODE="check"; shift ;;
        --apply)     MODE="apply"; shift ;;
        --revert)    MODE="revert"; shift ;;
        --no-reboot) NO_REBOOT=true; shift ;;
        --help)      usage ;;
        *) die "Opción desconocida: $1. Usa --help para ver las opciones." ;;
    esac
done

# ---------------------------------------------------------------------------
# Verificar entorno
# ---------------------------------------------------------------------------
[[ -f "$CMDLINE" ]] || die "$CMDLINE no encontrado. ¿Es una Raspberry Pi con Raspberry Pi OS / DietPi?"

# Detectar modelo de Pi
PI_MODEL=""
if [[ -f /proc/device-tree/model ]]; then
    PI_MODEL=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || true)
fi

# ---------------------------------------------------------------------------
# Modo: check
# ---------------------------------------------------------------------------
if [[ "$MODE" == "check" ]]; then
    echo "=== Estado del fix dwc_otg para Focusrite Scarlett ==="
    echo ""

    info "Archivo : $CMDLINE"
    info "Parámetro buscado: $PARAM"
    echo ""

    if [[ -n "$PI_MODEL" ]]; then
        info "Modelo detectado: $PI_MODEL"
    fi

    CURRENT=$(cat "$CMDLINE")
    info "Contenido actual de $CMDLINE:"
    echo "    $CURRENT"
    echo ""

    if echo "$CURRENT" | grep -q "$PARAM"; then
        ok "El fix YA está aplicado."
        echo ""
        echo "La Focusrite Scarlett debería funcionar sin ruido ni dropout."
        echo "Si acabas de aplicarlo, asegúrate de haber reiniciado."
    else
        warn "El fix NO está aplicado."
        echo ""
        echo "Si tienes ruido, dropout o errores con la Scarlett, aplicar con:"
        echo "  sudo $0 --apply"
    fi

    echo ""
    # Verificar si la Scarlett está conectada
    echo "=== Dispositivos Focusrite/Scarlett conectados ==="
    echo ""
    if command -v lsusb >/dev/null 2>&1; then
        if lsusb 2>/dev/null | grep -qi "focusrite\|scarlett"; then
            lsusb 2>/dev/null | grep -i "focusrite\|scarlett"
        else
            info "Ningún dispositivo Focusrite/Scarlett detectado en USB."
        fi
    else
        warn "lsusb no disponible. Instalar con: sudo apt install usbutils"
    fi

    echo ""
    if command -v arecord >/dev/null 2>&1; then
        echo "=== Dispositivos de captura ALSA ==="
        echo ""
        arecord -l 2>/dev/null || info "(ninguno)"
    fi

    exit 0
fi

# ---------------------------------------------------------------------------
# Requiere root para modificar /boot/cmdline.txt
# ---------------------------------------------------------------------------
[[ "$EUID" -eq 0 ]] || die "Este script requiere permisos de root. Ejecutar con: sudo $0 $*"

# ---------------------------------------------------------------------------
# Modo: revert
# ---------------------------------------------------------------------------
if [[ "$MODE" == "revert" ]]; then
    echo "=== Revertir fix dwc_otg ==="
    echo ""

    CURRENT=$(cat "$CMDLINE")

    if ! echo "$CURRENT" | grep -q "$PARAM"; then
        info "El parámetro '$PARAM' no está presente en $CMDLINE."
        info "No hay nada que revertir."
        exit 0
    fi

    info "Creando backup: ${CMDLINE}.bak"
    cp "$CMDLINE" "${CMDLINE}.bak"

    # Eliminar el parámetro (con espacio delante o detrás)
    NEW=$(echo "$CURRENT" | sed "s/ ${PARAM}//g" | sed "s/${PARAM} //g" | sed "s/${PARAM}//g")
    echo "$NEW" > "$CMDLINE"

    changed "Parámetro eliminado de $CMDLINE"
    info "Contenido nuevo:"
    echo "    $(cat "$CMDLINE")"
    echo ""

    if [[ "$NO_REBOOT" == true ]]; then
        warn "Reinicio omitido (--no-reboot). El cambio tendrá efecto en el próximo reinicio."
    else
        echo "Reiniciando en 5 segundos para aplicar el cambio..."
        echo "Ctrl+C para cancelar."
        sleep 5
        reboot
    fi

    exit 0
fi

# ---------------------------------------------------------------------------
# Modo: apply (default)
# ---------------------------------------------------------------------------
echo "=== Fix dwc_otg para Focusrite Scarlett en Pi 3B ==="
echo ""

if [[ -n "$PI_MODEL" ]]; then
    info "Modelo: $PI_MODEL"

    # Advertir si parece ser una Pi 4 (no necesita el fix)
    if echo "$PI_MODEL" | grep -qi "raspberry pi 4\|raspberry pi 5"; then
        warn "Este modelo usa controlador xhci, no dwc_otg."
        warn "El fix no es necesario para Pi 4/5."
        warn "La Scarlett debería funcionar directamente."
        echo ""
        read -r -p "¿Continuar de todos modos? [s/N] " CONFIRM
        [[ "$CONFIRM" =~ ^[sS]$ ]] || { info "Cancelado."; exit 0; }
        echo ""
    fi
fi

CURRENT=$(cat "$CMDLINE")
info "Archivo         : $CMDLINE"
info "Parámetro       : $PARAM"
echo ""

# Verificar si ya está aplicado
if echo "$CURRENT" | grep -q "$PARAM"; then
    ok "El fix ya está aplicado."
    info "Contenido de $CMDLINE:"
    echo "    $CURRENT"
    echo ""
    info "No se requieren cambios."
    echo ""
    echo "Verificar estado con: $0 --check"
    exit 0
fi

# Crear backup antes de modificar
info "Creando backup: ${CMDLINE}.bak"
cp "$CMDLINE" "${CMDLINE}.bak"
ok "Backup creado."
echo ""

# Agregar el parámetro al final de la línea (cmdline.txt es una sola línea)
# Usar printf para evitar agregar newline extra
NEWCONTENT="${CURRENT% } ${PARAM}"
printf '%s\n' "$NEWCONTENT" > "$CMDLINE"

changed "Parámetro agregado a $CMDLINE"
echo ""
info "Contenido anterior:"
echo "    $CURRENT"
echo ""
info "Contenido nuevo:"
echo "    $(cat "$CMDLINE")"
echo ""

echo "=== Resultado ==="
echo ""
echo "Fix aplicado correctamente."
echo ""
echo "Qué hace este fix:"
echo "  - Desactiva la FSQ (Finite State Queue) del controlador USB dwc_otg"
echo "  - Elimina el bug que produce ruido/dropout en dispositivos UAC2"
echo "  - Afecta solo a Pi 3B/3B+; no tiene impacto en Pi 4/5"
echo ""
echo "Para revertir si hubiera problemas:"
echo "  sudo $0 --revert"
echo ""

if [[ "$NO_REBOOT" == true ]]; then
    warn "Reinicio omitido (--no-reboot)."
    warn "El fix NO tiene efecto hasta el próximo reinicio."
    echo ""
    echo "Reiniciar cuando sea conveniente con: sudo reboot"
else
    echo "Reiniciando en 5 segundos para que el cambio surta efecto..."
    echo "Ctrl+C para cancelar el reinicio (el cambio en cmdline.txt ya está guardado)."
    sleep 5
    reboot
fi
