# Gotta Bike Fast — Godot client

Godot 4.6.3 / GDScript indoor-cycling game. Talks to a FastAPI backend
(`:8001`) and a Django backend (`:8000`); both live in sibling repos.

## Releases: every push to `main` is a release

CI (`.github/workflows/build.yml`) builds installable packages on every push
to `main` and the **`release` job auto-publishes a GitHub Release** with both
installers attached, tagged `v0.1.0-build.<run_number>`.

So: **when you commit + push to `main`, a tagged release is created
automatically.** After pushing, confirm the run is green and the release
appeared (`gh release list`). Don't hand-create releases — let CI do it.

## Build / packaging

- Two native runners: macOS → arm64 `.dmg` (Apple Silicon only; the universal
  engine binary is `lipo`-thinned to arm64), Windows → Inno Setup installer +
  portable zip.
- Each package **bundles the frozen BLE bridge** and the game auto-launches
  it, so end users need no Python/uv.
- `export_presets.cfg` is committed; signing creds (`export_credentials.cfg`)
  are gitignored and live only on the signing machine.

## BLE sensor bridge (`bridge/`)

Python ≥ 3.14, `uv`-managed. Reads BLE power / HR / cadence and controls
FTMS trainers, served to the game over `ws://127.0.0.1:8770`.

```bash
cd bridge
uv run gbf-bridge                                  # dev: run it yourself
uv run pytest                                      # GATT + trainer tests
uv run --group build pyinstaller gbf-bridge.spec   # freeze a binary
```

In exported builds the game spawns the bundled bridge; in the editor it does
not — run `uv run gbf-bridge` manually.

## Conventions

- Verify GDScript with a headless import before pushing:
  `Godot --headless --import .` (0 script errors).
- Keep secrets out of the repo and the transcript (they live in Railway / the
  signing machine only).
