"""Trainer (FTMS) write-path tests using a fake BLE client — no hardware.

Verifies that SensorHub.set_sim / set_erg write the correct Control Point
bytes, and that they no-op safely when no trainer is connected.
"""

import asyncio
import struct

from gbf_bridge import protocol as proto
from gbf_bridge.sensors import SensorHub


class FakeClient:
    def __init__(self) -> None:
        self.address = "FA:KE:00:00:00:01"
        self.writes: list[tuple[str, bytes]] = []

    async def write_gatt_char(self, uuid, data, response=True):  # noqa: ANN001
        self.writes.append((str(uuid), bytes(data)))


def _hub_with_trainer() -> tuple[SensorHub, FakeClient]:
    hub = SensorHub(lambda *_: None, lambda *_: None, lambda *_a, **_k: None)
    fake = FakeClient()
    hub._clients[fake.address] = fake  # noqa: SLF001 — test seam
    hub._trainer_address = fake.address  # noqa: SLF001
    return hub, fake


def test_set_sim_writes_control_point():
    hub, fake = _hub_with_trainer()
    asyncio.run(hub.set_sim(4.5))
    assert len(fake.writes) == 1
    uuid, data = fake.writes[0]
    assert uuid == proto.uuid16(proto.CHAR_FITNESS_MACHINE_CONTROL_POINT)
    assert data[0] == proto.FTMS_OP_SET_SIM_PARAMS
    assert struct.unpack("<h", data[3:5])[0] == 450  # 4.5% / 0.01


def test_set_erg_writes_control_point():
    hub, fake = _hub_with_trainer()
    asyncio.run(hub.set_erg(200))
    uuid, data = fake.writes[0]
    assert data[0] == proto.FTMS_OP_SET_TARGET_POWER
    assert struct.unpack("<h", data[1:3])[0] == 200


def test_set_sim_throttles_repeats():
    hub, fake = _hub_with_trainer()

    async def run():
        await hub.set_sim(4.5)
        await hub.set_sim(4.5)  # identical + immediate -> throttled
        await hub.set_sim(10.0)  # big change -> written

    asyncio.run(run())
    grades = [struct.unpack("<h", d[3:5])[0] for _, d in fake.writes]
    assert grades == [450, 1000]


def test_set_sim_noop_without_trainer():
    hub = SensorHub(lambda *_: None, lambda *_: None, lambda *_a, **_k: None)
    asyncio.run(hub.set_sim(5.0))  # no trainer connected -> no crash
    asyncio.run(hub.set_erg(150))
