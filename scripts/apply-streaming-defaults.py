#!/usr/bin/env python3
"""
Aplica defaults versionados sobre /etc/streaming.env preservando secretos.

Uso normal en la Raspberry Pi:
  sudo ./scripts/apply-streaming-defaults.py

El archivo systemd/default.streaming.env define la configuracion base. Este
script conserva STREAM_KEY/STREAM_KEY_META/RTMP_URL_SECONDARY locales y, si
detecta una URL antigua de YouTube con la key embebida, extrae la key para
reutilizarla sin dejarla incrustada en RTMP_URL.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import stat
import sys
from datetime import datetime
from pathlib import Path


REPO_DIR = Path(__file__).resolve().parents[1]
DEFAULT_DEFAULTS = REPO_DIR / "systemd" / "default.streaming.env"
DEFAULT_ENV = Path("/etc/streaming.env")
YOUTUBE_BASE = "rtmp://a.rtmp.youtube.com/live2"
PRESERVED_KEYS = ("STREAM_KEY", "STREAM_KEY_META", "RTMP_URL_SECONDARY")
SENSITIVE_KEYS = PRESERVED_KEYS
PLACEHOLDER_RE = re.compile(r"(xxxx|stream_key|tu_stream_key|aqui)", re.I)
STREAM_KEY_RE = re.compile(r"^[A-Za-z0-9_-]+$")


def parse_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    with path.open(encoding="utf-8") as fh:
        for raw_line in fh:
            line = raw_line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            values[key.strip()] = value.strip().strip('"').strip("'")
    return values


def format_env(values: dict[str, str]) -> str:
    header = [
        "# Generado por scripts/apply-streaming-defaults.py",
        "# Defaults: systemd/default.streaming.env",
        "# No subir este archivo si contiene claves reales.",
    ]
    lines = header + [f"{key}={value}" for key, value in values.items()]
    return "\n".join(lines) + "\n"


def redacted_values(values: dict[str, str]) -> dict[str, str]:
    redacted = dict(values)
    for key in SENSITIVE_KEYS:
        if redacted.get(key):
            redacted[key] = "<redacted>"
    return redacted


def is_placeholder(value: str) -> bool:
    return not value or bool(PLACEHOLDER_RE.search(value))


def extract_youtube_key(rtmp_url: str) -> str:
    value = rtmp_url.strip().rstrip("/")
    if not value or "youtube.com/live2" not in value:
        return ""
    if value == YOUTUBE_BASE:
        return ""
    key = value.rsplit("/", 1)[-1]
    if is_placeholder(key) or not STREAM_KEY_RE.match(key):
        return ""
    return key


def build_merged(defaults: dict[str, str], current: dict[str, str]) -> tuple[dict[str, str], dict[str, bool]]:
    merged = dict(defaults)
    report = {
        "stream_key_preserved": False,
        "stream_key_extracted": False,
        "stream_key_meta_preserved": False,
        "rtmp_url_secondary_preserved": False,
    }

    stream_key = current.get("STREAM_KEY", "").strip()
    if is_placeholder(stream_key):
        stream_key = ""

    if not stream_key:
        extracted = extract_youtube_key(current.get("RTMP_URL", ""))
        if extracted:
            stream_key = extracted
            report["stream_key_extracted"] = True

    for key in PRESERVED_KEYS:
        value = current.get(key, "").strip()
        if is_placeholder(value):
            value = ""
        if key == "STREAM_KEY":
            value = stream_key
        merged[key] = value

    # Forzar el flujo base de YouTube, pero con la key separada para que el
    # portal y los scripts puedan reutilizar el token local sin exponerlo.
    merged["RTMP_URL"] = defaults.get("RTMP_URL", YOUTUBE_BASE).rstrip("/")
    merged["STREAM_PLATFORM"] = defaults.get("STREAM_PLATFORM", "youtube")

    report["stream_key_preserved"] = bool(merged.get("STREAM_KEY"))
    report["stream_key_meta_preserved"] = bool(merged.get("STREAM_KEY_META"))
    report["rtmp_url_secondary_preserved"] = bool(merged.get("RTMP_URL_SECONDARY"))
    return merged, report


def copy_metadata(src: Path, dst: Path) -> None:
    if not src.exists():
        os.chmod(dst, 0o640)
        return
    st = src.stat()
    os.chown(dst, st.st_uid, st.st_gid)
    os.chmod(dst, stat.S_IMODE(st.st_mode))


def write_env(path: Path, content: str, dry_run: bool) -> Path | None:
    backup = None
    if dry_run:
        return None

    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        stamp = datetime.now().strftime("%Y%m%d%H%M%S")
        backup = path.with_name(f"{path.name}.bak.{stamp}")
        shutil.copy2(path, backup)

    tmp = path.with_name(f".{path.name}.tmp")
    tmp.write_text(content, encoding="utf-8")
    copy_metadata(path, tmp)
    os.replace(tmp, path)
    return backup


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Aplica systemd/default.streaming.env preservando claves locales."
    )
    parser.add_argument("--defaults", type=Path, default=DEFAULT_DEFAULTS)
    parser.add_argument("--env", type=Path, default=DEFAULT_ENV)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    if not args.defaults.exists():
        print(f"ERROR: no existe defaults: {args.defaults}", file=sys.stderr)
        return 1

    defaults = parse_env(args.defaults)
    if not defaults:
        print(f"ERROR: defaults vacio o invalido: {args.defaults}", file=sys.stderr)
        return 1

    current = parse_env(args.env)
    merged, report = build_merged(defaults, current)
    content = format_env(merged)

    if args.dry_run:
        print(format_env(redacted_values(merged)))
        print("Resumen:")
    else:
        backup = write_env(args.env, content, dry_run=False)
        print(f"Archivo actualizado: {args.env}")
        if backup:
            print(f"Backup creado: {backup}")
        print("Resumen:")

    print(f"  STREAM_KEY preservado/extractado: {'si' if report['stream_key_preserved'] else 'no'}")
    print(f"  STREAM_KEY extraido desde RTMP_URL viejo: {'si' if report['stream_key_extracted'] else 'no'}")
    print(f"  STREAM_KEY_META preservado: {'si' if report['stream_key_meta_preserved'] else 'no'}")
    print(f"  RTMP_URL_SECONDARY preservado: {'si' if report['rtmp_url_secondary_preserved'] else 'no'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
