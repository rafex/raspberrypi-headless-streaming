#!/usr/bin/env bash
# Envía un evento o frame al endpoint HTTP del servidor de IA (Pi 4B).
# Soporta envío de eventos JSON y frames JPEG codificados en base64.
#
# Uso:
#   ./send-event.sh [opciones]
#
# Modos:
#   --event TYPE     Enviar evento de texto (motion_start, motion_stop, etc.)
#   --frame FILE     Enviar frame JPEG como base64 para análisis visual
#   --frame-event FILE TYPE  Enviar frame + tipo de evento combinados
#
# Opciones:
#   --host H         Host del servidor IA (default: localhost o variable AI_HOST)
#   --port P         Puerto del servidor IA (default: 8080 o variable AI_PORT)
#   --path PATH      Ruta del endpoint (default: /analyze)
#   --context TEXT   Contexto adicional enviado con el frame (ej: "movimiento detectado")
#   --source TEXT    Identificador de la fuente (default: hostname de la Pi)
#   --timeout N      Timeout HTTP en segundos (default: 10)
#   --verbose        Mostrar respuesta completa del servidor
#   --help           Mostrar esta ayuda
#
# Variables de entorno:
#   AI_HOST          Host del servidor de IA (Pi 4B)
#   AI_PORT          Puerto del servidor de IA
#   AI_PATH          Ruta del endpoint
#
# Ejemplos:
#   # Notificar evento de movimiento
#   ./send-event.sh --event motion_start --host 192.168.1.100
#
#   # Enviar frame para análisis visual
#   ./send-event.sh --frame /tmp/frames/frame_20240101_120000.jpg --host 192.168.1.100
#
#   # Enviar frame con contexto
#   ./send-event.sh --frame /tmp/frames/latest.jpg \
#       --context "movimiento en cámara 1" \
#       --host 192.168.1.100
#
#   # Usado desde frame-extract.sh via --on-frame
#   ./send-event.sh --frame "$1" --context "extracción periódica"
#
# Formato del payload JSON enviado al servidor:
#   {
#     "event": "frame_analysis",
#     "source": "raspi-3b",
#     "timestamp": "2024-01-01T12:00:00+00:00",
#     "context": "movimiento detectado",
#     "frame": "<base64 del JPEG>"
#   }
#
# Respuesta esperada del servidor:
#   {
#     "analysis": "Se detecta una persona entrando por la puerta izquierda.",
#     "confidence": 0.92,
#     "tags": ["person", "motion", "indoor"]
#   }

set -euo pipefail

AI_HOST="${AI_HOST:-localhost}"
AI_PORT="${AI_PORT:-8080}"
AI_PATH="${AI_PATH:-/analyze}"
SOURCE=$(hostname 2>/dev/null || echo "raspi")
CONTEXT=""
TIMEOUT=10
VERBOSE=false

EVENT_TYPE=""
FRAME_FILE=""

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
        --event)       EVENT_TYPE="$2"; shift 2 ;;
        --frame)       FRAME_FILE="$2"; shift 2 ;;
        --frame-event) FRAME_FILE="$2"; EVENT_TYPE="$3"; shift 3 ;;
        --host)        AI_HOST="$2"; shift 2 ;;
        --port)        AI_PORT="$2"; shift 2 ;;
        --path)        AI_PATH="$2"; shift 2 ;;
        --context)     CONTEXT="$2"; shift 2 ;;
        --source)      SOURCE="$2"; shift 2 ;;
        --timeout)     TIMEOUT="$2"; shift 2 ;;
        --verbose)     VERBOSE=true; shift ;;
        --help)        usage ;;
        *) die "Opción desconocida: $1. Usa --help para ver las opciones." ;;
    esac
done

command -v curl >/dev/null 2>&1 || die "curl no encontrado. Instalar con: sudo apt install curl"

[[ -n "$EVENT_TYPE" || -n "$FRAME_FILE" ]] \
    || die "Especificar --event o --frame. Ver --help para más opciones."

[[ -z "$FRAME_FILE" || -f "$FRAME_FILE" ]] \
    || die "Frame no encontrado: $FRAME_FILE"

ENDPOINT="http://${AI_HOST}:${AI_PORT}${AI_PATH}"
TIMESTAMP=$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')

# --- Construir payload JSON ---
build_payload() {
    local event="${EVENT_TYPE:-frame_analysis}"
    local frame_b64=""

    if [[ -n "$FRAME_FILE" ]]; then
        command -v base64 >/dev/null 2>&1 || die "base64 no encontrado."
        frame_b64=$(base64 -w 0 "$FRAME_FILE" 2>/dev/null || base64 "$FRAME_FILE")
    fi

    # Escapar context para JSON
    local safe_context
    safe_context=$(echo "$CONTEXT" | sed 's/\\/\\\\/g; s/"/\\"/g')

    if [[ -n "$frame_b64" ]]; then
        cat <<EOF
{
  "event": "${event}",
  "source": "${SOURCE}",
  "timestamp": "${TIMESTAMP}",
  "context": "${safe_context}",
  "frame": "${frame_b64}"
}
EOF
    else
        cat <<EOF
{
  "event": "${event}",
  "source": "${SOURCE}",
  "timestamp": "${TIMESTAMP}",
  "context": "${safe_context}"
}
EOF
    fi
}

# --- Enviar ---
PAYLOAD=$(build_payload)

if [[ "$VERBOSE" == true ]]; then
    echo "→ POST ${ENDPOINT}"
    [[ -n "$FRAME_FILE" ]] && echo "  Frame: ${FRAME_FILE} ($(du -sh "$FRAME_FILE" | cut -f1))"
    echo "  Evento: ${EVENT_TYPE:-frame_analysis}"
    [[ -n "$CONTEXT" ]] && echo "  Contexto: ${CONTEXT}"
    echo ""
fi

RESPONSE=$(curl \
    --silent \
    --max-time "$TIMEOUT" \
    --connect-timeout 5 \
    --retry 2 \
    --retry-delay 1 \
    -X POST "$ENDPOINT" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    2>&1) || {
    echo "ERROR: no se pudo conectar con el servidor IA en ${ENDPOINT}" >&2
    echo "       Verificar que el servidor está corriendo en Pi 4B." >&2
    exit 1
}

if [[ "$VERBOSE" == true ]]; then
    echo "← Respuesta:"
    echo "$RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$RESPONSE"
else
    # Extraer solo el campo "analysis" de la respuesta si existe
    ANALYSIS=$(echo "$RESPONSE" \
        | grep -o '"analysis"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | sed 's/"analysis"[[:space:]]*:[[:space:]]*"\(.*\)"/\1/' \
        || echo "")

    if [[ -n "$ANALYSIS" ]]; then
        echo "[IA] ${ANALYSIS}"
    else
        echo "[IA] ${RESPONSE}"
    fi
fi
