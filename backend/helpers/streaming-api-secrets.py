#!/usr/bin/env python3
"""CLI operativo para tokens y certificados del backend streaming."""

from __future__ import annotations

import argparse
import base64
import os
import secrets
import shutil
import subprocess
import sys
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parents[2]
BACKEND_CERTS = ROOT_DIR / "backend" / "certs" / "backend"
FRONTEND_CERTS = ROOT_DIR / "backend" / "certs" / "frontend"
GITHUB_ENV_LOCAL = ROOT_DIR / "backend" / "helpers" / "github-secrets.env.local"
RASPI_ENV_LOCAL = ROOT_DIR / "backend" / "helpers" / "raspi-backend.env.local"


def die(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def run(cmd: list[str]) -> None:
    subprocess.check_call(cmd)


def require_openssl() -> None:
    if not shutil.which("openssl"):
        die("openssl no esta instalado o no esta en PATH")


def generate_token(prefix: str, nbytes: int) -> str:
    return f"{prefix}{secrets.token_urlsafe(nbytes)}"


def write_private(path: Path, content: str, overwrite: bool = False) -> None:
    if path.exists() and not overwrite:
        die(f"{path} ya existe. Usa --force para reemplazarlo.")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    os.chmod(path, 0o600)


def generate_certs(device_id: str, days: int, force: bool, force_ca: bool) -> None:
    require_openssl()
    BACKEND_CERTS.mkdir(parents=True, exist_ok=True)
    FRONTEND_CERTS.mkdir(parents=True, exist_ok=True)

    ca_key = BACKEND_CERTS / "ca.key"
    ca_crt = BACKEND_CERTS / "ca.crt"
    ca_srl = BACKEND_CERTS / "ca.srl"
    client_key = FRONTEND_CERTS / f"{device_id}.key"
    client_csr = FRONTEND_CERTS / f"{device_id}.csr"
    client_crt = FRONTEND_CERTS / f"{device_id}.crt"

    if force_ca:
        for path in (ca_key, ca_crt, ca_srl):
            path.unlink(missing_ok=True)

    if not ca_key.exists() or not ca_crt.exists():
        run(["openssl", "genrsa", "-out", str(ca_key), "4096"])
        run([
            "openssl", "req", "-x509", "-new", "-nodes",
            "-key", str(ca_key),
            "-sha256", "-days", str(days),
            "-subj", "/CN=raspi-streaming-client-ca",
            "-out", str(ca_crt),
        ])
        os.chmod(ca_key, 0o600)
    else:
        print(f"CA existente conservada: {ca_crt}")

    if force:
        for path in (client_key, client_csr, client_crt):
            path.unlink(missing_ok=True)

    if client_key.exists() or client_crt.exists():
        die(f"certificado cliente ya existe para {device_id}. Usa --force.")

    run(["openssl", "genrsa", "-out", str(client_key), "2048"])
    run([
        "openssl", "req", "-new",
        "-key", str(client_key),
        "-subj", f"/CN={device_id}",
        "-out", str(client_csr),
    ])
    run([
        "openssl", "x509", "-req",
        "-in", str(client_csr),
        "-CA", str(ca_crt),
        "-CAkey", str(ca_key),
        "-CAcreateserial",
        "-out", str(client_crt),
        "-days", str(days),
        "-sha256",
    ])
    client_csr.unlink(missing_ok=True)
    os.chmod(client_key, 0o600)

    # Mantener nombres compatibles con scripts existentes para la Raspi default.
    if device_id == "raspi-client":
        return
    compat_key = FRONTEND_CERTS / "raspi-client.key"
    compat_crt = FRONTEND_CERTS / "raspi-client.crt"
    if not compat_key.exists():
        compat_key.symlink_to(client_key.name)
    if not compat_crt.exists():
        compat_crt.symlink_to(client_crt.name)

    print("Certificados generados:")
    print(f"  CA publica Kubernetes : {ca_crt}")
    print(f"  CA privada local      : {ca_key}")
    print(f"  Cliente Raspi cert    : {client_crt}")
    print(f"  Cliente Raspi key     : {client_key}")


def ca_b64(ca_file: Path) -> str:
    return base64.b64encode(ca_file.read_bytes()).decode("ascii")


def cmd_token(args: argparse.Namespace) -> int:
    print(generate_token(args.prefix, args.bytes))
    return 0


def cmd_certs(args: argparse.Namespace) -> int:
    generate_certs(args.device_id, args.days, args.force, args.force_ca)
    return 0


def cmd_init(args: argparse.Namespace) -> int:
    raspi_token = args.raspi_token or generate_token("rsp_", args.token_bytes)
    admin_token = args.admin_token or generate_token("adm_", args.token_bytes)

    generate_certs(args.device_id, args.days, args.force, args.force_ca)

    ca_file = BACKEND_CERTS / "ca.crt"
    client_crt = FRONTEND_CERTS / f"{args.device_id}.crt"
    client_key = FRONTEND_CERTS / f"{args.device_id}.key"

    github_env = "\n".join([
        "# Generado por backend/helpers/streaming-api-secrets.py init",
        "K3S_SSH_USER=",
        "K3S_SSH_PRIVATE_KEY_FILE=",
        f"STREAMING_API_RASPI_TOKEN={raspi_token}",
        f"STREAMING_API_ADMIN_TOKEN={admin_token}",
        f"STREAMING_API_CLIENT_CA_CRT_FILE={ca_file}",
        "",
    ])
    write_private(args.github_env, github_env, overwrite=args.force)

    raspi_env = "\n".join([
        "# Copiar valores a /etc/raspi-streaming/health-reporter.env y backend-control-agent.env",
        "BACKEND_BASE_URL=https://streaming.rafex.io",
        f"BACKEND_DEVICE_ID={args.device_id}",
        f"BACKEND_TOKEN={raspi_token}",
        f"HEALTH_ENDPOINT=https://streaming.rafex.io/v1/raspi/{args.device_id}/health",
        f"HEALTH_TOKEN={raspi_token}",
        "BACKEND_CLIENT_CERT=/etc/raspi-streaming/backend-client/raspi-client.crt",
        "BACKEND_CLIENT_KEY=/etc/raspi-streaming/backend-client/raspi-client.key",
        "BACKEND_AGENT_INTERVAL_SECONDS=30",
        "HEALTH_INTERVAL_SECONDS=60",
        "",
    ])
    write_private(args.raspi_env, raspi_env, overwrite=args.force)

    print("Material local generado:")
    print(f"  GitHub secrets env : {args.github_env}")
    print(f"  Raspi env local    : {args.raspi_env}")
    print(f"  Raspi cert         : {client_crt}")
    print(f"  Raspi key          : {client_key}")
    print("")
    print("Siguientes pasos:")
    print("  1. Editar K3S_SSH_USER y K3S_SSH_PRIVATE_KEY_FILE en github-secrets.env.local")
    print("  2. source backend/helpers/github-secrets.env.local")
    print("  3. backend/helpers/set-github-secrets.sh")
    print(f"  4. backend/helpers/install-raspi-client-certs.sh root@192.168.3.169 --device-id {args.device_id}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Tokens y certificados de Streaming API.")
    sub = parser.add_subparsers(dest="command", required=True)

    token = sub.add_parser("token", help="Genera un token bearer seguro.")
    token.add_argument("--prefix", default="rsp_")
    token.add_argument("--bytes", type=int, default=32)
    token.set_defaults(func=cmd_token)

    certs = sub.add_parser("certs", help="Genera CA mTLS y certificado cliente.")
    certs.add_argument("--device-id", default="raspi3b")
    certs.add_argument("--days", type=int, default=825)
    certs.add_argument("--force", action="store_true", help="Reemplaza certificado cliente existente.")
    certs.add_argument("--force-ca", action="store_true", help="Reemplaza la CA local.")
    certs.set_defaults(func=cmd_certs)

    init = sub.add_parser("init", help="Genera tokens, certificados y envs locales.")
    init.add_argument("--device-id", default="raspi3b")
    init.add_argument("--days", type=int, default=825)
    init.add_argument("--token-bytes", type=int, default=32)
    init.add_argument("--raspi-token", default="")
    init.add_argument("--admin-token", default="")
    init.add_argument("--github-env", type=Path, default=GITHUB_ENV_LOCAL)
    init.add_argument("--raspi-env", type=Path, default=RASPI_ENV_LOCAL)
    init.add_argument("--force", action="store_true")
    init.add_argument("--force-ca", action="store_true")
    init.set_defaults(func=cmd_init)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
