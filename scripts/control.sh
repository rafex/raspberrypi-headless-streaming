#!/usr/bin/env bash
# Control del servicio de streaming systemd.
# Permite iniciar, detener, reiniciar y monitorear el stream desde terminal.
#
# Uso:
#   ./control.sh <comando> [servicio]
#
# Comandos:
#   start      Iniciar el servicio de streaming
#   stop       Detener el servicio de streaming
#   restart    Reiniciar el servicio de streaming
#   status     Mostrar estado del servicio y últimas líneas de log
#   logs       Ver logs en tiempo real (journald)
#   enable     Habilitar inicio automático en boot
#   disable    Deshabilitar inicio automático en boot
#   install    Instalar el servicio desde el repositorio
#   uninstall  Eliminar el servicio del sistema
#
# Servicios disponibles:
#   streaming          Stream básico sin overlays (default)
#   streaming-overlay  Stream con overlays
#   mediamtx           Servidor RTSP/RTMP/WebRTC local
#   motion-trigger     Stream activado por detección de movimiento
#
# Ejemplos:
#   ./control.sh start
#   ./control.sh start streaming-overlay
#   ./control.sh status
#   ./control.sh logs
#   ./control.sh install
#   ./control.sh enable

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SYSTEMD_DIR="${REPO_DIR}/systemd"
SYSTEMD_SYSTEM_DIR="/etc/systemd/system"
DEFAULT_SERVICE="streaming"

usage() {
    grep '^#' "$0" | grep -v '#!/' | sed 's/^# \{0,1\}//'
    exit 0
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

require_root() {
    [[ "$EUID" -eq 0 ]] || die "Este comando requiere permisos de root. Usar: sudo $0 $*"
}

# --- Argumentos ---
COMMAND="${1:-}"
SERVICE="${2:-$DEFAULT_SERVICE}"

[[ -n "$COMMAND" ]] || { usage; }

SERVICE_FILE="${SERVICE}.service"

# Verificar que el servicio es válido
valid_services=("streaming" "streaming-overlay" "mediamtx" "motion-trigger")
is_valid=false
for s in "${valid_services[@]}"; do
    [[ "$SERVICE" == "$s" ]] && is_valid=true && break
done
[[ "$is_valid" == true ]] || die "Servicio desconocido: '$SERVICE'. Usar: streaming | streaming-overlay"

case "$COMMAND" in

    start)
        echo "Iniciando ${SERVICE}..."
        sudo systemctl start "$SERVICE_FILE"
        sleep 2
        systemctl is-active --quiet "$SERVICE_FILE" \
            && echo "Servicio iniciado correctamente." \
            || echo "AVISO: el servicio no está activo. Revisar: $0 status ${SERVICE}"
        ;;

    stop)
        echo "Deteniendo ${SERVICE}..."
        sudo systemctl stop "$SERVICE_FILE"
        echo "Servicio detenido."
        ;;

    restart)
        echo "Reiniciando ${SERVICE}..."
        sudo systemctl restart "$SERVICE_FILE"
        sleep 2
        systemctl is-active --quiet "$SERVICE_FILE" \
            && echo "Servicio reiniciado correctamente." \
            || echo "AVISO: el servicio no está activo. Revisar: $0 status ${SERVICE}"
        ;;

    status)
        echo "=== Estado: ${SERVICE} ==="
        systemctl status "$SERVICE_FILE" --no-pager -l || true
        echo ""
        echo "=== Últimas 20 líneas de log ==="
        journalctl -u "$SERVICE_FILE" -n 20 --no-pager || true
        ;;

    logs)
        echo "Mostrando logs en tiempo real de ${SERVICE} (Ctrl+C para salir)..."
        journalctl -u "$SERVICE_FILE" -f
        ;;

    enable)
        echo "Habilitando inicio automático de ${SERVICE} en boot..."
        sudo systemctl enable "$SERVICE_FILE"
        echo "Habilitado. El servicio iniciará automáticamente con el sistema."
        ;;

    disable)
        echo "Deshabilitando inicio automático de ${SERVICE}..."
        sudo systemctl disable "$SERVICE_FILE"
        echo "Deshabilitado."
        ;;

    install)
        require_root install "$SERVICE"

        SERVICE_SRC="${SYSTEMD_DIR}/${SERVICE_FILE}"
        SERVICE_DST="${SYSTEMD_SYSTEM_DIR}/${SERVICE_FILE}"

        [[ -f "$SERVICE_SRC" ]] || die "Archivo de servicio no encontrado: ${SERVICE_SRC}"

        echo "Instalando ${SERVICE_FILE}..."

        # Ajustar la ruta WorkingDirectory al directorio real del repositorio
        sed "s|WorkingDirectory=.*|WorkingDirectory=${REPO_DIR}|g" \
            "$SERVICE_SRC" > "$SERVICE_DST"

        # Crear archivo de entorno si no existe
        ENV_EXAMPLE="${SYSTEMD_DIR}/streaming.env.example"
        ENV_DST="/etc/streaming.env"
        if [[ ! -f "$ENV_DST" && -f "$ENV_EXAMPLE" ]]; then
            cp "$ENV_EXAMPLE" "$ENV_DST"
            chmod 600 "$ENV_DST"
            echo "Archivo de entorno creado: ${ENV_DST}"
            echo "IMPORTANTE: editar ${ENV_DST} con la URL RTMP y stream key correctos."
        fi

        systemctl daemon-reload
        echo "Servicio instalado: ${SERVICE_DST}"
        echo ""
        echo "Próximos pasos:"
        echo "  1. Editar /etc/streaming.env con tu RTMP_URL"
        echo "  2. Ejecutar: $0 start ${SERVICE}"
        echo "  3. Para inicio automático: $0 enable ${SERVICE}"
        ;;

    uninstall)
        require_root uninstall "$SERVICE"

        SERVICE_DST="${SYSTEMD_SYSTEM_DIR}/${SERVICE_FILE}"

        systemctl is-active --quiet "$SERVICE_FILE" \
            && systemctl stop "$SERVICE_FILE" \
            || true

        systemctl is-enabled --quiet "$SERVICE_FILE" \
            && systemctl disable "$SERVICE_FILE" \
            || true

        [[ -f "$SERVICE_DST" ]] && rm "$SERVICE_DST"

        systemctl daemon-reload
        echo "Servicio ${SERVICE} eliminado del sistema."
        ;;

    *)
        die "Comando desconocido: '$COMMAND'. Usa --help para ver los comandos disponibles."
        ;;
esac
