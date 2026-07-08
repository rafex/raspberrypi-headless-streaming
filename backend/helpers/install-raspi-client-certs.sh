#!/usr/bin/env bash
set -euo pipefail

TARGET="${1:-}"
if [[ -z "$TARGET" ]]; then
    echo "Uso: $0 root@192.168.3.169 [--device-id raspi3b]" >&2
    exit 1
fi
shift || true

DEVICE_ID="${DEVICE_ID:-raspi3b}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --device-id) DEVICE_ID="$2"; shift 2 ;;
        *) echo "Opcion desconocida: $1" >&2; exit 1 ;;
    esac
done

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SRC_DIR="${ROOT_DIR}/backend/certs/frontend"
REMOTE_DIR="/etc/raspi-streaming/backend-client"

for file in "${DEVICE_ID}.crt" "${DEVICE_ID}.key"; do
    [[ -f "${SRC_DIR}/${file}" ]] || {
        echo "Falta ${SRC_DIR}/${file}. Ejecuta backend/helpers/generate-dev-certs.sh" >&2
        exit 1
    }
done

ssh "$TARGET" "install -d -m 700 ${REMOTE_DIR}"
scp "${SRC_DIR}/${DEVICE_ID}.crt" "${TARGET}:${REMOTE_DIR}/raspi-client.crt"
scp "${SRC_DIR}/${DEVICE_ID}.key" "${TARGET}:${REMOTE_DIR}/raspi-client.key"
ssh "$TARGET" "chmod 600 ${REMOTE_DIR}/raspi-client.key && chmod 644 ${REMOTE_DIR}/raspi-client.crt"

echo "Certificado cliente instalado en ${TARGET}:${REMOTE_DIR}"
