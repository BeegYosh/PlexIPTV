#!/bin/bash
set -e

BASE_DIR="/mnt/pool/plexiptv-stack"

# Create base directory structure
mkdir -p "$BASE_DIR"
mkdir -p "$BASE_DIR/plexiptv/cache"
mkdir -p "$BASE_DIR/plexiptv/dashboard/static"
mkdir -p "$BASE_DIR/plexiptv/hdhr"
mkdir -p "$BASE_DIR/plexiptv/proxy"
mkdir -p "$BASE_DIR/plexiptv/xtream"

# --- Dockerfile ---
cat << 'FILE1EOF' > "$BASE_DIR/Dockerfile"
FROM python:3.12-slim

LABEL maintainer="PlexIPTV"
LABEL description="Xtream Codes IPTV to Plex Live TV via HDHomeRun emulation"

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy the plexiptv package
COPY plexiptv/ /app/plexiptv/

RUN mkdir -p /data

ENV PLEXIPTV_CONFIG=/data/config.yaml \
    PLEXIPTV_DB=/data/plexiptv.db

EXPOSE 5004

CMD ["python", "-m", "plexiptv"]
FILE1EOF

# --- requirements.txt ---
cat << 'FILE2EOF' > "$BASE_DIR/requirements.txt"
fastapi>=0.110.0,<1.0.0
uvicorn[standard]>=0.29.0,<1.0.0
httpx>=0.27.0,<1.0.0
pydantic>=2.6.0,<3.0.0
pyyaml>=6.0,<7.0
aiosqlite>=0.20.0,<1.0.0
FILE2EOF

# --- .dockerignore ---
cat << 'FILE3EOF' > "$BASE_DIR/.dockerignore"
__pycache__
*.pyc
*.pyo
*.db
*.sqlite
.git
.gitignore
.env
*.egg-info
dist
build
FILE3EOF

# --- plexiptv/__init__.py ---
cat << 'FILE4EOF' > "$BASE_DIR/plexiptv/__init__.py"
"""PlexIPTV — Xtream Codes IPTV to Plex Live TV via HDHomeRun emulation."""

__version__ = "0.1.0"
FILE4EOF

# --- plexiptv/__main__.py ---
cat << 'FILE5EOF' > "$BASE_DIR/plexiptv/__main__.py"
"""Entry point for `python -m plexiptv` or the `plexiptv` console script."""

import uvicorn

from plexiptv.app import create_app
from plexiptv.config import load_config


def main() -> None:
    settings = load_config()
    app = create_app()
    uvicorn.run(
        app,
        host=settings.server.host,
        port=settings.server.port,
        log_level="info",
        access_log=True,
    )


if __name__ == "__main__":
    main()
FILE5EOF

# --- plexiptv/app.py ---
cat << 'FILE6EOF' > "$BASE_DIR/plexiptv/app.py"
from __future__ import annotations

import asyncio
import logging
import time
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles

from plexiptv.cache.store import CacheStore
from plexiptv.config import Settings, load_config
from plexiptv.dashboard.router import router as dashboard_router
from plexiptv.hdhr.router import router as hdhr_router
from plexiptv.hdhr.ssdp import SSDPServer
from plexiptv.proxy.stream import StreamManager
from plexiptv.utils import detect_lan_ip, setup_logging
from plexiptv.xtream.client import XtreamClient

logger = logging.getLogger(__name__)

STATIC_DIR = Path(__file__).parent / "dashboard" / "static"


async def initial_data_sync(xtream: XtreamClient, cache: CacheStore) -> None:
    """Fetch channels and EPG from Xtream if cache is empty."""
    try:
        existing, count = await cache.get_channels(per_page=1)
        if count > 0:
            logger.info("Cache has %d channels, skipping initial sync", count)
            return

        logger.info("Cache empty, performing initial data sync...")
        categories = await xtream.get_live_categories()
        await cache.upsert_categories(categories)
        logger.info("Loaded %d categories", len(categories))

        channels = await xtream.get_live_streams()
        await cache.upsert_channels(channels)
        logger.info("Loaded %d channels", len(channels))

        try:
            epg = await xtream.get_full_epg()
            await cache.upsert_epg(epg)
            logger.info("Loaded %d EPG entries", len(epg))
        except Exception as e:
            logger.warning("EPG sync failed (will retry later): %s", e)

    except Exception as e:
        logger.error("Initial data sync failed: %s", e)
        logger.info("You can trigger a manual refresh from the dashboard")


async def periodic_refresh(xtream: XtreamClient, cache: CacheStore, settings: Settings) -> None:
    """Background task to refresh channels and EPG periodically."""
    while True:
        await asyncio.sleep(settings.cache.channel_refresh_minutes * 60)
        try:
            logger.info("Starting periodic channel refresh...")
            categories = await xtream.get_live_categories()
            await cache.upsert_categories(categories)
            channels = await xtream.get_live_streams()
            await cache.upsert_channels(channels)
            logger.info("Refreshed %d categories, %d channels", len(categories), len(channels))
        except Exception:
            logger.exception("Channel refresh failed")

        try:
            epg = await xtream.get_full_epg()
            await cache.upsert_epg(epg)
            logger.info("Refreshed %d EPG entries", len(epg))
        except Exception:
            logger.exception("EPG refresh failed")


@asynccontextmanager
async def lifespan(app: FastAPI):
    setup_logging()
    settings = load_config()
    local_ip = detect_lan_ip()
    logger.info("PlexIPTV starting on %s:%d", local_ip, settings.server.port)

    # Store in app state
    app.state.settings = settings
    app.state.local_ip = local_ip
    app.state.start_time = time.time()

    # Initialize subsystems
    xtream = XtreamClient(settings)
    app.state.xtream = xtream

    cache = CacheStore()  # Uses PLEXIPTV_DB env var or default
    await cache.init()
    app.state.cache = cache

    stream_manager = StreamManager(settings, xtream)
    app.state.stream_manager = stream_manager

    # Initial data load
    await initial_data_sync(xtream, cache)

    # Background refresh
    refresh_task = asyncio.create_task(periodic_refresh(xtream, cache, settings))

    # SSDP discovery
    ssdp = SSDPServer(settings, local_ip)
    await ssdp.start()

    logger.info("PlexIPTV ready at http://%s:%d", local_ip, settings.server.port)
    logger.info("Dashboard: http://%s:%d/dashboard/", local_ip, settings.server.port)

    yield

    # Shutdown
    refresh_task.cancel()
    try:
        await refresh_task
    except asyncio.CancelledError:
        pass
    await ssdp.stop()
    await stream_manager.close()
    await xtream.close()
    await cache.close()
    logger.info("PlexIPTV stopped")


def create_app() -> FastAPI:
    app = FastAPI(title="PlexIPTV", version="0.1.0", lifespan=lifespan)

    # HDHomeRun endpoints at root level (Plex expects /discover.json etc.)
    app.include_router(hdhr_router)

    # Dashboard API
    app.include_router(dashboard_router)

    # Dashboard static files
    app.mount("/dashboard/static", StaticFiles(directory=str(STATIC_DIR)), name="dashboard-static")

    # Dashboard HTML (serve index.html at /dashboard)
    @app.get("/dashboard", include_in_schema=False)
    @app.get("/dashboard/", include_in_schema=False)
    async def dashboard_index():
        from fastapi.responses import FileResponse
        return FileResponse(STATIC_DIR / "index.html")

    return app
FILE6EOF

# --- plexiptv/config.py ---
cat << 'FILE7EOF' > "$BASE_DIR/plexiptv/config.py"
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
    return Path("/data/config.yaml")


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
FILE7EOF

# --- plexiptv/models.py ---
cat << 'FILE8EOF' > "$BASE_DIR/plexiptv/models.py"
from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel


class Category(BaseModel):
    category_id: str
    category_name: str


class Channel(BaseModel):
    stream_id: int
    name: str
    category_id: str = ""
    epg_channel_id: str | None = None
    stream_icon: str | None = None
    enabled: bool = True
    channel_number: int = 0


class EpgEntry(BaseModel):
    epg_id: str
    channel_id: str
    title: str
    description: str = ""
    start: datetime
    end: datetime


class ActiveStream(BaseModel):
    session_id: str
    stream_id: int
    channel_name: str
    client_ip: str
    started_at: datetime
    bytes_sent: int = 0
FILE8EOF

# --- plexiptv/utils.py ---
cat << 'FILE9EOF' > "$BASE_DIR/plexiptv/utils.py"
from __future__ import annotations

import logging
import socket


def detect_lan_ip() -> str:
    """Get this machine's LAN IP by connecting to a public address (no data sent)."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(2)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"


def setup_logging(level: str = "INFO") -> None:
    logging.basicConfig(
        format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
        level=getattr(logging, level.upper(), logging.INFO),
    )
FILE9EOF

# --- plexiptv/cache/__init__.py ---
cat << 'FILE10EOF' > "$BASE_DIR/plexiptv/cache/__init__.py"
FILE10EOF

# --- plexiptv/cache/store.py ---
cat << 'FILE11EOF' > "$BASE_DIR/plexiptv/cache/store.py"
from __future__ import annotations

import logging
import os

import aiosqlite

from plexiptv.models import Category, Channel, EpgEntry

logger = logging.getLogger(__name__)

_SCHEMA = """
CREATE TABLE IF NOT EXISTS categories (
    category_id TEXT PRIMARY KEY,
    category_name TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS channels (
    stream_id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    category_id TEXT DEFAULT '',
    epg_channel_id TEXT,
    stream_icon TEXT,
    enabled INTEGER DEFAULT 1,
    channel_number INTEGER DEFAULT 0
);
CREATE TABLE IF NOT EXISTS epg (
    epg_id TEXT,
    channel_id TEXT,
    title TEXT,
    description TEXT DEFAULT '',
    start_ts INTEGER,
    end_ts INTEGER,
    PRIMARY KEY (channel_id, start_ts)
);
CREATE INDEX IF NOT EXISTS idx_epg_channel ON epg(channel_id);
CREATE INDEX IF NOT EXISTS idx_channels_category ON channels(category_id);
CREATE INDEX IF NOT EXISTS idx_channels_enabled ON channels(enabled);
"""


class CacheStore:
    def __init__(self, db_path: str | None = None) -> None:
        self._db_path = db_path or os.environ.get("PLEXIPTV_DB", "plexiptv.db")
        self._db: aiosqlite.Connection | None = None

    async def init(self) -> None:
        self._db = await aiosqlite.connect(self._db_path)
        self._db.row_factory = aiosqlite.Row
        await self._db.executescript(_SCHEMA)
        await self._db.commit()

    async def close(self) -> None:
        if self._db:
            await self._db.close()

    # --- Categories ---

    async def upsert_categories(self, cats: list[Category]) -> None:
        assert self._db
        await self._db.executemany(
            "INSERT OR REPLACE INTO categories (category_id, category_name) VALUES (?, ?)",
            [(c.category_id, c.category_name) for c in cats],
        )
        await self._db.commit()

    async def get_categories(self) -> list[Category]:
        assert self._db
        async with self._db.execute("SELECT category_id, category_name FROM categories ORDER BY category_name") as cur:
            return [Category(category_id=row["category_id"], category_name=row["category_name"]) async for row in cur]

    # --- Channels ---

    async def upsert_channels(self, channels: list[Channel]) -> None:
        assert self._db
        for ch in channels:
            await self._db.execute(
                """INSERT INTO channels (stream_id, name, category_id, epg_channel_id, stream_icon)
                   VALUES (?, ?, ?, ?, ?)
                   ON CONFLICT(stream_id) DO UPDATE SET
                     name=excluded.name,
                     category_id=excluded.category_id,
                     epg_channel_id=excluded.epg_channel_id,
                     stream_icon=excluded.stream_icon""",
                (ch.stream_id, ch.name, ch.category_id, ch.epg_channel_id, ch.stream_icon),
            )
        await self._db.commit()
        await self._assign_channel_numbers()

    async def _assign_channel_numbers(self) -> None:
        """Assign sequential channel numbers to enabled channels that don't have one."""
        assert self._db
        async with self._db.execute(
            "SELECT stream_id FROM channels WHERE enabled=1 AND channel_number=0 ORDER BY name"
        ) as cur:
            rows = await cur.fetchall()

        if not rows:
            return

        # Find the current max channel number
        async with self._db.execute("SELECT COALESCE(MAX(channel_number), 0) FROM channels") as cur:
            row = await cur.fetchone()
            next_num = (row[0] if row else 0) + 1

        for row in rows:
            await self._db.execute(
                "UPDATE channels SET channel_number=? WHERE stream_id=?",
                (next_num, row["stream_id"]),
            )
            next_num += 1
        await self._db.commit()

    async def get_channels(
        self,
        category_id: str | None = None,
        enabled_only: bool = False,
        search: str | None = None,
        page: int = 1,
        per_page: int = 50,
    ) -> tuple[list[Channel], int]:
        assert self._db
        conditions = []
        params: list = []

        if category_id:
            conditions.append("category_id = ?")
            params.append(category_id)
        if enabled_only:
            conditions.append("enabled = 1")
        if search:
            conditions.append("name LIKE ?")
            params.append(f"%{search}%")

        where = f"WHERE {' AND '.join(conditions)}" if conditions else ""

        # Count
        async with self._db.execute(f"SELECT COUNT(*) FROM channels {where}", params) as cur:
            row = await cur.fetchone()
            total = row[0] if row else 0

        # Fetch page
        offset = (page - 1) * per_page
        query = f"SELECT * FROM channels {where} ORDER BY channel_number, name LIMIT ? OFFSET ?"
        async with self._db.execute(query, [*params, per_page, offset]) as cur:
            channels = [
                Channel(
                    stream_id=row["stream_id"],
                    name=row["name"],
                    category_id=row["category_id"],
                    epg_channel_id=row["epg_channel_id"],
                    stream_icon=row["stream_icon"],
                    enabled=bool(row["enabled"]),
                    channel_number=row["channel_number"],
                )
                async for row in cur
            ]

        return channels, total

    async def set_channel_enabled(self, stream_id: int, enabled: bool) -> None:
        assert self._db
        await self._db.execute("UPDATE channels SET enabled=? WHERE stream_id=?", (int(enabled), stream_id))
        await self._db.commit()

    async def toggle_category(self, category_id: str, enabled: bool) -> None:
        assert self._db
        await self._db.execute("UPDATE channels SET enabled=? WHERE category_id=?", (int(enabled), category_id))
        await self._db.commit()

    async def get_channel_by_id(self, stream_id: int) -> Channel | None:
        assert self._db
        async with self._db.execute("SELECT * FROM channels WHERE stream_id=?", (stream_id,)) as cur:
            row = await cur.fetchone()
            if not row:
                return None
            return Channel(
                stream_id=row["stream_id"],
                name=row["name"],
                category_id=row["category_id"],
                epg_channel_id=row["epg_channel_id"],
                stream_icon=row["stream_icon"],
                enabled=bool(row["enabled"]),
                channel_number=row["channel_number"],
            )

    # --- EPG ---

    async def upsert_epg(self, entries: list[EpgEntry]) -> None:
        assert self._db
        await self._db.executemany(
            """INSERT OR REPLACE INTO epg (epg_id, channel_id, title, description, start_ts, end_ts)
               VALUES (?, ?, ?, ?, ?, ?)""",
            [(e.epg_id, e.channel_id, e.title, e.description, int(e.start.timestamp()), int(e.end.timestamp())) for e in entries],
        )
        await self._db.commit()

    async def get_epg(self, channel_id: str, hours_ahead: int = 24) -> list[EpgEntry]:
        assert self._db
        from datetime import datetime, timezone, timedelta

        now = int(datetime.now(timezone.utc).timestamp())
        until = int((datetime.now(timezone.utc) + timedelta(hours=hours_ahead)).timestamp())

        async with self._db.execute(
            "SELECT * FROM epg WHERE channel_id=? AND end_ts > ? AND start_ts < ? ORDER BY start_ts",
            (channel_id, now, until),
        ) as cur:
            from datetime import datetime as dt
            return [
                EpgEntry(
                    epg_id=row["epg_id"],
                    channel_id=row["channel_id"],
                    title=row["title"],
                    description=row["description"],
                    start=dt.fromtimestamp(row["start_ts"], tz=timezone.utc),
                    end=dt.fromtimestamp(row["end_ts"], tz=timezone.utc),
                )
                async for row in cur
            ]

    async def get_all_epg_for_xmltv(self) -> tuple[list[dict], list[dict]]:
        """Return channel info and EPG entries for XMLTV generation."""
        assert self._db
        from datetime import datetime, timezone

        now = int(datetime.now(timezone.utc).timestamp())

        # Channels with EPG IDs
        channels = []
        async with self._db.execute(
            "SELECT stream_id, name, stream_icon, epg_channel_id, channel_number FROM channels WHERE enabled=1 AND epg_channel_id IS NOT NULL"
        ) as cur:
            async for row in cur:
                channels.append({
                    "id": row["epg_channel_id"],
                    "name": row["name"],
                    "icon": row["stream_icon"],
                    "number": row["channel_number"],
                })

        # EPG entries from now onwards
        programmes = []
        async with self._db.execute(
            "SELECT * FROM epg WHERE end_ts > ? ORDER BY channel_id, start_ts", (now,)
        ) as cur:
            async for row in cur:
                programmes.append({
                    "channel_id": row["channel_id"],
                    "title": row["title"],
                    "description": row["description"],
                    "start_ts": row["start_ts"],
                    "end_ts": row["end_ts"],
                })

        return channels, programmes
FILE11EOF

# --- plexiptv/dashboard/__init__.py ---
cat << 'FILE12EOF' > "$BASE_DIR/plexiptv/dashboard/__init__.py"
FILE12EOF

# --- plexiptv/dashboard/router.py ---
cat << 'FILE13EOF' > "$BASE_DIR/plexiptv/dashboard/router.py"
from __future__ import annotations

import logging
import time
from pathlib import Path

from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse, JSONResponse

from plexiptv.config import Settings, save_config

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api")

STATIC_DIR = Path(__file__).parent / "static"


@router.get("/status")
async def status(request: Request) -> dict:
    settings: Settings = request.app.state.settings
    stream_manager = request.app.state.stream_manager
    cache = request.app.state.cache
    start_time = request.app.state.start_time

    _, total_channels = await cache.get_channels(per_page=1)
    _, enabled_channels = await cache.get_channels(enabled_only=True, per_page=1)

    return {
        "server_name": settings.tuner.friendly_name,
        "uptime_seconds": int(time.time() - start_time),
        "tuner_count": settings.tuner.count,
        "active_streams": len(stream_manager.active_streams),
        "total_channels": total_channels,
        "enabled_channels": enabled_channels,
        "local_ip": request.app.state.local_ip,
        "port": settings.server.port,
        "xtream_server": settings.xtream.server,
    }


@router.get("/channels")
async def get_channels(
    request: Request,
    category: str | None = None,
    search: str | None = None,
    page: int = 1,
    per_page: int = 50,
) -> dict:
    cache = request.app.state.cache
    channels, total = await cache.get_channels(
        category_id=category, search=search, page=page, per_page=per_page,
    )
    return {
        "channels": [ch.model_dump() for ch in channels],
        "total": total,
        "page": page,
        "per_page": per_page,
        "pages": (total + per_page - 1) // per_page,
    }


@router.post("/channels/{stream_id}/toggle")
async def toggle_channel(stream_id: int, request: Request) -> dict:
    cache = request.app.state.cache
    channel = await cache.get_channel_by_id(stream_id)
    if not channel:
        return JSONResponse({"error": "Channel not found"}, status_code=404)
    new_state = not channel.enabled
    await cache.set_channel_enabled(stream_id, new_state)
    return {"stream_id": stream_id, "enabled": new_state}


@router.post("/channels/category/{category_id}/toggle")
async def toggle_category(category_id: str, request: Request, enabled: bool = True) -> dict:
    cache = request.app.state.cache
    await cache.toggle_category(category_id, enabled)
    return {"category_id": category_id, "enabled": enabled}


@router.get("/categories")
async def get_categories(request: Request) -> list[dict]:
    cache = request.app.state.cache
    cats = await cache.get_categories()
    return [c.model_dump() for c in cats]


@router.get("/epg/{stream_id}")
async def get_epg(stream_id: int, request: Request) -> list[dict]:
    cache = request.app.state.cache
    channel = await cache.get_channel_by_id(stream_id)
    if not channel or not channel.epg_channel_id:
        return []
    entries = await cache.get_epg(channel.epg_channel_id)
    return [e.model_dump() for e in entries]


@router.get("/streams")
async def get_streams(request: Request) -> list[dict]:
    stream_manager = request.app.state.stream_manager
    return [s.model_dump() for s in stream_manager.get_active()]


@router.get("/config")
async def get_config(request: Request) -> dict:
    settings: Settings = request.app.state.settings
    data = settings.model_dump()
    # Mask password
    data["xtream"]["password"] = "***"
    return data


@router.put("/config")
async def update_config(request: Request) -> dict:
    body = await request.json()
    settings: Settings = request.app.state.settings

    if "xtream" in body:
        xt = body["xtream"]
        if "server" in xt:
            settings.xtream.server = xt["server"]
        if "username" in xt:
            settings.xtream.username = xt["username"]
        if "password" in xt and xt["password"] != "***":
            settings.xtream.password = xt["password"]
    if "tuner" in body:
        t = body["tuner"]
        if "count" in t:
            settings.tuner.count = int(t["count"])
        if "friendly_name" in t:
            settings.tuner.friendly_name = t["friendly_name"]
    if "proxy" in body:
        p = body["proxy"]
        if "buffer_size_kb" in p:
            settings.proxy.buffer_size_kb = int(p["buffer_size_kb"])
    if "cache" in body:
        c = body["cache"]
        if "channel_refresh_minutes" in c:
            settings.cache.channel_refresh_minutes = int(c["channel_refresh_minutes"])
        if "epg_refresh_minutes" in c:
            settings.cache.epg_refresh_minutes = int(c["epg_refresh_minutes"])

    save_config(settings)
    return {"status": "ok"}


@router.post("/refresh")
async def force_refresh(request: Request) -> dict:
    xtream = request.app.state.xtream
    cache = request.app.state.cache

    try:
        categories = await xtream.get_live_categories()
        await cache.upsert_categories(categories)
        channels = await xtream.get_live_streams()
        await cache.upsert_channels(channels)
        logger.info("Force refresh: %d categories, %d channels", len(categories), len(channels))

        try:
            epg = await xtream.get_full_epg()
            await cache.upsert_epg(epg)
            logger.info("Force refresh: %d EPG entries", len(epg))
        except Exception as e:
            logger.warning("EPG refresh failed: %s", e)

        return {"status": "ok", "categories": len(categories), "channels": len(channels)}
    except Exception as e:
        logger.error("Force refresh failed: %s", e)
        return JSONResponse({"error": str(e)}, status_code=500)
FILE13EOF

# --- plexiptv/dashboard/static/index.html ---
cat << 'FILE14EOF' > "$BASE_DIR/plexiptv/dashboard/static/index.html"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>PlexIPTV Dashboard</title>
    <link rel="stylesheet" href="/dashboard/static/style.css">
</head>
<body>
    <div class="layout">
        <nav class="sidebar">
            <div class="logo">
                <h1>PlexIPTV</h1>
                <span class="version">v0.1.0</span>
            </div>
            <ul class="nav-links">
                <li><a href="#" class="nav-link active" data-tab="status">Status</a></li>
                <li><a href="#" class="nav-link" data-tab="channels">Channels</a></li>
                <li><a href="#" class="nav-link" data-tab="streams">Active Streams</a></li>
                <li><a href="#" class="nav-link" data-tab="settings">Settings</a></li>
            </ul>
            <div class="sidebar-footer">
                <div id="server-status" class="status-badge offline">Offline</div>
            </div>
        </nav>

        <main class="content">
            <!-- Status Tab -->
            <section id="tab-status" class="tab active">
                <h2>Server Status</h2>
                <div class="stats-grid" id="stats-grid"></div>
                <div class="actions-bar">
                    <button class="btn btn-primary" onclick="forceRefresh()">Refresh Channels & EPG</button>
                </div>
                <div class="info-card">
                    <h3>Plex Setup</h3>
                    <p>Your HDHomeRun tuner should auto-appear in Plex under <strong>Settings &gt; Live TV &amp; DVR</strong>.</p>
                    <p>If not found automatically, add it manually:</p>
                    <ul>
                        <li>Tuner URL: <code id="tuner-url">-</code></li>
                        <li>EPG/Guide URL: <code id="epg-url">-</code></li>
                    </ul>
                </div>
            </section>

            <!-- Channels Tab -->
            <section id="tab-channels" class="tab">
                <h2>Channels</h2>
                <div class="toolbar">
                    <input type="text" id="channel-search" placeholder="Search channels..." class="input">
                    <select id="category-filter" class="input">
                        <option value="">All Categories</option>
                    </select>
                    <span id="channel-count" class="badge">0 channels</span>
                </div>
                <div class="table-wrap">
                    <table class="table" id="channels-table">
                        <thead>
                            <tr>
                                <th>#</th>
                                <th>Logo</th>
                                <th>Name</th>
                                <th>Category</th>
                                <th>EPG</th>
                                <th>Enabled</th>
                            </tr>
                        </thead>
                        <tbody id="channels-body"></tbody>
                    </table>
                </div>
                <div class="pagination" id="pagination"></div>
            </section>

            <!-- Streams Tab -->
            <section id="tab-streams" class="tab">
                <h2>Active Streams</h2>
                <div id="streams-list" class="streams-list">
                    <p class="empty-state">No active streams</p>
                </div>
            </section>

            <!-- Settings Tab -->
            <section id="tab-settings" class="tab">
                <h2>Settings</h2>
                <form id="settings-form" class="settings-form">
                    <fieldset>
                        <legend>Xtream Codes</legend>
                        <label>Server URL<input type="text" name="xtream.server" class="input"></label>
                        <label>Username<input type="text" name="xtream.username" class="input"></label>
                        <label>Password<input type="password" name="xtream.password" class="input"></label>
                    </fieldset>
                    <fieldset>
                        <legend>Tuner</legend>
                        <label>Friendly Name<input type="text" name="tuner.friendly_name" class="input"></label>
                        <label>Tuner Count<input type="number" name="tuner.count" min="1" max="10" class="input"></label>
                    </fieldset>
                    <fieldset>
                        <legend>Proxy</legend>
                        <label>Buffer Size (KB)<input type="number" name="proxy.buffer_size_kb" min="64" max="4096" class="input"></label>
                    </fieldset>
                    <fieldset>
                        <legend>Cache</legend>
                        <label>Channel Refresh (min)<input type="number" name="cache.channel_refresh_minutes" min="5" class="input"></label>
                        <label>EPG Refresh (min)<input type="number" name="cache.epg_refresh_minutes" min="5" class="input"></label>
                    </fieldset>
                    <button type="submit" class="btn btn-primary">Save Settings</button>
                    <span id="save-status" class="save-status"></span>
                </form>
            </section>
        </main>
    </div>

    <div id="toast" class="toast hidden"></div>

    <script src="/dashboard/static/app.js"></script>
</body>
</html>
FILE14EOF

# --- plexiptv/dashboard/static/app.js ---
cat << 'FILE15EOF' > "$BASE_DIR/plexiptv/dashboard/static/app.js"
/* PlexIPTV Dashboard */

let currentPage = 1;
let currentCategory = '';
let currentSearch = '';
let statusInterval = null;
let streamsInterval = null;

// --- API ---

async function api(path, opts = {}) {
    const resp = await fetch('/api' + path, {
        headers: { 'Content-Type': 'application/json', ...opts.headers },
        ...opts,
    });
    return resp.json();
}

// --- Tab Navigation ---

document.querySelectorAll('.nav-link').forEach(link => {
    link.addEventListener('click', e => {
        e.preventDefault();
        const tab = link.dataset.tab;
        document.querySelectorAll('.nav-link').forEach(l => l.classList.remove('active'));
        document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
        link.classList.add('active');
        document.getElementById('tab-' + tab).classList.add('active');

        if (tab === 'status') loadStatus();
        if (tab === 'channels') loadChannels();
        if (tab === 'streams') loadStreams();
        if (tab === 'settings') loadConfig();
    });
});

// --- Status ---

async function loadStatus() {
    try {
        const data = await api('/status');
        const badge = document.getElementById('server-status');
        badge.textContent = 'Online';
        badge.className = 'status-badge online';

        const baseUrl = `http://${data.local_ip}:${data.port}`;
        document.getElementById('tuner-url').textContent = baseUrl;
        document.getElementById('epg-url').textContent = baseUrl + '/xmltv.xml';

        document.getElementById('stats-grid').innerHTML = `
            <div class="stat-card"><div class="label">Tuners</div><div class="value accent">${data.active_streams}/${data.tuner_count}</div></div>
            <div class="stat-card"><div class="label">Total Channels</div><div class="value">${data.total_channels}</div></div>
            <div class="stat-card"><div class="label">Enabled</div><div class="value">${data.enabled_channels}</div></div>
            <div class="stat-card"><div class="label">Uptime</div><div class="value">${formatUptime(data.uptime_seconds)}</div></div>
            <div class="stat-card"><div class="label">Server</div><div class="value" style="font-size:14px">${data.xtream_server}</div></div>
            <div class="stat-card"><div class="label">Local IP</div><div class="value" style="font-size:14px">${data.local_ip}:${data.port}</div></div>
        `;
    } catch {
        document.getElementById('server-status').textContent = 'Offline';
        document.getElementById('server-status').className = 'status-badge offline';
    }
}

function formatUptime(sec) {
    const h = Math.floor(sec / 3600);
    const m = Math.floor((sec % 3600) / 60);
    if (h > 0) return `${h}h ${m}m`;
    return `${m}m`;
}

// --- Channels ---

async function loadCategories() {
    const cats = await api('/categories');
    const select = document.getElementById('category-filter');
    select.innerHTML = '<option value="">All Categories</option>';
    cats.forEach(c => {
        const opt = document.createElement('option');
        opt.value = c.category_id;
        opt.textContent = c.category_name;
        select.appendChild(opt);
    });
}

async function loadChannels(page) {
    if (page !== undefined) currentPage = page;
    const params = new URLSearchParams({ page: currentPage, per_page: 50 });
    if (currentCategory) params.set('category', currentCategory);
    if (currentSearch) params.set('search', currentSearch);

    const data = await api('/channels?' + params);
    document.getElementById('channel-count').textContent = `${data.total} channels`;

    const tbody = document.getElementById('channels-body');
    tbody.innerHTML = data.channels.map(ch => `
        <tr>
            <td>${ch.channel_number || '-'}</td>
            <td>${ch.stream_icon ? `<img class="logo-img" src="${ch.stream_icon}" onerror="this.className='no-logo';this.src=''">` : '<span class="no-logo"></span>'}</td>
            <td>${esc(ch.name)}</td>
            <td style="color:var(--text-dim)">${esc(ch.category_id)}</td>
            <td><span class="epg-badge ${ch.epg_channel_id ? 'yes' : 'no'}">${ch.epg_channel_id ? 'Yes' : 'No'}</span></td>
            <td>
                <label class="toggle">
                    <input type="checkbox" ${ch.enabled ? 'checked' : ''} onchange="toggleChannel(${ch.stream_id})">
                    <span class="slider"></span>
                </label>
            </td>
        </tr>
    `).join('');

    renderPagination(data.page, data.pages);
}

function renderPagination(page, pages) {
    const el = document.getElementById('pagination');
    if (pages <= 1) { el.innerHTML = ''; return; }

    let html = `<button ${page <= 1 ? 'disabled' : ''} onclick="loadChannels(${page - 1})">Prev</button>`;
    html += `<span class="page-info">${page} / ${pages}</span>`;
    html += `<button ${page >= pages ? 'disabled' : ''} onclick="loadChannels(${page + 1})">Next</button>`;
    el.innerHTML = html;
}

async function toggleChannel(streamId) {
    await api(`/channels/${streamId}/toggle`, { method: 'POST' });
}

// Search debounce
let searchTimer;
document.getElementById('channel-search').addEventListener('input', e => {
    clearTimeout(searchTimer);
    searchTimer = setTimeout(() => {
        currentSearch = e.target.value;
        currentPage = 1;
        loadChannels();
    }, 300);
});

document.getElementById('category-filter').addEventListener('change', e => {
    currentCategory = e.target.value;
    currentPage = 1;
    loadChannels();
});

// --- Streams ---

async function loadStreams() {
    const streams = await api('/streams');
    const el = document.getElementById('streams-list');

    if (!streams.length) {
        el.innerHTML = '<p class="empty-state">No active streams</p>';
        return;
    }

    el.innerHTML = streams.map(s => `
        <div class="stream-card">
            <div class="stream-info">
                <h4><span class="live-dot"></span>${esc(s.channel_name)}</h4>
                <p>Stream #${s.stream_id} &middot; Client: ${s.client_ip}</p>
            </div>
            <div class="stream-meta">
                <div>${formatBytes(s.bytes_sent)}</div>
                <div>${timeSince(s.started_at)}</div>
            </div>
        </div>
    `).join('');
}

// --- Settings ---

async function loadConfig() {
    const cfg = await api('/config');
    const form = document.getElementById('settings-form');
    setField(form, 'xtream.server', cfg.xtream.server);
    setField(form, 'xtream.username', cfg.xtream.username);
    setField(form, 'xtream.password', cfg.xtream.password);
    setField(form, 'tuner.friendly_name', cfg.tuner.friendly_name);
    setField(form, 'tuner.count', cfg.tuner.count);
    setField(form, 'proxy.buffer_size_kb', cfg.proxy.buffer_size_kb);
    setField(form, 'cache.channel_refresh_minutes', cfg.cache.channel_refresh_minutes);
    setField(form, 'cache.epg_refresh_minutes', cfg.cache.epg_refresh_minutes);
}

function setField(form, name, value) {
    const el = form.querySelector(`[name="${name}"]`);
    if (el) el.value = value;
}

document.getElementById('settings-form').addEventListener('submit', async e => {
    e.preventDefault();
    const form = e.target;
    const body = {
        xtream: {
            server: form.querySelector('[name="xtream.server"]').value,
            username: form.querySelector('[name="xtream.username"]').value,
            password: form.querySelector('[name="xtream.password"]').value,
        },
        tuner: {
            friendly_name: form.querySelector('[name="tuner.friendly_name"]').value,
            count: parseInt(form.querySelector('[name="tuner.count"]').value),
        },
        proxy: {
            buffer_size_kb: parseInt(form.querySelector('[name="proxy.buffer_size_kb"]').value),
        },
        cache: {
            channel_refresh_minutes: parseInt(form.querySelector('[name="cache.channel_refresh_minutes"]').value),
            epg_refresh_minutes: parseInt(form.querySelector('[name="cache.epg_refresh_minutes"]').value),
        },
    };

    await api('/config', { method: 'PUT', body: JSON.stringify(body) });
    toast('Settings saved', 'success');
});

// --- Actions ---

async function forceRefresh() {
    toast('Refreshing channels & EPG...', '');
    try {
        const result = await api('/refresh', { method: 'POST' });
        if (result.error) {
            toast('Refresh failed: ' + result.error, 'error');
        } else {
            toast(`Refreshed: ${result.categories} categories, ${result.channels} channels`, 'success');
            loadStatus();
        }
    } catch {
        toast('Refresh failed', 'error');
    }
}

// --- Helpers ---

function esc(str) {
    const d = document.createElement('div');
    d.textContent = str || '';
    return d.innerHTML;
}

function formatBytes(b) {
    if (b < 1024) return b + ' B';
    if (b < 1048576) return (b / 1024).toFixed(1) + ' KB';
    if (b < 1073741824) return (b / 1048576).toFixed(1) + ' MB';
    return (b / 1073741824).toFixed(2) + ' GB';
}

function timeSince(isoStr) {
    const sec = Math.floor((Date.now() - new Date(isoStr).getTime()) / 1000);
    if (sec < 60) return sec + 's';
    if (sec < 3600) return Math.floor(sec / 60) + 'm';
    return Math.floor(sec / 3600) + 'h ' + Math.floor((sec % 3600) / 60) + 'm';
}

function toast(msg, type) {
    const el = document.getElementById('toast');
    el.textContent = msg;
    el.className = 'toast' + (type ? ' ' + type : '');
    setTimeout(() => el.classList.add('hidden'), 3000);
}

// --- Init ---

loadStatus();
loadCategories();

// Auto-refresh status every 10s
statusInterval = setInterval(() => {
    const tab = document.querySelector('.tab.active');
    if (tab && tab.id === 'tab-status') loadStatus();
    if (tab && tab.id === 'tab-streams') loadStreams();
}, 10000);
FILE15EOF

# --- plexiptv/dashboard/static/style.css ---
cat << 'FILE16EOF' > "$BASE_DIR/plexiptv/dashboard/static/style.css"
:root {
    --bg: #0f1117;
    --bg-card: #1a1d27;
    --bg-hover: #222633;
    --bg-input: #13151d;
    --border: #2a2e3d;
    --text: #e4e6ed;
    --text-dim: #8b8fa3;
    --accent: #e5a00d;
    --accent-hover: #f0b429;
    --green: #2ecc71;
    --red: #e74c3c;
    --radius: 8px;
    --shadow: 0 2px 8px rgba(0,0,0,0.3);
}

* { margin: 0; padding: 0; box-sizing: border-box; }

body {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
    background: var(--bg);
    color: var(--text);
    line-height: 1.5;
}

.layout {
    display: grid;
    grid-template-columns: 220px 1fr;
    min-height: 100vh;
}

/* Sidebar */
.sidebar {
    background: var(--bg-card);
    border-right: 1px solid var(--border);
    padding: 24px 0;
    display: flex;
    flex-direction: column;
    position: sticky;
    top: 0;
    height: 100vh;
}

.logo {
    padding: 0 20px 24px;
    border-bottom: 1px solid var(--border);
}

.logo h1 {
    font-size: 20px;
    font-weight: 700;
    color: var(--accent);
}

.version {
    font-size: 11px;
    color: var(--text-dim);
}

.nav-links {
    list-style: none;
    padding: 12px 0;
    flex: 1;
}

.nav-link {
    display: block;
    padding: 10px 20px;
    color: var(--text-dim);
    text-decoration: none;
    font-size: 14px;
    transition: all 0.15s;
}

.nav-link:hover { color: var(--text); background: var(--bg-hover); }
.nav-link.active { color: var(--accent); background: var(--bg-hover); border-left: 3px solid var(--accent); }

.sidebar-footer {
    padding: 16px 20px;
    border-top: 1px solid var(--border);
}

.status-badge {
    font-size: 12px;
    padding: 4px 10px;
    border-radius: 12px;
    text-align: center;
}

.status-badge.online { background: rgba(46,204,113,0.15); color: var(--green); }
.status-badge.offline { background: rgba(231,76,60,0.15); color: var(--red); }

/* Content */
.content {
    padding: 32px;
    overflow-y: auto;
}

.tab { display: none; }
.tab.active { display: block; }

h2 {
    font-size: 22px;
    font-weight: 600;
    margin-bottom: 20px;
}

/* Stats Grid */
.stats-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
    gap: 16px;
    margin-bottom: 24px;
}

.stat-card {
    background: var(--bg-card);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: 20px;
}

.stat-card .label {
    font-size: 12px;
    color: var(--text-dim);
    text-transform: uppercase;
    letter-spacing: 0.5px;
}

.stat-card .value {
    font-size: 28px;
    font-weight: 700;
    margin-top: 4px;
}

.stat-card .value.accent { color: var(--accent); }

/* Info Card */
.info-card {
    background: var(--bg-card);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: 20px;
    margin-top: 16px;
}

.info-card h3 { font-size: 16px; margin-bottom: 12px; }
.info-card p { color: var(--text-dim); font-size: 14px; margin-bottom: 8px; }
.info-card ul { padding-left: 20px; margin-top: 8px; }
.info-card li { color: var(--text-dim); font-size: 14px; margin-bottom: 4px; }

code {
    background: var(--bg);
    padding: 2px 8px;
    border-radius: 4px;
    font-size: 13px;
    color: var(--accent);
    user-select: all;
}

/* Toolbar */
.toolbar {
    display: flex;
    gap: 12px;
    align-items: center;
    margin-bottom: 16px;
    flex-wrap: wrap;
}

.input {
    background: var(--bg-input);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    color: var(--text);
    padding: 8px 12px;
    font-size: 14px;
    outline: none;
    transition: border-color 0.15s;
}

.input:focus { border-color: var(--accent); }

#channel-search { width: 260px; }
#category-filter { width: 200px; }

.badge {
    font-size: 12px;
    color: var(--text-dim);
    background: var(--bg-card);
    padding: 6px 12px;
    border-radius: 12px;
    white-space: nowrap;
}

/* Table */
.table-wrap {
    overflow-x: auto;
    border: 1px solid var(--border);
    border-radius: var(--radius);
}

.table {
    width: 100%;
    border-collapse: collapse;
}

.table th {
    text-align: left;
    padding: 12px 16px;
    font-size: 12px;
    text-transform: uppercase;
    letter-spacing: 0.5px;
    color: var(--text-dim);
    background: var(--bg-card);
    border-bottom: 1px solid var(--border);
}

.table td {
    padding: 10px 16px;
    font-size: 14px;
    border-bottom: 1px solid var(--border);
}

.table tr:hover td { background: var(--bg-hover); }

.table .logo-img {
    width: 28px;
    height: 28px;
    border-radius: 4px;
    object-fit: contain;
    background: var(--bg);
}

.table .no-logo {
    width: 28px;
    height: 28px;
    border-radius: 4px;
    background: var(--border);
    display: inline-block;
}

/* Toggle */
.toggle {
    position: relative;
    width: 40px;
    height: 22px;
    cursor: pointer;
}

.toggle input { opacity: 0; width: 0; height: 0; }

.toggle .slider {
    position: absolute;
    inset: 0;
    background: var(--border);
    border-radius: 11px;
    transition: 0.2s;
}

.toggle .slider::before {
    content: '';
    position: absolute;
    width: 16px;
    height: 16px;
    left: 3px;
    bottom: 3px;
    background: var(--text);
    border-radius: 50%;
    transition: 0.2s;
}

.toggle input:checked + .slider { background: var(--green); }
.toggle input:checked + .slider::before { transform: translateX(18px); }

.epg-badge {
    font-size: 11px;
    padding: 2px 6px;
    border-radius: 4px;
}

.epg-badge.yes { background: rgba(46,204,113,0.15); color: var(--green); }
.epg-badge.no { background: rgba(139,143,163,0.1); color: var(--text-dim); }

/* Pagination */
.pagination {
    display: flex;
    gap: 8px;
    justify-content: center;
    margin-top: 16px;
    align-items: center;
}

.pagination button {
    background: var(--bg-card);
    border: 1px solid var(--border);
    color: var(--text);
    padding: 6px 14px;
    border-radius: var(--radius);
    cursor: pointer;
    font-size: 13px;
}

.pagination button:hover { background: var(--bg-hover); }
.pagination button.active { background: var(--accent); color: var(--bg); border-color: var(--accent); }
.pagination button:disabled { opacity: 0.3; cursor: default; }
.pagination .page-info { font-size: 13px; color: var(--text-dim); }

/* Streams */
.streams-list { display: flex; flex-direction: column; gap: 12px; }

.stream-card {
    background: var(--bg-card);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: 16px;
    display: flex;
    justify-content: space-between;
    align-items: center;
}

.stream-card .stream-info h4 { font-size: 15px; }
.stream-card .stream-info p { font-size: 13px; color: var(--text-dim); }
.stream-card .stream-meta { text-align: right; font-size: 13px; color: var(--text-dim); }
.stream-card .live-dot {
    display: inline-block;
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: var(--green);
    animation: pulse 1.5s infinite;
    margin-right: 6px;
}

@keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.4; } }

.empty-state { color: var(--text-dim); font-size: 14px; text-align: center; padding: 40px; }

/* Settings */
.settings-form fieldset {
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: 20px;
    margin-bottom: 16px;
    background: var(--bg-card);
}

.settings-form legend {
    font-size: 14px;
    font-weight: 600;
    padding: 0 8px;
    color: var(--accent);
}

.settings-form label {
    display: block;
    font-size: 13px;
    color: var(--text-dim);
    margin-bottom: 12px;
}

.settings-form label .input {
    display: block;
    width: 100%;
    max-width: 400px;
    margin-top: 4px;
}

.save-status {
    font-size: 13px;
    margin-left: 12px;
    color: var(--green);
}

/* Buttons */
.btn {
    padding: 8px 20px;
    border-radius: var(--radius);
    border: 1px solid var(--border);
    font-size: 14px;
    cursor: pointer;
    transition: all 0.15s;
    background: var(--bg-card);
    color: var(--text);
}

.btn:hover { background: var(--bg-hover); }

.btn-primary {
    background: var(--accent);
    color: var(--bg);
    border-color: var(--accent);
    font-weight: 600;
}

.btn-primary:hover { background: var(--accent-hover); }

.actions-bar { margin-bottom: 16px; }

/* Toast */
.toast {
    position: fixed;
    bottom: 24px;
    right: 24px;
    background: var(--bg-card);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: 12px 20px;
    font-size: 14px;
    box-shadow: var(--shadow);
    z-index: 1000;
    transition: opacity 0.3s, transform 0.3s;
}

.toast.hidden { opacity: 0; transform: translateY(10px); pointer-events: none; }
.toast.success { border-color: var(--green); }
.toast.error { border-color: var(--red); }

/* Responsive */
@media (max-width: 768px) {
    .layout { grid-template-columns: 1fr; }
    .sidebar {
        position: relative;
        height: auto;
        flex-direction: row;
        align-items: center;
        padding: 12px;
    }
    .logo { padding: 0 12px 0 0; border-bottom: none; }
    .nav-links { display: flex; padding: 0; }
    .nav-link { padding: 8px 12px; font-size: 13px; }
    .nav-link.active { border-left: none; border-bottom: 2px solid var(--accent); }
    .sidebar-footer { display: none; }
    .content { padding: 20px; }
    .stats-grid { grid-template-columns: repeat(2, 1fr); }
}
FILE16EOF

# --- plexiptv/hdhr/__init__.py ---
cat << 'FILE17EOF' > "$BASE_DIR/plexiptv/hdhr/__init__.py"
FILE17EOF

# --- plexiptv/hdhr/router.py ---
cat << 'FILE18EOF' > "$BASE_DIR/plexiptv/hdhr/router.py"
from __future__ import annotations

import logging
from datetime import datetime, timezone
from xml.etree.ElementTree import Element, SubElement, tostring

from fastapi import APIRouter, Request, Response
from fastapi.responses import StreamingResponse

from plexiptv.proxy.stream import TunerBusyError

logger = logging.getLogger(__name__)

router = APIRouter()


@router.get("/discover.json")
async def discover(request: Request) -> dict:
    settings = request.app.state.settings
    local_ip = request.app.state.local_ip
    port = settings.server.port
    device_id = settings.tuner.device_id

    return {
        "FriendlyName": settings.tuner.friendly_name,
        "Manufacturer": "PlexIPTV",
        "ModelNumber": "HDTC-2US",
        "FirmwareName": "hdhomeruntc_atsc",
        "FirmwareVersion": "20240101",
        "DeviceID": device_id,
        "DeviceAuth": "plexiptv",
        "BaseURL": f"http://{local_ip}:{port}",
        "LineupURL": f"http://{local_ip}:{port}/lineup.json",
        "TunerCount": settings.tuner.count,
    }


@router.get("/lineup.json")
async def lineup(request: Request) -> list[dict]:
    cache = request.app.state.cache
    settings = request.app.state.settings
    local_ip = request.app.state.local_ip
    port = settings.server.port

    channels, _ = await cache.get_channels(enabled_only=True, per_page=10000)
    result = []
    for idx, ch in enumerate(channels, start=1):
        number = str(ch.channel_number) if ch.channel_number > 0 else str(idx)
        result.append({
            "GuideNumber": number,
            "GuideName": ch.name,
            "URL": f"http://{local_ip}:{port}/stream/{ch.stream_id}",
        })
    return result


@router.get("/lineup_status.json")
async def lineup_status() -> dict:
    return {
        "ScanInProgress": 0,
        "ScanPossible": 1,
        "Source": "Cable",
        "SourceList": ["Cable"],
    }


@router.post("/lineup.post")
async def lineup_scan() -> Response:
    return Response(status_code=200)


@router.get("/stream/{stream_id}")
async def proxy_stream(stream_id: int, request: Request) -> StreamingResponse:
    stream_manager = request.app.state.stream_manager
    cache = request.app.state.cache
    client_ip = request.client.host if request.client else "unknown"

    channel = await cache.get_channel_by_id(stream_id)
    channel_name = channel.name if channel else f"Channel {stream_id}"

    try:
        generator = stream_manager.open_stream(stream_id, channel_name, client_ip)
        return StreamingResponse(
            generator,
            media_type="video/mpegts",
            headers={
                "Connection": "close",
                "Cache-Control": "no-cache, no-store",
                "X-Accel-Buffering": "no",
            },
        )
    except TunerBusyError:
        return StreamingResponse(
            iter([b""]),
            status_code=503,
            media_type="text/plain",
        )


@router.get("/xmltv.xml")
async def xmltv(request: Request) -> Response:
    cache = request.app.state.cache
    channels, programmes = await cache.get_all_epg_for_xmltv()

    tv = Element("tv")
    tv.set("generator-info-name", "PlexIPTV")

    for ch in channels:
        chan_el = SubElement(tv, "channel")
        chan_el.set("id", ch["id"])
        dn = SubElement(chan_el, "display-name")
        dn.text = ch["name"]
        if ch.get("icon"):
            icon_el = SubElement(chan_el, "icon")
            icon_el.set("src", ch["icon"])

    for prog in programmes:
        prog_el = SubElement(tv, "programme")
        prog_el.set("start", _xmltv_time(prog["start_ts"]))
        prog_el.set("stop", _xmltv_time(prog["end_ts"]))
        prog_el.set("channel", prog["channel_id"])
        title_el = SubElement(prog_el, "title")
        title_el.text = prog["title"]
        if prog.get("description"):
            desc_el = SubElement(prog_el, "desc")
            desc_el.text = prog["description"]

    xml_bytes = b'<?xml version="1.0" encoding="UTF-8"?>\n' + tostring(tv, encoding="unicode").encode("utf-8")
    return Response(content=xml_bytes, media_type="application/xml")


def _xmltv_time(ts: int) -> str:
    dt = datetime.fromtimestamp(ts, tz=timezone.utc)
    return dt.strftime("%Y%m%d%H%M%S") + " +0000"
FILE18EOF

# --- plexiptv/hdhr/ssdp.py ---
cat << 'FILE19EOF' > "$BASE_DIR/plexiptv/hdhr/ssdp.py"
from __future__ import annotations

import asyncio
import logging
import socket
import struct

from plexiptv.config import Settings

logger = logging.getLogger(__name__)

SSDP_ADDR = "239.255.255.250"
SSDP_PORT = 1900
DEVICE_TYPE = "urn:schemas-upnp-org:device:MediaServer:1"


class SSDPServer:
    def __init__(self, settings: Settings, local_ip: str) -> None:
        self._settings = settings
        self._local_ip = local_ip
        self._port = settings.server.port
        self._device_id = settings.tuner.device_id
        self._uuid = f"uuid:{self._device_id}-PlexIPTV"
        self._running = False
        self._transport: asyncio.DatagramTransport | None = None
        self._tasks: list[asyncio.Task] = []

    @property
    def _location(self) -> str:
        return f"http://{self._local_ip}:{self._port}/discover.json"

    def _build_response(self, st: str) -> bytes:
        lines = [
            "HTTP/1.1 200 OK",
            f"CACHE-CONTROL: max-age=1800",
            f"ST: {st}",
            f"USN: {self._uuid}::{st}",
            f"LOCATION: {self._location}",
            f"SERVER: PlexIPTV/1.0 UPnP/1.0",
            "",
            "",
        ]
        return "\r\n".join(lines).encode()

    def _build_notify(self) -> bytes:
        lines = [
            "NOTIFY * HTTP/1.1",
            f"HOST: {SSDP_ADDR}:{SSDP_PORT}",
            "NTS: ssdp:alive",
            f"NT: {DEVICE_TYPE}",
            f"USN: {self._uuid}::{DEVICE_TYPE}",
            f"LOCATION: {self._location}",
            f"CACHE-CONTROL: max-age=1800",
            f"SERVER: PlexIPTV/1.0 UPnP/1.0",
            "",
            "",
        ]
        return "\r\n".join(lines).encode()

    def _build_byebye(self) -> bytes:
        lines = [
            "NOTIFY * HTTP/1.1",
            f"HOST: {SSDP_ADDR}:{SSDP_PORT}",
            "NTS: ssdp:byebye",
            f"NT: {DEVICE_TYPE}",
            f"USN: {self._uuid}::{DEVICE_TYPE}",
            "",
            "",
        ]
        return "\r\n".join(lines).encode()

    async def start(self) -> None:
        self._running = True
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            # On Windows, SO_REUSEPORT doesn't exist
            try:
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
            except (AttributeError, OSError):
                pass
            sock.bind(("", SSDP_PORT))

            # Join multicast group
            mreq = struct.pack("4s4s", socket.inet_aton(SSDP_ADDR), socket.inet_aton(self._local_ip))
            sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
            sock.setblocking(False)

            loop = asyncio.get_running_loop()
            self._transport, _ = await loop.create_datagram_endpoint(
                lambda: _SSDPProtocol(self),
                sock=sock,
            )

            self._tasks.append(asyncio.create_task(self._advertise_loop()))
            logger.info("SSDP server started on %s:%d", self._local_ip, SSDP_PORT)

        except OSError as e:
            logger.warning(
                "SSDP bind failed (port %d may be in use): %s. "
                "Plex can still find the tuner manually at %s",
                SSDP_PORT, e, self._location,
            )

    async def _advertise_loop(self) -> None:
        while self._running:
            try:
                if self._transport:
                    self._transport.sendto(self._build_notify(), (SSDP_ADDR, SSDP_PORT))
            except Exception as e:
                logger.debug("SSDP notify error: %s", e)
            await asyncio.sleep(60)

    def handle_search(self, data: bytes, addr: tuple[str, int]) -> None:
        msg = data.decode("utf-8", errors="ignore")
        if "M-SEARCH" not in msg:
            return

        st = ""
        for line in msg.split("\r\n"):
            if line.upper().startswith("ST:"):
                st = line.split(":", 1)[1].strip()
                break

        if st in ("ssdp:all", "upnp:rootdevice", DEVICE_TYPE):
            if self._transport:
                response = self._build_response(st if st != "ssdp:all" else DEVICE_TYPE)
                self._transport.sendto(response, addr)
                logger.debug("SSDP response sent to %s", addr)

    async def stop(self) -> None:
        self._running = False
        for task in self._tasks:
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass

        if self._transport:
            try:
                self._transport.sendto(self._build_byebye(), (SSDP_ADDR, SSDP_PORT))
            except Exception:
                pass
            self._transport.close()
        logger.info("SSDP server stopped")


class _SSDPProtocol(asyncio.DatagramProtocol):
    def __init__(self, server: SSDPServer) -> None:
        self._server = server

    def datagram_received(self, data: bytes, addr: tuple[str, int]) -> None:
        self._server.handle_search(data, addr)

    def error_received(self, exc: Exception) -> None:
        logger.debug("SSDP protocol error: %s", exc)
FILE19EOF

# --- plexiptv/proxy/__init__.py ---
cat << 'FILE20EOF' > "$BASE_DIR/plexiptv/proxy/__init__.py"
FILE20EOF

# --- plexiptv/proxy/stream.py ---
cat << 'FILE21EOF' > "$BASE_DIR/plexiptv/proxy/stream.py"
from __future__ import annotations

import asyncio
import logging
import uuid
from collections.abc import AsyncGenerator
from datetime import datetime, timezone

import httpx

from plexiptv.config import Settings
from plexiptv.models import ActiveStream
from plexiptv.xtream.client import XtreamClient

logger = logging.getLogger(__name__)

CHUNK_SIZE = 65536  # 64KB chunks
MAX_RECONNECT_ATTEMPTS = 5
RECONNECT_DELAY_SECONDS = 2


class StreamManager:
    def __init__(self, settings: Settings, xtream: XtreamClient) -> None:
        self._settings = settings
        self._xtream = xtream
        self._semaphore = asyncio.Semaphore(settings.tuner.count)
        self.active_streams: dict[str, ActiveStream] = {}
        self._client = httpx.AsyncClient(
            timeout=httpx.Timeout(connect=15, read=None, write=10, pool=10),
            limits=httpx.Limits(
                max_connections=settings.tuner.count + 4,
                max_keepalive_connections=settings.tuner.count,
            ),
            follow_redirects=True,
        )

    def tuner_available(self) -> bool:
        return len(self.active_streams) < self._settings.tuner.count

    def get_active(self) -> list[ActiveStream]:
        return list(self.active_streams.values())

    async def open_stream(
        self, stream_id: int, channel_name: str, client_ip: str
    ) -> AsyncGenerator[bytes, None]:
        session_id = uuid.uuid4().hex[:8]

        if not self._semaphore._value:
            logger.warning(
                "All tuners busy, rejecting stream %d from %s", stream_id, client_ip
            )
            raise TunerBusyError("All tuners are in use")

        await self._semaphore.acquire()
        stream_info = ActiveStream(
            session_id=session_id,
            stream_id=stream_id,
            channel_name=channel_name,
            client_ip=client_ip,
            started_at=datetime.now(timezone.utc),
        )
        self.active_streams[session_id] = stream_info
        logger.info(
            "Stream %s started: ch=%d (%s) client=%s",
            session_id, stream_id, channel_name, client_ip,
        )

        url = self._xtream.build_stream_url(stream_id)
        buffer_bytes = self._settings.proxy.buffer_size_kb * 1024

        try:
            attempt = 0
            while attempt <= MAX_RECONNECT_ATTEMPTS:
                try:
                    async with self._client.stream("GET", url) as resp:
                        resp.raise_for_status()

                        # Pre-buffer: accumulate before sending first byte
                        # Only on the very first attempt
                        if attempt == 0:
                            pre_buffer = bytearray()
                            async for chunk in resp.aiter_bytes(CHUNK_SIZE):
                                pre_buffer.extend(chunk)
                                if len(pre_buffer) >= buffer_bytes:
                                    break
                            if pre_buffer:
                                stream_info.bytes_sent += len(pre_buffer)
                                yield bytes(pre_buffer)

                        # Pass-through with keepalive tracking
                        last_data_time = asyncio.get_event_loop().time()
                        async for chunk in resp.aiter_bytes(CHUNK_SIZE):
                            stream_info.bytes_sent += len(chunk)
                            last_data_time = asyncio.get_event_loop().time()
                            yield chunk

                        # Stream ended cleanly (server closed) — try reconnect
                        logger.info(
                            "Stream %s: upstream closed connection after %d bytes, reconnecting...",
                            session_id, stream_info.bytes_sent,
                        )

                except httpx.HTTPStatusError as e:
                    logger.error(
                        "Stream %s: HTTP %d from upstream", session_id, e.response.status_code
                    )
                    if e.response.status_code in (401, 403, 404):
                        break  # Don't retry auth / not-found errors
                except (httpx.StreamError, httpx.RemoteProtocolError, httpx.ReadError) as e:
                    logger.warning(
                        "Stream %s: upstream error on attempt %d: %s",
                        session_id, attempt + 1, e,
                    )
                except httpx.ConnectError as e:
                    logger.warning(
                        "Stream %s: connection failed on attempt %d: %s",
                        session_id, attempt + 1, e,
                    )

                attempt += 1
                if attempt <= MAX_RECONNECT_ATTEMPTS:
                    delay = RECONNECT_DELAY_SECONDS * attempt
                    logger.info(
                        "Stream %s: reconnect attempt %d/%d in %.1fs",
                        session_id, attempt, MAX_RECONNECT_ATTEMPTS, delay,
                    )
                    await asyncio.sleep(delay)

            if attempt > MAX_RECONNECT_ATTEMPTS:
                logger.error(
                    "Stream %s: exhausted %d reconnect attempts",
                    session_id, MAX_RECONNECT_ATTEMPTS,
                )

        except GeneratorExit:
            logger.info("Client disconnected from stream %s", session_id)
        except Exception as e:
            logger.error("Unexpected error in stream %s: %s", session_id, e)
        finally:
            self.active_streams.pop(session_id, None)
            self._semaphore.release()
            logger.info(
                "Stream %s ended: %d bytes sent", session_id, stream_info.bytes_sent
            )

    async def close(self) -> None:
        await self._client.aclose()


class TunerBusyError(Exception):
    pass
FILE21EOF

# --- plexiptv/xtream/__init__.py ---
cat << 'FILE22EOF' > "$BASE_DIR/plexiptv/xtream/__init__.py"
FILE22EOF

# --- plexiptv/xtream/client.py ---
cat << 'FILE23EOF' > "$BASE_DIR/plexiptv/xtream/client.py"
from __future__ import annotations

import base64
import logging
from datetime import datetime, timezone

import httpx

from plexiptv.config import Settings
from plexiptv.models import Category, Channel, EpgEntry

logger = logging.getLogger(__name__)


class XtreamAPIError(Exception):
    pass


class XtreamClient:
    def __init__(self, settings: Settings) -> None:
        self._server = settings.xtream.server.rstrip("/")
        self._username = settings.xtream.username
        self._password = settings.xtream.password
        self._client = httpx.AsyncClient(
            timeout=httpx.Timeout(connect=15, read=60, write=10, pool=10),
            limits=httpx.Limits(max_connections=20, max_keepalive_connections=10),
            follow_redirects=True,
        )

    @property
    def _base_params(self) -> dict[str, str]:
        return {"username": self._username, "password": self._password}

    async def _get(self, action: str, extra: dict | None = None) -> list | dict:
        params = {**self._base_params, "action": action}
        if extra:
            params.update(extra)
        url = f"{self._server}/player_api.php"
        try:
            resp = await self._client.get(url, params=params)
            resp.raise_for_status()
            return resp.json()
        except httpx.HTTPStatusError as e:
            raise XtreamAPIError(f"API returned {e.response.status_code}") from e
        except Exception as e:
            raise XtreamAPIError(f"API request failed: {e}") from e

    async def get_account_info(self) -> dict:
        data = await self._get("get_account_info")
        return data if isinstance(data, dict) else {}

    async def get_live_categories(self) -> list[Category]:
        data = await self._get("get_live_categories")
        if not isinstance(data, list):
            return []
        results = []
        for item in data:
            try:
                results.append(Category(
                    category_id=str(item.get("category_id", "")),
                    category_name=item.get("category_name", "Unknown"),
                ))
            except Exception:
                logger.debug("Skipping malformed category: %s", item)
        return results

    async def get_live_streams(self, category_id: str | None = None) -> list[Channel]:
        extra = {}
        if category_id:
            extra["category_id"] = category_id
        data = await self._get("get_live_streams", extra)
        if not isinstance(data, list):
            return []
        results = []
        for item in data:
            try:
                results.append(Channel(
                    stream_id=int(item.get("stream_id", item.get("num", 0))),
                    name=item.get("name", item.get("stream_display_name", "Unknown")),
                    category_id=str(item.get("category_id", "")),
                    epg_channel_id=item.get("epg_channel_id") or None,
                    stream_icon=item.get("stream_icon") or None,
                ))
            except Exception:
                logger.debug("Skipping malformed channel: %s", item)
        return results

    async def get_short_epg(self, stream_id: int, limit: int = 10) -> list[EpgEntry]:
        data = await self._get(
            "get_short_epg", {"stream_id": str(stream_id), "limit": str(limit)}
        )
        return self._parse_epg(data)

    async def get_full_epg(self) -> list[EpgEntry]:
        """Try multiple EPG endpoints — providers vary in what they support."""
        # Method 1: get_simple_data_table with stream_id=all
        try:
            data = await self._get("get_simple_data_table", {"stream_id": "all"})
            entries = self._parse_epg(data)
            if entries:
                logger.info("EPG method 1 (get_simple_data_table) returned %d entries", len(entries))
                return entries
        except XtreamAPIError:
            logger.debug("EPG method 1 failed, trying next...")

        # Method 2: xmltv.php endpoint (some Xtream panels expose this)
        try:
            url = f"{self._server}/xmltv.php"
            resp = await self._client.get(url, params=self._base_params, timeout=120)
            if resp.status_code == 200 and resp.headers.get("content-type", "").startswith(("text/xml", "application/xml")):
                entries = self._parse_xmltv_epg(resp.text)
                if entries:
                    logger.info("EPG method 2 (xmltv.php) returned %d entries", len(entries))
                    return entries
        except Exception as e:
            logger.debug("EPG method 2 (xmltv.php) failed: %s", e)

        logger.warning("No EPG data could be fetched from any endpoint")
        return []

    def _parse_epg(self, data: dict | list) -> list[EpgEntry]:
        items = []
        if isinstance(data, dict):
            epg_listings = data.get("epg_listings", [])
            if isinstance(epg_listings, list):
                items = epg_listings
        elif isinstance(data, list):
            items = data

        results = []
        for item in items:
            try:
                # Many Xtream providers base64-encode title and description
                title = self._maybe_decode_b64(item.get("title", ""))
                description = self._maybe_decode_b64(
                    item.get("description", item.get("desc", ""))
                )

                start_str = item.get("start", item.get("start_timestamp", ""))
                end_str = item.get("end", item.get("stop_timestamp", ""))
                start = self._parse_datetime(str(start_str))
                end = self._parse_datetime(str(end_str))
                if not start or not end:
                    continue

                channel_id = str(
                    item.get("channel_id", item.get("epg_channel_id", item.get("stream_id", "")))
                )

                results.append(EpgEntry(
                    epg_id=str(item.get("id", item.get("epg_id", ""))),
                    channel_id=channel_id,
                    title=title,
                    description=description,
                    start=start,
                    end=end,
                ))
            except Exception:
                logger.debug("Skipping malformed EPG entry: %s", item)
        return results

    def _parse_xmltv_epg(self, xml_text: str) -> list[EpgEntry]:
        """Parse XMLTV format EPG data."""
        import xml.etree.ElementTree as ET

        results = []
        try:
            root = ET.fromstring(xml_text)
            for prog in root.findall("programme"):
                try:
                    start_str = prog.get("start", "")
                    stop_str = prog.get("stop", "")
                    channel_id = prog.get("channel", "")

                    title_el = prog.find("title")
                    desc_el = prog.find("desc")

                    title = title_el.text if title_el is not None and title_el.text else ""
                    description = desc_el.text if desc_el is not None and desc_el.text else ""

                    start = self._parse_xmltv_datetime(start_str)
                    stop = self._parse_xmltv_datetime(stop_str)
                    if not start or not stop:
                        continue

                    results.append(EpgEntry(
                        epg_id="",
                        channel_id=channel_id,
                        title=title,
                        description=description,
                        start=start,
                        end=stop,
                    ))
                except Exception:
                    continue
        except ET.ParseError:
            logger.warning("Failed to parse XMLTV EPG data")
        return results

    @staticmethod
    def _parse_xmltv_datetime(value: str) -> datetime | None:
        """Parse XMLTV datetime format: 20260402120000 +0000"""
        if not value:
            return None
        value = value.strip()
        for fmt in ("%Y%m%d%H%M%S %z", "%Y%m%d%H%M%S"):
            try:
                return datetime.strptime(value, fmt)
            except ValueError:
                continue
        return None

    @staticmethod
    def _maybe_decode_b64(value: str) -> str:
        """Attempt base64 decode; return original string if it fails."""
        if not value:
            return ""
        try:
            decoded = base64.b64decode(value, validate=True).decode("utf-8")
            # Sanity check: if it decodes to something printable, use it
            if decoded.isprintable() or "\n" in decoded:
                return decoded
        except Exception:
            pass
        return value

    @staticmethod
    def _parse_datetime(value: str) -> datetime | None:
        if not value:
            return None
        for fmt in (
            "%Y-%m-%d %H:%M:%S",
            "%Y-%m-%dT%H:%M:%S",
            "%Y-%m-%d %H:%M:%S.%f",
            "%Y-%m-%dT%H:%M:%S%z",
        ):
            try:
                dt = datetime.strptime(value, fmt)
                if dt.tzinfo is None:
                    dt = dt.replace(tzinfo=timezone.utc)
                return dt
            except ValueError:
                continue
        try:
            return datetime.fromtimestamp(int(value), tz=timezone.utc)
        except (ValueError, OSError):
            return None

    def build_stream_url(self, stream_id: int) -> str:
        return f"{self._server}/live/{self._username}/{self._password}/{stream_id}.ts"

    async def close(self) -> None:
        await self._client.aclose()
FILE23EOF

# Build the Docker image
cd "$BASE_DIR" && docker build -t plexiptv:latest . && echo "SUCCESS: plexiptv:latest image built!"
