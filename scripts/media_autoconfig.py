#!/usr/bin/env python3
"""Detecta y selecciona automáticamente las fuentes de video y audio.

El módulo no depende de paquetes Python externos. Se puede ejecutar desde los
servicios systemd o importar desde el health reporter y las pruebas.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import shlex
import shutil
import stat
import subprocess
from pathlib import Path
from typing import Callable


Runner = Callable[[list[str]], str]
DEFAULT_ENV = Path("/etc/streaming.env")
VIDEO_DEVICE_RE = re.compile(r"^/dev/video(\d+)$")
FFMPEG_PIXEL_FORMATS = {
    "YUYV": "yuyv422",
    "UYVY": "uyvy422",
    "MJPG": "mjpeg",
    "MJPEG": "mjpeg",
    "H264": "h264",
}


def command_runner(cmd: list[str]) -> str:
    try:
        return subprocess.check_output(cmd, stderr=subprocess.DEVNULL, text=True, timeout=5)
    except Exception:
        return ""


def read_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    try:
        for raw in path.read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            values[key.strip()] = value.strip()
    except OSError:
        pass
    return values


def write_env(path: Path, updates: dict[str, str]) -> None:
    """Actualiza solo las claves de detección y conserva secretos y comentarios."""
    lines: list[str] = []
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        pass

    seen: set[str] = set()
    output: list[str] = []
    for line in lines:
        if not line or line.lstrip().startswith("#") or "=" not in line:
            output.append(line)
            continue
        key, _, _ = line.partition("=")
        key = key.strip()
        if key in updates:
            output.append(f"{key}={updates[key]}")
            seen.add(key)
        else:
            output.append(line)
    for key, value in updates.items():
        if key not in seen:
            output.append(f"{key}={value}")

    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text("\n".join(output).rstrip() + "\n", encoding="utf-8")
    if path.exists():
        previous = path.stat()
        try:
            os.chown(temporary, previous.st_uid, previous.st_gid)
        except PermissionError:
            pass
        os.chmod(temporary, stat.S_IMODE(previous.st_mode))
    else:
        os.chmod(temporary, 0o640)
    temporary.replace(path)


def parse_v4l2_modes(output: str) -> list[dict[str, str | int]]:
    """Parsea --list-formats-ext sin asumir un orden concreto de formatos."""
    modes: list[dict[str, str | int]] = []
    current_format = ""
    current_size: tuple[int, int] | None = None
    for raw in output.splitlines():
        line = raw.strip()
        format_match = re.search(r'''['"]([A-Za-z0-9]+)['"]''', line) if line.startswith("[") else None
        if format_match:
            current_format = format_match.group(1).upper()
            current_size = None
            continue
        size_match = re.search(r"Size:\s+Discrete\s+(\d+)x(\d+)", line)
        if size_match:
            current_size = (int(size_match.group(1)), int(size_match.group(2)))
            continue
        interval_match = re.search(
            r"\((\d+(?:\.\d+)?)(?:-\d+(?:\.\d+)?)?\s*fps\)", line
        )
        if interval_match and current_format and current_size:
            fps = float(interval_match.group(1))
            modes.append({
                "format": current_format,
                "width": current_size[0],
                "height": current_size[1],
                "fps": int(round(fps)) if fps.is_integer() else fps,
            })
    return modes


def _video_score(name: str, device: str) -> int:
    text = f"{name} {device}".lower()
    if any(word in text for word in ("ms210x", "easycap", "easiercap", "av to usb", "usbtv", "stk1160")):
        return 100
    if any(word in text for word in ("uvc", "webcam", "camera", "c920")):
        return 50
    return 20


def _best_mode(modes: list[dict[str, str | int]], easycap: bool) -> dict[str, str | int] | None:
    if not modes:
        return None

    def score(mode: dict[str, str | int]) -> tuple[int, int, int, int]:
        pixel_format = str(mode["format"]).upper()
        width, height, fps = int(mode["width"]), int(mode["height"]), float(mode["fps"])
        format_score = {"YUYV": 40, "UYVY": 35, "MJPG": 20, "MJPEG": 20}.get(pixel_format, 0)
        ntsc_score = 20 if (width, height) == (720, 480) else 0
        fps_score = 20 if abs(fps - 30) < 0.1 else 0
        if not easycap:
            ntsc_score = 0
        # Prefer useful modes without requesting a larger input than necessary.
        size_score = min(width * height, 1920 * 1080) // 10000
        return format_score + ntsc_score + fps_score, size_score, int(fps), width * height

    return max(modes, key=score)


def list_video_devices(runner: Runner = command_runner, devices: list[str] | None = None) -> list[dict]:
    if devices is None:
        listed = runner(["v4l2-ctl", "--list-devices"])
        devices = sorted(set(re.findall(r"/dev/video\d+", listed)))
        if not devices:
            devices = sorted(glob.glob("/dev/video*"))
    found: list[dict] = []
    for device in devices:
        match = VIDEO_DEVICE_RE.match(device)
        if not match or int(match.group(1)) >= 10:
            continue
        info = runner(["v4l2-ctl", "--device", device, "--info"])
        if "Video Capture" not in info:
            continue
        name_match = re.search(r"Card type\s*:\s*(.+)", info)
        name = name_match.group(1).strip() if name_match else device
        formats = runner(["v4l2-ctl", "--device", device, "--list-formats-ext"])
        modes = parse_v4l2_modes(formats)
        if not modes:
            continue
        easycap = _video_score(name, device) >= 100
        found.append({
            "device": device,
            "name": name,
            "modes": modes,
            "easycap": easycap,
            "score": _video_score(name, device),
        })
    return sorted(found, key=lambda item: (-int(item["score"]), str(item["device"])))


def card_ids() -> dict[str, str]:
    ids: dict[str, str] = {}
    for path in glob.glob("/proc/asound/card*/id"):
        match = re.search(r"card(\d+)", path)
        if not match:
            continue
        try:
            ids[match.group(1)] = Path(path).read_text(encoding="utf-8").strip()
        except OSError:
            pass
    return ids


def _audio_kind(name: str, card_id: str) -> str:
    text = f"{name} {card_id}".lower()
    if "boya" in text or "boyalink" in text:
        return "boya"
    if any(word in text for word in ("webcam", "camera", "c920", "uvc")):
        return "webcam"
    return "usb"


def list_audio_devices(
    runner: Runner = command_runner,
    ids: dict[str, str] | None = None,
    output: str | None = None,
) -> list[dict]:
    ids = ids if ids is not None else card_ids()
    output = runner(["arecord", "-l"]) if output is None else output
    devices: list[dict] = []
    for line in output.splitlines():
        match = re.match(r"card (\d+).*device (\d+)[^[]*\[([^\]]+)\]", line)
        if not match:
            continue
        card, device, name = match.group(1), match.group(2), match.group(3).strip()
        card_id = ids.get(card, "")
        kind = _audio_kind(name, card_id)
        devices.append({
            "device": f"plughw:CARD={card_id},DEV={device}" if card_id else f"plughw:{card},{device}",
            "name": name,
            "card": card,
            "device_number": device,
            "card_id": card_id,
            "kind": kind,
        })
    return devices


def _audio_score(item: dict, selected_video: dict | None) -> tuple[int, int]:
    kind = str(item["kind"])
    if kind == "boya":
        return 400, 0
    text = f"{item.get('name', '')} {item.get('card_id', '')}".lower()
    video_text = f"{(selected_video or {}).get('name', '')}".lower()
    easycap = bool(selected_video and selected_video.get("easycap"))
    if easycap and any(word in text for word in ("ms210x", "usb audio", "av to usb")):
        return 300, 0
    if kind == "webcam":
        return 200, 0
    if easycap and "usb" in text:
        return 250, 1
    return 100, 1


def _libcamera_available() -> bool:
    return shutil.which("libcamera-vid") is not None


def detect_media(
    env: dict[str, str] | None = None,
    runner: Runner = command_runner,
    video_devices: list[str] | None = None,
    audio_output: str | None = None,
    audio_ids: dict[str, str] | None = None,
    libcamera_available: bool | None = None,
) -> dict:
    env = env or {}
    source = env.get("VIDEO_SOURCE", "auto").strip().lower() or "auto"
    configured_video = env.get("VIDEO_DEVICE", "").strip()
    usb_listing = runner(["lsusb"])
    v4l2_listing = runner(["v4l2-ctl", "--list-devices"])
    devices = list_video_devices(runner, video_devices)
    selected: dict | None = None
    if source == "v4l2" and configured_video:
        selected = next((item for item in devices if item["device"] == configured_video), None)
    elif source == "auto" and configured_video:
        # VIDEO_DEVICE puede ser un resultado cacheado, pero no debe impedir
        # que una EasyCAP recién conectada tome prioridad sobre él.
        selected = next((item for item in devices if item["device"] == configured_video and item.get("easycap")), None)
    if source != "libcamera" and selected is None and devices:
        selected = devices[0]

    if source == "libcamera" or (selected is None and (libcamera_available if libcamera_available is not None else _libcamera_available())):
        video = {
            "backend": "libcamera",
            "device": "",
            "name": "Cámara CSI/libcamera",
            "format": "H264",
            "width": int(env.get("STREAM_WIDTH", "1280") or 1280),
            "height": int(env.get("STREAM_HEIGHT", "720") or 720),
            "fps": int(env.get("STREAM_FPS", "30") or 30),
            "easycap": False,
            "reason": "sin captura V4L2 válida; fallback a libcamera",
        }
    elif selected:
        mode = _best_mode(selected["modes"], bool(selected["easycap"]))
        video = {
            "backend": "v4l2",
            "device": selected["device"],
            "name": selected["name"],
            "format": mode["format"] if mode else "",
            "width": mode["width"] if mode else 0,
            "height": mode["height"] if mode else 0,
            "fps": mode["fps"] if mode else 0,
            "easycap": bool(selected["easycap"]),
            "reason": "EasyCAP/AV priorizada" if selected["easycap"] else "captura V4L2 USB disponible",
        }
    else:
        video = {
            "backend": "none", "device": "", "name": "", "format": "",
            "width": 0, "height": 0, "fps": 0, "easycap": False,
            "reason": "no se detectó una fuente de video válida",
        }

    audio_source = env.get("AUDIO_SOURCE", "auto").strip().lower() or "auto"
    audio_configured = env.get("AUDIO_DEVICE", "").strip()
    audio = list_audio_devices(runner, audio_ids, audio_output)
    chosen_audio = None
    if audio_source == "manual" and audio_configured:
        chosen_audio = next((item for item in audio if item["device"] == audio_configured), None)
    elif audio_source != "manual":
        chosen_audio = max(audio, key=lambda item: _audio_score(item, selected), default=None)

    if chosen_audio:
        reason = {
            "boya": "BOYA/BOYALINK tiene prioridad",
            "webcam": "no hay BOYA ni audio EasyCAP; se usa micrófono de webcam",
            "usb": "se usa audio USB disponible",
        }.get(str(chosen_audio["kind"]), "audio seleccionado")
        if selected and selected.get("easycap") and chosen_audio["kind"] == "usb":
            reason = "audio ALSA asociado a la EasyCAP"
        audio_result = {
            "device": chosen_audio["device"],
            "name": chosen_audio["name"],
            "card_id": chosen_audio["card_id"],
            "kind": chosen_audio["kind"],
            "channels": int(env.get("AUDIO_CHANNELS", "1") or 1),
            "rate": 48000 if chosen_audio["kind"] == "boya" else int(env.get("AUDIO_RATE", "44100") or 44100),
            "reason": "selección manual" if audio_source == "manual" else reason,
        }
    else:
        audio_result = {
            "device": "", "name": "", "card_id": "", "kind": "none",
            "channels": int(env.get("AUDIO_CHANNELS", "1") or 1), "rate": 44100,
            "reason": "no hay entrada ALSA válida; se usará silencio AAC",
        }

    return {
        "video": video,
        "audio": audio_result,
        "video_devices": [
            {key: value for key, value in item.items() if key != "modes"}
            for item in devices
        ],
        "audio_devices": audio,
        "usb_devices": usb_listing.splitlines(),
        "v4l2_devices": v4l2_listing.splitlines(),
    }


def shell_env(media: dict) -> dict[str, str]:
    video, audio = media["video"], media["audio"]
    return {
        "VIDEO_BACKEND": str(video["backend"]),
        "VIDEO_DEVICE_RESOLVED": str(video["device"]),
        "VIDEO_INPUT_FORMAT": FFMPEG_PIXEL_FORMATS.get(
            str(video["format"]).upper(), str(video["format"]).lower()
        ),
        "VIDEO_INPUT_WIDTH": str(video["width"]),
        "VIDEO_INPUT_HEIGHT": str(video["height"]),
        "VIDEO_INPUT_FPS": str(video["fps"]),
        "VIDEO_NAME": str(video["name"]),
        "VIDEO_DETECTION_REASON": str(video["reason"]),
        "AUDIO_DEVICE_RESOLVED": str(audio["device"]),
        "AUDIO_KIND": str(audio["kind"]),
        "AUDIO_NAME": str(audio["name"]),
        "AUDIO_RATE_RESOLVED": str(audio["rate"]),
        "AUDIO_DETECTION_REASON": str(audio["reason"]),
        "MEDIA_AUDIO_AVAILABLE": "true" if audio["device"] else "false",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Detecta EasyCAP, cámaras V4L2 y audio ALSA")
    parser.add_argument("--env", type=Path, default=DEFAULT_ENV)
    parser.add_argument("--json", action="store_true", help="imprime el diagnóstico estructurado")
    parser.add_argument("--shell-env", action="store_true", help="imprime variables KEY=value")
    parser.add_argument("--persist", action="store_true", help="guarda la selección resuelta en streaming.env")
    parser.add_argument("--video-source", choices=("auto", "v4l2", "libcamera"))
    parser.add_argument("--video-device")
    parser.add_argument("--audio-source", choices=("auto", "manual"))
    parser.add_argument("--audio-device")
    args = parser.parse_args()

    values = read_env(args.env)
    if args.video_source:
        values["VIDEO_SOURCE"] = args.video_source
    if args.video_device is not None:
        values["VIDEO_DEVICE"] = args.video_device
    if args.audio_source:
        values["AUDIO_SOURCE"] = args.audio_source
    if args.audio_device is not None:
        values["AUDIO_DEVICE"] = args.audio_device
    media = detect_media(values)
    if args.persist:
        resolved = shell_env(media)
        updates = {
            "VIDEO_DEVICE": resolved["VIDEO_DEVICE_RESOLVED"],
            "VIDEO_INPUT_FORMAT": resolved["VIDEO_INPUT_FORMAT"],
            "VIDEO_INPUT_WIDTH": resolved["VIDEO_INPUT_WIDTH"],
            "VIDEO_INPUT_HEIGHT": resolved["VIDEO_INPUT_HEIGHT"],
            "VIDEO_INPUT_FPS": resolved["VIDEO_INPUT_FPS"],
            "AUDIO_DEVICE": resolved["AUDIO_DEVICE_RESOLVED"],
            "AUDIO_RATE": resolved["AUDIO_RATE_RESOLVED"],
            "STREAM_NO_AUDIO": "false" if resolved["MEDIA_AUDIO_AVAILABLE"] == "true" else "true",
        }
        write_env(args.env, updates)

    if args.shell_env:
        for key, value in shell_env(media).items():
            print(f"{key}={shlex.quote(value)}")
    elif args.json:
        print(json.dumps(media, ensure_ascii=False, indent=2))
    else:
        video, audio = media["video"], media["audio"]
        print(f"video: {video['backend']} {video['device'] or video['name']} {video['format']} {video['width']}x{video['height']}@{video['fps']}")
        print(f"video reason: {video['reason']}")
        print(f"audio: {audio['device'] or 'silencio AAC'} ({audio['name'] or 'none'})")
        print(f"audio reason: {audio['reason']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
