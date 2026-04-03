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

    # Dashboard static files (optional — app works without them)
    if STATIC_DIR.exists():
        app.mount("/dashboard/static", StaticFiles(directory=str(STATIC_DIR)), name="dashboard-static")

        @app.get("/dashboard", include_in_schema=False)
        @app.get("/dashboard/", include_in_schema=False)
        async def dashboard_index():
            from fastapi.responses import FileResponse
            return FileResponse(STATIC_DIR / "index.html")
    else:
        logger.warning("Dashboard static dir not found at %s — dashboard disabled", STATIC_DIR)

    return app
