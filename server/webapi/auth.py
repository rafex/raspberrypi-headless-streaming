"""
Sesión, login/logout, CSRF y control de acceso por rol para web-api.

Los roles forman una jerarquía simple: "operator" incluye todo lo que
puede hacer "viewer". La sesión es la cookie firmada de Flask (no hay
almacenamiento server-side); por eso el SECRET_KEY de la app debe ser
estable entre reinicios (se fija en /etc/web-api.env) y nunca debe
filtrarse, ya que con él se podría forjar una sesión "operator".
"""

import secrets
from functools import wraps

from flask import jsonify, request, session

ROLE_RANK = {"viewer": 1, "operator": 2}


def login(users: dict, username: str, password: str) -> dict | None:
    """Verifica credenciales contra el store ya descifrado. No toca disco."""
    from werkzeug.security import check_password_hash

    entry = users.get(username)
    if not entry or not check_password_hash(entry["password_hash"], password):
        return None

    session.clear()
    session.permanent = True
    session["user"] = username
    session["role"] = entry["role"]
    session["csrf"] = secrets.token_hex(32)
    return {"user": username, "role": entry["role"], "csrf_token": session["csrf"]}


def logout() -> None:
    session.clear()


def current_session() -> dict | None:
    if "user" not in session:
        return None
    return {"user": session["user"], "role": session["role"]}


def require_role(min_role: str):
    """Decorador: exige sesión activa con rol >= min_role (operator > viewer)."""
    required_rank = ROLE_RANK[min_role]

    def decorator(fn):
        @wraps(fn)
        def wrapper(*args, **kwargs):
            role = session.get("role")
            if role is None:
                return jsonify({"error": "No autenticado"}), 401
            if ROLE_RANK.get(role, 0) < required_rank:
                return jsonify({"error": "Permisos insuficientes"}), 403

            # Cualquier request que mute estado (no GET) requiere el token CSRF
            # emitido en el login, enviado en el header X-CSRF-Token.
            if request.method not in ("GET", "HEAD", "OPTIONS"):
                token = request.headers.get("X-CSRF-Token", "")
                if not token or not secrets.compare_digest(token, session.get("csrf", "")):
                    return jsonify({"error": "CSRF token inválido o ausente"}), 403

            return fn(*args, **kwargs)

        return wrapper

    return decorator
