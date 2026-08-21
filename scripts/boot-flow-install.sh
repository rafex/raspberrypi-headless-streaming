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

if ! command -v ngrok >/dev/null 2>&1; then
    "${REPO_DIR}/scripts/install-deps.sh" --ngrok
fi

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

# Actualizar únicamente valores que pertenecían a defaults anteriores.
# Cualquier valor diferente representa una decisión explícita del usuario y se
# conserva para no sobrescribir configuración personalizada en una actualización.
migrate_boot_flow_delay() {
    local dst="$1"
    local current
    [[ -f "$dst" ]] || return 0

    current="$(awk -F= '$1 == "AUTO_STREAM_DELAY_SECONDS" {print $2; exit}' "$dst")"
    case "$current" in
        120|420)
            sed -i 's/^AUTO_STREAM_DELAY_SECONDS=.*/AUTO_STREAM_DELAY_SECONDS=600/' "$dst"
            echo "Delay migrado: ${dst} (${current}s → 600s)"
            ;;
    esac
}

install_config_if_missing "${REPO_DIR}/systemd/boot-flow.env.example" "${CONFIG_DIR}/boot-flow.env" 600
migrate_boot_flow_delay "${CONFIG_DIR}/boot-flow.env"
install_config_if_missing "${REPO_DIR}/systemd/health-reporter.env.example" "${CONFIG_DIR}/health-reporter.env" 600
install_config_if_missing "${REPO_DIR}/systemd/backend-control-agent.env.example" "${CONFIG_DIR}/backend-control-agent.env" 600
install_config_if_missing "${REPO_DIR}/systemd/ngrok.env.example" "${CONFIG_DIR}/ngrok.env" 600
install_config_if_missing "${REPO_DIR}/systemd/ngrok.yml.example" "${CONFIG_DIR}/ngrok.yml" 600

sed "s|__REPO_DIR__|${REPO_DIR}|g" \
    "${REPO_DIR}/systemd/boot-stream-orchestrator.service" \
    > "${SYSTEMD_DIR}/boot-stream-orchestrator.service"

sed "s|__REPO_DIR__|${REPO_DIR}|g" \
    "${REPO_DIR}/systemd/health-reporter.service" \
    > "${SYSTEMD_DIR}/health-reporter.service"

sed "s|__REPO_DIR__|${REPO_DIR}|g" \
    "${REPO_DIR}/systemd/backend-control-agent.service" \
    > "${SYSTEMD_DIR}/backend-control-agent.service"

cp "${REPO_DIR}/systemd/ngrok-web.service" "${SYSTEMD_DIR}/ngrok-web.service"

systemctl daemon-reload

# El orquestador queda enabled. El auto-stream depende de boot-flow.env y de
# que exista una ruta default y un RTMP_URL valido.
systemctl enable boot-stream-orchestrator.service

echo ""
echo "Servicios instalados:"
echo "  boot-stream-orchestrator.service (enabled; auto-stream depende de boot-flow.env)"
echo "  health-reporter.service (disabled por defecto)"
echo "  backend-control-agent.service (disabled por defecto)"
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
echo "Para control remoto desde backend:"
echo "  sudo nano ${CONFIG_DIR}/backend-control-agent.env"
echo "  sudo systemctl enable --now backend-control-agent.service"
echo ""
echo "Para ngrok:"
echo "  poner authtoken en ${CONFIG_DIR}/ngrok.yml"
echo "  sudo nano ${CONFIG_DIR}/ngrok.env"
echo "  sudo systemctl enable --now ngrok-web.service"
