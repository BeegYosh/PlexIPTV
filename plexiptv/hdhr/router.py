from __future__ import annotations

import logging
from datetime import datetime, timezone
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
        # GuideName must match XMLTV channel id for Plex EPG mapping
        xmltv_id = ch.epg_channel_id or str(ch.stream_id)
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

    # Build XML manually for better control over encoding and size
    parts: list[str] = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<!DOCTYPE tv SYSTEM "xmltv.dtd">',
        '<tv generator-info-name="PlexIPTV">',
    ]

    for ch in channels:
        cid = _xml_escape(ch["id"])
        name = _xml_escape(ch["name"] or "Unknown")
        parts.append(f'<channel id="{cid}">')
        parts.append(f'<display-name>{name}</display-name>')
        if ch.get("icon"):
            parts.append(f'<icon src="{_xml_escape(ch["icon"])}" />')
        parts.append('</channel>')

    for prog in programmes:
        start = _xmltv_time(prog["start_ts"])
        stop = _xmltv_time(prog["end_ts"])
        cid = _xml_escape(prog["channel_id"])
        title = _xml_escape(prog["title"] or "")
        parts.append(f'<programme start="{start}" stop="{stop}" channel="{cid}">')
        parts.append(f'<title lang="es">{title}</title>')
        desc = prog.get("description")
        if desc:
            parts.append(f'<desc lang="es">{_xml_escape(desc)}</desc>')
        parts.append('</programme>')

    parts.append('</tv>')

    xml_str = "\n".join(parts)
    logger.info("XMLTV: %d channels, %d programmes, %d bytes",
                len(channels), len(programmes), len(xml_str))
    return Response(
        content=xml_str.encode("utf-8"),
        media_type="application/xml; charset=utf-8",
    )


def _xml_escape(text: str) -> str:
    """Escape XML special characters."""
    return (
        text.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
        .replace("'", "&apos;")
    )


def _xmltv_time(ts: int) -> str:
    dt = datetime.fromtimestamp(ts, tz=timezone.utc)
    return dt.strftime("%Y%m%d%H%M%S") + " +0000"
