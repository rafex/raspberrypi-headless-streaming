#!/usr/bin/env python3
"""Reporta salud de la Raspi a un endpoint HTTP publico, sin secretos."""

from __future__ import annotations

import argparse
import json
import os
import socket
import ssl
import subprocess
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path


STREAMING_ENV = Path("/etc/streaming.env")
PREVIEW_ENV = Path("/etc/preview.env")

SAFE_STREAM_CONFIG_KEYS = (
    "STREAM_PLATFORM", "STREAM_DUAL", "STREAM_WIDTH", "STREAM_HEIGHT",
    "STREAM_FPS", "STREAM_BITRATE", "STREAM_PRESET", "VIDEO_DEVICE",
    "AUDIO_DEVICE", "AUDIO_CHANNELS", "AUDIO_RATE", "STREAM_NO_AUDIO",
    "STREAM_AUDIO_BOOST", "OVERLAY_LOGO_ENABLED", "OVERLAY_LOGO_POS",
    "OVERLAY_BANNER_ENABLED", "OVERLAY_BANNER_POS", "OVERLAY_TEXT_ENABLED",
    "OVERLAY_TEXT_POS", "OVERLAY_TIMESTAMP", "OVERLAY_TIMESTAMP_POS",
)


def run(cmd: list[str], timeout: int = 5) -> str:
    try:
        return subprocess.check_output(cmd, stderr=subprocess.DEVNULL, text=True, timeout=timeout).strip()
    except Exception:
        return ""


def run_status(cmd: list[str], timeout: int = 5) -> str:
    try:
        result = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=timeout,
            check=False,
        )
    except Exception:
        return ""
    return result.stdout.strip()


def read_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    try:
        for raw in path.read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            values[key.strip()] = value.strip()
    except FileNotFoundError:
        pass
    return values


def ngrok_tunnels() -> dict[str, str]:
    raw = run(["curl", "-fsS", "http://127.0.0.1:4040/api/tunnels"], timeout=3)
    if not raw:
        return {}
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    tunnels: dict[str, str] = {}
    for tunnel in data.get("tunnels", []):
        name = str(tunnel.get("name", "")).strip()
        url = str(tunnel.get("public_url", ""))
        if name and url:
            tunnels[name] = url
        if url.startswith("https://") and "web" not in tunnels:
            tunnels["web"] = url
        if url.startswith("tcp://") and "ssh" not in tunnels:
            tunnels["ssh"] = url
    return tunnels


def ssh_command(ssh_url: str) -> str:
    if not ssh_url.startswith("tcp://"):
        return ""
    endpoint = ssh_url.removeprefix("tcp://").strip()
    host, sep, port = endpoint.rpartition(":")
    if not sep or not host or not port:
        return ""
    return f"ssh root@{host} -p {port}"


def service_state(service: str) -> dict[str, str | bool]:
    active = run_status(["systemctl", "is-active", service])
    enabled = run_status(["systemctl", "is-enabled", service])
    return {
        "active": active == "active",
        "state": active or "unknown",
        "enabled": enabled or "unknown",
    }


def safe_stream_config() -> dict[str, str]:
    cfg = read_env(STREAMING_ENV)
    return {key: cfg.get(key, "") for key in SAFE_STREAM_CONFIG_KEYS}


def payload() -> dict:
    ip = run(["sh", "-c", "ip -4 -o addr show scope global | awk '{print $2\":\"$4}'"])
    route = run(["ip", "route", "show", "default"])
    ssid = run(["iwgetid", "-r"])
    tunnels = ngrok_tunnels()
    web_url = tunnels.get("web", "")
    ssh_url = tunnels.get("ssh", "")
    return {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "hostname": socket.gethostname(),
        "ip": ip,
        "default_route": route,
        "wifi_ssid": ssid,
        "ngrok_url": web_url,
        "ngrok_ssh_url": ssh_url,
        "ngrok_ssh_command": ssh_command(ssh_url),
        "services": {
            "wifi_bootstrap": service_state("raspi-wifi-bootstrap.service"),
            "wifi-bootstrap": service_state("raspi-wifi-bootstrap.service"),
            "web_api": service_state("web-api.service"),
            "web-api": service_state("web-api.service"),
            "streaming": service_state("streaming.service"),
            "streaming_overlay": service_state("streaming-overlay.service"),
            "streaming-overlay": service_state("streaming-overlay.service"),
            "preview": service_state("preview.service"),
            "ngrok_web": service_state("ngrok-web.service"),
            "ngrok-web": service_state("ngrok-web.service"),
        },
        "devices": {
            "audio": run(["arecord", "-l"]),
            "video": run(["sh", "-c", "ls -1 /dev/video* 2>/dev/null || true"]),
        },
        "stream_config": safe_stream_config(),
        "preview_config": read_env(PREVIEW_ENV),
        "recent_stream_errors": run([
            "sh", "-c",
            "journalctl -u streaming.service -u streaming-overlay.service -u preview.service "
            "-n 30 --no-pager -o cat | grep -Ei 'error|fail|warn|xrun|disconnect|timeout' | tail -n 10 || true",
        ]),
    }


def post_json(
    url: str,
    body: dict,
    token: str = "",
    client_cert: str = "",
    client_key: str = "",
) -> None:
    data = json.dumps(body, ensure_ascii=False).encode("utf-8")
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    context = None
    if client_cert and client_key:
        context = ssl.create_default_context()
        context.load_cert_chain(certfile=client_cert, keyfile=client_key)
    with urllib.request.urlopen(req, timeout=10, context=context) as resp:
        resp.read()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--endpoint", default=os.environ.get("HEALTH_ENDPOINT", ""))
    parser.add_argument("--token", default=os.environ.get("HEALTH_TOKEN", ""))
    parser.add_argument("--interval", type=int, default=int(os.environ.get("HEALTH_INTERVAL_SECONDS", "60")))
    parser.add_argument("--client-cert", default=os.environ.get("BACKEND_CLIENT_CERT", ""))
    parser.add_argument("--client-key", default=os.environ.get("BACKEND_CLIENT_KEY", ""))
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()

    if not args.endpoint:
        print("[health-reporter] HEALTH_ENDPOINT no definido; saliendo.")
        return 0

    while True:
        body = payload()
        try:
            post_json(args.endpoint, body, args.token, args.client_cert, args.client_key)
            print(f"[health-reporter] posted {body['timestamp']} to {args.endpoint}", flush=True)
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            print(f"[health-reporter] post failed: {exc}", flush=True)
        if args.once:
            break
        time.sleep(max(args.interval, 10))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
