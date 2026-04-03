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
    reconnect_attempts: int = 5


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
    return Path("/app/data/config.yaml")


def _apply_env_overrides(settings: Settings) -> None:
    """Override config values with environment variables when set."""
    mapping = {
        "XTREAM_SERVER": lambda v: setattr(settings.xtream, "server", v),
        "XTREAM_USERNAME": lambda v: setattr(settings.xtream, "username", v),
        "XTREAM_PASSWORD": lambda v: setattr(settings.xtream, "password", v),
        "TUNER_COUNT": lambda v: setattr(settings.tuner, "count", int(v)),
        "TUNER_NAME": lambda v: setattr(settings.tuner, "friendly_name", v),
        "TUNER_DEVICE_ID": lambda v: setattr(settings.tuner, "device_id", v),
        "SERVER_HOST": lambda v: setattr(settings.server, "host", v),
        "SERVER_PORT": lambda v: setattr(settings.server, "port", int(v)),
        "BUFFER_SIZE_KB": lambda v: setattr(settings.proxy, "buffer_size_kb", int(v)),
        "CHANNEL_REFRESH_MIN": lambda v: setattr(settings.cache, "channel_refresh_minutes", int(v)),
        "EPG_REFRESH_MIN": lambda v: setattr(settings.cache, "epg_refresh_minutes", int(v)),
    }
    for env_key, setter in mapping.items():
        val = os.environ.get(env_key)
        if val:
            try:
                setter(val)
            except (ValueError, TypeError):
                pass


def load_config() -> Settings:
    path = _config_path()
    if path.exists():
        with open(path, "r", encoding="utf-8") as f:
            raw = yaml.safe_load(f) or {}
        settings = Settings(**raw)
    else:
        settings = Settings()

    # Env vars always win over config file
    _apply_env_overrides(settings)

    # Auto-generate device_id on first run
    if not settings.tuner.device_id:
        settings.tuner.device_id = secrets.token_hex(4).upper()
        try:
            save_config(settings)
        except OSError:
            pass  # Read-only filesystem is fine

    return settings


def save_config(settings: Settings) -> None:
    path = _config_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    data = settings.model_dump()
    with open(path, "w", encoding="utf-8") as f:
        yaml.dump(data, f, default_flow_style=False, sort_keys=False)
