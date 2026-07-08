from __future__ import annotations

from fastapi import Depends, FastAPI, Request

from .auth import Principal, authenticate, require_admin
from .models import AckPayload, DesiredStateIn, DesiredStateOut, HealthPayload
from .settings import settings
from .store import Store


app = FastAPI(title=settings.app_name)
store = Store(settings.database_path)


async def enforce_payload_limit(request: Request) -> None:
    raw_length = request.headers.get("content-length")
    if raw_length and int(raw_length) > settings.max_payload_bytes:
        from fastapi import HTTPException

        raise HTTPException(status_code=413, detail="payload too large")


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


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
