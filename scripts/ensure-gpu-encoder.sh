#!/usr/bin/env bash
# Garantiza que el módulo bcm2835-codec (encoder H.264 del VideoCore, usado
# por h264_v4l2m2m) esté cargado y lo deje así de forma persistente.
#
# DietPi trae por defecto /etc/modprobe.d/dietpi-disable_rpi_codec.conf con
# "blacklist bcm2835_codec". Un `apt upgrade` de dietpi-config o paquetes
# relacionados puede recrear ese archivo y reintroducir la línea, deshaciendo
# el fix aplicado en la instalación (ver docs/reboot-validation.md). Este
# script no asume que el fix de instalación sigue vigente: revisa TODOS los
# archivos de /etc/modprobe.d/ en cada ejecución y neutraliza cualquier
# blacklist activo de bcm2835_codec que encuentre, antes de intentar cargar
# el módulo.
#
# Pensado para correr como root, en cada arranque, ANTES de iniciar streaming
# (streaming-overlay.service corre como el usuario sin privilegios "streamer",
# que no puede hacer modprobe ni tocar /etc/modprobe.d/).
#
# Uso:
#   sudo ./scripts/ensure-gpu-encoder.sh
#
# Código de salida: 0 siempre (nunca bloquea el arranque de streaming; si el
# hardware no está disponible, stream-overlay.sh cae a libx264 igualmente).

set -uo pipefail

log() { echo "[ensure-gpu-encoder] $*"; }

if [[ "$EUID" -ne 0 ]]; then
    log "Requiere root (modprobe / editar /etc/modprobe.d). Omitiendo."
    exit 0
fi

if ! modinfo bcm2835-codec >/dev/null 2>&1; then
    log "bcm2835-codec no existe en este kernel; nada que hacer."
    exit 0
fi

# --- 1. Neutralizar cualquier blacklist activo, sea cual sea su origen ---
FOUND_BLACKLIST=false
for conf in /etc/modprobe.d/*.conf; do
    [[ -f "$conf" ]] || continue
    if grep -q '^blacklist[[:space:]]\+bcm2835_codec' "$conf" 2>/dev/null; then
        sed -i 's/^blacklist[[:space:]]\+bcm2835_codec/#blacklist bcm2835_codec  # comentado por raspi-streaming (GPU encoder) — ver docs\/reboot-validation.md/' "$conf"
        log "Blacklist activo encontrado y neutralizado en: ${conf}"
        FOUND_BLACKLIST=true
    fi
done
[[ "$FOUND_BLACKLIST" == false ]] && log "Sin blacklist activo de bcm2835_codec."

# --- 2. Asegurar la entrada de carga automática en boot ---
MODULES_LOAD_FILE="/etc/modules-load.d/raspi-streaming.conf"
if [[ ! -f "$MODULES_LOAD_FILE" ]] || ! grep -q '^bcm2835-codec$' "$MODULES_LOAD_FILE" 2>/dev/null; then
    echo "bcm2835-codec" > "$MODULES_LOAD_FILE"
    chmod 644 "$MODULES_LOAD_FILE"
    log "Entrada de carga automática recreada: ${MODULES_LOAD_FILE}"
fi

# --- 3. Cargar el módulo ahora si no está activo ---
if lsmod 2>/dev/null | grep -q '^bcm2835_codec'; then
    log "Módulo ya activo."
else
    if modprobe bcm2835-codec 2>/dev/null; then
        log "Módulo cargado correctamente."
    else
        log "AVISO: modprobe bcm2835-codec falló; el stream usará libx264."
    fi
fi

exit 0
