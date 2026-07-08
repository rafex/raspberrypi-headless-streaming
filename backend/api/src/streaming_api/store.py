from __future__ import annotations

import json
import sqlite3
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .models import AckPayload, ControlCommand, DesiredStateIn, DesiredStateOut, HealthPayload


def _utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _parse_dt(value: str | None) -> datetime | None:
    if not value:
        return None
    return datetime.fromisoformat(value)


class Store:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._init_db()

    def connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.path)
        conn.row_factory = sqlite3.Row
        return conn

    def _init_db(self) -> None:
        with self.connect() as conn:
            conn.executescript(
                """
                CREATE TABLE IF NOT EXISTS devices (
                    device_id TEXT PRIMARY KEY,
                    last_seen_at TEXT,
                    last_health_json TEXT NOT NULL DEFAULT '{}',
                    last_ack_json TEXT NOT NULL DEFAULT '{}'
                );

                CREATE TABLE IF NOT EXISTS desired_states (
                    device_id TEXT PRIMARY KEY,
                    sequence INTEGER NOT NULL,
                    updated_at TEXT NOT NULL,
                    config_json TEXT NOT NULL DEFAULT '{}',
                    command_json TEXT NOT NULL DEFAULT '{}'
                );
                """
            )

    def upsert_health(self, device_id: str, payload: HealthPayload) -> None:
        with self.connect() as conn:
            conn.execute(
                """
                INSERT INTO devices (device_id, last_seen_at, last_health_json)
                VALUES (?, ?, ?)
                ON CONFLICT(device_id) DO UPDATE SET
                    last_seen_at = excluded.last_seen_at,
                    last_health_json = excluded.last_health_json
                """,
                (
                    device_id,
                    _utc_now_iso(),
                    payload.model_dump_json(),
                ),
            )

    def get_desired(self, device_id: str) -> DesiredStateOut:
        with self.connect() as conn:
            row = conn.execute(
                "SELECT * FROM desired_states WHERE device_id = ?",
                (device_id,),
            ).fetchone()

        if not row:
            return DesiredStateOut(
                device_id=device_id,
                sequence=0,
                updated_at=datetime.fromtimestamp(0, tz=timezone.utc),
                config={},
                command=ControlCommand(),
            )

        return DesiredStateOut(
            device_id=device_id,
            sequence=int(row["sequence"]),
            updated_at=_parse_dt(row["updated_at"]) or datetime.fromtimestamp(0, tz=timezone.utc),
            config=json.loads(row["config_json"] or "{}"),
            command=ControlCommand.model_validate(json.loads(row["command_json"] or "{}")),
        )

    def set_desired(self, device_id: str, desired: DesiredStateIn) -> DesiredStateOut:
        current = self.get_desired(device_id)
        next_sequence = current.sequence + 1
        updated_at = _utc_now_iso()
        with self.connect() as conn:
            conn.execute(
                """
                INSERT INTO desired_states (device_id, sequence, updated_at, config_json, command_json)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(device_id) DO UPDATE SET
                    sequence = excluded.sequence,
                    updated_at = excluded.updated_at,
                    config_json = excluded.config_json,
                    command_json = excluded.command_json
                """,
                (
                    device_id,
                    next_sequence,
                    updated_at,
                    json.dumps(desired.config, ensure_ascii=False),
                    desired.command.model_dump_json(),
                ),
            )
        return self.get_desired(device_id)

    def ack(self, device_id: str, payload: AckPayload) -> None:
        body = payload.model_dump()
        body["ack_at"] = _utc_now_iso()
        with self.connect() as conn:
            conn.execute(
                """
                INSERT INTO devices (device_id, last_seen_at, last_ack_json)
                VALUES (?, ?, ?)
                ON CONFLICT(device_id) DO UPDATE SET
                    last_seen_at = excluded.last_seen_at,
                    last_ack_json = excluded.last_ack_json
                """,
                (device_id, _utc_now_iso(), json.dumps(body, ensure_ascii=False)),
            )

    def get_device(self, device_id: str) -> dict[str, Any]:
        desired = self.get_desired(device_id)
        with self.connect() as conn:
            row = conn.execute(
                "SELECT * FROM devices WHERE device_id = ?",
                (device_id,),
            ).fetchone()

        if not row:
            return {
                "device_id": device_id,
                "last_seen_at": None,
                "last_health": {},
                "desired": desired.model_dump(mode="json"),
                "last_ack": {},
            }

        return {
            "device_id": device_id,
            "last_seen_at": row["last_seen_at"],
            "last_health": json.loads(row["last_health_json"] or "{}"),
            "desired": desired.model_dump(mode="json"),
            "last_ack": json.loads(row["last_ack_json"] or "{}"),
        }

    def list_devices(self) -> list[dict[str, Any]]:
        with self.connect() as conn:
            rows = conn.execute(
                "SELECT device_id, last_seen_at, last_ack_json FROM devices ORDER BY last_seen_at DESC"
            ).fetchall()
        return [
            {
                "device_id": row["device_id"],
                "last_seen_at": row["last_seen_at"],
                "last_ack": json.loads(row["last_ack_json"] or "{}"),
            }
            for row in rows
        ]
