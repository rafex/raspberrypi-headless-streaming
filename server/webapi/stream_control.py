"""
Control de los servicios systemd de streaming desde web-api.

El proceso corre como el usuario de sistema sin privilegios "webapi"
(ver scripts/web-api-install.sh), que tiene permiso sudo sin password
SOLO para systemctl start|stop|is-active sobre estas unidades exactas
(/etc/sudoers.d/web-api). No se acepta el nombre de servicio como texto
libre en ningún punto de la API: siempre se valida contra SERVICES.

Para leer el journal (last_errors) el usuario webapi debe pertenecer al
grupo systemd-journal (lo agrega web-api-install.sh).
"""

import re
import subprocess
import time

# "preview" comparte cámara con streaming/streaming-overlay (ver start()),
# pero transmite siempre a un destino local — nunca a la plataforma real
# (ver systemd/preview.service).
SERVICES = ("streaming", "streaming-overlay", "preview")

# Patrón para detectar líneas de error/advertencia relevantes en el journal.
_ERROR_RE = re.compile(
    r"error|fail|warn|refused|lost|drop|disconnect|reset|timeout",
    re.IGNORECASE,
)


class StreamControlError(RuntimeError):
    pass


def _unit(service: str) -> str:
    if service not in SERVICES:
        raise StreamControlError(f"Servicio desconocido: {service!r}. Válidos: {SERVICES}")
    return f"{service}.service"


def is_active(service: str) -> bool:
    unit = _unit(service)
    result = subprocess.run(
        ["sudo", "systemctl", "is-active", unit],
        capture_output=True,
    )
    return result.returncode == 0


def last_errors(service: str, scan_lines: int = 40, max_return: int = 5) -> list[str]:
    """Retorna las últimas líneas relevantes (error/warn/fail) del journal del servicio."""
    unit = _unit(service)
    try:
        result = subprocess.run(
            ["journalctl", "-u", unit, "-n", str(scan_lines), "--no-pager", "-o", "cat"],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode != 0:
            return []
        matches = [line for line in result.stdout.splitlines() if _ERROR_RE.search(line)]
        return matches[-max_return:]
    except Exception:
        return []


def status(service: str) -> dict:
    unit = _unit(service)
    active = is_active(service)
    return {
        "service": service,
        "active": active,
        "state": "running" if active else "dead",
        "last_errors": last_errors(service) if not active else [],
    }


def start(service: str) -> dict:
    unit = _unit(service)

    # Evitar que dos pipelines de ffmpeg/libcamera-vid compitan por la cámara.
    for other in SERVICES:
        if other != service and is_active(other):
            stop(other)

    result = subprocess.run(
        ["sudo", "systemctl", "start", unit],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise StreamControlError(f"No se pudo iniciar {unit}: {result.stderr.strip()}")

    # Polling en lugar de sleep fijo: espera hasta 3s en pasos de 300ms.
    for _ in range(10):
        time.sleep(0.3)
        if is_active(service):
            break

    return status(service)


def stop(service: str) -> dict:
    unit = _unit(service)
    result = subprocess.run(
        ["sudo", "systemctl", "stop", unit],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise StreamControlError(f"No se pudo detener {unit}: {result.stderr.strip()}")

    return status(service)
