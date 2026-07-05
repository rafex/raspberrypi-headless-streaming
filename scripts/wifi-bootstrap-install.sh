#!/usr/bin/env bash
# Instala el bootstrap WiFi/AP. No inicia streaming ni preview.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SYSTEMD_DIR="/etc/systemd/system"
CONFIG_DIR="/etc/raspi-streaming"
CONFIG_FILE="${CONFIG_DIR}/wifi-networks.toml"
SECRETS_FILE="${CONFIG_DIR}/wifi-secrets.env"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ "$EUID" -eq 0 ]] || die "Requiere root. Ejecutar con: sudo $0"

echo "=== Instalacion WiFi bootstrap ==="
echo "  Repo   : ${REPO_DIR}"
echo "  Config : ${CONFIG_FILE}"
echo ""

apt-get update -qq
apt-get install -y -qq python3 python3-tomli wpasupplicant wireless-tools iw iproute2 isc-dhcp-client hostapd dnsmasq rfkill

# El bootstrap lanza hostapd/dnsmasq manualmente con configs temporales en
# /run. Los servicios distro deben quedar apagados para no ocupar puertos ni
# interferir con el fallback AP al arrancar.
systemctl disable --now hostapd.service dnsmasq.service 2>/dev/null || true

mkdir -p "$CONFIG_DIR"
if [[ ! -f "$CONFIG_FILE" ]]; then
    cp "${REPO_DIR}/systemd/wifi-networks.toml.example" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    echo "Config creada: ${CONFIG_FILE}"
else
    echo "Config existente conservada: ${CONFIG_FILE}"
fi

if [[ ! -f "$SECRETS_FILE" ]]; then
    cat > "$SECRETS_FILE" <<'EOF'
# Secretos WiFi locales. Referenciar desde wifi-networks.toml con password_env.
# Ejemplo:
# WIFI_CASA_PASSWORD="clave-super-secreta"
EOF
    chmod 600 "$SECRETS_FILE"
    echo "Secrets creado: ${SECRETS_FILE}"
else
    chmod 600 "$SECRETS_FILE"
    echo "Secrets existente conservado: ${SECRETS_FILE}"
fi

sed "s|__REPO_DIR__|${REPO_DIR}|g" \
    "${REPO_DIR}/systemd/raspi-wifi-bootstrap.service" \
    > "${SYSTEMD_DIR}/raspi-wifi-bootstrap.service"

systemctl daemon-reload
systemctl enable raspi-wifi-bootstrap.service

# Nunca arrancar streaming/preview por instalar este bootstrap.
systemctl disable streaming.service streaming-overlay.service preview.service 2>/dev/null || true
systemctl stop streaming.service streaming-overlay.service preview.service 2>/dev/null || true
systemctl reset-failed streaming.service streaming-overlay.service preview.service 2>/dev/null || true

echo ""
echo "Instalado. Editar redes en:"
echo "  ${CONFIG_FILE}"
echo ""
echo "Arrancar ahora con:"
echo "  sudo systemctl start raspi-wifi-bootstrap.service"
