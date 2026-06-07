# Gotta Bike Fast — BLE Sensor Bridge

A small Python process that talks to Bluetooth Low Energy cycling sensors
(power meters, heart-rate straps, speed/cadence sensors) using
[`bleak`](https://github.com/hbldh/bleak) and rebroadcasts their readings to
the game over a **localhost WebSocket**.

The game (Godot) connects to `ws://127.0.0.1:8770`, drives pairing through
it (scan / connect), and uses the measured power in place of the keyboard
ramp. **Keyboard control still works** — it's the default and the fallback
whenever no live sensor feed is selected or a sensor drops out.

Why a separate process? `bleak` is cross-platform (CoreBluetooth on macOS,
WinRT on Windows, BlueZ on Linux) but is Python, not GDScript. Running it
beside the game keeps the Godot build pure. Requires **Python ≥ 3.14**.

## Packaged builds (end users)

The installable artifacts from CI **bundle a frozen copy of this bridge** and
the game **launches it automatically** — no Python or `uv` required:

- **macOS** `.dmg` (Apple Silicon only) → the bridge lives at
  `GottaBikeFast.app/Contents/Resources/bridge/gbf-bridge`.
- **Windows** installer / portable zip → `gbf-bridge.exe` sits next to
  `GottaBikeFast.exe`.

The game spawns it on demand (when you enable sensors) and shuts it down on
exit. Just open **Ride → Sensors** and pair.

## Run it (dev)

In the editor the game does **not** auto-launch the bridge — run it yourself:

```bash
cd bridge
uv run gbf-bridge            # serves ws://127.0.0.1:8770
uv run gbf-bridge -v         # with debug logging
uv run gbf-bridge --port 9000
```

Then in the game: **Ride → Sensors**, choose **Sensor** as the power source,
**Scan**, and **Connect** your meter / strap.

## Freeze a standalone binary

```bash
cd bridge
uv sync --group build
uv run --group build pyinstaller gbf-bridge.spec --noconfirm   # -> dist/gbf-bridge[.exe]
```

CI does this per-OS and bundles the result into the installers. The binary
matches the build machine's architecture (CI macOS runners are arm64).

### macOS Bluetooth permission

CoreBluetooth access is granted to the process that calls it. In dev that's
the terminal you launch `uv run` from, so the first run prompts *"<Terminal>
would like to use Bluetooth"* — allow it (System Settings → Privacy &
Security → Bluetooth). A frozen `.app` later carries its own
`NSBluetoothAlwaysUsageDescription`.

## Supported GATT profiles

| Service | UUID | Used for |
|---|---|---|
| Cycling Power | `0x1818` | instantaneous power + crank cadence |
| Heart Rate | `0x180D` | heart rate (bpm) |
| Cycling Speed & Cadence | `0x1816` | crank cadence |
| Fitness Machine (FTMS) | `0x1826` | smart-trainer power/cadence **and resistance control** |

### Smart-trainer control (FTMS)

When a connected device exposes the FTMS Control Point (`0x2AD9`), the bridge
takes control of it (Request Control + Start) so the game can drive
resistance:

- **SIM mode** — the ride streams the live road grade
  (`{"cmd": "set_sim", "grade": <percent>, "crr": …, "cw": …}`); resistance
  follows the hill. This is the default.
- **ERG mode** — hold a fixed wattage (`{"cmd": "set_erg", "watts": <int>}`).

The trainer's own power + cadence are also read from Indoor Bike Data
(`0x2AD2`), so a trainer that doesn't advertise the Cycling Power service
still works as the power source. Choose the mode in **Ride → Sensors →
Trainer resistance**.

ANT+ is intentionally not supported — it needs a USB dongle, and modern
sensors are dual ANT+/BLE.

## Protocol

JSON text frames. The game sends `{"cmd": "scan"}`,
`{"cmd": "connect", "address": "...", "kind": "auto"}`,
`{"cmd": "disconnect", "address": "..."}`, `{"cmd": "status"}`.

The bridge pushes `device`, `connected`, `disconnected`, `scan_started`,
`scan_stopped`, `error`, and a merged `sensor` snapshot
(`{power_w, cadence_rpm, heart_rate_bpm, ts_ms}`) on every notification plus
a 2 Hz heartbeat. See [`gbf_bridge/server.py`](gbf_bridge/server.py).

## Tests

```bash
uv run pytest        # GATT parser unit tests (no hardware needed)
```
