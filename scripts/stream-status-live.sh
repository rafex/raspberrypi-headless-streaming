#!/usr/bin/env bash
# Panel de salud en terminal para streaming/preview.

set -euo pipefail

INTERVAL=2
LOG_LINES=28
ONCE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --interval)
            INTERVAL="${2:-2}"; shift 2 ;;
        --logs)
            LOG_LINES="${2:-28}"; shift 2 ;;
        --once)
            ONCE=true; shift ;;
        -h|--help)
            echo "Uso: $0 [--once] [--interval SEGUNDOS] [--logs LINEAS]"
            exit 0 ;;
        *)
            echo "ERROR: argumento no reconocido: $1" >&2
            exit 1 ;;
    esac
done

services=(streaming.service streaming-overlay.service preview.service)
support_services=(mediamtx.service web-api.service)
all_log_units=(streaming.service streaming-overlay.service preview.service mediamtx.service)
journal_args=()
for unit in "${all_log_units[@]}"; do
    journal_args+=(-u "$unit")
done

color() {
    local code="$1"
    if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
        tput setaf "$code" 2>/dev/null || true
    fi
}

reset_color() {
    if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
        tput sgr0 2>/dev/null || true
    fi
}

print_state() {
    local state="$1"
    case "$state" in
        active) color 2; printf "%s" "$state"; reset_color ;;
        failed) color 1; printf "%s" "$state"; reset_color ;;
        inactive|unknown|not-found) color 3; printf "%s" "$state"; reset_color ;;
        *) printf "%s" "$state" ;;
    esac
}

systemctl_value() {
    local unit="$1"
    local prop="$2"
    systemctl show "$unit" -p "$prop" --value 2>/dev/null || true
}

unit_exists() {
    local load_state
    load_state="$(systemctl_value "$1" LoadState)"
    [[ -n "$load_state" && "$load_state" != "not-found" ]]
}

print_unit_row() {
    local unit="$1"
    local active enabled result pid restarts since
    active="$(systemctl is-active "$unit" 2>/dev/null || true)"
    enabled="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
    result="$(systemctl_value "$unit" Result)"
    pid="$(systemctl_value "$unit" MainPID)"
    restarts="$(systemctl_value "$unit" NRestarts)"
    since="$(systemctl_value "$unit" ActiveEnterTimestamp)"
    [[ -n "$active" ]] || active="unknown"
    [[ -n "$enabled" ]] || enabled="unknown"
    [[ -n "$result" ]] || result="-"
    [[ -n "$pid" && "$pid" != "0" ]] || pid="-"
    [[ -n "$restarts" ]] || restarts="0"
    [[ -n "$since" ]] || since="-"
    printf "%-28s " "$unit"
    print_state "$active"
    printf " enabled=%-9s pid=%-7s restarts=%-3s result=%-10s since=%s\n" "$enabled" "$pid" "$restarts" "$result" "$since"
}

print_process_table() {
    local pattern='[f]fmpeg|[l]ibcamera-vid|[m]ediamtx|[r]picam-vid'
    if ! ps -eo pid,ppid,etime,%cpu,%mem,rss,args | grep -E "$pattern"; then
        echo "No hay procesos ffmpeg/libcamera/mediamtx activos."
    fi
}

print_health() {
    local active_streams=0
    local failed_units=0
    local ffmpeg_count=0
    local active_preview=false

    for unit in "${services[@]}"; do
        case "$(systemctl is-active "$unit" 2>/dev/null || true)" in
            active)
                active_streams=$((active_streams + 1))
                [[ "$unit" == "preview.service" ]] && active_preview=true
                ;;
            failed)
                failed_units=$((failed_units + 1))
                ;;
        esac
    done

    ffmpeg_count="$(pgrep -cx ffmpeg 2>/dev/null || true)"
    [[ -n "$ffmpeg_count" ]] || ffmpeg_count=0

    if (( failed_units > 0 )); then
        color 1; echo "HEALTH: PROBLEMA - hay servicios en failed."; reset_color
    elif (( active_streams == 0 )); then
        color 3; echo "HEALTH: IDLE - no hay streaming ni preview activo."; reset_color
    elif (( ffmpeg_count == 0 )); then
        color 1; echo "HEALTH: PROBLEMA - servicio activo pero no hay proceso ffmpeg."; reset_color
    else
        color 2; echo "HEALTH: OK - servicio activo con ffmpeg corriendo."; reset_color
    fi

    if [[ "$active_preview" == true ]]; then
        local mediamtx_state
        mediamtx_state="$(systemctl is-active mediamtx.service 2>/dev/null || true)"
        if [[ "$mediamtx_state" != "active" ]]; then
            color 3; echo "AVISO: preview activo, pero mediamtx.service no esta active."; reset_color
        fi
    fi
}

draw_once() {
    if [[ -t 1 && "$ONCE" == false ]]; then
        clear
    fi

    echo "=== Streaming / Preview monitor ==="
    date '+%Y-%m-%d %H:%M:%S %Z'
    hostname 2>/dev/null || true
    echo

    print_health
    echo

    echo "=== Systemd ==="
    for unit in "${services[@]}"; do
        print_unit_row "$unit"
    done
    echo
    echo "=== Servicios de soporte ==="
    for unit in "${support_services[@]}"; do
        if unit_exists "$unit"; then
            print_unit_row "$unit"
        fi
    done
    echo

    echo "=== Procesos de video ==="
    print_process_table
    echo

    echo "=== Red ==="
    ip -4 -o addr show scope global 2>/dev/null || true
    ip route show default 2>/dev/null || true
    echo

    echo "=== Ultimos logs ==="
    journalctl --no-pager -n "$LOG_LINES" "${journal_args[@]}" 2>/dev/null || true
}

while true; do
    draw_once
    [[ "$ONCE" == true ]] && break
    sleep "$INTERVAL"
done
