#!/usr/bin/env python3
"""
WiFi bootstrap para Raspberry Pi headless.

Lee un TOML con redes candidatas. Si no puede conectarse a ninguna, levanta un
hotspot/AP con un formulario HTTP mínimo para agregar una red y reintentar.
Mantiene un loop de monitoreo: si la conexión se pierde, vuelve a intentar las
redes configuradas y finalmente regresa a modo AP.
"""

from __future__ import annotations

import argparse
import html
import os
import signal
import socket
import subprocess
import sys
import tempfile
import textwrap
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover - Python < 3.11
    print("ERROR: requiere Python 3.11+ para leer TOML (tomllib).", file=sys.stderr)
    sys.exit(1)


DEFAULT_CONFIG = Path("/etc/raspi-streaming/wifi-networks.toml")
STATE_DIR = Path("/run/raspi-wifi-bootstrap")
DEFAULT_COUNTRY = "MX"


def log(msg: str) -> None:
    print(f"[wifi-bootstrap] {msg}", flush=True)


def run(cmd: list[str], *, check: bool = False, input_text: str | None = None) -> subprocess.CompletedProcess:
    log("+ " + " ".join(cmd))
    return subprocess.run(
        cmd,
        input=input_text,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=check,
    )


def command_exists(cmd: str) -> bool:
    return subprocess.call(["sh", "-c", f"command -v {cmd} >/dev/null 2>&1"]) == 0


def load_config(path: Path) -> dict:
    if not path.exists():
        return {}
    with path.open("rb") as fh:
        return tomllib.load(fh)


def toml_quote(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def write_config(path: Path, cfg: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    hotspot = cfg.get("hotspot", {})
    networks = cfg.get("networks", [])
    lines = [
        "# Editado por raspi-wifi-bootstrap.",
        "",
        "[hotspot]",
        f"interface = {toml_quote(str(hotspot.get('interface', 'wlan0')))}",
        f"ssid = {toml_quote(str(hotspot.get('ssid', 'RaspiStreaming-Setup')))}",
        f"password = {toml_quote(str(hotspot.get('password', 'raspistream')))}",
        f"country = {toml_quote(str(hotspot.get('country', DEFAULT_COUNTRY)))}",
        f"channel = {int(hotspot.get('channel', 6))}",
        f"address = {toml_quote(str(hotspot.get('address', '10.41.0.1/24')))}",
        f"dhcp_start = {toml_quote(str(hotspot.get('dhcp_start', '10.41.0.20')))}",
        f"dhcp_end = {toml_quote(str(hotspot.get('dhcp_end', '10.41.0.80')))}",
        f"portal_port = {int(hotspot.get('portal_port', 8088))}",
        "",
    ]
    for net in networks:
        lines.extend([
            "[[networks]]",
            f"ssid = {toml_quote(str(net.get('ssid', '')))}",
            f"password = {toml_quote(str(net.get('password', '')))}",
            f"priority = {int(net.get('priority', 100))}",
            f"hidden = {'true' if bool(net.get('hidden', False)) else 'false'}",
            "",
        ])
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text("\n".join(lines), encoding="utf-8")
    os.chmod(tmp, 0o600)
    tmp.replace(path)


def cfg_hotspot(cfg: dict) -> dict:
    hotspot = dict(cfg.get("hotspot", {}))
    hotspot.setdefault("interface", "wlan0")
    hotspot.setdefault("ssid", "RaspiStreaming-Setup")
    hotspot.setdefault("password", "raspistream")
    hotspot.setdefault("country", DEFAULT_COUNTRY)
    hotspot.setdefault("channel", 6)
    hotspot.setdefault("address", "10.41.0.1/24")
    hotspot.setdefault("dhcp_start", "10.41.0.20")
    hotspot.setdefault("dhcp_end", "10.41.0.80")
    hotspot.setdefault("portal_port", 8088)
    return hotspot


def cfg_networks(cfg: dict) -> list[dict]:
    networks = cfg.get("networks", [])
    if not isinstance(networks, list):
        return []
    cleaned = []
    for raw in networks:
        ssid = str(raw.get("ssid", "")).strip()
        if not ssid:
            continue
        cleaned.append({
            "ssid": ssid,
            "password": str(raw.get("password", "")),
            "priority": int(raw.get("priority", 100)),
            "hidden": bool(raw.get("hidden", False)),
        })
    return sorted(cleaned, key=lambda item: item["priority"])


def stop_processes() -> None:
    for pattern in ("wpa_supplicant.*raspi-wifi-bootstrap", "hostapd.*raspi-wifi-bootstrap", "dnsmasq.*raspi-wifi-bootstrap"):
        run(["pkill", "-f", pattern], check=False)


def stop_network_managers(iface: str) -> None:
    # Best-effort: no fallar si el sistema no usa alguno de estos servicios.
    for service in ("NetworkManager.service", "wpa_supplicant.service"):
        run(["systemctl", "stop", service], check=False)
    run(["rfkill", "unblock", "wifi"], check=False)
    run(["ip", "link", "set", iface, "up"], check=False)


def has_ipv4(iface: str) -> bool:
    out = run(["ip", "-4", "-o", "addr", "show", "dev", iface], check=False).stdout
    return "inet " in out


def default_route_iface() -> str:
    out = run(["ip", "route", "show", "default"], check=False).stdout
    for line in out.splitlines():
        parts = line.split()
        if "dev" in parts:
            return parts[parts.index("dev") + 1]
    return ""


def connected(iface: str) -> bool:
    return has_ipv4(iface) and default_route_iface() == iface


def wpa_psk_block(ssid: str, password: str, hidden: bool) -> str:
    if password:
        proc = run(["wpa_passphrase", ssid], input_text=password + "\n", check=False)
        block = proc.stdout
        if "network={" not in block:
            raise RuntimeError(f"wpa_passphrase no pudo procesar SSID {ssid!r}")
    else:
        block = textwrap.dedent(f"""
        network={{
            ssid={toml_quote(ssid)}
            key_mgmt=NONE
        }}
        """)
    if hidden:
        block = block.rstrip().replace("\n}", "\n\tscan_ssid=1\n}") + "\n"
    return block


def connect_network(iface: str, country: str, net: dict) -> bool:
    stop_processes()
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    conf = STATE_DIR / "wpa_supplicant.conf"
    conf.write_text(
        f"ctrl_interface=/run/wpa_supplicant\nupdate_config=0\ncountry={country}\n\n"
        + wpa_psk_block(net["ssid"], net["password"], net["hidden"]),
        encoding="utf-8",
    )
    os.chmod(conf, 0o600)

    run(["ip", "addr", "flush", "dev", iface], check=False)
    run(["ip", "link", "set", iface, "up"], check=False)
    run(["wpa_supplicant", "-B", "-P", str(STATE_DIR / "wpa_supplicant.pid"), "-i", iface, "-c", str(conf)], check=False)

    deadline = time.time() + 18
    while time.time() < deadline:
        status = run(["wpa_cli", "-i", iface, "status"], check=False).stdout
        if "wpa_state=COMPLETED" in status:
            break
        time.sleep(1)
    else:
        log(f"No se pudo asociar a {net['ssid']!r}")
        return False

    run(["dhclient", "-v", iface], check=False)
    for _ in range(10):
        if connected(iface):
            log(f"Conectado a {net['ssid']!r}")
            return True
        time.sleep(1)
    log(f"Asociado a {net['ssid']!r}, pero sin ruta IPv4")
    return False


def try_all_networks(cfg_path: Path, cfg: dict) -> bool:
    hotspot = cfg_hotspot(cfg)
    iface = hotspot["interface"]
    country = hotspot["country"]
    stop_network_managers(iface)
    for net in cfg_networks(cfg):
        log(f"Probando WiFi: {net['ssid']!r}")
        if connect_network(iface, country, net):
            return True
    return False


def start_ap(cfg_path: Path, cfg: dict, retry_event: threading.Event) -> None:
    hotspot = cfg_hotspot(cfg)
    iface = hotspot["interface"]
    address = hotspot["address"]
    ap_ip = address.split("/")[0]
    portal_port = int(hotspot["portal_port"])

    stop_processes()
    stop_network_managers(iface)
    STATE_DIR.mkdir(parents=True, exist_ok=True)

    hostapd_conf = STATE_DIR / "hostapd.conf"
    dnsmasq_conf = STATE_DIR / "dnsmasq.conf"
    hostapd_conf.write_text(textwrap.dedent(f"""
        interface={iface}
        driver=nl80211
        ssid={hotspot['ssid']}
        hw_mode=g
        channel={hotspot['channel']}
        country_code={hotspot['country']}
        ieee80211n=1
        wmm_enabled=1
        auth_algs=1
        wpa=2
        wpa_passphrase={hotspot['password']}
        wpa_key_mgmt=WPA-PSK
        rsn_pairwise=CCMP
    """).strip() + "\n", encoding="utf-8")
    dnsmasq_conf.write_text(textwrap.dedent(f"""
        interface={iface}
        bind-interfaces
        dhcp-range={hotspot['dhcp_start']},{hotspot['dhcp_end']},255.255.255.0,12h
        address=/#/{ap_ip}
    """).strip() + "\n", encoding="utf-8")

    run(["ip", "addr", "flush", "dev", iface], check=False)
    run(["ip", "addr", "add", address, "dev", iface], check=False)
    run(["ip", "link", "set", iface, "up"], check=False)
    run(["dnsmasq", "--conf-file", str(dnsmasq_conf), "--pid-file", str(STATE_DIR / "dnsmasq.pid")], check=False)
    run(["hostapd", "-B", "-P", str(STATE_DIR / "hostapd.pid"), str(hostapd_conf)], check=False)

    log(f"Hotspot activo: SSID={hotspot['ssid']} portal=http://{ap_ip}:{portal_port}")
    server = build_portal_server(cfg_path, cfg, ap_ip, portal_port, retry_event)
    try:
        while not retry_event.is_set():
            server.handle_request()
    finally:
        server.server_close()
        stop_processes()


def build_portal_server(cfg_path: Path, cfg: dict, host: str, port: int, retry_event: threading.Event) -> ThreadingHTTPServer:
    class Handler(BaseHTTPRequestHandler):
        def _send(self, code: int, body: str, ctype: str = "text/html; charset=utf-8") -> None:
            data = body.encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self) -> None:  # noqa: N802
            current = load_config(cfg_path)
            networks = cfg_networks(current)
            rows = "".join(
                f"<li><strong>{html.escape(n['ssid'])}</strong> prioridad {n['priority']} {'hidden' if n['hidden'] else ''}</li>"
                for n in networks
            ) or "<li>No hay redes configuradas.</li>"
            self._send(200, f"""<!doctype html>
<html lang="es"><head><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Configurar WiFi</title>
<style>
body{{font-family:system-ui,sans-serif;margin:0;background:#101820;color:#f3f4f6}}
main{{max-width:440px;margin:auto;padding:20px}}input,button{{width:100%;padding:12px;margin:6px 0 14px;border-radius:6px;border:1px solid #334155;background:#17212f;color:#fff}}
button{{background:#2563eb;border:0;font-weight:700}}label{{color:#cbd5e1}}.muted{{color:#94a3b8;font-size:.9rem}}
</style></head><body><main>
<h1>Configurar WiFi</h1>
<p class="muted">Agrega una red para que la Raspi salga del modo hotspot.</p>
<form method="post" action="/save">
<label>SSID<input name="ssid" required autocomplete="off"></label>
<label>Password<input name="password" type="password" autocomplete="off"></label>
<label>Prioridad<input name="priority" type="number" value="10"></label>
<label><input name="hidden" type="checkbox" value="1" style="width:auto"> Red oculta</label>
<button>Guardar y reintentar</button>
</form>
<h2>Redes configuradas</h2><ul>{rows}</ul>
<form method="post" action="/retry"><button>Reintentar ahora</button></form>
</main></body></html>""")

        def do_POST(self) -> None:  # noqa: N802
            length = int(self.headers.get("Content-Length", "0"))
            form = urllib.parse.parse_qs(self.rfile.read(length).decode("utf-8"))
            if self.path == "/save":
                current = load_config(cfg_path)
                networks = cfg_networks(current)
                networks.append({
                    "ssid": form.get("ssid", [""])[0].strip(),
                    "password": form.get("password", [""])[0],
                    "priority": int(form.get("priority", ["10"])[0] or "10"),
                    "hidden": form.get("hidden", [""])[0] == "1",
                })
                current["networks"] = networks
                current["hotspot"] = cfg_hotspot(current)
                write_config(cfg_path, current)
                retry_event.set()
                self._send(200, "<html><body><p>Guardado. Reintentando conexion WiFi...</p></body></html>")
            elif self.path == "/retry":
                retry_event.set()
                self._send(200, "<html><body><p>Reintentando conexion WiFi...</p></body></html>")
            else:
                self._send(404, "not found", "text/plain")

        def log_message(self, fmt: str, *args) -> None:
            log(fmt % args)

    server = ThreadingHTTPServer((host, port), Handler)
    server.timeout = 1
    return server


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--monitor-interval", type=int, default=30)
    args = parser.parse_args()

    if os.geteuid() != 0:
        print("ERROR: ejecutar como root.", file=sys.stderr)
        return 1
    missing = [cmd for cmd in ("ip", "wpa_supplicant", "wpa_passphrase", "wpa_cli", "dhclient", "hostapd", "dnsmasq") if not command_exists(cmd)]
    if missing:
        print("ERROR: faltan dependencias: " + ", ".join(missing), file=sys.stderr)
        return 1

    stop = False

    def _stop(_signum, _frame):
        nonlocal stop
        stop = True
        stop_processes()

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)

    while not stop:
        cfg = load_config(args.config)
        hotspot = cfg_hotspot(cfg)
        iface = hotspot["interface"]

        if try_all_networks(args.config, cfg):
            while not stop and connected(iface):
                time.sleep(args.monitor_interval)
            if not stop:
                log("Conexion perdida; reintentando redes configuradas.")
            continue

        retry = threading.Event()
        start_ap(args.config, cfg, retry)
        time.sleep(2)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
