#!/usr/bin/env bash
# Orquesta el arranque post-WiFi: espera estabilización, selecciona audio y
# arranca streaming solo si está habilitado explícitamente.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="/etc/raspi-streaming/boot-flow.env"
STREAMING_ENV="/etc/streaming.env"

AUTO_STREAM_ENABLED=false
AUTO_STREAM_SERVICE=streaming-overlay.service
AUTO_STREAM_DELAY_SECONDS=120
AUTO_STREAM_WAIT_SERVICES="web-api.service"
AUTO_STREAM_REQUIRE_DEFAULT_ROUTE=true
AUTO_STREAM_AUDIO_CHANNELS=1

log() { echo "[boot-stream] $*"; }

if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
else
    log "Config ${CONFIG_FILE} no existe; auto-stream deshabilitado."
fi

if [[ "$AUTO_STREAM_ENABLED" != "true" ]]; then
    log "AUTO_STREAM_ENABLED!=true; no se inicia transmision automatica."
    exit 0
fi

case "$AUTO_STREAM_SERVICE" in
    streaming.service|streaming-overlay.service) ;;
    *) log "Servicio no permitido: ${AUTO_STREAM_SERVICE}"; exit 1 ;;
esac

if [[ "$AUTO_STREAM_REQUIRE_DEFAULT_ROUTE" == "true" ]]; then
    log "Esperando ruta default..."
    for _ in {1..60}; do
        if ip route show default 2>/dev/null | grep -q '^default '; then
            ip route show default
            break
        fi
        sleep 2
    done
    if ! ip route show default 2>/dev/null | grep -q '^default '; then
        log "Sin ruta default; probablemente en modo AP. No se inicia streaming."
        exit 0
    fi
fi

for service in $AUTO_STREAM_WAIT_SERVICES; do
    log "Esperando servicio ${service}..."
    for _ in {1..60}; do
        if systemctl is-active --quiet "$service"; then
            break
        fi
        sleep 2
    done
    if ! systemctl is-active --quiet "$service"; then
        log "Servicio ${service} no esta active; continuo por timeout."
    fi
done

if [[ "$AUTO_STREAM_DELAY_SECONDS" =~ ^[0-9]+$ && "$AUTO_STREAM_DELAY_SECONDS" -gt 0 ]]; then
    log "Delay de estabilizacion: ${AUTO_STREAM_DELAY_SECONDS}s"
    sleep "$AUTO_STREAM_DELAY_SECONDS"
fi

log "Aplicando configuracion automatica de audio base..."
"${REPO_DIR}/scripts/stream-audio-autoconfig.py" \
    --env "$STREAMING_ENV" \
    --channels "$AUTO_STREAM_AUDIO_CHANNELS"

# El servicio de streaming corre como usuario sin privilegios (streamer), que
# no puede hacer modprobe. Si GPU_ENCODER=true, cargar el módulo acá (root)
# ANTES de arrancar el servicio, para que detect_hw_encoder() lo encuentre
# ya activo. Sin esto, tras un reboot el módulo queda sin cargar aunque
# modules-load.d lo liste (ver docs/gpu-encoder.md — blacklist de DietPi).
if grep -q '^GPU_ENCODER=true' "$STREAMING_ENV" 2>/dev/null; then
    if ! lsmod 2>/dev/null | grep -q bcm2835_codec; then
        log "GPU_ENCODER=true; cargando módulo bcm2835-codec..."
        modprobe bcm2835-codec 2>/dev/null \
            && log "Módulo bcm2835-codec cargado." \
            || log "AVISO: no se pudo cargar bcm2835-codec; se usará libx264."
    fi
fi

log "Limpiando servicios de streaming/preview antes de iniciar..."
systemctl stop streaming.service streaming-overlay.service preview.service 2>/dev/null || true
systemctl kill --kill-who=all --signal=KILL streaming.service streaming-overlay.service preview.service 2>/dev/null || true
systemctl reset-failed streaming.service streaming-overlay.service preview.service 2>/dev/null || true

RTMP_URL_VALUE="$(awk -F= '$1=="RTMP_URL"{print $2; exit}' "$STREAMING_ENV" 2>/dev/null || true)"
if [[ -z "$RTMP_URL_VALUE" ]]; then
    log "RTMP_URL vacio en ${STREAMING_ENV}; no se inicia streaming."
    exit 0
fi

log "Iniciando ${AUTO_STREAM_SERVICE}"
systemctl start "$AUTO_STREAM_SERVICE"
systemctl --no-pager --full status "$AUTO_STREAM_SERVICE" | sed -n '1,25p' || true
