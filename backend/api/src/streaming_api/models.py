from __future__ import annotations

from datetime import datetime, timezone
from typing import Any, Literal

from pydantic import BaseModel, Field


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


class HealthPayload(BaseModel):
    timestamp: str | None = None
    hostname: str = ""
    ip: str = ""
    default_route: str = ""
    wifi_ssid: str = ""
    ngrok_url: str = ""
    ngrok_ssh_url: str = ""
    ngrok_ssh_command: str = ""
    services: dict[str, Any] = Field(default_factory=dict)
    devices: dict[str, Any] = Field(default_factory=dict)
    stream_config: dict[str, Any] = Field(default_factory=dict)
    preview_config: dict[str, Any] = Field(default_factory=dict)
    recent_stream_errors: str = ""


class ControlCommand(BaseModel):
    action: Literal[
        "none",
        "start_streaming",
        "start_streaming_overlay",
        "stop_streaming",
        "stop_all",
        "start_preview",
        "stop_preview",
        "apply_config",
        "reboot",
    ] = "none"
    reason: str = ""


class DesiredStateIn(BaseModel):
    config: dict[str, str] = Field(default_factory=dict)
    command: ControlCommand = Field(default_factory=ControlCommand)


class DesiredStateOut(BaseModel):
    device_id: str
    sequence: int
    updated_at: datetime
    config: dict[str, str]
    command: ControlCommand


class AckPayload(BaseModel):
    sequence: int
    status: Literal["applied", "failed", "ignored"]
    message: str = ""


class DeviceState(BaseModel):
    device_id: str
    last_seen_at: datetime | None = None
    last_health: dict[str, Any] = Field(default_factory=dict)
    desired: DesiredStateOut | None = None
    last_ack: dict[str, Any] = Field(default_factory=dict)
