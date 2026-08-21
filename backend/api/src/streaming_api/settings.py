from __future__ import annotations

from pathlib import Path

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="", env_file=".env", extra="ignore")

    app_name: str = "raspi-streaming-api"
    public_base_url: str = "https://streaming.rafex.io"
    database_path: Path = Path("/data/streaming-api.db")

    api_token_raspi: str = ""
    api_token_admin: str = ""

    portal_username: str = ""
    portal_password_hash: str = ""
    portal_session_secret: str = ""
    portal_session_ttl_seconds: int = 7_200

    portal_proxy_domain: str = "rafex.io"
    portal_proxy_allowed_host_suffixes: str = ".ngrok-free.app,.ngrok.app"
    portal_proxy_timeout_seconds: float = 20.0

    require_mtls: bool = True
    # Health reports are already authenticated by the Raspi bearer token. Keep
    # mTLS optional here so a broken edge header forwarding path cannot freeze
    # the published ngrok/SSH endpoints; control APIs remain mTLS-protected.
    health_report_require_mtls: bool = False
    mtls_verify_header: str = "x-ssl-client-verify"
    mtls_verify_success_value: str = "SUCCESS"
    mtls_subject_header: str = "x-ssl-client-dn"
    mtls_cn_header: str = "x-ssl-client-cn"
    mtls_cert_header: str = "x-ssl-client-cert"

    max_payload_bytes: int = 262_144


settings = Settings()
