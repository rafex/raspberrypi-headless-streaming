#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
BACKEND_CERTS="${ROOT_DIR}/backend/certs/backend"
FRONTEND_CERTS="${ROOT_DIR}/backend/certs/frontend"
DAYS="${DAYS:-825}"

mkdir -p "$BACKEND_CERTS" "$FRONTEND_CERTS"

openssl genrsa -out "${BACKEND_CERTS}/ca.key" 4096
openssl req -x509 -new -nodes \
    -key "${BACKEND_CERTS}/ca.key" \
    -sha256 -days "$DAYS" \
    -subj "/CN=raspi-streaming-client-ca" \
    -out "${BACKEND_CERTS}/ca.crt"

openssl genrsa -out "${FRONTEND_CERTS}/raspi-client.key" 2048
openssl req -new \
    -key "${FRONTEND_CERTS}/raspi-client.key" \
    -subj "/CN=raspi-streaming-raspi" \
    -out "${FRONTEND_CERTS}/raspi-client.csr"

openssl x509 -req \
    -in "${FRONTEND_CERTS}/raspi-client.csr" \
    -CA "${BACKEND_CERTS}/ca.crt" \
    -CAkey "${BACKEND_CERTS}/ca.key" \
    -CAcreateserial \
    -out "${FRONTEND_CERTS}/raspi-client.crt" \
    -days "$DAYS" -sha256

chmod 600 "${BACKEND_CERTS}/ca.key" "${FRONTEND_CERTS}/raspi-client.key"
rm -f "${FRONTEND_CERTS}/raspi-client.csr"

cat <<EOF
Certificados generados:
  ${BACKEND_CERTS}/ca.crt
  ${BACKEND_CERTS}/ca.key
  ${FRONTEND_CERTS}/raspi-client.crt
  ${FRONTEND_CERTS}/raspi-client.key

No subas claves reales al repositorio.
EOF
