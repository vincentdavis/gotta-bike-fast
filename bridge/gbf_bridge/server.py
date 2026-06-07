"""Localhost WebSocket server bridging the SensorHub to the Godot client.

Protocol (JSON text frames):

  game -> bridge
    {"cmd": "scan"}
    {"cmd": "stop_scan"}
    {"cmd": "connect", "address": "...", "kind": "power|hr|csc|auto"}
    {"cmd": "disconnect", "address": "..."}
    {"cmd": "disconnect_all"}
    {"cmd": "status"}

  bridge -> game
    {"type": "hello", "bridge_version": "...", "platform": "..."}
    {"type": "scan_started"} / {"type": "scan_stopped"}
    {"type": "device", "address", "name", "rssi", "kinds", "connected"}
    {"type": "connected", "address", "name", "kinds"}
    {"type": "disconnected", "address"}
    {"type": "sensor", "power_w", "cadence_rpm", "heart_rate_bpm", "ts_ms"}
    {"type": "status", ...}
    {"type": "error", "message"}

The bridge serves a single game instance well, and tolerates several
connected clients (each gets every broadcast). Sensor snapshots are pushed
on every BLE notification plus a low-rate heartbeat so the game can detect a
stalled feed.
"""

from __future__ import annotations

import asyncio
import json
import logging
import platform

import websockets

from . import __version__
from .sensors import SensorHub

log = logging.getLogger("gbf_bridge.server")

HEARTBEAT_HZ = 2.0


class Bridge:
    def __init__(self, host: str, port: int) -> None:
        self.host = host
        self.port = port
        self._clients: set = set()
        self.hub = SensorHub(
            on_device=self._broadcast_device,
            on_update=self.broadcast,
            on_event=self._on_event,
        )

    # --- outbound ---

    async def broadcast(self, message: dict) -> None:
        if not self._clients:
            return
        text = json.dumps(message)
        dead = []
        for ws in list(self._clients):
            try:
                await ws.send(text)
            except Exception:  # noqa: BLE001 — drop clients that went away
                dead.append(ws)
        for ws in dead:
            self._clients.discard(ws)

    async def _broadcast_device(self, info: dict) -> None:
        await self.broadcast({"type": "device", **info})

    async def _on_event(self, event: str, payload: dict) -> None:
        # scan_started / scan_stopped / connected / disconnected / error all
        # map to a {"type": <event>, ...} frame.
        await self.broadcast({"type": event, **payload})

    # --- inbound ---

    async def _handle(self, websocket, *_args) -> None:
        self._clients.add(websocket)
        peer = getattr(websocket, "remote_address", None)
        log.info("client connected: %s", peer)
        await self._send(
            websocket,
            {
                "type": "hello",
                "bridge_version": __version__,
                "platform": platform.system(),
            },
        )
        await self._send(websocket, self.hub.status())
        try:
            async for raw in websocket:
                await self._dispatch(websocket, raw)
        except websockets.ConnectionClosed:
            pass
        finally:
            self._clients.discard(websocket)
            log.info("client disconnected: %s", peer)

    async def _dispatch(self, websocket, raw: str) -> None:
        try:
            msg = json.loads(raw)
        except (ValueError, TypeError):
            await self._send(websocket, {"type": "error", "message": "bad json"})
            return
        cmd = str(msg.get("cmd", ""))
        try:
            if cmd == "scan":
                await self.hub.start_scan()
            elif cmd == "stop_scan":
                await self.hub.stop_scan()
            elif cmd == "connect":
                await self.hub.connect(
                    str(msg.get("address", "")), str(msg.get("kind", "auto"))
                )
            elif cmd == "disconnect":
                await self.hub.disconnect(str(msg.get("address", "")))
            elif cmd == "disconnect_all":
                await self.hub.disconnect_all()
            elif cmd == "set_sim":
                await self.hub.set_sim(
                    float(msg.get("grade", 0.0)),
                    float(msg.get("crr", 0.004)),
                    float(msg.get("cw", 0.51)),
                    float(msg.get("wind", 0.0)),
                )
            elif cmd == "set_erg":
                await self.hub.set_erg(int(msg.get("watts", 0)))
            elif cmd == "status":
                await self._send(websocket, self.hub.status())
            else:
                await self._send(
                    websocket, {"type": "error", "message": f"unknown cmd: {cmd}"}
                )
        except Exception as exc:  # noqa: BLE001 — keep the socket alive
            log.exception("command %s failed", cmd)
            await self._send(websocket, {"type": "error", "message": str(exc)})

    async def _send(self, websocket, message: dict) -> None:
        try:
            await websocket.send(json.dumps(message))
        except Exception:  # noqa: BLE001
            self._clients.discard(websocket)

    # --- lifecycle ---

    async def _heartbeat(self) -> None:
        period = 1.0 / HEARTBEAT_HZ
        while True:
            await asyncio.sleep(period)
            if self._clients:
                await self.broadcast(self.hub.snapshot())

    async def run(self) -> None:
        log.info(
            "gbf-bridge %s listening on ws://%s:%d", __version__, self.host, self.port
        )
        heartbeat = asyncio.create_task(self._heartbeat())
        try:
            async with websockets.serve(self._handle, self.host, self.port):
                await asyncio.Future()  # run forever
        finally:
            heartbeat.cancel()
            await self.hub.shutdown()
