"""BLE sensor discovery + connection on top of bleak.

A single SensorHub owns all BLE state: an active scanner, the set of
connected clients, and the merged measurement snapshot the WebSocket layer
broadcasts to the game. Everything runs on one asyncio event loop, so the
bleak notification callbacks and the WebSocket server never race.

The hub is transport-agnostic: it takes callbacks (on_device, on_update,
on_event) and never imports the WebSocket layer, which keeps the BLE code
unit-testable and the server thin.
"""

from __future__ import annotations

import asyncio
import logging
import time
from collections.abc import Awaitable, Callable
from typing import Any

from bleak import BleakClient, BleakScanner
from bleak.backends.device import BLEDevice
from bleak.backends.scanner import AdvertisementData

from . import protocol as proto

log = logging.getLogger("gbf_bridge.sensors")

# A measurement older than this is treated as stale by the game; we also
# zero cadence here when the crank stops advancing for this long.
STALE_AFTER_S = 3.0

DeviceCb = Callable[[dict], Awaitable[None] | None]
UpdateCb = Callable[[dict], Awaitable[None] | None]
EventCb = Callable[[str, dict], Awaitable[None] | None]


class SensorHub:
    def __init__(
        self,
        on_device: DeviceCb,
        on_update: UpdateCb,
        on_event: EventCb,
    ) -> None:
        self._on_device = on_device
        self._on_update = on_update
        self._on_event = on_event

        self._scanner: BleakScanner | None = None
        self._seen: dict[str, dict] = {}  # address -> device info dict
        self._clients: dict[str, BleakClient] = {}
        self._kinds: dict[str, list[str]] = {}  # address -> subscribed kinds

        # Merged latest reading. None means "no source for this metric yet".
        self.power_w: int | None = None
        self.cadence_rpm: float | None = None
        self.heart_rate_bpm: int | None = None

        # Cadence derivation state (from whichever device supplies crank data).
        self._crank_revs: int | None = None
        self._crank_time: int | None = None
        self._crank_seen_at: float = 0.0

        # FTMS trainer control state. _trainer_address is the connected
        # device whose Control Point we drive; _sim_* throttle SIM writes.
        self._trainer_address: str | None = None
        self._sim_last_grade: float = 999.0
        self._sim_last_write: float = 0.0

    # --- scanning ---

    async def start_scan(self) -> None:
        if self._scanner is not None:
            return
        self._seen.clear()
        self._scanner = BleakScanner(detection_callback=self._on_detection)
        await self._scanner.start()
        await _maybe_await(self._on_event("scan_started", {}))
        log.info("scan started")

    async def stop_scan(self) -> None:
        if self._scanner is None:
            return
        try:
            await self._scanner.stop()
        finally:
            self._scanner = None
        await _maybe_await(self._on_event("scan_stopped", {}))
        log.info("scan stopped")

    def _on_detection(self, device: BLEDevice, adv: AdvertisementData) -> None:
        kinds: list[str] = []
        for su in adv.service_uuids or []:
            num = proto.short_uuid(su)
            if num in proto.SERVICE_KINDS:
                kinds.append(proto.SERVICE_KINDS[num])
        # Only surface cycling-relevant devices; ignore the sea of phones,
        # earbuds, and beacons a scan otherwise turns up.
        if not kinds:
            return
        info = {
            "address": device.address,
            "name": device.name or adv.local_name or "(unknown)",
            "rssi": adv.rssi,
            "kinds": sorted(set(kinds)),
            "connected": device.address in self._clients,
        }
        prev = self._seen.get(device.address)
        self._seen[device.address] = info
        if prev != info:
            _schedule(self._on_device(info))

    # --- connecting ---

    async def connect(self, address: str, kind: str = "auto") -> None:
        if address in self._clients:
            await _maybe_await(
                self._on_event("error", {"message": f"already connected: {address}"})
            )
            return
        log.info("connecting to %s (kind=%s)", address, kind)
        client = BleakClient(address, disconnected_callback=self._on_disconnect)
        try:
            await client.connect()
        except Exception as exc:  # noqa: BLE001 — surface any pairing failure
            log.warning("connect failed: %s", exc)
            await _maybe_await(
                self._on_event("error", {"message": f"connect failed: {exc}"})
            )
            return

        self._clients[address] = client
        subscribed = await self._subscribe(client, address, kind)
        self._kinds[address] = subscribed
        # If this device exposes the FTMS Control Point, take control of it so
        # the game can drive resistance (SIM grade / ERG power).
        controllable = _has_char(client, proto.CHAR_FITNESS_MACHINE_CONTROL_POINT)
        if controllable:
            controllable = await self._setup_trainer_control(client, address)
        name = self._seen.get(address, {}).get("name", address)
        if address in self._seen:
            self._seen[address]["connected"] = True
        await _maybe_await(
            self._on_event(
                "connected",
                {
                    "address": address,
                    "name": name,
                    "kinds": subscribed,
                    "controllable": controllable,
                },
            )
        )
        log.info(
            "connected to %s, subscribed=%s, controllable=%s",
            address, subscribed, controllable,
        )

    async def _subscribe(
        self, client: BleakClient, address: str, kind: str
    ) -> list[str]:
        # Which kinds to try: the requested one, or everything the device
        # exposes when kind == auto.
        available = _available_kinds(client)
        wanted = available if kind == "auto" else [kind]
        subscribed: list[str] = []
        for k in wanted:
            char = proto.KIND_CHARS.get(k)
            if char is None or k not in available:
                continue
            uuid = proto.uuid16(char)
            handler = self._make_handler(k)
            try:
                await client.start_notify(uuid, handler)
                subscribed.append(k)
            except Exception as exc:  # noqa: BLE001
                log.warning("start_notify %s on %s failed: %s", k, address, exc)
        return subscribed

    def _make_handler(self, kind: str):
        def handler(_char: Any, data: bytearray) -> None:
            try:
                self._handle_measurement(kind, bytes(data))
            except Exception:  # noqa: BLE001 — never let a bad packet kill us
                log.exception("error parsing %s packet", kind)

        return handler

    def _handle_measurement(self, kind: str, data: bytes) -> None:
        now = time.monotonic()
        if kind == proto.KIND_POWER:
            parsed = proto.parse_cycling_power(data)
            if parsed["power_w"] is not None:
                self.power_w = max(0, parsed["power_w"])
            if parsed["crank_revs"] is not None:
                self._ingest_crank(parsed["crank_revs"], parsed["crank_time"], now)
        elif kind == proto.KIND_CSC:
            parsed = proto.parse_csc(data)
            if parsed["crank_revs"] is not None:
                self._ingest_crank(parsed["crank_revs"], parsed["crank_time"], now)
        elif kind == proto.KIND_HR:
            parsed = proto.parse_heart_rate(data)
            if parsed["heart_rate_bpm"] is not None:
                self.heart_rate_bpm = parsed["heart_rate_bpm"]
        elif kind == proto.KIND_TRAINER:
            # Indoor Bike Data — a trainer's own power + cadence. Lets a
            # trainer that doesn't advertise the Cycling Power / CSC services
            # still act as the power source.
            parsed = proto.parse_indoor_bike_data(data)
            if parsed["power_w"] is not None:
                self.power_w = max(0, parsed["power_w"])
            if parsed["cadence_rpm"] is not None:
                self.cadence_rpm = parsed["cadence_rpm"]
        self._emit_snapshot(now)

    def _ingest_crank(self, revs: int, time_1024: int, now: float) -> None:
        cad = proto.cadence_from_crank(
            self._crank_revs, self._crank_time, revs, time_1024
        )
        if cad is not None:
            self.cadence_rpm = cad
            self._crank_seen_at = now
        elif self._crank_revs is not None and revs == self._crank_revs:
            # Same crank count came around again — pedalling has stopped.
            if now - self._crank_seen_at > STALE_AFTER_S:
                self.cadence_rpm = 0.0
        self._crank_revs = revs
        self._crank_time = time_1024

    # --- trainer (FTMS) control ---

    async def _setup_trainer_control(self, client: BleakClient, address: str) -> bool:
        # Subscribe to Control Point indications, request control of the
        # machine, then start/resume it. Returns True once the machine is
        # ready to accept SIM/ERG commands.
        cp = proto.uuid16(proto.CHAR_FITNESS_MACHINE_CONTROL_POINT)
        try:
            await client.start_notify(cp, self._on_control_response)
            await client.write_gatt_char(cp, proto.ftms_request_control(), response=True)
            await asyncio.sleep(0.2)
            await client.write_gatt_char(cp, proto.ftms_start(), response=True)
        except Exception as exc:  # noqa: BLE001
            log.warning("trainer control setup failed on %s: %s", address, exc)
            await _maybe_await(
                self._on_event(
                    "error", {"message": f"trainer control unavailable: {exc}"}
                )
            )
            return False
        self._trainer_address = address
        self._sim_last_grade = 999.0  # force the first SIM write through
        await _maybe_await(self._on_event("trainer_ready", {"address": address}))
        log.info("trainer control ready on %s", address)
        return True

    def _on_control_response(self, _char: Any, data: bytearray) -> None:
        resp = proto.parse_ftms_response(bytes(data))
        if resp is None:
            return
        _schedule(self._on_event("trainer_response", resp))

    def _trainer_client(self) -> BleakClient | None:
        if self._trainer_address is None:
            return None
        return self._clients.get(self._trainer_address)

    async def set_sim(
        self, grade_pct: float, crr: float = 0.004, cw: float = 0.51,
        wind_mps: float = 0.0,
    ) -> None:
        """SIM mode: make resistance follow the road grade."""
        client = self._trainer_client()
        if client is None:
            return
        now = time.monotonic()
        # Throttle redundant writes — the game streams grade continuously but
        # the trainer only needs an update when it meaningfully changes.
        if abs(grade_pct - self._sim_last_grade) < 0.1 and (now - self._sim_last_write) < 1.0:
            return
        self._sim_last_grade = grade_pct
        self._sim_last_write = now
        cp = proto.uuid16(proto.CHAR_FITNESS_MACHINE_CONTROL_POINT)
        try:
            await client.write_gatt_char(
                cp, proto.ftms_set_sim(grade_pct, wind_mps, crr, cw), response=True
            )
        except Exception as exc:  # noqa: BLE001
            log.warning("set_sim failed: %s", exc)

    async def set_erg(self, watts: int) -> None:
        """ERG mode: hold a fixed target wattage."""
        client = self._trainer_client()
        if client is None:
            return
        cp = proto.uuid16(proto.CHAR_FITNESS_MACHINE_CONTROL_POINT)
        try:
            await client.write_gatt_char(
                cp, proto.ftms_set_target_power(watts), response=True
            )
        except Exception as exc:  # noqa: BLE001
            log.warning("set_erg failed: %s", exc)

    def snapshot(self) -> dict:
        return {
            "type": "sensor",
            "power_w": self.power_w,
            "cadence_rpm": (
                round(self.cadence_rpm, 1) if self.cadence_rpm is not None else None
            ),
            "heart_rate_bpm": self.heart_rate_bpm,
            "ts_ms": int(time.time() * 1000),
        }

    def _emit_snapshot(self, _now: float) -> None:
        _schedule(self._on_update(self.snapshot()))

    # --- disconnecting ---

    def _on_disconnect(self, client: BleakClient) -> None:
        address = _client_address(client)
        log.info("device disconnected: %s", address)
        self._clients.pop(address, None)
        self._kinds.pop(address, None)
        if self._trainer_address == address:
            self._trainer_address = None
        if address in self._seen:
            self._seen[address]["connected"] = False
        _schedule(self._on_event("disconnected", {"address": address}))

    async def disconnect(self, address: str) -> None:
        client = self._clients.get(address)
        if client is None:
            return
        try:
            await client.disconnect()
        except Exception as exc:  # noqa: BLE001
            log.warning("disconnect %s failed: %s", address, exc)

    async def disconnect_all(self) -> None:
        for address in list(self._clients):
            await self.disconnect(address)

    def status(self) -> dict:
        return {
            "type": "status",
            "scanning": self._scanner is not None,
            "connected": [
                {"address": a, "kinds": self._kinds.get(a, [])}
                for a in self._clients
            ],
            "trainer": (
                {"address": self._trainer_address, "controllable": True}
                if self._trainer_address is not None
                else None
            ),
            **{k: v for k, v in self.snapshot().items() if k != "type"},
        }

    async def shutdown(self) -> None:
        await self.stop_scan()
        await self.disconnect_all()


# --- helpers ---

def _available_kinds(client: BleakClient) -> list[str]:
    """Kinds whose notify characteristic the connected device actually has."""
    kinds: list[str] = []
    try:
        services = client.services
    except Exception:  # noqa: BLE001
        return kinds
    have_chars = {
        proto.short_uuid(c.uuid)
        for s in services
        for c in s.characteristics
    }
    for kind, char in proto.KIND_CHARS.items():
        if char in have_chars:
            kinds.append(kind)
    return kinds


def _has_char(client: BleakClient, char_16: int) -> bool:
    """True if the connected device exposes the given 16-bit characteristic."""
    try:
        services = client.services
    except Exception:  # noqa: BLE001
        return False
    for s in services:
        for c in s.characteristics:
            if proto.short_uuid(c.uuid) == char_16:
                return True
    return False


def _client_address(client: BleakClient) -> str:
    return getattr(client, "address", "")


async def _maybe_await(value: Awaitable[None] | None) -> None:
    if value is not None and hasattr(value, "__await__"):
        await value


def _schedule(value: Awaitable[None] | None) -> None:
    """Fire-and-forget a coroutine from a sync bleak callback context."""
    if value is None or not hasattr(value, "__await__"):
        return
    import asyncio

    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        return
    loop.create_task(value)
