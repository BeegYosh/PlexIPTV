from __future__ import annotations

import asyncio
import logging
import socket
import struct

from plexiptv.config import Settings

logger = logging.getLogger(__name__)

SSDP_ADDR = "239.255.255.250"
SSDP_PORT = 1900
DEVICE_TYPE = "urn:schemas-upnp-org:device:MediaServer:1"


class SSDPServer:
    def __init__(self, settings: Settings, local_ip: str) -> None:
        self._settings = settings
        self._local_ip = local_ip
        self._port = settings.server.port
        self._device_id = settings.tuner.device_id
        self._uuid = f"uuid:{self._device_id}-PlexIPTV"
        self._running = False
        self._transport: asyncio.DatagramTransport | None = None
        self._tasks: list[asyncio.Task] = []

    @property
    def _location(self) -> str:
        return f"http://{self._local_ip}:{self._port}/discover.json"

    def _build_response(self, st: str) -> bytes:
        lines = [
            "HTTP/1.1 200 OK",
            f"CACHE-CONTROL: max-age=1800",
            f"ST: {st}",
            f"USN: {self._uuid}::{st}",
            f"LOCATION: {self._location}",
            f"SERVER: PlexIPTV/1.0 UPnP/1.0",
            "",
            "",
        ]
        return "\r\n".join(lines).encode()

    def _build_notify(self) -> bytes:
        lines = [
            "NOTIFY * HTTP/1.1",
            f"HOST: {SSDP_ADDR}:{SSDP_PORT}",
            "NTS: ssdp:alive",
            f"NT: {DEVICE_TYPE}",
            f"USN: {self._uuid}::{DEVICE_TYPE}",
            f"LOCATION: {self._location}",
            f"CACHE-CONTROL: max-age=1800",
            f"SERVER: PlexIPTV/1.0 UPnP/1.0",
            "",
            "",
        ]
        return "\r\n".join(lines).encode()

    def _build_byebye(self) -> bytes:
        lines = [
            "NOTIFY * HTTP/1.1",
            f"HOST: {SSDP_ADDR}:{SSDP_PORT}",
            "NTS: ssdp:byebye",
            f"NT: {DEVICE_TYPE}",
            f"USN: {self._uuid}::{DEVICE_TYPE}",
            "",
            "",
        ]
        return "\r\n".join(lines).encode()

    async def start(self) -> None:
        self._running = True
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            # On Windows, SO_REUSEPORT doesn't exist
            try:
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
            except (AttributeError, OSError):
                pass
            sock.bind(("", SSDP_PORT))

            # Join multicast group
            mreq = struct.pack("4s4s", socket.inet_aton(SSDP_ADDR), socket.inet_aton(self._local_ip))
            sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
            sock.setblocking(False)

            loop = asyncio.get_running_loop()
            self._transport, _ = await loop.create_datagram_endpoint(
                lambda: _SSDPProtocol(self),
                sock=sock,
            )

            self._tasks.append(asyncio.create_task(self._advertise_loop()))
            logger.info("SSDP server started on %s:%d", self._local_ip, SSDP_PORT)

        except OSError as e:
            logger.warning(
                "SSDP bind failed (port %d may be in use): %s. "
                "Plex can still find the tuner manually at %s",
                SSDP_PORT, e, self._location,
            )

    async def _advertise_loop(self) -> None:
        while self._running:
            try:
                if self._transport:
                    self._transport.sendto(self._build_notify(), (SSDP_ADDR, SSDP_PORT))
            except Exception as e:
                logger.debug("SSDP notify error: %s", e)
            await asyncio.sleep(60)

    def handle_search(self, data: bytes, addr: tuple[str, int]) -> None:
        msg = data.decode("utf-8", errors="ignore")
        if "M-SEARCH" not in msg:
            return

        st = ""
        for line in msg.split("\r\n"):
            if line.upper().startswith("ST:"):
                st = line.split(":", 1)[1].strip()
                break

        if st in ("ssdp:all", "upnp:rootdevice", DEVICE_TYPE):
            if self._transport:
                response = self._build_response(st if st != "ssdp:all" else DEVICE_TYPE)
                self._transport.sendto(response, addr)
                logger.debug("SSDP response sent to %s", addr)

    async def stop(self) -> None:
        self._running = False
        for task in self._tasks:
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass

        if self._transport:
            try:
                self._transport.sendto(self._build_byebye(), (SSDP_ADDR, SSDP_PORT))
            except Exception:
                pass
            self._transport.close()
        logger.info("SSDP server stopped")


class _SSDPProtocol(asyncio.DatagramProtocol):
    def __init__(self, server: SSDPServer) -> None:
        self._server = server

    def datagram_received(self, data: bytes, addr: tuple[str, int]) -> None:
        self._server.handle_search(data, addr)

    def error_received(self, exc: Exception) -> None:
        logger.debug("SSDP protocol error: %s", exc)
