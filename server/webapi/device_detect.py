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


def list_mics() -> list[dict]:
    """
    Devuelve lista de dispositivos de captura ALSA.
    Cada elemento: {"dev": "plughw:N,M", "name": "..."}
    """
    mics = []
    output = _run(["arecord", "-l"])
    for line in output.splitlines():
        if not line.startswith("card"):
            continue
        m = re.match(r"card (\d+).*device (\d+)[^[]*\[([^\]]+)\]", line)
        if not m:
            continue
        card, device, name = m.group(1), m.group(2), m.group(3).strip()
        mics.append({"dev": f"plughw:{card},{device}", "name": name})
    return mics
