from __future__ import annotations

from urllib.parse import urlsplit, urlunsplit

import httpx
from fastapi import HTTPException, Request, status
from fastapi.responses import Response

from .settings import settings
from .store import Store


HOP_BY_HOP_HEADERS = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
}

DROP_RESPONSE_HEADERS = HOP_BY_HOP_HEADERS | {
    "content-encoding",
    "content-length",
}


def portal_host_for_device(device_id: str) -> str:
    return f"{device_id}.{settings.portal_proxy_domain}".lower()


def device_id_from_host(host: str) -> str | None:
    hostname = host.split(":", 1)[0].lower().strip(".")
    public_hostname = urlsplit(settings.public_base_url).hostname
    if public_hostname and hostname == public_hostname.lower():
        return None
    suffix = f".{settings.portal_proxy_domain.lower().strip('.')}"
    if not hostname.endswith(suffix):
        return None
    device_id = hostname[: -len(suffix)]
    if not device_id or "." in device_id:
        return None
    return device_id


def portal_url_for_device(store: Store, device_id: str) -> str:
    state = store.get_device(device_id)
    health = state.get("last_health") or {}
    url = str(health.get("ngrok_url") or "").strip().rstrip("/")
    if not url:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="portal tunnel not reported yet",
        )

    parsed = urlsplit(url)
    if parsed.scheme != "https" or not parsed.netloc:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="invalid portal tunnel url",
        )

    allowed_suffixes = [
        suffix.strip().lower()
        for suffix in settings.portal_proxy_allowed_host_suffixes.split(",")
        if suffix.strip()
    ]
    upstream_host = parsed.hostname.lower() if parsed.hostname else ""
    if allowed_suffixes and not any(upstream_host.endswith(suffix) for suffix in allowed_suffixes):
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="portal tunnel host is not allowed",
        )
    return url


def _proxy_headers(request: Request, upstream_host: str) -> dict[str, str]:
    headers: dict[str, str] = {}
    for name, value in request.headers.items():
        lname = name.lower()
        if lname in HOP_BY_HOP_HEADERS or lname == "host" or lname == "content-length":
            continue
        if lname == "authorization":
            continue
        if lname.startswith("x-forwarded-") or lname in {"forwarded", "x-scheme"}:
            continue
        headers[name] = value
    headers["host"] = upstream_host
    headers["ngrok-skip-browser-warning"] = "true"
    return headers


def _response_headers(response: httpx.Response, public_base: str, upstream_base: str) -> dict[str, str]:
    headers: dict[str, str] = {}
    for name, value in response.headers.items():
        lname = name.lower()
        if lname in DROP_RESPONSE_HEADERS:
            continue
        if lname == "location":
            value = value.replace(upstream_base, public_base)
        elif lname == "set-cookie":
            value = value.replace(f"Domain={urlsplit(upstream_base).hostname}", f"Domain={urlsplit(public_base).hostname}")
        headers[name] = value
    return headers


async def proxy_portal_request(request: Request, store: Store, device_id: str) -> Response:
    upstream_base = portal_url_for_device(store, device_id)
    public_base = f"https://{portal_host_for_device(device_id)}"
    upstream = urlsplit(upstream_base)
    upstream_path = request.url.path or "/"
    target_url = urlunsplit(
        (
            upstream.scheme,
            upstream.netloc,
            upstream_path,
            request.url.query,
            "",
        )
    )

    body = await request.body()
    timeout = httpx.Timeout(settings.portal_proxy_timeout_seconds)
    async with httpx.AsyncClient(timeout=timeout, follow_redirects=False) as client:
        upstream_response = await client.request(
            request.method,
            target_url,
            content=body,
            headers=_proxy_headers(request, upstream.netloc),
        )

    return Response(
        content=upstream_response.content,
        status_code=upstream_response.status_code,
        headers=_response_headers(upstream_response, public_base, upstream_base),
        media_type=upstream_response.headers.get("content-type"),
    )


async def proxy_headless_request(
    request: Request,
    store: Store,
    device_id: str,
    path: str,
    token: str,
) -> Response:
    upstream_base = portal_url_for_device(store, device_id)
    upstream = urlsplit(upstream_base)
    clean_path = "/" + path.lstrip("/")
    target_url = urlunsplit(
        (
            upstream.scheme,
            upstream.netloc,
            clean_path,
            request.url.query,
            "",
        )
    )

    headers = _proxy_headers(request, upstream.netloc)
    headers["Authorization"] = f"Bearer {token}"
    body = await request.body()
    timeout = httpx.Timeout(settings.portal_proxy_timeout_seconds)
    async with httpx.AsyncClient(timeout=timeout, follow_redirects=False) as client:
        upstream_response = await client.request(
            request.method,
            target_url,
            content=body,
            headers=headers,
        )

    return Response(
        content=upstream_response.content,
        status_code=upstream_response.status_code,
        headers=_response_headers(upstream_response, "", upstream_base),
        media_type=upstream_response.headers.get("content-type"),
    )
