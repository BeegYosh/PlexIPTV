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
