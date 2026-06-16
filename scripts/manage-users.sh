#!/usr/bin/env bash
# Administra los usuarios de web-api dentro de server/webapi/secrets.enc.yaml,
# cifrado con sops + age (ver .sops.yaml). Nunca edites ese archivo a mano.
#
# Uso:
#   ./manage-users.sh add <usuario> <viewer|operator>
#   ./manage-users.sh remove <usuario>
#   ./manage-users.sh list
#
# Requisitos: sops, python3 con el paquete pyyaml instalado
# (pip install pyyaml). El hasheo de contraseñas usa solo librería estándar
# (no necesita werkzeug).
#
# La contraseña se pide por stdin oculta y se hashea con PBKDF2-SHA256
# antes de tocar el disco; el texto plano no se escribe en ningún archivo.
# El hash queda en el mismo formato que usa werkzeug.security, así que
# check_password_hash() lo verifica en tiempo de ejecución sin cambios.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SECRETS_FILE="${REPO_DIR}/server/webapi/secrets.enc.yaml"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

usage() {
    grep '^#' "$0" | grep -v '#!/' | sed 's/^# \{0,1\}//'
    exit 0
}

command -v sops >/dev/null 2>&1 || die "sops no encontrado. Ver https://github.com/getsops/sops"
command -v python3 >/dev/null 2>&1 || die "python3 no encontrado."
python3 -c "import yaml" 2>/dev/null || die "Falta el paquete pyyaml. Instalar con: pip install pyyaml"

COMMAND="${1:-}"
[[ -n "$COMMAND" ]] || usage

# Directorio temporal en memoria si está disponible (evita swap a disco),
# si no, /tmp con permisos restringidos; se borra siempre al salir.
if [[ -d /dev/shm ]]; then
    TMPDIR_MU="$(mktemp -d /dev/shm/manage-users.XXXXXX)"
else
    TMPDIR_MU="$(mktemp -d)"
fi
chmod 700 "$TMPDIR_MU"
trap 'rm -rf "$TMPDIR_MU"' EXIT

PLAIN_FILE="${TMPDIR_MU}/secrets.yaml"

load_plain() {
    if [[ -f "$SECRETS_FILE" ]]; then
        sops -d "$SECRETS_FILE" > "$PLAIN_FILE"
    else
        echo "users: []" > "$PLAIN_FILE"
    fi
}

save_encrypted() {
    cp "$PLAIN_FILE" "$SECRETS_FILE"
    sops -e -i "$SECRETS_FILE"
}

hash_password() {
    local password="$1"
    python3 - "$password" <<'PYEOF'
import hashlib, secrets, string, sys

password = sys.argv[1]
alphabet = string.ascii_letters + string.digits
salt = "".join(secrets.choice(alphabet) for _ in range(16))
iterations = 600000
digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt.encode(), iterations).hex()
print(f"pbkdf2:sha256:{iterations}${salt}${digest}")
PYEOF
}

case "$COMMAND" in
    add)
        USERNAME="${2:-}"
        ROLE="${3:-}"
        [[ -n "$USERNAME" && -n "$ROLE" ]] || die "Uso: $0 add <usuario> <viewer|operator>"
        [[ "$ROLE" == "viewer" || "$ROLE" == "operator" ]] || die "Rol inválido: $ROLE. Usar: viewer | operator"

        read -rsp "Contraseña para ${USERNAME}: " PASSWORD
        echo ""
        read -rsp "Confirmar contraseña: " PASSWORD_CONFIRM
        echo ""
        [[ "$PASSWORD" == "$PASSWORD_CONFIRM" ]] || die "Las contraseñas no coinciden."
        [[ ${#PASSWORD} -ge 8 ]] || die "La contraseña debe tener al menos 8 caracteres."

        PASSWORD_HASH="$(hash_password "$PASSWORD")"
        unset PASSWORD PASSWORD_CONFIRM

        load_plain
        python3 - "$PLAIN_FILE" "$USERNAME" "$ROLE" "$PASSWORD_HASH" <<'PYEOF'
import sys
import yaml

path, username, role, password_hash = sys.argv[1:5]

with open(path) as fh:
    data = yaml.safe_load(fh) or {"users": []}

users = [u for u in data.get("users", []) if u.get("username") != username]
users.append({"username": username, "password_hash": password_hash, "role": role})
data["users"] = users

with open(path, "w") as fh:
    yaml.safe_dump(data, fh, default_flow_style=False)
PYEOF
        save_encrypted
        echo "Usuario '${USERNAME}' (${ROLE}) guardado en ${SECRETS_FILE}"
        ;;

    remove)
        USERNAME="${2:-}"
        [[ -n "$USERNAME" ]] || die "Uso: $0 remove <usuario>"

        load_plain
        python3 - "$PLAIN_FILE" "$USERNAME" <<'PYEOF'
import sys
import yaml

path, username = sys.argv[1:3]

with open(path) as fh:
    data = yaml.safe_load(fh) or {"users": []}

before = len(data.get("users", []))
data["users"] = [u for u in data.get("users", []) if u.get("username") != username]

if len(data["users"]) == before:
    print(f"AVISO: '{username}' no existía.", file=sys.stderr)

with open(path, "w") as fh:
    yaml.safe_dump(data, fh, default_flow_style=False)
PYEOF
        save_encrypted
        echo "Usuario '${USERNAME}' eliminado (si existía) de ${SECRETS_FILE}"
        ;;

    list)
        [[ -f "$SECRETS_FILE" ]] || die "No existe ${SECRETS_FILE} todavía."
        load_plain
        python3 - "$PLAIN_FILE" <<'PYEOF'
import sys
import yaml

with open(sys.argv[1]) as fh:
    data = yaml.safe_load(fh) or {"users": []}

for u in data.get("users", []):
    print(f"{u['username']}\t{u['role']}")
PYEOF
        ;;

    --help|-h)
        usage
        ;;

    *)
        die "Comando desconocido: $COMMAND. Usa --help para ver las opciones."
        ;;
esac
