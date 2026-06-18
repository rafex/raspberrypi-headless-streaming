#!/usr/bin/env bash
# Renueva el certificado TLS autofirmado de web-api si expira en menos de
# DAYS_WARN días (default: 60). Diseñado para cron mensual como root:
#
#   0 3 1 * * root /opt/web-api/scripts/renew-tls-cert.sh \
#               >> /var/log/web-api-cert-renew.log 2>&1
#
# Instalar el cron:
#   sudo cp scripts/renew-tls-cert.sh /opt/web-api/scripts/
#   echo '0 3 1 * * root /opt/web-api/scripts/renew-tls-cert.sh >> /var/log/web-api-cert-renew.log 2>&1' \
#       | sudo tee /etc/cron.d/web-api-cert-renew
#
# Para ver días restantes manualmente:
#   openssl x509 -in /etc/raspi-streaming/tls/cert.pem -noout -enddate

set -euo pipefail

DAYS_WARN="${DAYS_WARN:-60}"
ENV_FILE="/etc/web-api.env"

[[ "$EUID" -eq 0 ]] || { echo "ERROR: requiere root. Usar: sudo $0"; exit 1; }
[[ -f "$ENV_FILE" ]] || { echo "ERROR: no existe $ENV_FILE"; exit 1; }

# Leer rutas del entorno
TLS_CERT=$(grep -E '^TLS_CERT=' "$ENV_FILE" | cut -d= -f2- | tr -d ' ')
TLS_KEY=$(grep -E '^TLS_KEY='  "$ENV_FILE" | cut -d= -f2- | tr -d ' ')

[[ -n "$TLS_CERT" && -f "$TLS_CERT" ]] || { echo "ERROR: certificado no encontrado: ${TLS_CERT:-vacío}"; exit 1; }
[[ -n "$TLS_KEY"  ]]                    || { echo "ERROR: TLS_KEY no definido en $ENV_FILE"; exit 1; }

# Calcular días hasta expiración (compatible con GNU date en Raspberry Pi OS)
EXPIRY_STR=$(openssl x509 -in "$TLS_CERT" -noout -enddate | cut -d= -f2)
EXPIRY_EPOCH=$(date -d "$EXPIRY_STR" +%s 2>/dev/null || date -jf "%b %d %T %Y %Z" "$EXPIRY_STR" +%s)
NOW_EPOCH=$(date +%s)
DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))

TS=$(date -Iseconds)

if [[ "$DAYS_LEFT" -gt "$DAYS_WARN" ]]; then
    echo "${TS} OK: certificado válido por ${DAYS_LEFT} días. Sin acción."
    exit 0
fi

echo "${TS} AVISO: certificado expira en ${DAYS_LEFT} días — renovando..."

HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
HOST_NAME="$(hostname)"

# Generar en archivos temporales para no dejar cert roto si algo falla
openssl req -x509 -newkey rsa:2048 -days 825 -nodes \
    -subj "/CN=${HOST_NAME}" \
    -addext "subjectAltName=DNS:${HOST_NAME},IP:${HOST_IP:-127.0.0.1}" \
    -keyout "${TLS_KEY}.new" \
    -out "${TLS_CERT}.new" 2>/dev/null

mv "${TLS_KEY}.new"  "$TLS_KEY"
mv "${TLS_CERT}.new" "$TLS_CERT"
chmod 600 "$TLS_KEY"
chmod 644 "$TLS_CERT"

systemctl restart web-api.service
echo "${TS} Certificado renovado (825 días). web-api reiniciado."
