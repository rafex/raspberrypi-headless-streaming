"""
Carga de usuarios cifrados con sops + age para el servicio web-api.

El archivo secrets.enc.yaml se descifra en memoria al arrancar el proceso
(invocando el binario `sops`) y nunca se escribe en claro a disco. Tiene
el siguiente formato una vez descifrado:

    users:
      - username: admin
        password_hash: "pbkdf2:sha256:..."
        role: operator
      - username: invitado
        password_hash: "pbkdf2:sha256:..."
        role: viewer

ROLES = {"viewer", "operator"}.
"""

import subprocess

import yaml

ROLES = ("viewer", "operator")


class SecretsError(RuntimeError):
    pass


def load_users(secrets_path: str) -> dict:
    """Descifra secrets_path con sops y devuelve {username: {password_hash, role}}."""
    try:
        result = subprocess.run(
            ["sops", "-d", secrets_path],
            capture_output=True,
            check=True,
            text=True,
        )
    except FileNotFoundError as exc:
        raise SecretsError("El binario 'sops' no está instalado o no está en PATH.") from exc
    except subprocess.CalledProcessError as exc:
        raise SecretsError(f"sops no pudo descifrar {secrets_path}: {exc.stderr.strip()}") from exc

    data = yaml.safe_load(result.stdout) or {}
    users = data.get("users", [])
    if not users:
        raise SecretsError(f"{secrets_path} no contiene usuarios.")

    store = {}
    for entry in users:
        username = entry.get("username")
        password_hash = entry.get("password_hash")
        role = entry.get("role")

        if not username or not password_hash or role not in ROLES:
            raise SecretsError(f"Entrada de usuario inválida en {secrets_path}: {entry!r}")

        store[username] = {"password_hash": password_hash, "role": role}

    return store
