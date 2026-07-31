#!/usr/bin/env bash
# Crea el usuario de sistema "streamer" y registra los servicios systemd
# de streaming con los permisos mínimos necesarios.
#
# Uso:
#   sudo ./scripts/streaming-install.sh
#
# El usuario "streamer":
#   - Sin shell interactivo ni directorio home
#   - Miembro de los grupos "video" y "audio" (acceso a cámara y micrófono)
#   - Acceso de lectura/ejecución al repositorio (grupo propietario)
#   - NO tiene acceso a red, sudo, ni a ningún otro recurso del sistema

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
STREAM_USER="streamer"
SYSTEMD_DIR="/etc/systemd/system"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ "$EUID" -eq 0 ]] || die "Requiere root. Ejecutar con: sudo $0"

echo "=== Instalación de servicios de streaming ==="
echo "  Usuario : ${STREAM_USER}"
echo "  Repo    : ${REPO_DIR}"
echo "============================================="
echo ""

# --- 1. Usuario de sistema ---
if ! id "$STREAM_USER" >/dev/null 2>&1; then
    useradd \
        --system \
        --no-create-home \
        --shell /usr/sbin/nologin \
        --comment "Raspberry Pi streaming service" \
        "$STREAM_USER"
    echo "Usuario de sistema creado: ${STREAM_USER}"
else
    echo "Usuario existente conservado: ${STREAM_USER}"
fi

# --- 2. Grupos de dispositivos ---
# video → /dev/video* (cámara USB / CSI)
# audio → /dev/snd/*  (micrófono)
for grp in video audio; do
    if getent group "$grp" >/dev/null 2>&1; then
        usermod -aG "$grp" "$STREAM_USER"
        echo "  Añadido al grupo: ${grp}"
    else
        echo "  AVISO: grupo '${grp}' no existe en este sistema"
    fi
done

# --- 3. Permisos sobre el repositorio ---
# streamer necesita leer scripts y assets, pero NO escribir.
# Se asigna el repo al grupo "streamer" con permisos g+rX.
chgrp -R "$STREAM_USER" "$REPO_DIR"
# g+rX: r en archivos, r+x en directorios; sin escritura
chmod -R g+rX "$REPO_DIR"
# Asegurar que los scripts .sh sean ejecutables para el grupo
find "$REPO_DIR/scripts" -name "*.sh" -exec chmod g+x {} \;
echo "Permisos de repo asignados: ${REPO_DIR} → grupo ${STREAM_USER} (lectura/ejecución)"

# --- 4. Permisos sobre /etc/streaming.env ---
# web-api lee/escribe este archivo para pintar y guardar el portal; streamer
# queda como grupo compartido para que los servicios y scripts puedan leerlo.
if [[ -f /etc/streaming.env ]]; then
    if id webapi >/dev/null 2>&1; then
        usermod -aG "$STREAM_USER" webapi
        chown webapi:"$STREAM_USER" /etc/streaming.env
        chmod 660 /etc/streaming.env
    else
        chgrp "$STREAM_USER" /etc/streaming.env
        chmod 640 /etc/streaming.env
    fi
    owner="$(stat -c '%U:%G' /etc/streaming.env)"
    mode="$(stat -c '%a' /etc/streaming.env)"
    echo "Permisos de /etc/streaming.env: ${mode} (${owner})"
else
    install -m 660 -o root -g "$STREAM_USER" "${REPO_DIR}/systemd/default.streaming.env" /etc/streaming.env
    echo "Archivo creado desde defaults: /etc/streaming.env"
fi

# --- 5. Instalar unit files con sustitución de placeholders ---
sed -e "s|__STREAM_USER__|${STREAM_USER}|g" \
    -e "s|__REPO_DIR__|${REPO_DIR}|g" \
    "${REPO_DIR}/systemd/streaming.service" \
    > "${SYSTEMD_DIR}/streaming.service"

sed -e "s|__STREAM_USER__|${STREAM_USER}|g" \
    -e "s|__REPO_DIR__|${REPO_DIR}|g" \
    "${REPO_DIR}/systemd/streaming-overlay.service" \
    > "${SYSTEMD_DIR}/streaming-overlay.service"

sed -e "s|__STREAM_USER__|${STREAM_USER}|g" \
    -e "s|__REPO_DIR__|${REPO_DIR}|g" \
    "${REPO_DIR}/systemd/preview.service" \
    > "${SYSTEMD_DIR}/preview.service"

# --- 5b. Encoder de hardware H.264 (Pi 3B/4B): cargar bcm2835-codec en boot ---
# ensure-gpu-encoder.sh también corre en cada boot (vía boot-stream-orchestrator.sh)
# para re-aplicar este fix si un `apt upgrade` de DietPi reintroduce el blacklist —
# ver docs/reboot-validation.md.
"${REPO_DIR}/scripts/ensure-gpu-encoder.sh"

systemctl daemon-reload
echo "Servicios instalados:"
echo "  ${SYSTEMD_DIR}/streaming.service"
echo "  ${SYSTEMD_DIR}/streaming-overlay.service"
echo "  ${SYSTEMD_DIR}/preview.service"

# Estos servicios nunca deben arrancar automaticamente en boot. Solo deben
# iniciarse por accion explicita desde el portal web, TUI o control.sh.
systemctl disable streaming.service streaming-overlay.service preview.service 2>/dev/null || true
systemctl stop streaming.service streaming-overlay.service preview.service 2>/dev/null || true
systemctl reset-failed streaming.service streaming-overlay.service preview.service 2>/dev/null || true

echo ""
echo "=== Instalación completada ==="
echo ""
echo "Próximos pasos:"
echo "  1. Configurar URL RTMP desde la web: https://<ip-pi>:8443"
echo "  2. Iniciar stream solo desde la web, TUI o make start-streaming"
