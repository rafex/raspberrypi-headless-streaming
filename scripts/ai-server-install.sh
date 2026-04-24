#!/usr/bin/env bash
# Instala y configura el servidor de análisis IA en Raspberry Pi 4B.
# Configura un virtualenv Python, instala dependencias y registra el servicio systemd.
#
# Uso:
#   sudo ./ai-server-install.sh [opciones]
#
# Opciones:
#   --provider deepseek|openrouter  Proveedor de IA (default: openrouter)
#   --model MODEL                   Modelo a usar (default del proveedor si no se indica)
#   --port PORT                     Puerto del servidor (default: 8080)
#   --help                          Mostrar esta ayuda
#
# Tras instalar:
#   1. Editar /etc/ai-server.env con las API keys
#   2. sudo systemctl start ai-server
#   3. sudo systemctl enable ai-server
#
# Verificar que funciona:
#   curl http://localhost:8080/health

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SERVER_DIR="${REPO_DIR}/server"
VENV_DIR="/opt/ai-server/venv"
INSTALL_DIR="/opt/ai-server"

PROVIDER="openrouter"
MODEL=""
PORT=8080

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
        --provider) PROVIDER="$2"; shift 2 ;;
        --model)    MODEL="$2"; shift 2 ;;
        --port)     PORT="$2"; shift 2 ;;
        --help)     usage ;;
        *) die "Opción desconocida: $1. Usa --help para ver las opciones." ;;
    esac
done

[[ "$EUID" -eq 0 ]] || die "Requiere root. Ejecutar con: sudo $0"
[[ "$PROVIDER" == "deepseek" || "$PROVIDER" == "openrouter" ]] \
    || die "Proveedor inválido: $PROVIDER. Usar: deepseek | openrouter"

echo "=== Instalación del servidor IA ==="
echo "  Proveedor : ${PROVIDER}"
echo "  Puerto    : ${PORT}"
echo "  Destino   : ${INSTALL_DIR}"
echo "==================================="
echo ""

# --- 1. Dependencias del sistema ---
echo "Instalando dependencias del sistema..."
apt-get update -qq
apt-get install -y -qq python3 python3-pip python3-venv

# --- 2. Directorio de instalación ---
mkdir -p "$INSTALL_DIR"
cp "${SERVER_DIR}/analyze-server.py" "${INSTALL_DIR}/analyze-server.py"
cp "${SERVER_DIR}/requirements.txt" "${INSTALL_DIR}/requirements.txt"

# --- 3. Virtualenv ---
echo "Creando entorno virtual Python..."
python3 -m venv "$VENV_DIR"
"${VENV_DIR}/bin/pip" install --upgrade pip -q
"${VENV_DIR}/bin/pip" install -r "${INSTALL_DIR}/requirements.txt" -q
echo "Dependencias instaladas."

# --- 4. Archivo de entorno ---
ENV_EXAMPLE="${SERVER_DIR}/server.env.example"
ENV_DST="/etc/ai-server.env"

if [[ ! -f "$ENV_DST" ]]; then
    cp "$ENV_EXAMPLE" "$ENV_DST"
    # Pre-configurar el proveedor elegido
    sed -i "s|^AI_PROVIDER=.*|AI_PROVIDER=${PROVIDER}|" "$ENV_DST"
    [[ -n "$MODEL" ]] && sed -i "s|^AI_MODEL=.*|AI_MODEL=${MODEL}|" "$ENV_DST"
    sed -i "s|^SERVER_PORT=.*|SERVER_PORT=${PORT}|" "$ENV_DST"
    chmod 600 "$ENV_DST"
    echo "Archivo de entorno creado: ${ENV_DST}"
    echo ""
    echo "IMPORTANTE: editar ${ENV_DST} y agregar la API key:"
    if [[ "$PROVIDER" == "deepseek" ]]; then
        echo "  DEEPSEEK_API_KEY=sk-..."
    else
        echo "  OPENROUTER_API_KEY=sk-or-..."
    fi
else
    echo "Archivo de entorno existente conservado: ${ENV_DST}"
fi

# --- 5. Servicio systemd ---
SERVICE_SRC="${REPO_DIR}/systemd/ai-server.service"
SERVICE_DST="/etc/systemd/system/ai-server.service"

sed \
    -e "s|__VENV_DIR__|${VENV_DIR}|g" \
    -e "s|__INSTALL_DIR__|${INSTALL_DIR}|g" \
    "$SERVICE_SRC" > "$SERVICE_DST"

systemctl daemon-reload
echo "Servicio instalado: ${SERVICE_DST}"

echo ""
echo "=== Instalación completada ==="
echo ""
echo "Próximos pasos:"
echo "  1. sudo nano /etc/ai-server.env   # agregar API key"
echo "  2. sudo systemctl start ai-server"
echo "  3. sudo systemctl enable ai-server"
echo "  4. curl http://localhost:${PORT}/health"
