#!/usr/bin/env bash
# Instala el flujo post-WiFi: auto-stream diferido, health reporter y ngrok web.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_DIR="/etc/raspi-streaming"
SYSTEMD_DIR="/etc/systemd/system"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ "$EUID" -eq 0 ]] || die "Requiere root. Ejecutar con: sudo $0"

mkdir -p "$CONFIG_DIR"

install_config_if_missing() {
    local src="$1"
    local dst="$2"
    local mode="${3:-600}"
    if [[ ! -f "$dst" ]]; then
        cp "$src" "$dst"
        chmod "$mode" "$dst"
        echo "Config creada: $dst"
    else
        chmod "$mode" "$dst"
        echo "Config existente conservada: $dst"
    fi
}

install_config_if_missing "${REPO_DIR}/systemd/boot-flow.env.example" "${CONFIG_DIR}/boot-flow.env" 600
install_config_if_missing "${REPO_DIR}/systemd/health-reporter.env.example" "${CONFIG_DIR}/health-reporter.env" 600
install_config_if_missing "${REPO_DIR}/systemd/ngrok.env.example" "${CONFIG_DIR}/ngrok.env" 600

sed "s|__REPO_DIR__|${REPO_DIR}|g" \
    "${REPO_DIR}/systemd/boot-stream-orchestrator.service" \
    > "${SYSTEMD_DIR}/boot-stream-orchestrator.service"

sed "s|__REPO_DIR__|${REPO_DIR}|g" \
    "${REPO_DIR}/systemd/health-reporter.service" \
    > "${SYSTEMD_DIR}/health-reporter.service"

cp "${REPO_DIR}/systemd/ngrok-web.service" "${SYSTEMD_DIR}/ngrok-web.service"

systemctl daemon-reload

# Seguro por defecto: el orquestador queda enabled, pero no arranca stream si
# AUTO_STREAM_ENABLED=false. Health/ngrok se habilitan cuando tengan config.
systemctl enable boot-stream-orchestrator.service

echo ""
echo "Servicios instalados:"
echo "  boot-stream-orchestrator.service (enabled; auto-stream depende de boot-flow.env)"
echo "  health-reporter.service (disabled por defecto)"
echo "  ngrok-web.service (disabled por defecto)"
echo ""
echo "Para habilitar auto-stream:"
echo "  sudo nano ${CONFIG_DIR}/boot-flow.env"
echo "  AUTO_STREAM_ENABLED=true"
echo ""
echo "Para health reporter:"
echo "  sudo nano ${CONFIG_DIR}/health-reporter.env"
echo "  sudo systemctl enable --now health-reporter.service"
echo ""
echo "Para ngrok:"
echo "  instalar/configurar ngrok y ajustar NGROK_BIN si no esta en PATH"
echo "  sudo nano ${CONFIG_DIR}/ngrok.env"
echo "  sudo systemctl enable --now ngrok-web.service"
