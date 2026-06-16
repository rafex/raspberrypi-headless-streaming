"""
Lectura/escritura de /etc/streaming.env — el mismo archivo que ya leen
los servicios systemd "streaming" y "streaming-overlay"
(ver systemd/streaming.env.example). web-api no inventa variables
nuevas, reutiliza exactamente estas seis claves.
"""

import re

FIELDS = ("RTMP_URL", "STREAM_WIDTH", "STREAM_HEIGHT", "STREAM_FPS", "STREAM_BITRATE", "STREAM_PRESET")

VALID_PRESETS = ("ultrafast", "superfast", "veryfast", "faster", "fast")
RTMP_URL_RE = re.compile(r"^rtmps?://[^\s]+$")


class ConfigValidationError(ValueError):
    pass


def read_config(env_path: str) -> dict:
    """Devuelve {RTMP_URL: ..., STREAM_WIDTH: ..., ...} con strings tal cual están en el archivo."""
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

    return {field: values.get(field, "") for field in FIELDS}


def mask_rtmp_url(rtmp_url: str) -> str:
    """Para el rol viewer: nunca exponer la stream key, solo la plataforma."""
    if not rtmp_url:
        return ""
    if "youtube.com" in rtmp_url:
        platform = "YouTube"
    elif "facebook.com" in rtmp_url:
        platform = "Facebook"
    else:
        platform = "Personalizado"
    return f"{platform} (oculto)"


def validate_config(data: dict) -> dict:
    """Valida el payload entrante de PUT /api/config. Lanza ConfigValidationError si algo no sirve."""
    errors = []

    rtmp_url = str(data.get("rtmp_url", "")).strip()
    if not RTMP_URL_RE.match(rtmp_url):
        errors.append("rtmp_url debe ser una URL rtmp:// o rtmps:// válida")

    def _int_in_range(key, lo, hi):
        raw = data.get(key)
        try:
            value = int(raw)
        except (TypeError, ValueError):
            errors.append(f"{key} debe ser un entero")
            return None
        if not (lo <= value <= hi):
            errors.append(f"{key} debe estar entre {lo} y {hi}")
            return None
        return value

    width = _int_in_range("width", 320, 1920)
    height = _int_in_range("height", 240, 1080)
    fps = _int_in_range("fps", 1, 60)
    bitrate = _int_in_range("bitrate", 200_000, 25_000_000)

    preset = str(data.get("preset", "veryfast")).strip()
    if preset not in VALID_PRESETS:
        errors.append(f"preset debe ser uno de: {', '.join(VALID_PRESETS)}")

    if errors:
        raise ConfigValidationError("; ".join(errors))

    return {
        "RTMP_URL": rtmp_url,
        "STREAM_WIDTH": str(width),
        "STREAM_HEIGHT": str(height),
        "STREAM_FPS": str(fps),
        "STREAM_BITRATE": str(bitrate),
        "STREAM_PRESET": preset,
    }


def write_config(env_path: str, validated: dict) -> None:
    """Reescribe env_path solo con las claves conocidas (formato KEY=value, una por línea)."""
    lines = [f"{field}={validated[field]}" for field in FIELDS]
    with open(env_path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
