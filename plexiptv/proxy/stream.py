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
MAX_RECONNECT_ATTEMPTS = 5
RECONNECT_DELAY_SECONDS = 2


class StreamManager:
    def __init__(self, settings: Settings, xtream: XtreamClient) -> None:
        self._settings = settings
        self._xtream = xtream
        self._semaphore = asyncio.Semaphore(settings.tuner.count)
        self.active_streams: dict[str, ActiveStream] = {}
        self._client = httpx.AsyncClient(
            timeout=httpx.Timeout(connect=15, read=None, write=10, pool=10),
            limits=httpx.Limits(
                max_connections=settings.tuner.count + 4,
                max_keepalive_connections=settings.tuner.count,
            ),
            follow_redirects=True,
        )

    def tuner_available(self) -> bool:
        return len(self.active_streams) < self._settings.tuner.count

    def get_active(self) -> list[ActiveStream]:
        return list(self.active_streams.values())

    async def open_stream(
        self, stream_id: int, channel_name: str, client_ip: str
    ) -> AsyncGenerator[bytes, None]:
        session_id = uuid.uuid4().hex[:8]

        if not self._semaphore._value:
            logger.warning(
                "All tuners busy, rejecting stream %d from %s", stream_id, client_ip
            )
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
        logger.info(
            "Stream %s started: ch=%d (%s) client=%s",
            session_id, stream_id, channel_name, client_ip,
        )

        url = self._xtream.build_stream_url(stream_id)
        buffer_bytes = self._settings.proxy.buffer_size_kb * 1024

        try:
            attempt = 0
            while attempt <= MAX_RECONNECT_ATTEMPTS:
                try:
                    async with self._client.stream("GET", url) as resp:
                        resp.raise_for_status()

                        # Pre-buffer: accumulate before sending first byte
                        # Only on the very first attempt
                        if attempt == 0:
                            pre_buffer = bytearray()
                            async for chunk in resp.aiter_bytes(CHUNK_SIZE):
                                pre_buffer.extend(chunk)
                                if len(pre_buffer) >= buffer_bytes:
                                    break
                            if pre_buffer:
                                stream_info.bytes_sent += len(pre_buffer)
                                yield bytes(pre_buffer)

                        # Pass-through with keepalive tracking
                        last_data_time = asyncio.get_event_loop().time()
                        async for chunk in resp.aiter_bytes(CHUNK_SIZE):
                            stream_info.bytes_sent += len(chunk)
                            last_data_time = asyncio.get_event_loop().time()
                            yield chunk

                        # Stream ended cleanly (server closed) — try reconnect
                        logger.info(
                            "Stream %s: upstream closed connection after %d bytes, reconnecting...",
                            session_id, stream_info.bytes_sent,
                        )

                except httpx.HTTPStatusError as e:
                    logger.error(
                        "Stream %s: HTTP %d from upstream", session_id, e.response.status_code
                    )
                    if e.response.status_code in (401, 403, 404):
                        break  # Don't retry auth / not-found errors
                except (httpx.StreamError, httpx.RemoteProtocolError, httpx.ReadError) as e:
                    logger.warning(
                        "Stream %s: upstream error on attempt %d: %s",
                        session_id, attempt + 1, e,
                    )
                except httpx.ConnectError as e:
                    logger.warning(
                        "Stream %s: connection failed on attempt %d: %s",
                        session_id, attempt + 1, e,
                    )

                attempt += 1
                if attempt <= MAX_RECONNECT_ATTEMPTS:
                    delay = RECONNECT_DELAY_SECONDS * attempt
                    logger.info(
                        "Stream %s: reconnect attempt %d/%d in %.1fs",
                        session_id, attempt, MAX_RECONNECT_ATTEMPTS, delay,
                    )
                    await asyncio.sleep(delay)

            if attempt > MAX_RECONNECT_ATTEMPTS:
                logger.error(
                    "Stream %s: exhausted %d reconnect attempts",
                    session_id, MAX_RECONNECT_ATTEMPTS,
                )

        except GeneratorExit:
            logger.info("Client disconnected from stream %s", session_id)
        except Exception as e:
            logger.error("Unexpected error in stream %s: %s", session_id, e)
        finally:
            self.active_streams.pop(session_id, None)
            self._semaphore.release()
            logger.info(
                "Stream %s ended: %d bytes sent", session_id, stream_info.bytes_sent
            )

    async def close(self) -> None:
        await self._client.aclose()


class TunerBusyError(Exception):
    pass
