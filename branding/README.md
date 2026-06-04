# App icon / branding

`icon_master.svg` is the source of truth for the app icon — the
"Speed Wheel" mark (bike wheel + motion streaks on a blue→cyan tile).
`concept_*.svg` are the other concepts that were considered.

The project icon (`res://icon.svg`) is a copy of `icon_master.svg`.

## Regenerating the platform icons

Needs `rsvg-convert` (`brew install librsvg`), macOS `iconutil`, and
Pillow (in the web venv).

```bash
cd branding

# macOS .icns
rm -rf icon.iconset && mkdir icon.iconset
for s in 16:icon_16x16 32:icon_16x16@2x 32:icon_32x32 64:icon_32x32@2x \
         128:icon_128x128 256:icon_128x128@2x 256:icon_256x256 \
         512:icon_256x256@2x 512:icon_512x512 1024:icon_512x512@2x; do
  px=${s%%:*}; n=${s##*:}; rsvg-convert -w $px -h $px icon_master.svg -o "icon.iconset/$n.png"
done
iconutil -c icns icon.iconset -o icon.icns

# Windows .ico (multi-size) — via Pillow
rsvg-convert -w 1024 -h 1024 icon_master.svg -o icon_1024.png
python3 -c "from PIL import Image; Image.open('icon_1024.png').save('icon.ico', \
  sizes=[(16,16),(24,24),(32,32),(48,48),(64,64),(128,128),(256,256)])"

# Godot project icon
cp icon_master.svg ../icon.svg
```

## Where the icons are wired in

- `project.godot` — `config/icon` (editor + generic), `config/windows_native_icon`
  (`branding/icon.ico`, runtime window/taskbar icon), `config/macos_native_icon`
  (`branding/icon.icns`, runtime dock icon).
- `export_presets.cfg` (gitignored) — macOS preset `application/icon` =
  `res://branding/icon.icns` (Finder bundle icon, ✅ works); Windows preset
  `application/icon` = `res://branding/icon.ico` + `modify_resources=true`.

## Known limitation

The Windows **.exe file icon** (what Explorer shows) is embedded via
`rcedit`, which on macOS needs Wine. Without it the embed is skipped and
the exe keeps the default template icon — build on Windows, or install
rcedit + Wine, to embed it. The in-game window/taskbar icon still comes
from `windows_native_icon`. The macOS `.app` icon needs no external tool
and is applied correctly.
