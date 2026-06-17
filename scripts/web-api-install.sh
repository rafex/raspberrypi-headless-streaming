#!/usr/bin/env bash
# Instala el servicio web-api: API REST + frontend ligero para controlar
# la transmisión desde el celular, sobre HTTPS con certificado autofirmado.
#
# Uso:
#   sudo ./web-api-install.sh [opciones]
#
# Opciones:
#   --port PORT   Puerto HTTPS (default: 8443)
#   --help        Mostrar esta ayuda
#
# Requisitos previos (no los instala este script, ver docs/web-api.md):
#   - sops y age (age-keygen) instalados
#   - uv instalado y visible para root (sudo). Si lo instalaste con tu
#     usuario normal, instalarlo también para root con:
#       curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh
#   - server/webapi/secrets.enc.yaml ya creado con al menos un usuario
#     (ejecutar primero: scripts/manage-users.sh add <usuario> <rol>)
#
# Tras instalar:
#   1. sudo systemctl start web-api
#   2. sudo systemctl enable web-api
#   3. Abrir https://<ip-de-la-pi>:<puerto> desde el celular
#      (aceptar el aviso de certificado autofirmado la primera vez)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WEBAPI_SRC="${REPO_DIR}/server/webapi"
INSTALL_DIR="/opt/web-api"
VENV_DIR="${INSTALL_DIR}/venv"
TLS_DIR="/etc/raspi-streaming/tls"
AGE_DIR="/etc/raspi-streaming/age"
AGE_KEY_FILE="${AGE_DIR}/key.txt"
ENV_DST="/etc/web-api.env"
SERVICE_USER="webapi"
PORT=8443

usage() {
    grep '^#' "$0" | grep -v '#!/' | sed 's/^# \{0,1\}//'
    exit 0
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port) PORT="$2"; shift 2 ;;
        --help) usage ;;
        *) die "Opción desconocida: $1. Usa --help para ver las opciones." ;;
    esac
done

[[ "$EUID" -eq 0 ]] || die "Requiere root. Ejecutar con: sudo $0"

echo "=== Instalación de web-api ==="
echo "  Puerto    : ${PORT}"
echo "  Destino   : ${INSTALL_DIR}"
echo "==============================="
echo ""

# --- 1. Verificar dependencias que NO se instalan automáticamente ---
command -v sops >/dev/null 2>&1 \
    || die "sops no encontrado. Instalar según https://github.com/getsops/sops antes de continuar."
command -v age-keygen >/dev/null 2>&1 \
    || die "age no encontrado. Instalar con: sudo apt install age"
command -v uv >/dev/null 2>&1 \
    || die "uv no encontrado para root. Instalar con: curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh"

[[ -f "${WEBAPI_SRC}/secrets.enc.yaml" ]] \
    || die "Falta ${WEBAPI_SRC}/secrets.enc.yaml. Crear el primer usuario con: scripts/manage-users.sh add <usuario> <viewer|operator>"

SYSTEMCTL_BIN="$(command -v systemctl)" || die "systemctl no encontrado."

# --- 2. Dependencias del sistema ---
# uv gestiona el venv y los paquetes Python; solo necesitamos el
# intérprete base del sistema y openssl para el certificado.
echo "Instalando dependencias del sistema..."
apt-get update -qq
apt-get install -y -qq python3 openssl

# --- 3. Usuario de servicio dedicado, sin privilegios ---
if ! id "$SERVICE_USER" >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
    echo "Usuario de sistema creado: ${SERVICE_USER}"
fi

# --- 4. Copiar código de la aplicación ---
mkdir -p "$INSTALL_DIR"
rm -rf "${INSTALL_DIR}/webapi"
cp -r "$WEBAPI_SRC" "${INSTALL_DIR}/webapi"
rm -f "${INSTALL_DIR}/webapi/requirements.txt"

# --- 5. Virtualenv (uv) ---
echo "Creando entorno virtual con uv..."
uv venv "$VENV_DIR" --python python3
uv pip install --python "${VENV_DIR}/bin/python" -r "${WEBAPI_SRC}/requirements.txt"
echo "Dependencias instaladas."

# --- 6. Certificado TLS autofirmado ---
mkdir -p "$TLS_DIR"
if [[ ! -f "${TLS_DIR}/cert.pem" || ! -f "${TLS_DIR}/key.pem" ]]; then
    HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
    HOST_NAME="$(hostname)"
    echo "Generando certificado autofirmado (CN=${HOST_NAME}, IP=${HOST_IP:-sin detectar})..."
    openssl req -x509 -newkey rsa:2048 -days 825 -nodes \
        -subj "/CN=${HOST_NAME}" \
        -addext "subjectAltName=DNS:${HOST_NAME},IP:${HOST_IP:-127.0.0.1}" \
        -keyout "${TLS_DIR}/key.pem" \
        -out "${TLS_DIR}/cert.pem" 2>/dev/null
    chmod 600 "${TLS_DIR}/key.pem"
    chmod 644 "${TLS_DIR}/cert.pem"
    echo "Certificado generado en ${TLS_DIR}"
else
    echo "Certificado TLS existente conservado: ${TLS_DIR}"
fi

# --- 7. Age key para descifrar secrets.enc.yaml ---
mkdir -p "$AGE_DIR"
if [[ ! -f "$AGE_KEY_FILE" ]]; then
    echo ""
    echo "AVISO: no existe ${AGE_KEY_FILE}."
    echo "Si ya generaste la age key en otro paso (recomendado, ver docs/web-api.md),"
    echo "copiala manualmente a esa ruta antes de iniciar el servicio."
    echo "Si no, generando una nueva ahora:"
    age-keygen -o "$AGE_KEY_FILE"
    echo ""
    echo "IMPORTANTE: agregar la public key impresa arriba a .sops.yaml y volver a"
    echo "cifrar/crear usuarios con: scripts/manage-users.sh add <usuario> <rol>"
fi
chmod 600 "$AGE_KEY_FILE"

chown -R "${SERVICE_USER}:${SERVICE_USER}" "$INSTALL_DIR" "$TLS_DIR" "$AGE_DIR"

# --- 8a. streaming.env — crearlo si no existe y asignar permisos a webapi ---
STREAMING_ENV="/etc/streaming.env"
if [[ ! -f "$STREAMING_ENV" ]]; then
    cat > "$STREAMING_ENV" <<'EOF'
RTMP_URL=
STREAM_WIDTH=1280
STREAM_HEIGHT=720
STREAM_FPS=30
STREAM_BITRATE=2500000
STREAM_PRESET=veryfast
OVERLAY_TEXT=
OVERLAY_TEXT_POS=bl
OVERLAY_TIMESTAMP=false
OVERLAY_LOGO_FILE=
OVERLAY_LOGO_POS=br
OVERLAY_LOGO_PAD=20
EOF
    echo "Archivo de streaming creado: ${STREAMING_ENV}"
fi
chown "${SERVICE_USER}:${SERVICE_USER}" "$STREAMING_ENV"
chmod 640 "$STREAMING_ENV"

# --- 8b. Directorio de logos subidos desde la web ---
LOGO_DIR="/var/lib/raspi-streaming/assets/logos"
mkdir -p "$LOGO_DIR"
chown "${SERVICE_USER}:${SERVICE_USER}" "$LOGO_DIR"
chmod 755 "$LOGO_DIR"   # webapi escribe; streamer y otros usuarios pueden leer
echo "Directorio de logos: ${LOGO_DIR}"

# --- 8c. Archivo de entorno ---
if [[ ! -f "$ENV_DST" ]]; then
    SECRET_KEY="$(openssl rand -hex 32)"
    cat > "$ENV_DST" <<EOF
SECRET_KEY=${SECRET_KEY}
PORT=${PORT}
TLS_CERT=${TLS_DIR}/cert.pem
TLS_KEY=${TLS_DIR}/key.pem
SECRETS_PATH=${INSTALL_DIR}/webapi/secrets.enc.yaml
STREAMING_ENV_PATH=/etc/streaming.env
LOGO_UPLOAD_DIR=/var/lib/raspi-streaming/assets/logos
SOPS_AGE_KEY_FILE=${AGE_KEY_FILE}
EOF
    chmod 600 "$ENV_DST"
    echo "Archivo de entorno creado: ${ENV_DST}"
else
    echo "Archivo de entorno existente conservado: ${ENV_DST}"
fi

# --- 9. sudoers: permitir solo systemctl start/stop de los dos servicios ---
SUDOERS_DST="/etc/sudoers.d/web-api"
cat > "${SUDOERS_DST}.tmp" <<EOF
${SERVICE_USER} ALL=(root) NOPASSWD: ${SYSTEMCTL_BIN} start streaming.service
${SERVICE_USER} ALL=(root) NOPASSWD: ${SYSTEMCTL_BIN} stop streaming.service
${SERVICE_USER} ALL=(root) NOPASSWD: ${SYSTEMCTL_BIN} start streaming-overlay.service
${SERVICE_USER} ALL=(root) NOPASSWD: ${SYSTEMCTL_BIN} stop streaming-overlay.service
EOF
visudo -c -f "${SUDOERS_DST}.tmp" || die "El sudoers generado no es válido, abortando."
mv "${SUDOERS_DST}.tmp" "$SUDOERS_DST"
chmod 440 "$SUDOERS_DST"
echo "Permisos sudo acotados instalados: ${SUDOERS_DST}"

# --- 10. Servicio systemd ---
SERVICE_SRC="${REPO_DIR}/systemd/web-api.service"
SERVICE_DST="/etc/systemd/system/web-api.service"

sed "s|__VENV_DIR__|${VENV_DIR}|g" "$SERVICE_SRC" > "$SERVICE_DST"

systemctl daemon-reload
echo "Servicio instalado: ${SERVICE_DST}"

echo ""
echo "=== Instalación completada ==="
echo ""
echo "Próximos pasos:"
echo "  1. sudo systemctl start web-api"
echo "  2. sudo systemctl enable web-api"
echo "  3. https://<ip-de-la-pi>:${PORT}  (aceptar el aviso de certificado autofirmado)"
