# Keyboard-only web build

A browser (HTML5/WebAssembly) build of the game. **Keyboard power only** — a
browser can't reach the local BLE bridge, so sensors/trainers are disabled
(`SensorBridge` no-ops every connection path when `OS.has_feature("web")`, and
the Ride tab shows "Power source: Keyboard (web build)"). It renders with the
**Compatibility** (WebGL2) renderer, so the Forward+ effects (SSR, volumetric
fog, SSAO, glow) are off; the Belleville ink post-process still works.

## Build + test locally

```bash
GODOT="$HOME/Applications/Godot.app/Contents/MacOS/Godot"

# 1. Export the "Web" preset (writes build/web/index.html + .wasm/.pck/...).
"$GODOT" --headless --path . --export-release "Web" build/web/index.html

# 2. Serve it (correct wasm MIME + no-cache) and open the printed URL.
python tools/web/serve.py            # → http://127.0.0.1:8060/
```

Then open `http://127.0.0.1:8060/` in Chrome / Edge / Firefox. You should see
the game boot into the menu and be able to ride solo with the keyboard.

> First export is the slowest (it pulls the web export template). `build/` is
> gitignored — the export output is never committed.

## Notes / config

- **Preset:** `export_presets.cfg` → `[preset.2]` `Web`, thread support **off**
  (`variant/thread_support=false`). No threads ⇒ no cross-origin-isolation
  (COOP/COEP) headers required ⇒ simplest hosting and no interference with the
  game's cross-origin API calls.
- **Renderer:** `project.godot` sets `renderer/rendering_method.web="gl_compatibility"`.
- **Backend access:** the menu/login/courses come from the FastAPI + Django
  services. In a browser those are **cross-origin**, so the backends must send
  CORS headers allowing the game's origin. That's part of the Railway hosting
  step — locally you can confirm the build boots and the menu renders even
  before CORS is set up.
- **Switching to threads later** (better perf): set `variant/thread_support=true`
  and serve/host with `Cross-Origin-Opener-Policy: same-origin` +
  `Cross-Origin-Embedder-Policy: require-corp` (and the backends need CORP/CORS).
