#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${1:-streaming-rafex-io}"
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
BACKEND_CERTS="${ROOT_DIR}/backend/certs/backend"

[[ -f "${BACKEND_CERTS}/ca.crt" ]] || {
    echo "Falta ${BACKEND_CERTS}/ca.crt. Ejecuta backend/helpers/generate-dev-certs.sh" >&2
    exit 1
}

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$NAMESPACE" create secret generic streaming-api-client-ca \
    --from-file=ca.crt="${BACKEND_CERTS}/ca.crt" \
    --dry-run=client -o yaml | kubectl apply -f -

echo "Secret creado/actualizado: ${NAMESPACE}/streaming-api-client-ca"
