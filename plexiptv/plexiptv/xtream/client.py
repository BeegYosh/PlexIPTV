from __future__ import annotations

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
            timeout=httpx.Timeout(connect=10, read=30, write=10, pool=10),
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
        data = await self._get("get_short_epg", {"stream_id": str(stream_id), "limit": str(limit)})
        return self._parse_epg(data)

    async def get_full_epg(self) -> list[EpgEntry]:
        data = await self._get("get_simple_data_table", {"stream_id": "all"})
        return self._parse_epg(data)

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
                start_str = item.get("start", "")
                end_str = item.get("end", "")
                start = self._parse_datetime(start_str)
                end = self._parse_datetime(end_str)
                if not start or not end:
                    continue
                results.append(EpgEntry(
                    epg_id=str(item.get("id", item.get("epg_id", ""))),
                    channel_id=str(item.get("channel_id", item.get("epg_channel_id", ""))),
                    title=item.get("title", ""),
                    description=item.get("description", item.get("desc", "")),
                    start=start,
                    end=end,
                ))
            except Exception:
                logger.debug("Skipping malformed EPG entry: %s", item)
        return results

    @staticmethod
    def _parse_datetime(value: str) -> datetime | None:
        if not value:
            return None
        for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d %H:%M:%S.%f"):
            try:
                return datetime.strptime(value, fmt).replace(tzinfo=timezone.utc)
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
