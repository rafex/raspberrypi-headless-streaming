#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Uso:
  source backend/helpers/github-secrets.env.local
  backend/helpers/set-github-secrets.sh

Variables requeridas:
  K3S_SSH_USER
  K3S_SSH_PRIVATE_KEY_FILE
  STREAMING_API_RASPI_TOKEN
  STREAMING_API_ADMIN_TOKEN
  STREAMING_API_CLIENT_CA_CRT_FILE

Requiere GitHub CLI autenticado con permisos para administrar secrets:
  gh auth login
EOF
}

if [[ "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

require_var() {
    local name="$1"
    if [[ -z "${!name:-}" ]]; then
        echo "Falta variable: ${name}" >&2
        usage >&2
        exit 1
    fi
}

require_file() {
    local name="$1"
    local path="${!name}"
    if [[ ! -f "$path" ]]; then
        echo "No existe archivo ${name}: ${path}" >&2
        exit 1
    fi
}

command -v gh >/dev/null 2>&1 || {
    echo "gh no esta instalado o no esta en PATH" >&2
    exit 1
}

require_var K3S_SSH_USER
require_var K3S_SSH_PRIVATE_KEY_FILE
require_var STREAMING_API_RASPI_TOKEN
require_var STREAMING_API_ADMIN_TOKEN
require_var STREAMING_API_CLIENT_CA_CRT_FILE
require_file K3S_SSH_PRIVATE_KEY_FILE
require_file STREAMING_API_CLIENT_CA_CRT_FILE

gh secret set K3S_SSH_USER --body "$K3S_SSH_USER"
gh secret set K3S_SSH_PRIVATE_KEY < "$K3S_SSH_PRIVATE_KEY_FILE"
gh secret set STREAMING_API_RASPI_TOKEN --body "$STREAMING_API_RASPI_TOKEN"
gh secret set STREAMING_API_ADMIN_TOKEN --body "$STREAMING_API_ADMIN_TOKEN"
base64 < "$STREAMING_API_CLIENT_CA_CRT_FILE" \
    | tr -d '\n' \
    | gh secret set STREAMING_API_CLIENT_CA_CRT_B64 --body-file -

echo "Secrets de GitHub creados/actualizados."
