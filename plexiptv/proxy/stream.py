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


class StreamManager:
    def __init__(self, settings: Settings, xtream: XtreamClient) -> None:
        self._settings = settings
        self._xtream = xtream
        self._semaphore = asyncio.Semaphore(settings.tuner.count)
        self.active_streams: dict[str, ActiveStream] = {}
        self._client = httpx.AsyncClient(
            timeout=httpx.Timeout(connect=10, read=None, write=10, pool=10),
            limits=httpx.Limits(max_connections=settings.tuner.count + 2, max_keepalive_connections=settings.tuner.count),
            follow_redirects=True,
        )

    def tuner_available(self) -> bool:
        return len(self.active_streams) < self._settings.tuner.count

    def get_active(self) -> list[ActiveStream]:
        return list(self.active_streams.values())

    async def open_stream(self, stream_id: int, channel_name: str, client_ip: str) -> AsyncGenerator[bytes, None]:
        session_id = uuid.uuid4().hex[:8]

        if not self._semaphore._value:
            logger.warning("All tuners busy, rejecting stream %d from %s", stream_id, client_ip)
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
        logger.info("Stream %s started: ch=%d (%s) client=%s", session_id, stream_id, channel_name, client_ip)

        url = self._xtream.build_stream_url(stream_id)
        buffer_bytes = self._settings.proxy.buffer_size_kb * 1024

        try:
            async with self._client.stream("GET", url) as resp:
                resp.raise_for_status()

                # Pre-buffer phase: accumulate data before sending first byte
                pre_buffer = bytearray()
                async for chunk in resp.aiter_bytes(CHUNK_SIZE):
                    pre_buffer.extend(chunk)
                    if len(pre_buffer) >= buffer_bytes:
                        break

                if pre_buffer:
                    stream_info.bytes_sent += len(pre_buffer)
                    yield bytes(pre_buffer)

                # Pass-through phase
                async for chunk in resp.aiter_bytes(CHUNK_SIZE):
                    stream_info.bytes_sent += len(chunk)
                    yield chunk

        except httpx.HTTPStatusError as e:
            logger.error("Upstream HTTP error for stream %d: %s", stream_id, e)
        except (httpx.StreamError, httpx.RemoteProtocolError) as e:
            logger.warning("Upstream stream error for %d: %s", stream_id, e)
        except GeneratorExit:
            logger.info("Client disconnected from stream %s", session_id)
        except Exception as e:
            logger.error("Unexpected error in stream %s: %s", session_id, e)
        finally:
            self.active_streams.pop(session_id, None)
            self._semaphore.release()
            logger.info("Stream %s ended: %d bytes sent", session_id, stream_info.bytes_sent)

    async def close(self) -> None:
        await self._client.aclose()


class TunerBusyError(Exception):
    pass
