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

    async def apply_category_filter(self, keywords: list[str]) -> int:
        """Disable all channels, then enable only those whose category name
        contains at least one of the given keywords (case-insensitive).
        Returns the number of enabled channels."""
        assert self._db
        if not keywords:
            return 0

        # Disable everything first
        await self._db.execute("UPDATE channels SET enabled=0")

        # Build a query that matches any keyword in the category name
        # Join channels to categories so we can filter by category_name
        conditions = " OR ".join(["c2.category_name LIKE ?" for _ in keywords])
        params = [f"%{kw}%" for kw in keywords]

        await self._db.execute(
            f"""UPDATE channels SET enabled=1
                WHERE category_id IN (
                    SELECT c2.category_id FROM categories c2
                    WHERE {conditions}
                )""",
            params,
        )
        await self._db.commit()

        # Reset channel numbers for newly enabled set
        await self._db.execute("UPDATE channels SET channel_number=0 WHERE enabled=1")
        await self._db.commit()
        await self._assign_channel_numbers()

        # Count enabled
        async with self._db.execute("SELECT COUNT(*) FROM channels WHERE enabled=1") as cur:
            row = await cur.fetchone()
            return row[0] if row else 0

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
        """Return ALL enabled channels and EPG entries for XMLTV generation.

        XMLTV channel IDs always use stream_id (numeric, unique, clean).
        EPG entries from the provider are re-mapped from epg_channel_id →
        stream_id so everything stays consistent with lineup.json Station.
        Channels without real EPG get placeholder 3-hour blocks for 7 days.
        """
        assert self._db
        from datetime import datetime, timezone

        now = int(datetime.now(timezone.utc).timestamp())

        # ── Enabled channels ─────────────────────────────────────────
        # Always use stream_id as the XMLTV id for consistency with lineup
        channels: list[dict] = []
        # Map provider epg_channel_id → stream_id for re-mapping EPG entries
        epg_id_to_stream_id: dict[str, str] = {}
        stream_ids: set[str] = set()

        async with self._db.execute(
            "SELECT stream_id, name, stream_icon, epg_channel_id, channel_number "
            "FROM channels WHERE enabled=1 ORDER BY channel_number, name"
        ) as cur:
            async for row in cur:
                sid = str(row["stream_id"])
                channels.append({
                    "id": sid,
                    "stream_id": row["stream_id"],
                    "name": row["name"],
                    "icon": row["stream_icon"],
                    "number": row["channel_number"],
                })
                stream_ids.add(sid)
                if row["epg_channel_id"]:
                    epg_id_to_stream_id[row["epg_channel_id"]] = sid

        # ── Real EPG entries — re-map channel_id to stream_id ────────
        programmes: list[dict] = []
        channels_with_epg: set[str] = set()

        if epg_id_to_stream_id:
            # Fetch EPG for all provider epg_channel_ids that belong to enabled channels
            placeholders = ",".join("?" for _ in epg_id_to_stream_id)
            async with self._db.execute(
                f"SELECT * FROM epg WHERE end_ts > ? AND channel_id IN ({placeholders}) "
                "ORDER BY channel_id, start_ts",
                [now, *epg_id_to_stream_id.keys()],
            ) as cur:
                async for row in cur:
                    # Re-map from provider epg_channel_id to our stream_id
                    mapped_id = epg_id_to_stream_id.get(row["channel_id"], row["channel_id"])
                    programmes.append({
                        "channel_id": mapped_id,
                        "title": row["title"],
                        "description": row["description"],
                        "start_ts": row["start_ts"],
                        "end_ts": row["end_ts"],
                    })
                    channels_with_epg.add(mapped_id)

        # ── Placeholder programmes for channels without real EPG ─────
        BLOCK_HOURS = 3
        BLOCK_SEC = BLOCK_HOURS * 3600
        DAYS_AHEAD = 7
        block_start = now - (now % BLOCK_SEC)
        total_blocks = (DAYS_AHEAD * 24) // BLOCK_HOURS

        for ch in channels:
            if ch["id"] not in channels_with_epg:
                for i in range(total_blocks):
                    ts = block_start + (i * BLOCK_SEC)
                    programmes.append({
                        "channel_id": ch["id"],
                        "title": ch["name"],
                        "description": "No programme information available. Guide data updates automatically when events are scheduled.",
                        "start_ts": ts,
                        "end_ts": ts + BLOCK_SEC,
                    })

        return channels, programmes
