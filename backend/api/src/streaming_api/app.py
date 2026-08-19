from __future__ import annotations

from pathlib import Path

from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse, RedirectResponse, Response
from fastapi.staticfiles import StaticFiles

from .auth import (
    Principal,
    authenticate,
    authenticate_admin_token,
    create_portal_session,
    require_admin,
    verify_portal_credentials,
)
from .models import AckPayload, DesiredStateIn, DesiredStateOut, HealthPayload, PortalLoginIn, PortalLoginOut
from .portal_proxy import (
    device_id_from_host,
    portal_host_for_device,
    proxy_headless_request,
    proxy_portal_request,
)
from .settings import settings
from .store import Store


# The public UI is served from /static. Keep FastAPI's schema and interactive
# documentation disabled so route metadata is not exposed without auth.
app = FastAPI(
    title=settings.app_name,
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
)
store = Store(settings.database_path)
STATIC_DIR = Path(__file__).with_name("static")


@app.middleware("http")
async def portal_proxy_middleware(request: Request, call_next):
    host = request.headers.get("host", "")
    device_id = device_id_from_host(host)
    if device_id:
        try:
            return await proxy_portal_request(request, store, device_id)
        except HTTPException as exc:
            return JSONResponse({"detail": exc.detail}, status_code=exc.status_code)
    return await call_next(request)


async def enforce_payload_limit(request: Request) -> None:
    raw_length = request.headers.get("content-length")
    if raw_length and int(raw_length) > settings.max_payload_bytes:
        from fastapi import HTTPException

        raise HTTPException(status_code=413, detail="payload too large")


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


if STATIC_DIR.exists():
    app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")


@app.get("/")
@app.head("/")
def frontend() -> RedirectResponse:
    return RedirectResponse("/static/index.html", status_code=302)


@app.get("/portal/{device_id}")
@app.get("/portal/{device_id}/")
@app.head("/portal/{device_id}")
@app.head("/portal/{device_id}/")
def redirect_to_portal(
    device_id: str,
    _: Principal = Depends(authenticate_admin_token),
) -> RedirectResponse:
    return RedirectResponse(f"https://{portal_host_for_device(device_id)}/", status_code=302)


@app.post("/ui/api/login", response_model=PortalLoginOut)
def ui_login(credentials: PortalLoginIn) -> PortalLoginOut:
    if not verify_portal_credentials(credentials.username, credentials.password):
        raise HTTPException(status_code=401, detail="usuario o contraseña inválidos")
    access_token, expires_at = create_portal_session()
    return PortalLoginOut(access_token=access_token, expires_at=expires_at)


@app.get("/ui/api/raspi/{device_id}/state")
def ui_get_device_state(
    device_id: str,
    _: Principal = Depends(authenticate_admin_token),
) -> dict:
    return store.get_device(device_id)


@app.api_route(
    "/ui/api/raspi/{device_id}/headless/{path:path}",
    methods=["GET", "POST", "PUT", "PATCH", "DELETE"],
)
async def ui_headless_proxy(
    device_id: str,
    path: str,
    request: Request,
    _: Principal = Depends(authenticate_admin_token),
) -> Response:
    try:
        return await proxy_headless_request(request, store, device_id, path, settings.api_token_raspi)
    except HTTPException as exc:
        return JSONResponse({"detail": exc.detail}, status_code=exc.status_code)


@app.post("/v1/raspi/{device_id}/health", dependencies=[Depends(enforce_payload_limit)])
def report_health(
    device_id: str,
    payload: HealthPayload,
    principal: Principal = Depends(authenticate),
) -> dict[str, str]:
    store.upsert_health(device_id, payload)
    return {"status": "accepted", "role": principal.role}


@app.get("/v1/raspi/{device_id}/desired-state", response_model=DesiredStateOut)
def get_desired_state(
    device_id: str,
    _: Principal = Depends(authenticate),
) -> DesiredStateOut:
    return store.get_desired(device_id)


@app.post("/v1/raspi/{device_id}/ack")
def ack_desired_state(
    device_id: str,
    payload: AckPayload,
    _: Principal = Depends(authenticate),
) -> dict[str, str]:
    store.ack(device_id, payload)
    return {"status": "accepted"}


@app.put("/v1/raspi/{device_id}/desired-state", response_model=DesiredStateOut)
def set_desired_state(
    device_id: str,
    desired: DesiredStateIn,
    principal: Principal = Depends(authenticate),
) -> DesiredStateOut:
    require_admin(principal)
    return store.set_desired(device_id, desired)


@app.get("/v1/raspi/{device_id}/state")
def get_device_state(
    device_id: str,
    principal: Principal = Depends(authenticate),
) -> dict:
    require_admin(principal)
    return store.get_device(device_id)


@app.get("/v1/raspi")
def list_devices(principal: Principal = Depends(authenticate)) -> dict[str, list[dict]]:
    require_admin(principal)
    return {"devices": store.list_devices()}
