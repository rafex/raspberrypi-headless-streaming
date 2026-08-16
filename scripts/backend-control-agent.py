#!/usr/bin/env python3
"""Consume desired-state del backend publico y aplica cambios locales."""

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
from pathlib import Path


DEFAULT_ENV = Path("/etc/streaming.env")
DEFAULT_STATE = Path("/var/lib/raspi-streaming/backend-control-agent.json")

ALLOWED_CONFIG_KEYS = {
    "RTMP_URL", "STREAM_PLATFORM", "STREAM_KEY", "STREAM_DUAL",
    "STREAM_KEY_META", "RTMP_URL_SECONDARY", "STREAM_WIDTH", "STREAM_HEIGHT",
    "STREAM_FPS", "STREAM_BITRATE", "STREAM_PRESET", "VIDEO_DEVICE",
    "AUDIO_DEVICE", "AUDIO_CHANNELS", "AUDIO_RATE", "STREAM_NO_AUDIO",
    "STREAM_AUDIO_BOOST", "OVERLAY_TEXT_ENABLED", "OVERLAY_TEXT", "OVERLAY_TEXT_POS",
    "OVERLAY_TIMESTAMP", "OVERLAY_TIMESTAMP_POS",
    "OVERLAY_LOGO_ENABLED", "OVERLAY_LOGO_FILE", "OVERLAY_LOGO_POS",
    "OVERLAY_LOGO_PAD", "OVERLAY_LOGO_W", "OVERLAY_BANNER_ENABLED",
    "OVERLAY_BANNER", "OVERLAY_BANNER_POS",
}

COMMANDS = {
    "none": [],
    "apply_config": [],
    "start_streaming": ["systemctl", "start", "streaming.service"],
    "start_streaming_overlay": ["systemctl", "start", "streaming-overlay.service"],
    "stop_streaming": ["systemctl", "stop", "streaming.service", "streaming-overlay.service"],
    "stop_all": ["systemctl", "stop", "streaming.service", "streaming-overlay.service", "preview.service"],
    "start_preview": ["systemctl", "start", "preview.service"],
    "stop_preview": ["systemctl", "stop", "preview.service"],
    "reboot": ["systemctl", "reboot"],
}


def log(message: str) -> None:
    print(f"[backend-agent] {message}", flush=True)


def ssl_context(client_cert: str, client_key: str) -> ssl.SSLContext | None:
    if not (client_cert and client_key):
        return None
    context = ssl.create_default_context()
    context.load_cert_chain(certfile=client_cert, keyfile=client_key)
    return context


def request_json(
    method: str,
    url: str,
    token: str,
    context: ssl.SSLContext | None,
    body: dict | None = None,
) -> dict:
    data = None if body is None else json.dumps(body, ensure_ascii=False).encode("utf-8")
    headers = {"Authorization": f"Bearer {token}"}
    if data is not None:
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=15, context=context) as resp:
        raw = resp.read().decode("utf-8")
    return json.loads(raw) if raw else {}


def read_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip()
    return values


def write_env(path: Path, values: dict[str, str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = [f"{key}={value}" for key, value in values.items()]
    tmp = path.with_name(f".{path.name}.tmp")
    tmp.write_text("\n".join(lines) + "\n", encoding="utf-8")
    if path.exists():
        st = path.stat()
        os.chown(tmp, st.st_uid, st.st_gid)
        os.chmod(tmp, st.st_mode & 0o777)
    else:
        os.chmod(tmp, 0o640)
    os.replace(tmp, path)


def apply_config(env_path: Path, config: dict[str, str]) -> list[str]:
    filtered = {key: str(value) for key, value in config.items() if key in ALLOWED_CONFIG_KEYS}
    if not filtered:
        return []
    current = read_env(env_path)
    changed: list[str] = []
    for key, value in filtered.items():
        if current.get(key) != value:
            current[key] = value
            changed.append(key)
    if changed:
        write_env(env_path, current)
    return changed


def run_command(action: str) -> None:
    cmd = COMMANDS.get(action)
    if cmd is None:
        raise ValueError(f"accion no permitida: {action}")
    if not cmd:
        return
    subprocess.check_call(cmd)


def read_last_sequence(path: Path) -> int:
    try:
        return int(json.loads(path.read_text(encoding="utf-8")).get("last_sequence", 0))
    except Exception:
        return 0


def write_last_sequence(path: Path, sequence: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"last_sequence": sequence}) + "\n", encoding="utf-8")


def handle_once(args: argparse.Namespace, context: ssl.SSLContext | None) -> None:
    desired_url = f"{args.base_url.rstrip('/')}/v1/raspi/{args.device_id}/desired-state"
    ack_url = f"{args.base_url.rstrip('/')}/v1/raspi/{args.device_id}/ack"
    desired = request_json("GET", desired_url, args.token, context)
    sequence = int(desired.get("sequence", 0))
    last_sequence = read_last_sequence(args.state_file)
    if sequence <= last_sequence:
        return

    status = "applied"
    message = ""
    try:
        changed = apply_config(args.env, desired.get("config") or {})
        command = desired.get("command") or {}
        action = command.get("action", "none")
        run_command(action)
        message = f"config={','.join(changed) or 'sin-cambios'} action={action}"
        write_last_sequence(args.state_file, sequence)
        log(f"sequence {sequence} aplicado: {message}")
    except Exception as exc:
        status = "failed"
        message = str(exc)
        log(f"sequence {sequence} fallo: {message}")

    request_json(
        "POST",
        ack_url,
        args.token,
        context,
        {"sequence": sequence, "status": status, "message": message},
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default=os.environ.get("BACKEND_BASE_URL", "https://streaming.rafex.io"))
    parser.add_argument("--device-id", default=os.environ.get("BACKEND_DEVICE_ID", socket.gethostname()))
    parser.add_argument("--token", default=os.environ.get("BACKEND_TOKEN", os.environ.get("HEALTH_TOKEN", "")))
    parser.add_argument("--client-cert", default=os.environ.get("BACKEND_CLIENT_CERT", ""))
    parser.add_argument("--client-key", default=os.environ.get("BACKEND_CLIENT_KEY", ""))
    parser.add_argument("--env", type=Path, default=Path(os.environ.get("STREAMING_ENV", str(DEFAULT_ENV))))
    parser.add_argument("--state-file", type=Path, default=Path(os.environ.get("BACKEND_AGENT_STATE", str(DEFAULT_STATE))))
    parser.add_argument("--interval", type=int, default=int(os.environ.get("BACKEND_AGENT_INTERVAL_SECONDS", "30")))
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()

    if not args.token:
        log("BACKEND_TOKEN/HEALTH_TOKEN no definido; saliendo.")
        return 0

    context = ssl_context(args.client_cert, args.client_key)
    while True:
        try:
            handle_once(args, context)
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            log(f"consulta fallo: {exc}")
        if args.once:
            break
        time.sleep(max(args.interval, 10))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
