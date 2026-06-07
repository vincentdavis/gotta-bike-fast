"""Unit tests for the GATT measurement parsers — no BLE hardware needed."""

import struct

from gbf_bridge import protocol as proto


def test_uuid_roundtrip():
    assert proto.uuid16(0x2A63) == "00002a63-0000-1000-8000-00805f9b34fb"
    assert proto.short_uuid("00002a63-0000-1000-8000-00805f9b34fb") == 0x2A63
    assert proto.short_uuid("0000180d-0000-1000-8000-00805f9b34fb") == 0x180D
    # Vendor UUID outside the SIG base range -> None.
    assert proto.short_uuid("12345678-1234-1234-1234-123456789abc") is None


def test_cycling_power_minimal():
    # flags=0 (no optional fields), power=210 W.
    data = struct.pack("<Hh", 0x0000, 210)
    out = proto.parse_cycling_power(data)
    assert out["power_w"] == 210
    assert out["crank_revs"] is None
    assert out["crank_time"] is None


def test_cycling_power_with_crank():
    # flags: crank data present (0x20). power=300. crank_revs=1000, time=2048.
    data = struct.pack("<Hh", 0x0020, 300) + struct.pack("<HH", 1000, 2048)
    out = proto.parse_cycling_power(data)
    assert out["power_w"] == 300
    assert out["crank_revs"] == 1000
    assert out["crank_time"] == 2048


def test_cycling_power_crank_offset_after_optional_fields():
    # flags: pedal balance (0x01) + accumulated torque (0x04) + wheel (0x10)
    # + crank (0x20). The crank block must be located *after* 1 + 2 + 6 bytes
    # of optional data.
    flags = 0x01 | 0x04 | 0x10 | 0x20
    body = struct.pack("<Hh", flags, 150)
    body += struct.pack("<B", 50)  # pedal power balance
    body += struct.pack("<H", 1234)  # accumulated torque
    body += struct.pack("<IH", 99, 500)  # wheel revs + wheel event time
    body += struct.pack("<HH", 777, 4096)  # crank revs + crank event time
    out = proto.parse_cycling_power(body)
    assert out["power_w"] == 150
    assert out["crank_revs"] == 777
    assert out["crank_time"] == 4096


def test_heart_rate_uint8():
    data = bytes([0x00, 72])  # flags=0 -> 8-bit, 72 bpm
    assert proto.parse_heart_rate(data)["heart_rate_bpm"] == 72


def test_heart_rate_uint16():
    data = bytes([0x01]) + struct.pack("<H", 300)  # flags bit0 -> 16-bit
    assert proto.parse_heart_rate(data)["heart_rate_bpm"] == 300


def test_csc_crank_only():
    # flags bit1 (crank present), no wheel.
    data = bytes([0x02]) + struct.pack("<HH", 10, 1024)
    out = proto.parse_csc(data)
    assert out["crank_revs"] == 10
    assert out["crank_time"] == 1024


def test_csc_crank_after_wheel():
    # flags bits0+1 (wheel + crank). Crank block is offset by 1+6 bytes.
    data = bytes([0x03]) + struct.pack("<IH", 5, 200) + struct.pack("<HH", 20, 2048)
    out = proto.parse_csc(data)
    assert out["crank_revs"] == 20
    assert out["crank_time"] == 2048


def test_cadence_from_crank_basic():
    # 1 crank rev in 1024 ticks (1.0 s) -> 60 rpm.
    assert proto.cadence_from_crank(100, 0, 101, 1024) == 60.0


def test_cadence_from_crank_wraps():
    # Time wraps past 65536; revs +2 over 512 ticks (0.5 s) -> 240 rpm.
    cad = proto.cadence_from_crank(10, 65500, 12, (65500 + 512) & 0xFFFF)
    assert round(cad, 1) == 240.0


def test_cadence_from_crank_no_delta():
    assert proto.cadence_from_crank(None, None, 5, 100) is None
    assert proto.cadence_from_crank(5, 100, 5, 100) is None  # no time advance


# --- FTMS trainer control ---

def test_ftms_set_sim_encoding():
    pkt = proto.ftms_set_sim(4.5, wind_mps=0.0, crr=0.004, cw=0.51)
    assert pkt[0] == proto.FTMS_OP_SET_SIM_PARAMS
    wind, grade = struct.unpack("<hh", pkt[1:5])
    crr_raw, cw_raw = pkt[5], pkt[6]
    assert wind == 0
    assert grade == 450  # 4.5% / 0.01
    assert crr_raw == 40  # 0.004 / 0.0001
    assert cw_raw == 51  # 0.51 / 0.01


def test_ftms_set_sim_negative_grade():
    pkt = proto.ftms_set_sim(-8.2)
    grade = struct.unpack("<h", pkt[3:5])[0]
    assert grade == -820


def test_ftms_set_sim_clamps_crr_cw():
    # Absurd inputs must not overflow the uint8 fields.
    pkt = proto.ftms_set_sim(0.0, crr=10.0, cw=10.0)
    assert pkt[5] == 255
    assert pkt[6] == 255


def test_ftms_set_target_power():
    pkt = proto.ftms_set_target_power(250)
    assert pkt[0] == proto.FTMS_OP_SET_TARGET_POWER
    assert struct.unpack("<h", pkt[1:3])[0] == 250


def test_ftms_simple_ops():
    assert proto.ftms_request_control() == bytes([0x00])
    assert proto.ftms_start() == bytes([0x07])
    assert proto.ftms_stop() == bytes([0x08, 0x01])


def test_parse_ftms_response():
    assert proto.parse_ftms_response(bytes([0x80, 0x11, 0x01]))["ok"] is True
    fail = proto.parse_ftms_response(bytes([0x80, 0x05, 0x02]))
    assert fail["ok"] is False and fail["request_op"] == 0x05
    assert proto.parse_ftms_response(bytes([0x11, 0x00])) is None  # not a response


def test_indoor_bike_data_power_cadence():
    # flags: speed present (bit0=0), cadence (bit2), power (bit6).
    flags = 0x0004 | 0x0040
    data = struct.pack("<H", flags)
    data += struct.pack("<H", 2500)  # instantaneous speed 25.00 km/h (skipped)
    data += struct.pack("<H", 180)  # cadence raw -> 90.0 rpm
    data += struct.pack("<h", 245)  # instantaneous power 245 W
    out = proto.parse_indoor_bike_data(data)
    assert out["power_w"] == 245
    assert out["cadence_rpm"] == 90.0


def test_indoor_bike_data_speed_absent_when_bit0_set():
    # bit0 set => Instantaneous Speed ABSENT; power present (bit6).
    flags = 0x0001 | 0x0040
    data = struct.pack("<H", flags) + struct.pack("<h", 300)
    out = proto.parse_indoor_bike_data(data)
    assert out["power_w"] == 300
    assert out["cadence_rpm"] is None
