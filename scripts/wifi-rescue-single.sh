#!/usr/bin/env bash
# Rescate WiFi: conecta la Raspi a una sola red y deja SSH recuperable por DHCP.
#
# Uso:
#   sudo scripts/wifi-rescue-single.sh --ssid "Mi WiFi" --password "clave"
#   sudo scripts/wifi-rescue-single.sh --ssid "Red Abierta" --open
#
# Este script es intencionalmente independiente del bootstrap/AP. Detiene y
# deshabilita raspi-wifi-bootstrap.service para que no vuelva a tomar wlan0.

set -euo pipefail

IFACE="wlan0"
SSID=""
PASSWORD=""
OPEN=false
COUNTRY="${WIFI_COUNTRY:-MX}"
STATE_DIR="/run/raspi-wifi-rescue"
CONF_FILE="${STATE_DIR}/wpa_supplicant.conf"
PID_FILE="${STATE_DIR}/wpa_supplicant.pid"
DHCLIENT_PID="/run/dhclient.${IFACE}.pid"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[wifi-rescue] $*"; }

usage() {
    sed -n '1,12p' "$0"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --iface)
            IFACE="${2:-}"; shift 2 ;;
        --ssid)
            SSID="${2:-}"; shift 2 ;;
        --password)
            PASSWORD="${2:-}"; shift 2 ;;
        --open)
            OPEN=true; shift ;;
        --country)
            COUNTRY="${2:-}"; shift 2 ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            die "Argumento no reconocido: $1" ;;
    esac
done

[[ "$EUID" -eq 0 ]] || die "Ejecutar como root."
[[ -n "$SSID" ]] || die "Falta --ssid."
if [[ "$OPEN" == false && -z "$PASSWORD" ]]; then
    die "Falta --password, o usa --open para una red sin clave."
fi

for cmd in ip wpa_supplicant wpa_cli dhclient rfkill systemctl; do
    command -v "$cmd" >/dev/null 2>&1 || die "Falta comando: $cmd"
done
if [[ "$OPEN" == false ]]; then
    command -v wpa_passphrase >/dev/null 2>&1 || die "Falta comando: wpa_passphrase"
fi

log "Deshabilitando bootstrap para recuperar control manual de ${IFACE}."
systemctl disable --now raspi-wifi-bootstrap.service 2>/dev/null || true
systemctl kill -s KILL raspi-wifi-bootstrap.service 2>/dev/null || true
systemctl reset-failed raspi-wifi-bootstrap.service 2>/dev/null || true

log "Deteniendo procesos WiFi/AP anteriores."
pkill -f "wpa_supplicant.*raspi-wifi" 2>/dev/null || true
pkill -f "hostapd.*raspi-wifi" 2>/dev/null || true
pkill -f "dnsmasq.*raspi-wifi" 2>/dev/null || true
pkill -f "wpa_supplicant.*${IFACE}" 2>/dev/null || true
pkill -f "dhclient.*${IFACE}" 2>/dev/null || true

systemctl stop NetworkManager.service wpa_supplicant.service hostapd.service dnsmasq.service 2>/dev/null || true

rm -rf "$STATE_DIR"
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
rm -f "/run/wpa_supplicant/${IFACE}" "$DHCLIENT_PID" 2>/dev/null || true

log "Preparando ${IFACE}."
rfkill unblock wifi || true
ip addr flush dev "$IFACE" || true
ip link set "$IFACE" up

{
    echo "ctrl_interface=/run/wpa_supplicant"
    echo "update_config=0"
    echo "country=${COUNTRY}"
    echo
    if [[ "$OPEN" == true ]]; then
        cat <<EOF
network={
    ssid="${SSID//\"/\\\"}"
    key_mgmt=NONE
}
EOF
    else
        wpa_passphrase "$SSID" "$PASSWORD"
    fi
} > "$CONF_FILE"
chmod 600 "$CONF_FILE"

log "Intentando conectar a SSID='${SSID}' en ${IFACE}."
wpa_supplicant -B -P "$PID_FILE" -i "$IFACE" -c "$CONF_FILE"

deadline=$((SECONDS + 25))
last_state=""
while (( SECONDS < deadline )); do
    status="$(wpa_cli -i "$IFACE" status 2>/dev/null || true)"
    state="$(printf '%s\n' "$status" | awk -F= '/^wpa_state=/{print $2; exit}')"
    if [[ -n "$state" && "$state" != "$last_state" ]]; then
        log "wpa_state=${state}"
        last_state="$state"
    fi
    if printf '%s\n' "$status" | grep -q '^wpa_state=COMPLETED$'; then
        break
    fi
    sleep 1
done

if ! wpa_cli -i "$IFACE" status 2>/dev/null | grep -q '^wpa_state=COMPLETED$'; then
    wpa_cli -i "$IFACE" status 2>/dev/null || true
    die "No se pudo asociar al WiFi."
fi

log "Asociado. Solicitando DHCP."
dhclient -v "$IFACE"

log "Resultado:"
ip -4 -o addr show dev "$IFACE" || true
ip route show default || true

ip_addr="$(ip -4 -o addr show dev "$IFACE" | awk '{print $4}' | cut -d/ -f1 | head -n1)"
if [[ -n "$ip_addr" ]]; then
    log "Listo. Desde tu maquina prueba: ssh root@${ip_addr}"
else
    die "Conecto a WiFi, pero no obtuvo IPv4 por DHCP."
fi
