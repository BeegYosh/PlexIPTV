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
