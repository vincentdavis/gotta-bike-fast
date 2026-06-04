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

## Notes

- The exe carries the default Godot icon. To embed a custom `.ico` +
  version metadata on macOS you need Wine + rcedit configured, then set
  `application/modify_resources=true` and `application/icon=...` in the
  preset.
- Windows SmartScreen will warn on an unsigned exe. Code-signing needs
  a Windows Authenticode cert (out of scope here).
- Other platforms: add a preset (*Project → Export → Add*) for
  "macOS"/"Linux/X11" and run `--export-release "<preset name>" <out>`.
