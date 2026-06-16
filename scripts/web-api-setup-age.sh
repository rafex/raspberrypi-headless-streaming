#!/usr/bin/env bash
# Genera (si no existe) la age key usada por web-api para descifrar
# server/webapi/secrets.enc.yaml, e inyecta la public key resultante en
# .sops.yaml. Pensado para invocarse vía "make age-key".
#
# Uso:
#   ./web-api-setup-age.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SOPS_YAML="${REPO_DIR}/.sops.yaml"
AGE_DIR="/etc/raspi-streaming/age"
AGE_KEY_FILE="${AGE_DIR}/key.txt"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

command -v age-keygen >/dev/null 2>&1 \
    || die "age no encontrado. Instalar con: sudo scripts/install-deps.sh --web-api"
[[ -f "$SOPS_YAML" ]] || die "No se encontró ${SOPS_YAML}."

if [[ -f "$AGE_KEY_FILE" ]]; then
    echo "Age key ya existe: ${AGE_KEY_FILE} (no se genera una nueva)."
else
    echo "Generando age key en ${AGE_KEY_FILE}..."
    sudo mkdir -p "$AGE_DIR"
    sudo age-keygen -o "$AGE_KEY_FILE"
    sudo chmod 600 "$AGE_KEY_FILE"
fi

PUBLIC_KEY="$(sudo age-keygen -y "$AGE_KEY_FILE")"
[[ -n "$PUBLIC_KEY" ]] || die "No se pudo leer la public key desde ${AGE_KEY_FILE}."

echo "Public key: ${PUBLIC_KEY}"

sed -i.bak "s|age: .*|age: ${PUBLIC_KEY}|" "$SOPS_YAML"
rm -f "${SOPS_YAML}.bak"

echo "${SOPS_YAML} actualizado con la public key."
echo ""
echo "Siguiente paso: make add-user WEBAPI_USER=admin WEBAPI_ROLE=operator"
