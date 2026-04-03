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
