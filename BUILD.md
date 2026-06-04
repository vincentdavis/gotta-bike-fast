# Building & distributing the game

The Godot client is exported per-platform. Below is the Windows build;
the same steps apply to macOS/Linux by changing the preset.

## One-time setup

1. **Install the matching export templates** (one big download, ~1.3 GB).
   In the Godot editor: *Editor → Manage Export Templates → Download and
   Install*. It auto-picks the version that matches the editor
   (currently `4.6.3.stable`).

   Or install manually: download
   `Godot_v<ver>-stable_export_templates.tpz`, unzip, and copy the
   contents of its `templates/` folder into
   `~/Library/Application Support/Godot/export_templates/<ver>.stable/`
   (macOS) — `version.txt` inside must read `<ver>.stable`.

2. The Windows preset already lives in `export_presets.cfg` (gitignored;
   recreate from this doc if missing). Key options: single-file output
   (`embed_pck=true`), `x86_64`, no console wrapper, `modify_resources`
   off (icon/metadata embedding needs Wine on macOS — skipped for now).

## Build the Windows .exe

From the project root:

```bash
GODOT="$HOME/Applications/Godot.app/Contents/MacOS/Godot"
"$GODOT" --headless --import .                                    # bake resources
"$GODOT" --headless --export-release "Windows Desktop" \
    "$PWD/build/windows/GottaBikeFast.exe"
```

Output: `build/windows/GottaBikeFast.exe` (~105 MB, self-contained —
the `.pck` is embedded, so it's the only file you ship). `build/` is
gitignored.

A debug build (console window, asserts on) is the same with
`--export-debug`.

## Running / distributing

⚠️ **The client is useless without reachable servers.** It talks to:

- FastAPI (live game state) — default `http://127.0.0.1:8001`
- Django (accounts/riders/routes) — default `http://127.0.0.1:8000`

So the `.exe` only works where those are reachable. Options:

- **Same machine:** run both Python servers (see each repo's README)
  and launch the exe — defaults point at localhost.
- **Another machine / another person:** they won't have your servers.
  Either (a) point the client at a host they can reach via the in-game
  **System tab → Dev menu** (edit the three URLs; saved to
  `user://dev_settings.cfg`), or (b) change the defaults in
  `scripts/network/dev_settings.gd` before building and host the
  backends somewhere public (e.g. a VPS / Fly.io / Render). Real
  distribution needs the backends hosted — that's a separate task.

## Build the macOS .app

The "macOS" preset (in `export_presets.cfg`) builds a **universal**
(arm64 + x86_64) `.app`, ad-hoc signed (`codesign/codesign=1`,
`identity="-"`) so it runs locally without a developer certificate.

Universal/arm64 exports require ETC2 ASTC texture import, enabled
project-wide via `rendering/textures/vram_compression/import_etc2_astc=true`
in `project.godot` (already set).

```bash
GODOT="$HOME/Applications/Godot.app/Contents/MacOS/Godot"
"$GODOT" --headless --import .                                    # bake resources
"$GODOT" --headless --export-release "macOS" \
    "$PWD/build/macos/GottaBikeFast.app"
```

Output: `build/macos/GottaBikeFast.app` (~178 MB; bigger than Windows
because it's two architectures + the extra texture format). Double-click
to run, or `open build/macos/GottaBikeFast.app`.

To distribute to *other* Macs you'd need Apple Developer ID signing +
notarization (set `codesign/codesign` to rcodesign/Xcode and
`notarization/notarization`) — otherwise Gatekeeper blocks it with
"unidentified developer". The ad-hoc build runs only on the machine
that built it (or after a manual right-click → Open).

## Notes

- The Windows exe / macOS app carry the default Godot icon. Custom icons:
  Windows needs Wine + rcedit (`application/modify_resources=true` +
  `application/icon=...`); macOS takes an `.icns` via `application/icon`.
- Windows SmartScreen / macOS Gatekeeper will warn on unsigned builds.
  Proper signing needs a Windows Authenticode cert / Apple Developer ID
  (out of scope here).
- Linux: add a "Linux/X11" preset and run
  `--export-release "<preset name>" build/linux/GottaBikeFast.x86_64`.
