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

    settings: Settings = request.app.state.settings

    try:
        categories = await xtream.get_live_categories()
        await cache.upsert_categories(categories)
        channels = await xtream.get_live_streams()
        await cache.upsert_channels(channels)
        logger.info("Force refresh: %d categories, %d channels", len(categories), len(channels))

        # Re-insert custom channels and re-apply filters (same as initial sync)
        if settings.filter.custom_channels:
            await cache.upsert_custom_channels(settings.filter.custom_channels)
        cat_kw = settings.filter.category_keywords
        cat_ex = settings.filter.category_exclude
        ch_names = settings.filter.channel_names
        if cat_kw or ch_names:
            await cache.apply_combined_filter(cat_kw, ch_names, cat_ex)

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
