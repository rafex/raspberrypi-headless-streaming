#!/usr/bin/env python3
"""
Selecciona audio base para streaming antes de arrancar:
1. BOYA / BOYALINK si está conectado
2. audio USB asociado a EasyCAP/MS210x
3. micrófono de webcam
4. primer micrófono USB disponible
5. silencio AAC si no hay micrófono

Actualiza /etc/streaming.env sin tocar RTMP_URL ni stream keys.
"""

from __future__ import annotations

import argparse
import glob
import os
import re
import stat
import subprocess
from pathlib import Path


DEFAULT_ENV = Path("/etc/streaming.env")


def run(cmd: list[str]) -> str:
    try:
        return subprocess.check_output(cmd, stderr=subprocess.DEVNULL, text=True, timeout=5)
    except Exception:
        return ""


def card_ids() -> dict[str, str]:
    ids: dict[str, str] = {}
    for path in glob.glob("/proc/asound/card*/id"):
        m = re.search(r"card(\d+)", path)
        if not m:
            continue
        try:
            ids[m.group(1)] = Path(path).read_text(encoding="utf-8").strip()
        except OSError:
            pass
    return ids


def kind_for(name: str, card_id: str) -> str:
    text = f"{name} {card_id}".lower()
    if "boya" in text or "boyalink" in text:
        return "boya"
    if "webcam" in text or "camera" in text or "c920" in text or "uvc" in text:
        return "webcam"
    return "usb"


def list_mics() -> list[dict[str, str | int]]:
    output = run(["arecord", "-l"])
    ids = card_ids()
    mics: list[dict[str, str | int]] = []
    for line in output.splitlines():
        if not line.startswith("card"):
            continue
        m = re.match(r"card (\d+).*device (\d+)[^[]*\[([^\]]+)\]", line)
        if not m:
            continue
        card, device, name = m.group(1), m.group(2), m.group(3).strip()
        card_id = ids.get(card, "")
        dev = f"plughw:CARD={card_id},DEV={device}" if card_id else f"plughw:{card},{device}"
        kind = kind_for(name, card_id)
        if kind == "boya":
            priority = 0
        elif "ms210x" in f"{name} {card_id}".lower():
            priority = 1
        elif kind == "webcam":
            priority = 2
        else:
            priority = 3
        rate = 48000 if kind == "boya" else 44100
        mics.append({
            "dev": dev,
            "name": name,
            "card_id": card_id,
            "kind": kind,
            "priority": priority,
            "rate": rate,
        })
    return sorted(mics, key=lambda item: int(item["priority"]))


def read_env(path: Path) -> tuple[list[str], dict[str, str]]:
    lines: list[str] = []
    values: dict[str, str] = {}
    if path.exists():
        lines = path.read_text(encoding="utf-8").splitlines()
    for line in lines:
        if not line or line.lstrip().startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip()
    return lines, values


def write_env(path: Path, updates: dict[str, str]) -> None:
    lines, values = read_env(path)
    values.update(updates)
    seen: set[str] = set()
    out: list[str] = []
    for line in lines:
        if not line or line.lstrip().startswith("#") or "=" not in line:
            out.append(line)
            continue
        key, _, _value = line.partition("=")
        key = key.strip()
        if key in updates:
            out.append(f"{key}={updates[key]}")
            seen.add(key)
        else:
            out.append(line)
    for key in updates:
        if key not in seen:
            out.append(f"{key}={updates[key]}")
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text("\n".join(out).rstrip() + "\n", encoding="utf-8")
    if path.exists():
        st = path.stat()
        os.chown(tmp, st.st_uid, st.st_gid)
        os.chmod(tmp, stat.S_IMODE(st.st_mode))
    else:
        os.chmod(tmp, 0o640)
    tmp.replace(path)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--env", type=Path, default=DEFAULT_ENV)
    parser.add_argument("--channels", default="1")
    args = parser.parse_args()

    mics = list_mics()
    if mics:
        chosen = mics[0]
        updates = {
            "AUDIO_DEVICE": str(chosen["dev"]),
            "AUDIO_SOURCE": "auto",
            "AUDIO_RATE": str(chosen["rate"]),
            "AUDIO_CHANNELS": str(args.channels),
            "STREAM_NO_AUDIO": "false",
        }
        write_env(args.env, updates)
        print(
            f"audio selected: {chosen['kind']} {chosen['name']} "
            f"dev={chosen['dev']} rate={chosen['rate']}"
        )
        return 0

    write_env(args.env, {
        "AUDIO_DEVICE": "",
        "AUDIO_SOURCE": "auto",
        "AUDIO_RATE": "44100",
        "AUDIO_CHANNELS": str(args.channels),
        "STREAM_NO_AUDIO": "true",
    })
    print("audio selected: none; STREAM_NO_AUDIO=true")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
