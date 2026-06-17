"""
Lectura/escritura de /etc/streaming.env — el mismo archivo que ya leen
los servicios systemd "streaming" y "streaming-overlay"
(ver systemd/streaming.env.example). web-api no inventa variables
nuevas, reutiliza exactamente estas seis claves.
"""

import re

FIELDS = (
    "RTMP_URL", "STREAM_WIDTH", "STREAM_HEIGHT", "STREAM_FPS", "STREAM_BITRATE", "STREAM_PRESET",
    "VIDEO_DEVICE", "AUDIO_DEVICE", "AUDIO_CHANNELS", "STREAM_NO_AUDIO",
    "OVERLAY_TEXT", "OVERLAY_TEXT_POS", "OVERLAY_TIMESTAMP",
    "OVERLAY_LOGO_FILE", "OVERLAY_LOGO_POS", "OVERLAY_LOGO_PAD",
)

VALID_PRESETS = ("ultrafast", "superfast", "veryfast", "faster", "fast")
VALID_TEXT_POS = ("tl", "tr", "bl", "br", "center")
VALID_LOGO_POS = ("tl", "tr", "bl", "br")
RTMP_URL_RE = re.compile(r"^rtmps?://[^\s]+$")
LOGO_PATH_RE = re.compile(r"^[^\x00\n\r;|&`$<>]+$")


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

    overlay_text = str(data.get("overlay_text", "")).strip().replace("\n", " ").replace("\r", "")[:200]

    overlay_text_pos = str(data.get("overlay_text_pos", "bl")).strip()
    if overlay_text_pos not in VALID_TEXT_POS:
        errors.append(f"overlay_text_pos debe ser uno de: {', '.join(VALID_TEXT_POS)}")

    overlay_timestamp_raw = data.get("overlay_timestamp", False)
    if isinstance(overlay_timestamp_raw, str):
        overlay_timestamp = overlay_timestamp_raw.lower() in ("true", "1", "yes")
    else:
        overlay_timestamp = bool(overlay_timestamp_raw)

    overlay_logo_file = str(data.get("overlay_logo_file", "")).strip()
    if overlay_logo_file and not LOGO_PATH_RE.match(overlay_logo_file):
        errors.append("overlay_logo_file contiene caracteres no permitidos")

    overlay_logo_pos = str(data.get("overlay_logo_pos", "br")).strip()
    if overlay_logo_pos not in VALID_LOGO_POS:
        errors.append(f"overlay_logo_pos debe ser uno de: {', '.join(VALID_LOGO_POS)}")

    overlay_logo_pad = data.get("overlay_logo_pad", 20)
    try:
        overlay_logo_pad = int(overlay_logo_pad)
        if not (0 <= overlay_logo_pad <= 200):
            errors.append("overlay_logo_pad debe estar entre 0 y 200")
    except (TypeError, ValueError):
        errors.append("overlay_logo_pad debe ser un entero")
        overlay_logo_pad = 20

    video_device = str(data.get("video_device", "")).strip()
    if video_device and not re.match(r"^/dev/video\d+$", video_device):
        errors.append("video_device debe ser /dev/videoN")

    audio_device = str(data.get("audio_device", "")).strip()
    if audio_device and not re.match(r"^(plughw|hw):\d+,\d+$", audio_device):
        errors.append("audio_device debe ser plughw:N,M o hw:N,M")

    audio_channels_raw = data.get("audio_channels", 1)
    try:
        audio_channels = int(audio_channels_raw)
        if audio_channels not in (1, 2):
            errors.append("audio_channels debe ser 1 (mono) o 2 (stereo)")
    except (TypeError, ValueError):
        errors.append("audio_channels debe ser 1 o 2")
        audio_channels = 1

    no_audio_raw = data.get("stream_no_audio", False)
    if isinstance(no_audio_raw, str):
        no_audio = no_audio_raw.lower() in ("true", "1", "yes")
    else:
        no_audio = bool(no_audio_raw)

    if errors:
        raise ConfigValidationError("; ".join(errors))

    return {
        "RTMP_URL": rtmp_url,
        "STREAM_WIDTH": str(width),
        "STREAM_HEIGHT": str(height),
        "STREAM_FPS": str(fps),
        "STREAM_BITRATE": str(bitrate),
        "STREAM_PRESET": preset,
        "VIDEO_DEVICE": video_device,
        "AUDIO_DEVICE": audio_device,
        "AUDIO_CHANNELS": str(audio_channels),
        "STREAM_NO_AUDIO": "true" if no_audio else "false",
        "OVERLAY_TEXT": overlay_text,
        "OVERLAY_TEXT_POS": overlay_text_pos,
        "OVERLAY_TIMESTAMP": "true" if overlay_timestamp else "false",
        "OVERLAY_LOGO_FILE": overlay_logo_file,
        "OVERLAY_LOGO_POS": overlay_logo_pos,
        "OVERLAY_LOGO_PAD": str(overlay_logo_pad),
    }


def write_config(env_path: str, validated: dict) -> None:
    """Reescribe env_path solo con las claves conocidas (formato KEY=value, una por línea)."""
    lines = [f"{field}={validated[field]}" for field in FIELDS]
    with open(env_path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
