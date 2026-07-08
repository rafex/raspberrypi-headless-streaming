#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEVICE_ID="${DEVICE_ID:-raspi3b}"
DAYS="${DAYS:-825}"

exec "${SCRIPT_DIR}/streaming-api-secrets.py" certs \
    --device-id "$DEVICE_ID" \
    --days "$DAYS" \
    "$@"
