#!/usr/bin/env bash
set -euo pipefail

TARGET="${1:-}"
if [[ -z "$TARGET" ]]; then
    echo "Uso: $0 root@192.168.3.169" >&2
    exit 1
fi

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SRC_DIR="${ROOT_DIR}/backend/certs/frontend"
REMOTE_DIR="/etc/raspi-streaming/backend-client"

for file in raspi-client.crt raspi-client.key; do
    [[ -f "${SRC_DIR}/${file}" ]] || {
        echo "Falta ${SRC_DIR}/${file}. Ejecuta backend/helpers/generate-dev-certs.sh" >&2
        exit 1
    }
done

ssh "$TARGET" "install -d -m 700 ${REMOTE_DIR}"
scp "${SRC_DIR}/raspi-client.crt" "${SRC_DIR}/raspi-client.key" "${TARGET}:${REMOTE_DIR}/"
ssh "$TARGET" "chmod 600 ${REMOTE_DIR}/raspi-client.key && chmod 644 ${REMOTE_DIR}/raspi-client.crt"

echo "Certificado cliente instalado en ${TARGET}:${REMOTE_DIR}"
