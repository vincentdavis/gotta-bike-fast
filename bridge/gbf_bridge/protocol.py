"""Wire protocol constants, BLE UUIDs, and GATT measurement parsers.

The bridge speaks JSON text frames over a localhost WebSocket. The game
(Godot) connects as a client, sends commands (scan / connect / disconnect),
and receives device lists plus a merged sensor snapshot.

GATT parsing here follows the Bluetooth SIG characteristic specs:
  * Cycling Power Measurement   (0x2A63)
  * Heart Rate Measurement      (0x2A37)
  * CSC Measurement             (0x2A5B)

Only the fields the game needs (instantaneous power, crank cadence, heart
rate) are decoded; the rest of each packet is skipped by offset.
"""

from __future__ import annotations

# --- 16-bit assigned numbers (services) ---
SVC_CYCLING_POWER = 0x1818
SVC_HEART_RATE = 0x180D
SVC_CSC = 0x1816  # Cycling Speed and Cadence
SVC_FTMS = 0x1826  # Fitness Machine Service (trainer control — milestone 2)

# --- 16-bit assigned numbers (characteristics) ---
CHAR_CYCLING_POWER_MEASUREMENT = 0x2A63
CHAR_HEART_RATE_MEASUREMENT = 0x2A37
CHAR_CSC_MEASUREMENT = 0x2A5B
# FTMS (Fitness Machine Service) characteristics — trainer control.
CHAR_FITNESS_MACHINE_FEATURE = 0x2ACC
CHAR_INDOOR_BIKE_DATA = 0x2AD2
CHAR_FITNESS_MACHINE_CONTROL_POINT = 0x2AD9
CHAR_FITNESS_MACHINE_STATUS = 0x2ADA

# Human-readable kind tags shared with the Godot client.
KIND_POWER = "power"
KIND_HR = "hr"
KIND_CSC = "csc"
KIND_TRAINER = "trainer"

# Map an advertised/known service UUID (16-bit) to the kind tag we expose.
SERVICE_KINDS: dict[int, str] = {
    SVC_CYCLING_POWER: KIND_POWER,
    SVC_HEART_RATE: KIND_HR,
    SVC_CSC: KIND_CSC,
    SVC_FTMS: KIND_TRAINER,
}

# Which notify characteristic backs each kind. For a trainer it's Indoor
# Bike Data (power + cadence); control writes go to the Control Point.
KIND_CHARS: dict[str, int] = {
    KIND_POWER: CHAR_CYCLING_POWER_MEASUREMENT,
    KIND_HR: CHAR_HEART_RATE_MEASUREMENT,
    KIND_CSC: CHAR_CSC_MEASUREMENT,
    KIND_TRAINER: CHAR_INDOOR_BIKE_DATA,
}

# --- FTMS Control Point opcodes (Bluetooth SIG, FTMS 1.0 §4.16) ---
FTMS_OP_REQUEST_CONTROL = 0x00
FTMS_OP_RESET = 0x01
FTMS_OP_SET_TARGET_POWER = 0x05  # + sint16 watts
FTMS_OP_START_RESUME = 0x07
FTMS_OP_STOP_PAUSE = 0x08  # + uint8 (0x01 stop, 0x02 pause)
FTMS_OP_SET_SIM_PARAMS = 0x11  # + wind(sint16) grade(sint16) crr(uint8) cw(uint8)
FTMS_RESPONSE_CODE = 0x80  # first byte of a Control Point indication
FTMS_RESULT_SUCCESS = 0x01

_BASE_UUID_SUFFIX = "-0000-1000-8000-00805f9b34fb"


def uuid16(value: int) -> str:
    """Expand a 16-bit assigned number to its full 128-bit UUID string."""
    return f"0000{value:04x}{_BASE_UUID_SUFFIX}"


def short_uuid(uuid: str) -> int | None:
    """Collapse a 128-bit Bluetooth-base UUID back to its 16-bit number.

    Returns None for vendor/custom UUIDs that aren't in the SIG base range.
    """
    u = str(uuid).lower()
    if u.endswith(_BASE_UUID_SUFFIX) and u.startswith("0000"):
        try:
            return int(u[4:8], 16)
        except ValueError:
            return None
    return None


def _u16(data: bytes, offset: int) -> int:
    return int.from_bytes(data[offset : offset + 2], "little", signed=False)


def _s16(data: bytes, offset: int) -> int:
    return int.from_bytes(data[offset : offset + 2], "little", signed=True)


def parse_cycling_power(data: bytes) -> dict:
    """Decode Cycling Power Measurement (0x2A63).

    Returns {"power_w": int, "crank_revs": int|None, "crank_time": int|None}.
    crank_* are the raw cumulative crank-revolution count and last-event
    time (1/1024 s units, 16-bit rolling) used upstream to derive cadence;
    they're None when the meter doesn't include crank data.
    """
    if len(data) < 4:
        return {"power_w": None, "crank_revs": None, "crank_time": None}
    flags = _u16(data, 0)
    power_w = _s16(data, 2)
    offset = 4
    # Walk past optional fields that precede the crank-revolution block.
    if flags & 0x0001:  # Pedal Power Balance Present (uint8)
        offset += 1
    if flags & 0x0004:  # Accumulated Torque Present (uint16)
        offset += 2
    if flags & 0x0010:  # Wheel Revolution Data Present (uint32 + uint16)
        offset += 6
    crank_revs = None
    crank_time = None
    if flags & 0x0020:  # Crank Revolution Data Present (uint16 + uint16)
        if len(data) >= offset + 4:
            crank_revs = _u16(data, offset)
            crank_time = _u16(data, offset + 2)
    return {"power_w": power_w, "crank_revs": crank_revs, "crank_time": crank_time}


def parse_heart_rate(data: bytes) -> dict:
    """Decode Heart Rate Measurement (0x2A37) → {"heart_rate_bpm": int}."""
    if not data:
        return {"heart_rate_bpm": None}
    flags = data[0]
    if flags & 0x01:  # 16-bit HR value
        if len(data) < 3:
            return {"heart_rate_bpm": None}
        return {"heart_rate_bpm": _u16(data, 1)}
    if len(data) < 2:
        return {"heart_rate_bpm": None}
    return {"heart_rate_bpm": data[1]}


def parse_csc(data: bytes) -> dict:
    """Decode CSC Measurement (0x2A5B) crank block → cadence raw values.

    Returns {"crank_revs": int|None, "crank_time": int|None}. Wheel data is
    skipped (we use the power meter / crank for cadence, not wheel speed).
    """
    if not data:
        return {"crank_revs": None, "crank_time": None}
    flags = data[0]
    offset = 1
    if flags & 0x01:  # Wheel Revolution Data Present (uint32 + uint16)
        offset += 6
    if flags & 0x02:  # Crank Revolution Data Present (uint16 + uint16)
        if len(data) >= offset + 4:
            return {
                "crank_revs": _u16(data, offset),
                "crank_time": _u16(data, offset + 2),
            }
    return {"crank_revs": None, "crank_time": None}


def cadence_from_crank(
    prev_revs: int | None,
    prev_time: int | None,
    revs: int,
    time_1024: int,
) -> float | None:
    """Crank cadence in rpm from two successive cumulative readings.

    Both counters are 16-bit and wrap; deltas are taken modulo 65536. Time
    is in 1/1024 s units. Returns None when there's no usable delta (first
    sample, or no time advance), and 0.0 when revolutions didn't advance
    despite time passing (coasting / stopped pedalling).
    """
    if prev_revs is None or prev_time is None:
        return None
    d_time = (time_1024 - prev_time) & 0xFFFF
    if d_time == 0:
        return None  # no new crank event since last packet — caller holds last
    d_revs = (revs - prev_revs) & 0xFFFF
    return d_revs * 1024.0 * 60.0 / d_time


# --- FTMS trainer control: Control Point command builders ---

def _clamp(value: int, lo: int, hi: int) -> int:
    return max(lo, min(hi, value))


def ftms_request_control() -> bytes:
    return bytes([FTMS_OP_REQUEST_CONTROL])


def ftms_reset() -> bytes:
    return bytes([FTMS_OP_RESET])


def ftms_start() -> bytes:
    return bytes([FTMS_OP_START_RESUME])


def ftms_stop() -> bytes:
    return bytes([FTMS_OP_STOP_PAUSE, 0x01])


def ftms_set_target_power(watts: int) -> bytes:
    """ERG mode: hold a fixed wattage. Param is sint16 watts (LE)."""
    w = _clamp(int(round(watts)), -32768, 32767)
    return bytes([FTMS_OP_SET_TARGET_POWER]) + w.to_bytes(2, "little", signed=True)


def ftms_set_sim(
    grade_pct: float,
    wind_mps: float = 0.0,
    crr: float = 0.004,
    cw: float = 0.51,
) -> bytes:
    """SIM mode: simulate riding at `grade_pct` percent.

    Field resolutions per the FTMS spec:
      * wind speed: sint16, 0.001 m/s
      * grade:      sint16, 0.01 %
      * Crr:        uint8,  0.0001
      * Cw (kg/m):  uint8,  0.01
    """
    wind_raw = _clamp(int(round(wind_mps / 0.001)), -32768, 32767)
    grade_raw = _clamp(int(round(grade_pct / 0.01)), -32768, 32767)
    crr_raw = _clamp(int(round(crr / 0.0001)), 0, 255)
    cw_raw = _clamp(int(round(cw / 0.01)), 0, 255)
    return (
        bytes([FTMS_OP_SET_SIM_PARAMS])
        + wind_raw.to_bytes(2, "little", signed=True)
        + grade_raw.to_bytes(2, "little", signed=True)
        + bytes([crr_raw, cw_raw])
    )


def parse_ftms_response(data: bytes) -> dict | None:
    """Decode a Control Point indication: [0x80, request_op, result_code].

    Returns {"request_op", "result", "ok"} or None if it isn't a response.
    """
    if len(data) < 3 or data[0] != FTMS_RESPONSE_CODE:
        return None
    return {
        "request_op": data[1],
        "result": data[2],
        "ok": data[2] == FTMS_RESULT_SUCCESS,
    }


def parse_indoor_bike_data(data: bytes) -> dict:
    """Decode Indoor Bike Data (0x2AD2) → {"power_w", "cadence_rpm"}.

    A trainer exposes power and cadence here even when it doesn't advertise
    the separate Cycling Power / CSC services, so this doubles as a power
    source. Only the fields we need are pulled; the rest advance the offset.

    Note the quirk: Instantaneous Speed is present when flag bit 0 is *clear*
    ("More Data" = 0), the inverse of every other field.
    """
    if len(data) < 2:
        return {"power_w": None, "cadence_rpm": None}
    flags = _u16(data, 0)
    off = 2
    power = None
    cadence = None
    if not (flags & 0x0001):  # Instantaneous Speed (uint16) present when bit0=0
        off += 2
    if flags & 0x0002:  # Average Speed (uint16)
        off += 2
    if flags & 0x0004:  # Instantaneous Cadence (uint16, 0.5 /min)
        if len(data) >= off + 2:
            cadence = _u16(data, off) * 0.5
        off += 2
    if flags & 0x0008:  # Average Cadence (uint16)
        off += 2
    if flags & 0x0010:  # Total Distance (uint24)
        off += 3
    if flags & 0x0020:  # Resistance Level (sint16)
        off += 2
    if flags & 0x0040:  # Instantaneous Power (sint16)
        if len(data) >= off + 2:
            power = _s16(data, off)
        off += 2
    return {"power_w": power, "cadence_rpm": cadence}
