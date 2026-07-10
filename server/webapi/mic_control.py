"""
Lectura del nivel de señal y control de ganancia del micrófono ALSA.

El usuario de servicio "webapi" pertenece al grupo "audio"
(ver scripts/web-api-install.sh), por lo que puede acceder a /dev/snd
directamente: ni arecord/ffmpeg (medición de nivel) ni amixer (ganancia)
requieren sudo. Esto respeta el diseño de mínimos privilegios: el sudoers
de web-api solo cubre systemctl sobre las unidades de streaming.

El dispositivo se toma de AUDIO_DEVICE en /etc/streaming.env
(mismo valor que usan los servicios systemd), en formato
plughw:CARD=NOMBRE,DEV=0 o plughw:N,M.

La medición de nivel abre el dispositivo de captura, así que NO debe
intentarse mientras streaming/streaming-overlay/preview lo estén usando
(el caller debe verificar stream_control.is_active antes de llamar
measure_level). El ajuste de ganancia sí funciona en cualquier momento.
"""

import fcntl
import json
import os
import re
import subprocess
import threading
import time

# Orden de preferencia al elegir el control de captura ajustable.
CAPTURE_CONTROL_PREFERENCE = ("Capture", "Mic", "Digital", "PCM")

# Solo una captura de nivel a la vez: dos ffmpeg sobre el mismo device fallan.
# _measure_lock protege entre threads del mismo worker; _LOCK_PATH (flock)
# protege entre los múltiples workers de gunicorn (ver systemd/web-api.service).
_measure_lock = threading.Lock()

# Caché en tmpfs: varios workers/clientes SSE comparten la última medición en
# vez de abrir el micrófono cada uno por su cuenta.
_CACHE_PATH = os.environ.get("MIC_LEVEL_CACHE", "/dev/shm/webapi-mic-level.json")
_LOCK_PATH = os.environ.get("MIC_LEVEL_LOCK", "/dev/shm/webapi-mic-measure.lock")

_PCT_RE  = re.compile(r"\[(\d+)%\]")
_DB_RE   = re.compile(r"\[(-?\d+(?:\.\d+)?)dB\]")
_MEAN_RE = re.compile(r"mean_volume:\s*(-?\d+(?:\.\d+)?) dB")
_MAX_RE  = re.compile(r"max_volume:\s*(-?\d+(?:\.\d+)?) dB")
_SCTRL_RE = re.compile(r"Simple mixer control '([^']+)'")


class MicControlError(RuntimeError):
    pass


def _run(cmd: list[str], timeout: float = 5):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except Exception:
        return None


def _card_ref(device: str) -> str | None:
    """De AUDIO_DEVICE extrae la referencia de tarjeta para amixer -c.

    plughw:CARD=U0x46d0x8ce,DEV=0 -> "U0x46d0x8ce"
    plughw:1,0 / hw:1,0           -> "1"
    """
    if not device:
        return None
    m = re.search(r"CARD=([^,]+)", device)
    if m:
        return m.group(1)
    m = re.search(r"(?:plug)?hw:(\d+)", device)
    if m:
        return m.group(1)
    return None


def _capture_controls(card_ref: str) -> list[str]:
    res = _run(["amixer", "-c", card_ref, "scontrols"])
    if not res or res.returncode != 0:
        return []
    return _SCTRL_RE.findall(res.stdout)


def _read_control(card_ref: str, name: str) -> dict | None:
    """Devuelve {control, percent, db} si el control tiene volumen de captura."""
    res = _run(["amixer", "-c", card_ref, "sget", name])
    if not res or res.returncode != 0:
        return None
    out = res.stdout
    if "Capture" not in out:
        return None
    for line in out.splitlines():
        if "Capture" not in line or "%" not in line:
            continue
        mp = _PCT_RE.search(line)
        if not mp:
            continue
        md = _DB_RE.search(line)
        return {
            "control": name,
            "percent": int(mp.group(1)),
            "db": float(md.group(1)) if md else None,
        }
    return None


def _find_capture_control(card_ref: str) -> dict | None:
    names = _capture_controls(card_ref)
    if not names:
        return None

    def rank(n: str) -> int:
        low = n.lower()
        for i, pref in enumerate(CAPTURE_CONTROL_PREFERENCE):
            if pref.lower() in low:
                return i
        return len(CAPTURE_CONTROL_PREFERENCE)

    for name in sorted(names, key=rank):
        info = _read_control(card_ref, name)
        if info:
            return info
    return None


def get_gain(device: str) -> dict | None:
    """Ganancia de captura actual: {control, percent, db} o None si no aplica."""
    card_ref = _card_ref(device)
    if not card_ref:
        return None
    return _find_capture_control(card_ref)


def set_gain(device: str, percent: int) -> dict | None:
    """Ajusta la ganancia de captura vía amixer. Devuelve la ganancia releída."""
    card_ref = _card_ref(device)
    if not card_ref:
        raise MicControlError("No se pudo determinar la tarjeta de audio")
    info = _find_capture_control(card_ref)
    if not info:
        raise MicControlError("No se encontró un control de captura ajustable")
    res = _run(["amixer", "-c", card_ref, "sset", info["control"], f"{percent}%"])
    if not res or res.returncode != 0:
        detail = (res.stderr.strip() if res and res.stderr else "amixer no disponible")
        raise MicControlError(f"No se pudo ajustar la ganancia: {detail}")
    return _find_capture_control(card_ref)


def _db_to_pct(db: float | None) -> int:
    if db is None:
        return 0
    pct = (db + 60.0) / 60.0 * 100.0
    return max(0, min(100, round(pct)))


def measure_level(device: str, seconds: int = 1, max_age: float = 0.0) -> dict | None:
    """Mide el nivel con ffmpeg volumedetect (captura acotada de `seconds`).

    Devuelve {mean_db, max_db, mean_pct, peak_pct, ts} o None si el dispositivo
    está ocupado, no hay señal parseable o no se pudo tomar el lock.
    El caller debe garantizar que ningún servicio está usando el micrófono.

    Coordinación multi-worker (gunicorn corre varios procesos):
      - Si hay una medición en caché más reciente que `max_age` segundos, se
        reutiliza sin volver a abrir el micrófono.
      - El flock entre procesos evita que dos workers midan a la vez; el que
        no obtiene el lock devuelve la última medición cacheada.
    """
    if not device:
        return None

    if max_age > 0:
        cached = read_cached_level(max_age)
        if cached is not None:
            return cached

    if not _measure_lock.acquire(blocking=False):
        return read_cached_level(max_age) if max_age > 0 else None

    lock_fd = None
    try:
        lock_fd = os.open(_LOCK_PATH, os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            # Otro worker está midiendo — usar su resultado en cuanto exista.
            return read_cached_level(max_age) if max_age > 0 else None

        # Segundo chequeo de caché: pudo haberla escrito otro worker mientras
        # esperábamos el lock de threads.
        if max_age > 0:
            cached = read_cached_level(max_age)
            if cached is not None:
                return cached

        res = _run(
            ["ffmpeg", "-hide_banner", "-nostdin", "-f", "alsa", "-i", device,
             "-t", str(seconds), "-af", "volumedetect", "-f", "null", "-"],
            timeout=seconds + 4,
        )
    finally:
        if lock_fd is not None:
            try:
                fcntl.flock(lock_fd, fcntl.LOCK_UN)
                os.close(lock_fd)
            except OSError:
                pass
        _measure_lock.release()

    if not res:
        return None
    err = res.stderr or ""
    mmean = _MEAN_RE.search(err)
    mmax = _MAX_RE.search(err)
    if not mmean and not mmax:
        return None
    mean_db = float(mmean.group(1)) if mmean else None
    max_db = float(mmax.group(1)) if mmax else None
    level = {
        "mean_db": mean_db,
        "max_db": max_db,
        "mean_pct": _db_to_pct(mean_db),
        "peak_pct": _db_to_pct(max_db),
        "ts": time.time(),
    }
    _write_cached_level(level)
    return level


def read_cached_level(max_age: float) -> dict | None:
    """Devuelve la última medición cacheada si es más reciente que max_age (s)."""
    try:
        with open(_CACHE_PATH, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return None
    ts = data.get("ts")
    if not isinstance(ts, (int, float)):
        return None
    if time.time() - ts > max_age:
        return None
    return data


def _write_cached_level(level: dict) -> None:
    tmp = f"{_CACHE_PATH}.{os.getpid()}.tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(level, fh)
        os.replace(tmp, _CACHE_PATH)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass

