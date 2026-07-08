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

    require_mtls: bool = True
    mtls_verify_header: str = "x-ssl-client-verify"
    mtls_verify_success_value: str = "SUCCESS"
    mtls_subject_header: str = "x-ssl-client-dn"
    mtls_cn_header: str = "x-ssl-client-cn"

    max_payload_bytes: int = 262_144


settings = Settings()
