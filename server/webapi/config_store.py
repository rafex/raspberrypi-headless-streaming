"""
Lectura/escritura de /etc/streaming.env — el mismo archivo que ya leen
los servicios systemd "streaming" y "streaming-overlay"
(ver systemd/streaming.env.example). web-api no inventa variables
nuevas, reutiliza exactamente estas claves.
"""

import os
import re

FIELDS = (
    "RTMP_URL", "STREAM_PLATFORM", "STREAM_KEY",
    "STREAM_DUAL", "STREAM_KEY_META", "RTMP_URL_SECONDARY",
    "STREAM_WIDTH", "STREAM_HEIGHT", "STREAM_FPS", "STREAM_BITRATE", "STREAM_PRESET",
    "VIDEO_SOURCE", "VIDEO_DEVICE", "VIDEO_INPUT_FORMAT", "VIDEO_INPUT_WIDTH", "VIDEO_INPUT_HEIGHT", "VIDEO_INPUT_FPS",
    "AUDIO_SOURCE", "AUDIO_DEVICE", "AUDIO_CHANNELS", "AUDIO_RATE", "STREAM_NO_AUDIO",
    "STREAM_AUDIO_BOOST",
    "GPU_ENCODER",
    "OVERLAY_TEXT_ENABLED", "OVERLAY_TEXT", "OVERLAY_TEXT_POS",
    "OVERLAY_TIMESTAMP", "OVERLAY_TIMESTAMP_POS",
    "OVERLAY_LOGO_ENABLED", "OVERLAY_LOGO_FILE", "OVERLAY_LOGO_POS", "OVERLAY_LOGO_PAD", "OVERLAY_LOGO_W",
    "OVERLAY_BANNER_ENABLED", "OVERLAY_BANNER", "OVERLAY_BANNER_POS",
)

VALID_PRESETS     = ("ultrafast", "superfast", "veryfast", "faster", "fast")
VALID_TEXT_POS    = ("tl", "tr", "bl", "br", "center")
VALID_TIMESTAMP_POS = ("tl", "tr", "bl", "br", "center")
VALID_LOGO_POS    = ("tl", "tr", "bl", "br")
VALID_BANNER_POS  = ("footer", "header")
VALID_PLATFORMS   = ("youtube", "facebook", "custom", "dual")
VALID_AUDIO_RATES = (44100, 48000)
VALID_VIDEO_SOURCES = ("auto", "v4l2", "libcamera")
VALID_AUDIO_SOURCES = ("auto", "manual")

PLATFORM_BASE_URLS = {
    "youtube":  "rtmp://a.rtmp.youtube.com/live2/",
    "facebook": "rtmps://live-api-s.facebook.com:443/rtmp/",
}

RTMP_URL_RE   = re.compile(r"^rtmps?://[^\s]+$")
LOGO_PATH_RE  = re.compile(r"^[^\x00\n\r;|&`$<>]+$")
STREAM_KEY_RE = re.compile(r"^[A-Za-z0-9_\-]+$")


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

    # --- Plataforma y destino RTMP ---
    platform = str(data.get("platform", "custom")).strip()
    if platform not in VALID_PLATFORMS:
        errors.append(f"platform debe ser uno de: {', '.join(VALID_PLATFORMS)}")
        platform = "custom"

    stream_key      = str(data.get("stream_key",      "")).strip()
    stream_key_meta = str(data.get("stream_key_meta", "")).strip()

    rtmp_url           = ""
    rtmp_url_secondary = ""
    stream_dual        = platform == "dual"

    if platform == "dual":
        # YouTube principal + Facebook secundario
        if not stream_key:
            errors.append("stream_key (YouTube) es requerido para dual stream")
        elif not STREAM_KEY_RE.match(stream_key):
            errors.append("stream_key solo puede contener letras, números, guiones y guiones bajos")
        if not stream_key_meta:
            errors.append("stream_key_meta (Facebook) es requerido para dual stream")
        elif not STREAM_KEY_RE.match(stream_key_meta):
            errors.append("stream_key_meta solo puede contener letras, números, guiones y guiones bajos")
        rtmp_url           = PLATFORM_BASE_URLS["youtube"].rstrip("/")
        rtmp_url_secondary = PLATFORM_BASE_URLS["facebook"] + stream_key_meta
    elif platform in ("youtube", "facebook"):
        if not stream_key:
            errors.append("stream_key es requerido para YouTube y Facebook")
        elif not STREAM_KEY_RE.match(stream_key):
            errors.append("stream_key solo puede contener letras, números, guiones y guiones bajos")
        rtmp_url = PLATFORM_BASE_URLS.get(platform, "").rstrip("/")
    else:
        rtmp_url = str(data.get("rtmp_url", "")).strip()
        if not RTMP_URL_RE.match(rtmp_url):
            errors.append("rtmp_url debe ser una URL rtmp:// o rtmps:// válida")

    def _bool(key, default=True):
        raw = data.get(key, default)
        if isinstance(raw, str):
            return raw.lower() in ("true", "1", "yes")
        return bool(raw)

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

    width   = _int_in_range("width",   320,       1920)
    height  = _int_in_range("height",  240,       1080)
    fps     = _int_in_range("fps",     1,         60)
    bitrate = _int_in_range("bitrate", 200_000,   25_000_000)

    preset = str(data.get("preset", "veryfast")).strip()
    if preset not in VALID_PRESETS:
        errors.append(f"preset debe ser uno de: {', '.join(VALID_PRESETS)}")

    # --- Audio ---
    audio_rate_raw = data.get("audio_rate", 44100)
    try:
        audio_rate = int(audio_rate_raw)
        if audio_rate not in VALID_AUDIO_RATES:
            errors.append(f"audio_rate debe ser uno de: {', '.join(str(r) for r in VALID_AUDIO_RATES)}")
    except (TypeError, ValueError):
        errors.append("audio_rate debe ser un entero")
        audio_rate = 44100

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

    audio_boost_raw = data.get("stream_audio_boost", False)
    if isinstance(audio_boost_raw, str):
        audio_boost = audio_boost_raw.lower() in ("true", "1", "yes")
    else:
        audio_boost = bool(audio_boost_raw)

    gpu_encoder_raw = data.get("gpu_encoder", False)
    if isinstance(gpu_encoder_raw, str):
        gpu_encoder = gpu_encoder_raw.lower() in ("true", "1", "yes")
    else:
        gpu_encoder = bool(gpu_encoder_raw)

    video_source = str(data.get("video_source", "auto")).strip().lower() or "auto"
    if video_source not in VALID_VIDEO_SOURCES:
        errors.append(f"video_source debe ser uno de: {', '.join(VALID_VIDEO_SOURCES)}")
        video_source = "auto"

    video_device = str(data.get("video_device", "")).strip()
    if video_device and not re.match(r"^/dev/video\d+$", video_device):
        errors.append("video_device debe ser /dev/videoN")

    audio_source = str(data.get("audio_source", "auto")).strip().lower() or "auto"
    if audio_source not in VALID_AUDIO_SOURCES:
        errors.append(f"audio_source debe ser uno de: {', '.join(VALID_AUDIO_SOURCES)}")
        audio_source = "auto"

    audio_device = str(data.get("audio_device", "")).strip()
    if audio_device and not re.match(r"^(plughw|hw):(\d+,\d+|CARD=[A-Za-z0-9_=-]+,DEV=\d+)$", audio_device):
        errors.append("audio_device debe ser plughw:N,M, hw:N,M o plughw:CARD=NOMBRE,DEV=N")

    # --- Overlay ---
    # Cada overlay tiene su propio toggle *_enabled, independiente de los demás.
    # El contenido (texto/logo/banner) se guarda siempre, incluso deshabilitado —
    # solo *_enabled decide si stream-overlay.sh lo renderiza.
    overlay_text_enabled = _bool("overlay_text_enabled")
    overlay_text = str(data.get("overlay_text", "")).strip().replace("\n", " ").replace("\r", "")[:200]

    overlay_text_pos = str(data.get("overlay_text_pos", "bl")).strip()
    if overlay_text_pos not in VALID_TEXT_POS:
        errors.append(f"overlay_text_pos debe ser uno de: {', '.join(VALID_TEXT_POS)}")

    overlay_timestamp = _bool("overlay_timestamp", default=False)

    overlay_timestamp_pos = str(data.get("overlay_timestamp_pos", "tl")).strip()
    if overlay_timestamp_pos not in VALID_TIMESTAMP_POS:
        errors.append(f"overlay_timestamp_pos debe ser uno de: {', '.join(VALID_TIMESTAMP_POS)}")

    overlay_logo_enabled = _bool("overlay_logo_enabled")
    overlay_logo_file = str(data.get("overlay_logo_file", "")).strip()
    if overlay_logo_file:
        if not LOGO_PATH_RE.match(overlay_logo_file):
            errors.append("overlay_logo_file contiene caracteres no permitidos")
        else:
            # Normalizar para neutralizar traversal (../../etc/shadow -> /etc/shadow)
            # y verificar que el path quede dentro del directorio gestionado o
            # dentro de assets/ versionado del repositorio.
            normalized = os.path.normpath(overlay_logo_file)
            is_managed_upload = normalized.startswith("/var/lib/raspi-streaming/")
            is_repo_asset = normalized.startswith("assets/") and ".." not in normalized.split(os.sep)
            if not (is_managed_upload or is_repo_asset):
                errors.append(
                    "overlay_logo_file debe estar dentro de /var/lib/raspi-streaming/ o assets/"
                )
            else:
                overlay_logo_file = normalized

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

    overlay_logo_w = data.get("overlay_logo_w", 0)
    try:
        overlay_logo_w = int(overlay_logo_w)
        if not (0 <= overlay_logo_w <= 500):
            errors.append("overlay_logo_w debe estar entre 0 y 500")
    except (TypeError, ValueError):
        errors.append("overlay_logo_w debe ser un entero")
        overlay_logo_w = 0

    overlay_banner_enabled = _bool("overlay_banner_enabled")
    overlay_banner = str(data.get("overlay_banner", "")).strip().replace("\n", " ").replace("\r", "")[:200]

    overlay_banner_pos = str(data.get("overlay_banner_pos", "footer")).strip()
    if overlay_banner_pos not in VALID_BANNER_POS:
        errors.append(f"overlay_banner_pos debe ser uno de: {', '.join(VALID_BANNER_POS)}")
        overlay_banner_pos = "footer"

    if errors:
        raise ConfigValidationError("; ".join(errors))

    return {
        "RTMP_URL":           rtmp_url,
        "STREAM_PLATFORM":    platform,
        "STREAM_KEY":         stream_key,
        "STREAM_DUAL":        "true" if stream_dual else "false",
        "STREAM_KEY_META":    stream_key_meta,
        "RTMP_URL_SECONDARY": rtmp_url_secondary,
        "STREAM_WIDTH":       str(width),
        "STREAM_HEIGHT":      str(height),
        "STREAM_FPS":         str(fps),
        "STREAM_BITRATE":     str(bitrate),
        "STREAM_PRESET":      preset,
        "VIDEO_SOURCE":       video_source,
        "VIDEO_DEVICE":       video_device if video_source != "auto" else "",
        "VIDEO_INPUT_FORMAT": "",
        "VIDEO_INPUT_WIDTH":  "",
        "VIDEO_INPUT_HEIGHT": "",
        "VIDEO_INPUT_FPS":    "",
        "AUDIO_SOURCE":       audio_source,
        "AUDIO_DEVICE":       audio_device,
        "AUDIO_CHANNELS":     str(audio_channels),
        "AUDIO_RATE":         str(audio_rate),
        "STREAM_NO_AUDIO":    "true" if no_audio else "false",
        "STREAM_AUDIO_BOOST": "true" if audio_boost else "false",
        "GPU_ENCODER":        "true" if gpu_encoder else "false",
        "OVERLAY_TEXT_ENABLED": "true" if overlay_text_enabled else "false",
        "OVERLAY_TEXT":       overlay_text,
        "OVERLAY_TEXT_POS":   overlay_text_pos,
        "OVERLAY_TIMESTAMP":  "true" if overlay_timestamp else "false",
        "OVERLAY_TIMESTAMP_POS": overlay_timestamp_pos,
        "OVERLAY_LOGO_ENABLED": "true" if overlay_logo_enabled else "false",
        "OVERLAY_LOGO_FILE":  overlay_logo_file,
        "OVERLAY_LOGO_POS":   overlay_logo_pos,
        "OVERLAY_LOGO_PAD":   str(overlay_logo_pad),
        "OVERLAY_LOGO_W":     str(overlay_logo_w),
        "OVERLAY_BANNER_ENABLED": "true" if overlay_banner_enabled else "false",
        "OVERLAY_BANNER":     overlay_banner,
        "OVERLAY_BANNER_POS": overlay_banner_pos,
    }


def write_config(env_path: str, validated: dict) -> None:
    """Reescribe env_path solo con las claves conocidas (formato KEY=value, una por línea)."""
    lines = [f"{field}={validated[field]}" for field in FIELDS]
    with open(env_path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
