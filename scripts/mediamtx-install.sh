#!/usr/bin/env bash
# Descarga e instala mediamtx (servidor RTSP/RTMP/WebRTC) para Raspberry Pi.
# mediamtx es un servidor ligero que no requiere dependencias adicionales.
#
# Uso:
#   sudo ./mediamtx-install.sh [opciones]
#
# Opciones:
#   -v VERSION   Versión de mediamtx a instalar (default: latest)
#   --no-service No instalar como servicio systemd
#   --help       Mostrar esta ayuda
#
# Después de instalar:
#   sudo systemctl start mediamtx
#   sudo systemctl enable mediamtx
#
# URL de streams disponibles tras instalar:
#   RTSP  : rtsp://localhost:8554/<nombre>
#   RTMP  : rtmp://localhost:1935/<nombre>
#   WebRTC: http://localhost:8889/<nombre>
#   HLS   : http://localhost:8888/<nombre>/index.m3u8

set -euo pipefail

INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/mediamtx"
VERSION="latest"
INSTALL_SERVICE=true
ARCH=""

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
        -v)           VERSION="$2"; shift 2 ;;
        --no-service) INSTALL_SERVICE=false; shift ;;
        --help)       usage ;;
        *) die "Opción desconocida: $1. Usa --help para ver las opciones." ;;
    esac
done

[[ "$EUID" -eq 0 ]] || die "Este script requiere permisos de root. Ejecutar con: sudo $0"

command -v curl >/dev/null 2>&1 || die "curl no encontrado. Instalar con: sudo apt install curl"

# Detectar arquitectura para descargar el binario correcto
MACHINE=$(uname -m)
case "$MACHINE" in
    armv6l)  ARCH="linux_armv6" ;;
    armv7l)  ARCH="linux_armv7" ;;
    aarch64) ARCH="linux_arm64v8" ;;
    x86_64)  ARCH="linux_amd64" ;;
    *) die "Arquitectura no soportada: $MACHINE" ;;
esac

echo "=== Instalación de mediamtx ==="
echo "  Arquitectura : ${MACHINE} → ${ARCH}"
echo "  Versión      : ${VERSION}"
echo "  Destino      : ${INSTALL_DIR}/mediamtx"
echo "==============================="
echo ""

# Obtener la URL de descarga
if [[ "$VERSION" == "latest" ]]; then
    DOWNLOAD_URL=$(curl -s https://api.github.com/repos/bluenviron/mediamtx/releases/latest \
        | grep "browser_download_url" \
        | grep "${ARCH}" \
        | grep -v ".tar.gz.sha256" \
        | head -1 \
        | cut -d '"' -f 4)
else
    DOWNLOAD_URL="https://github.com/bluenviron/mediamtx/releases/download/v${VERSION}/mediamtx_v${VERSION}_${ARCH}.tar.gz"
fi

[[ -n "$DOWNLOAD_URL" ]] || die "No se pudo obtener la URL de descarga. Verificar conexión a internet."

echo "Descargando desde: ${DOWNLOAD_URL}"

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

curl -L "$DOWNLOAD_URL" -o "${TMPDIR}/mediamtx.tar.gz"

echo "Extrayendo..."
tar -xzf "${TMPDIR}/mediamtx.tar.gz" -C "$TMPDIR"

# Instalar binario
install -m 755 "${TMPDIR}/mediamtx" "${INSTALL_DIR}/mediamtx"
echo "Binario instalado: ${INSTALL_DIR}/mediamtx"

# Instalar configuración
mkdir -p "$CONFIG_DIR"
if [[ -f "${TMPDIR}/mediamtx.yml" && ! -f "${CONFIG_DIR}/mediamtx.yml" ]]; then
    cp "${TMPDIR}/mediamtx.yml" "${CONFIG_DIR}/mediamtx.yml"
    echo "Configuración instalada: ${CONFIG_DIR}/mediamtx.yml"
else
    echo "Configuración existente conservada: ${CONFIG_DIR}/mediamtx.yml"
fi

# Verificar versión instalada
echo ""
mediamtx --version 2>/dev/null || echo "mediamtx instalado correctamente."

# Instalar servicio systemd
if [[ "$INSTALL_SERVICE" == true ]]; then
    SERVICE_FILE="/etc/systemd/system/mediamtx.service"
    cat > "$SERVICE_FILE" <<'EOF'
[Unit]
Description=mediamtx — RTSP/RTMP/WebRTC media server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/mediamtx /etc/mediamtx/mediamtx.yml
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=mediamtx

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    echo "Servicio instalado: ${SERVICE_FILE}"
    echo ""
    echo "Iniciar mediamtx:"
    echo "  sudo systemctl start mediamtx"
    echo "  sudo systemctl enable mediamtx   # arranque automático"
fi

echo ""
echo "=== Instalación completada ==="
echo ""
echo "Puertos disponibles tras iniciar mediamtx:"
echo "  RTSP   : rtsp://$(hostname -I | awk '{print $1}'):8554/<nombre>"
echo "  RTMP   : rtmp://$(hostname -I | awk '{print $1}'):1935/<nombre>"
echo "  HLS    : http://$(hostname -I | awk '{print $1}'):8888/<nombre>/index.m3u8"
echo "  WebRTC : http://$(hostname -I | awk '{print $1}'):8889/<nombre>"
echo ""
echo "Publicar stream:"
echo "  scripts/stream-rtsp.sh -n cam"
echo ""
echo "Consumir stream desde otro dispositivo:"
echo "  vlc rtsp://$(hostname -I | awk '{print $1}'):8554/cam"
