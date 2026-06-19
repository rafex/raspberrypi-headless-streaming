"""
Lectura/escritura de /etc/preview.env — configuración del transporte de
vista previa local (RTMP vía mediamtx, o MPEG-TS por TCP/UDP), consumida
por systemd/preview.service → scripts/stream-overlay.sh.

Deliberadamente separado de config_store.py: el preview reutiliza la
cámara/audio/overlays de streaming.env pero su destino siempre debe ser
local, nunca la plataforma real (ver systemd/preview.service).
"""

import re

FIELDS = ("PREVIEW_TRANSPORT", "PREVIEW_PORT", "PREVIEW_CLIENT_IP", "PREVIEW_RTMP_NAME", "PREVIEW_OVERLAY")

VALID_TRANSPORTS = ("rtmp", "tcp", "udp")

RTMP_NAME_RE = re.compile(r"^[A-Za-z0-9_\-]+$")
IPV4_RE = re.compile(r"^(\d{1,3}\.){3}\d{1,3}$")


class ConfigValidationError(ValueError):
    pass


def read_config(env_path: str) -> dict:
    """Devuelve {PREVIEW_TRANSPORT: ..., ...} con strings tal cual están en el archivo."""
    values = {}
    try:
        with open(env_path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                key = key.strip()
                if key in FIELDS:
                    values[key] = value.strip()
    except FileNotFoundError:
        pass

    defaults = {
        "PREVIEW_TRANSPORT": "rtmp",
        "PREVIEW_PORT": "1935",
        "PREVIEW_CLIENT_IP": "",
        "PREVIEW_RTMP_NAME": "preview",
        "PREVIEW_OVERLAY": "true",
    }
    return {field: values.get(field, defaults[field]) for field in FIELDS}


def validate_config(data: dict) -> dict:
    """Valida el payload entrante de PUT /api/preview/config. Lanza ConfigValidationError si algo no sirve."""
    errors = []

    transport = str(data.get("transport", "rtmp")).strip()
    if transport not in VALID_TRANSPORTS:
        errors.append(f"transport debe ser uno de: {', '.join(VALID_TRANSPORTS)}")
        transport = "rtmp"

    try:
        port = int(data.get("port", 1935))
        if not (1 <= port <= 65535):
            errors.append("port debe estar entre 1 y 65535")
            port = 1935
    except (TypeError, ValueError):
        errors.append("port debe ser un entero")
        port = 1935

    client_ip = str(data.get("client_ip", "")).strip()
    if transport == "udp":
        if not client_ip:
            errors.append("client_ip es requerido para transporte udp")
        elif not IPV4_RE.match(client_ip):
            errors.append("client_ip debe ser una dirección IPv4 válida")
    elif client_ip and not IPV4_RE.match(client_ip):
        errors.append("client_ip debe ser una dirección IPv4 válida")

    rtmp_name = str(data.get("rtmp_name", "preview")).strip() or "preview"
    if not RTMP_NAME_RE.match(rtmp_name):
        errors.append("rtmp_name solo puede contener letras, números, guiones y guiones bajos")
        rtmp_name = "preview"

    overlay_raw = data.get("overlay", True)
    if isinstance(overlay_raw, str):
        overlay = overlay_raw.lower() in ("true", "1", "yes")
    else:
        overlay = bool(overlay_raw)

    if errors:
        raise ConfigValidationError("; ".join(errors))

    return {
        "PREVIEW_TRANSPORT": transport,
        "PREVIEW_PORT": str(port),
        "PREVIEW_CLIENT_IP": client_ip,
        "PREVIEW_RTMP_NAME": rtmp_name,
        "PREVIEW_OVERLAY": "true" if overlay else "false",
    }


def write_config(env_path: str, validated: dict) -> None:
    """Reescribe env_path solo con las claves conocidas (formato KEY=value, una por línea)."""
    lines = [f"{field}={validated[field]}" for field in FIELDS]
    with open(env_path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
