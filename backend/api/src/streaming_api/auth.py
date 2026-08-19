from __future__ import annotations

import base64
import hashlib
import hmac
import json
import time
from dataclasses import dataclass
from typing import Literal

from fastapi import Header, HTTPException, Request, status

from .settings import settings


Role = Literal["raspi", "admin"]
PASSWORD_HASH_ALGORITHM = "pbkdf2_sha256"


@dataclass(frozen=True)
class Principal:
    role: Role
    mtls_subject: str = ""
    mtls_cn: str = ""


def _extract_token(authorization: str | None, x_api_token: str | None) -> str:
    if authorization:
        scheme, _, value = authorization.partition(" ")
        if scheme.lower() == "bearer" and value:
            return value.strip()
    return (x_api_token or "").strip()


def _b64url_encode(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def _b64url_decode(value: str) -> bytes:
    padding = "=" * (-len(value) % 4)
    return base64.urlsafe_b64decode(value + padding)


def verify_password(password: str, encoded_hash: str) -> bool:
    try:
        algorithm, iterations_raw, salt_b64, digest_b64 = encoded_hash.split("$", 3)
        if algorithm != PASSWORD_HASH_ALGORITHM:
            return False
        iterations = int(iterations_raw)
        salt = base64.b64decode(salt_b64.encode("ascii"), validate=True)
        expected = base64.b64decode(digest_b64.encode("ascii"), validate=True)
    except Exception:
        return False
    actual = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, iterations)
    return hmac.compare_digest(actual, expected)


def verify_portal_credentials(username: str, password: str) -> bool:
    if not settings.portal_username or not settings.portal_password_hash:
        return False
    if not hmac.compare_digest(username, settings.portal_username):
        return False
    return verify_password(password, settings.portal_password_hash)


def create_portal_session() -> tuple[str, int]:
    if not settings.portal_session_secret:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="portal session secret not configured",
        )
    expires_at = int(time.time()) + int(settings.portal_session_ttl_seconds)
    payload = {"role": "admin", "exp": expires_at}
    payload_b64 = _b64url_encode(json.dumps(payload, separators=(",", ":")).encode("utf-8"))
    signature = hmac.new(
        settings.portal_session_secret.encode("utf-8"),
        payload_b64.encode("ascii"),
        hashlib.sha256,
    ).digest()
    return f"pst_{payload_b64}.{_b64url_encode(signature)}", expires_at


def validate_portal_session(token: str) -> bool:
    if not settings.portal_session_secret or not token.startswith("pst_"):
        return False
    try:
        payload_b64, signature_b64 = token.removeprefix("pst_").split(".", 1)
        expected = hmac.new(
            settings.portal_session_secret.encode("utf-8"),
            payload_b64.encode("ascii"),
            hashlib.sha256,
        ).digest()
        provided = _b64url_decode(signature_b64)
        if not hmac.compare_digest(provided, expected):
            return False
        payload = json.loads(_b64url_decode(payload_b64))
        return payload.get("role") == "admin" and int(payload.get("exp", 0)) > int(time.time())
    except Exception:
        return False


def _validate_mtls(request: Request) -> tuple[str, str]:
    if not settings.require_mtls:
        return "", ""

    subject = request.headers.get(settings.mtls_subject_header, "")
    cn = request.headers.get(settings.mtls_cn_header, "")
    certificate = request.headers.get(settings.mtls_cert_header, "")
    if not subject:
        subject = request.headers.get("x-streaming-client-dn", "")
    if not cn:
        cn = request.headers.get("x-streaming-client-cn", "")

    # nginx-ingress commonly forwards X-SSL-Client-Verify=SUCCESS. HAProxy
    # Ingress validates at the edge and forwards X-SSL-Client-CN/DN instead.
    # If TLS is terminated before the Ingress, the edge proxy forwards
    # X-Streaming-Client-CN/DN because HAProxy Ingress strips X-SSL-* headers
    # received from outside.
    # HAProxy Ingress forwards the client certificate fields only after it
    # terminates TLS. The verify header alone is not sufficient: clients can
    # otherwise spoof X-SSL-Client-Verify before the trusted proxy.
    if certificate or cn or subject:
        return subject, cn

    if settings.require_mtls:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="mTLS client certificate required",
        )
    return subject, cn


def authenticate(
    request: Request,
    authorization: str | None = Header(default=None),
    x_api_token: str | None = Header(default=None),
) -> Principal:
    token = _extract_token(authorization, x_api_token)
    subject, cn = _validate_mtls(request)

    if settings.api_token_admin and token == settings.api_token_admin:
        return Principal(role="admin", mtls_subject=subject, mtls_cn=cn)
    if settings.api_token_raspi and token == settings.api_token_raspi:
        return Principal(role="raspi", mtls_subject=subject, mtls_cn=cn)

    raise HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="invalid or missing token",
    )


def require_admin(principal: Principal) -> None:
    if principal.role != "admin":
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="admin token required",
        )


def authenticate_admin_token(
    authorization: str | None = Header(default=None),
    x_api_token: str | None = Header(default=None),
) -> Principal:
    token = _extract_token(authorization, x_api_token)
    if settings.api_token_admin and token == settings.api_token_admin:
        return Principal(role="admin")
    if validate_portal_session(token):
        return Principal(role="admin")
    raise HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="invalid or missing admin session",
    )
