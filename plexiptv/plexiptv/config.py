from __future__ import annotations

import os
import secrets
from pathlib import Path

import yaml
from pydantic import BaseModel


class XtreamConfig(BaseModel):
    server: str = "http://localhost:8080"
    username: str = ""
    password: str = ""


class TunerConfig(BaseModel):
    count: int = 4
    device_id: str = ""
    friendly_name: str = "PlexIPTV"


class ServerConfig(BaseModel):
    host: str = "0.0.0.0"
    port: int = 5004


class CacheConfig(BaseModel):
    channel_refresh_minutes: int = 120
    epg_refresh_minutes: int = 60


class ProxyConfig(BaseModel):
    buffer_size_kb: int = 512


class Settings(BaseModel):
    xtream: XtreamConfig = XtreamConfig()
    tuner: TunerConfig = TunerConfig()
    server: ServerConfig = ServerConfig()
    cache: CacheConfig = CacheConfig()
    proxy: ProxyConfig = ProxyConfig()


def _config_path() -> Path:
    env = os.environ.get("PLEXIPTV_CONFIG")
    if env:
        return Path(env)
    return Path("config.yaml")


def load_config() -> Settings:
    path = _config_path()
    if path.exists():
        with open(path, "r", encoding="utf-8") as f:
            raw = yaml.safe_load(f) or {}
        settings = Settings(**raw)
    else:
        settings = Settings()

    # Auto-generate device_id on first run
    if not settings.tuner.device_id:
        settings.tuner.device_id = secrets.token_hex(4).upper()
        save_config(settings)

    return settings


def save_config(settings: Settings) -> None:
    path = _config_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    data = settings.model_dump()
    with open(path, "w", encoding="utf-8") as f:
        yaml.dump(data, f, default_flow_style=False, sort_keys=False)
