from __future__ import annotations

from dataclasses import dataclass
from typing import Literal

from fastapi import Header, HTTPException, Request, status

from .settings import settings


Role = Literal["raspi", "admin"]


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


def _validate_mtls(request: Request) -> tuple[str, str]:
    if not settings.require_mtls:
        return "", ""

    verify_value = request.headers.get(settings.mtls_verify_header, "")
    subject = request.headers.get(settings.mtls_subject_header, "")
    cn = request.headers.get(settings.mtls_cn_header, "")
    if not subject:
        subject = request.headers.get("x-streaming-client-dn", "")
    if not cn:
        cn = request.headers.get("x-streaming-client-cn", "")

    # nginx-ingress commonly forwards X-SSL-Client-Verify=SUCCESS. HAProxy
    # Ingress validates at the edge and forwards X-SSL-Client-CN/DN instead.
    # If TLS is terminated before the Ingress, the edge proxy forwards
    # X-Streaming-Client-CN/DN because HAProxy Ingress strips X-SSL-* headers
    # received from outside.
    if verify_value == settings.mtls_verify_success_value:
        return subject, cn
    if cn or subject:
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
    raise HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="invalid or missing admin token",
    )
