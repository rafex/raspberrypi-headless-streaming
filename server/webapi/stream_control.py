"""
Control de los servicios systemd de streaming desde web-api.

El proceso corre como el usuario de sistema sin privilegios "webapi"
(ver scripts/web-api-install.sh), que tiene permiso sudo sin password
SOLO para systemctl start|stop|status sobre estas dos unidades exactas
(/etc/sudoers.d/web-api). No se acepta el nombre de servicio como texto
libre en ningún punto de la API: siempre se valida contra SERVICES.
"""

import subprocess

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
        ["systemctl", "is-active", "--quiet", unit],
        capture_output=True,
    )
    return result.returncode == 0


def status(service: str) -> dict:
    unit = _unit(service)
    result = subprocess.run(
        ["systemctl", "show", unit, "--property=ActiveState,SubState"],
        capture_output=True,
        text=True,
    )
    props = dict(
        line.split("=", 1) for line in result.stdout.strip().splitlines() if "=" in line
    )
    return {
        "service": service,
        "active": props.get("ActiveState") == "active",
        "state": props.get("SubState", "unknown"),
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
