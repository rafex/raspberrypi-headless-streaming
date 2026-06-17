"""
Control de los servicios systemd de streaming desde web-api.

El proceso corre como el usuario de sistema sin privilegios "webapi"
(ver scripts/web-api-install.sh), que tiene permiso sudo sin password
SOLO para systemctl start|stop|status sobre estas dos unidades exactas
(/etc/sudoers.d/web-api). No se acepta el nombre de servicio como texto
libre en ningún punto de la API: siempre se valida contra SERVICES.
"""

import subprocess
import time

SERVICES = ("streaming", "streaming-overlay")


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


def status(service: str) -> dict:
    unit = _unit(service)
    active = is_active(service)
    return {
        "service": service,
        "active": active,
        "state": "running" if active else "dead",
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

    # Type=simple: el proceso arranca de inmediato pero puede tardar ~1s en activarse.
    time.sleep(1)
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
