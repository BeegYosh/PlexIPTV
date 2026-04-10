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

CHUNK_SIZE = 32768  # 32KB chunks — smaller for faster first-byte delivery
MAX_RECONNECT_ATTEMPTS = 8
RECONNECT_DELAY_SECONDS = 1


async def _resolve_redirect(client: httpx.AsyncClient, url: str) -> str:
    """Follow redirects manually to get the final streaming URL.

    Xtream providers often 302-redirect to a token-based URL.
    httpx's follow_redirects + streaming conflicts because the
    redirect consumes the response body iterator.  We resolve the
    final URL with a HEAD/GET first, then stream from that URL.
    """
    try:
        # Use a non-streaming request with follow_redirects to find the final URL
        resp = await client.send(
            client.build_request("GET", url),
            follow_redirects=True,
            stream=True,
        )
        final_url = str(resp.url)
        await resp.aclose()
        return final_url
    except Exception:
        return url  # Fallback to original URL


class StreamManager:
    def __init__(self, settings: Settings, xtream: XtreamClient) -> None:
        self._settings = settings
        self._xtream = xtream
        self._semaphore = asyncio.Semaphore(settings.tuner.count)
        self.active_streams: dict[str, ActiveStream] = {}
        # Redirect resolver — follows redirects but doesn't stream
        self._resolver = httpx.AsyncClient(
            timeout=httpx.Timeout(connect=15, read=30, write=10, pool=10),
            follow_redirects=True,
        )
        # Stream client — does NOT follow redirects (we give it the final URL)
        self._streamer = httpx.AsyncClient(
            timeout=httpx.Timeout(connect=15, read=None, write=10, pool=10),
            limits=httpx.Limits(
                max_connections=settings.tuner.count + 4,
                max_keepalive_connections=settings.tuner.count,
            ),
            follow_redirects=False,
        )

    def tuner_available(self) -> bool:
        return len(self.active_streams) < self._settings.tuner.count

    def get_active(self) -> list[ActiveStream]:
        return list(self.active_streams.values())

    async def open_stream(
        self, stream_id: int, channel_name: str, client_ip: str,
        override_url: str | None = None,
    ) -> AsyncGenerator[bytes, None]:
        """Acquire a tuner slot and return a streaming async generator.

        Raises TunerBusyError immediately if all tuners are in use,
        so callers can catch it before starting the response.
        """
        session_id = uuid.uuid4().hex[:8]

        # Check tuner availability without racing: locked() returns True
        # when the semaphore value is 0 (no slots free)
        if self._semaphore.locked():
            logger.warning(
                "All tuners busy, rejecting stream %d from %s", stream_id, client_ip
            )
            raise TunerBusyError("All tuners are in use")

        # Acquire the slot (will succeed immediately since we checked locked())
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

        base_url = override_url or self._xtream.build_stream_url(stream_id)
        return self._stream_data(session_id, stream_info, base_url)

    async def _stream_data(
        self, session_id: str, stream_info: ActiveStream, base_url: str,
    ) -> AsyncGenerator[bytes, None]:
        """Async generator that streams data with reconnection logic.

        The caller must have already acquired a semaphore slot.
        """
        try:
            attempt = 0
            while attempt <= MAX_RECONNECT_ATTEMPTS:
                try:
                    # Step 1: Resolve redirects to get the final streaming URL
                    stream_url = await _resolve_redirect(self._resolver, base_url)
                    if stream_url != base_url:
                        logger.debug(
                            "Stream %s: resolved redirect to %s",
                            session_id, stream_url[:80],
                        )

                    # Step 2: Stream from the final URL (no redirects)
                    async with self._streamer.stream("GET", stream_url) as resp:
                        resp.raise_for_status()

                        async for chunk in resp.aiter_bytes(CHUNK_SIZE):
                            stream_info.bytes_sent += len(chunk)
                            yield chunk

                        # Stream ended cleanly (server closed) — try reconnect
                        logger.info(
                            "Stream %s: upstream closed after %d bytes, reconnecting...",
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
        await self._resolver.aclose()
        await self._streamer.aclose()


class TunerBusyError(Exception):
    pass
