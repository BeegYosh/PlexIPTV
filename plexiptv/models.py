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
