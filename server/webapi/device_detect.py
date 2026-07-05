"""
Detección de cámaras USB y micrófonos ALSA disponibles en el sistema.
Equivalente Python de detect_cameras() / detect_mics() en scripts/lib/common.sh.
"""

import re
import subprocess


def _run(cmd: list[str]) -> str:
    try:
        return subprocess.check_output(cmd, stderr=subprocess.DEVNULL, text=True, timeout=5)
    except Exception:
        return ""


def list_cameras() -> list[dict]:
    """
    Devuelve lista de cámaras v4l2 con soporte de video útil.
    Cada elemento: {"dev": "/dev/videoN", "name": "..."}
    """
    import glob

    cameras = []
    for dev in sorted(glob.glob("/dev/video*")):
        formats = _run(["v4l2-ctl", "--device", dev, "--list-formats"])
        if not re.search(r"MJPG|MJPEG|YUYV|H264", formats):
            continue
        info = _run(["v4l2-ctl", "--device", dev, "--info"])
        m = re.search(r"Card type\s*:\s*(.+)", info)
        name = m.group(1).strip() if m else dev
        cameras.append({"dev": dev, "name": name})
    return cameras


def _card_ids() -> dict[str, str]:
    ids = {}
    try:
        import glob

        for path in glob.glob("/proc/asound/card*/id"):
            card = re.search(r"card(\d+)", path)
            if not card:
                continue
            with open(path, encoding="utf-8") as fh:
                ids[card.group(1)] = fh.read().strip()
    except Exception:
        pass
    return ids


def _audio_kind(name: str, card_id: str) -> tuple[str, str]:
    text = f"{name} {card_id}".lower()
    if "boya" in text or "boyalink" in text:
        return "boya", "BOYA / micrófono inalámbrico USB"
    if "webcam" in text or "c920" in text or "camera" in text:
        return "webcam", "Micrófono incluido en la webcam"
    if "focusrite" in text or "scarlett" in text:
        return "interface", "Interfaz de audio USB"
    return "usb", "Micrófono USB"


def list_mics() -> list[dict]:
    """
    Devuelve lista de dispositivos de captura ALSA.
    Cada elemento: {"dev": "plughw:N,M", "name": "..."}
    """
    mics = []
    output = _run(["arecord", "-l"])
    card_ids = _card_ids()
    for line in output.splitlines():
        if not line.startswith("card"):
            continue
        m = re.match(r"card (\d+).*device (\d+)[^[]*\[([^\]]+)\]", line)
        if not m:
            continue
        card, device, name = m.group(1), m.group(2), m.group(3).strip()
        card_id = card_ids.get(card, "")
        stable_dev = f"plughw:CARD={card_id},DEV={device}" if card_id else f"plughw:{card},{device}"
        kind, description = _audio_kind(name, card_id)
        preferred_rate = 48000 if kind in ("boya", "interface") else 44100
        mics.append({
            "dev": stable_dev,
            "numeric_dev": f"plughw:{card},{device}",
            "name": name,
            "card": int(card),
            "device": int(device),
            "card_id": card_id,
            "kind": kind,
            "description": description,
            "preferred_rate": preferred_rate,
        })
    return mics
