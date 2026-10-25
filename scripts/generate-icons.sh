#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

svg="$repo_root/Assets/CamMicIcon.svg"
master="$repo_root/Assets/CamMicIcon-1024.png"
mac_master="$repo_root/Assets/CamMicIcon-macOS-1024.png"
ios_intermediate="$(mktemp "${TMPDIR:-/tmp}/cammic-icon-ios.XXXXXX.png")"
mac_intermediate="$(mktemp "${TMPDIR:-/tmp}/cammic-icon-mac.XXXXXX.png")"
mac_svg="$(mktemp "${TMPDIR:-/tmp}/cammic-icon-mac.XXXXXX.svg")"
appicon_dir="$repo_root/Assets.xcassets/AppIcon.appiconset"
mac_iconset="$repo_root/Assets/CamMicIcon.iconset"
trap 'rm -f "$ios_intermediate" "$mac_intermediate" "$mac_svg"' EXIT

mkdir -p "$appicon_dir" "$mac_iconset"
rm -f "$appicon_dir"/*.png "$mac_iconset"/*.png
sips -s format png "$svg" --out "$ios_intermediate" >/dev/null
swift "$repo_root/scripts/render-opaque-png.swift" "$ios_intermediate" "$master"
python3 - "$svg" "$mac_svg" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
rect = '  <rect width="1024" height="1024" fill="url(#background)"/>\n  <rect width="1024" height="1024" fill="url(#glow)"/>\n'
decoration = '  <circle cx="512" cy="480" r="392" fill="#B7FBFF" opacity="0.055"/>\n  <ellipse cx="512" cy="520" rx="252" ry="380" fill="url(#symbolShadow)"/>\n'
if source.count(rect) != 1 or source.count(decoration) != 1:
    raise SystemExit("Expected the editable master background and decoration exactly once.")
source = source.replace(rect, '''  <defs>
    <filter id="card-shadow" x="-12%" y="-12%" width="124%" height="124%" color-interpolation-filters="sRGB">
      <feGaussianBlur stdDeviation="14"/>
    </filter>
    <clipPath id="mac-icon-shape"><rect x="72" y="72" width="880" height="880" rx="210"/></clipPath>
  </defs>
  <rect x="78" y="84" width="880" height="880" rx="210" fill="#063B68" opacity="0.28" filter="url(#card-shadow)"/>
  <g clip-path="url(#mac-icon-shape)">
    <rect x="72" y="72" width="880" height="880" fill="url(#background)"/>
    <rect x="72" y="72" width="880" height="880" fill="url(#glow)"/>
''' + decoration.replace('  ', '    ') + '  </g>\n')
needle = '<g id="microphone-symbol" '
replacement = '<g id="microphone-symbol" transform="translate(30.72 30.72) scale(0.94)" '
if source.count(needle) != 1:
    raise SystemExit("Expected exactly one editable microphone-symbol group in the SVG master.")
pathlib.Path(sys.argv[2]).write_text(source.replace(needle, replacement, 1))
PY
sips -s format png "$mac_svg" --out "$mac_intermediate" >/dev/null
swift "$repo_root/scripts/render-alpha-png.swift" "$mac_intermediate" "$mac_master"

python3 - "$appicon_dir" "$mac_iconset" "$master" "$mac_master" <<'PY'
import json
import pathlib
import subprocess
import sys

app_dir = pathlib.Path(sys.argv[1])
mac_dir = pathlib.Path(sys.argv[2])
master = pathlib.Path(sys.argv[3])
mac_master = pathlib.Path(sys.argv[4])

icons = []
def app_icon(name, points, scale, idiom):
    px = round(float(points) * int(scale[0]))
    path = app_dir / name
    subprocess.run(["sips", "-z", str(px), str(px), str(master), "--out", str(path)], check=True, stdout=subprocess.DEVNULL)
    icons.append({"filename": name, "idiom": idiom, "scale": scale, "size": f"{points}x{points}"})

for points in (20, 29, 40, 60):
    for scale in ("2x", "3x"):
        app_icon(f"AppIcon-{points}@{scale}.png", points, scale, "iphone")
for points in (20, 29, 40, 76):
    for scale in ("1x", "2x"):
        app_icon(f"AppIcon-iPad-{points}@{scale}.png", points, scale, "ipad")
app_icon("AppIcon-iPad-83.5@2x.png", 83.5, "2x", "ipad")
app_icon("AppIcon-1024.png", 1024, "1x", "ios-marketing")

(app_dir / "Contents.json").write_text(json.dumps({"images": icons, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")

for points in (16, 32, 128, 256, 512):
    subprocess.run(["sips", "-z", str(points), str(points), str(mac_master), "--out", str(mac_dir / f"icon_{points}x{points}.png")], check=True, stdout=subprocess.DEVNULL)
    subprocess.run(["sips", "-z", str(points * 2), str(points * 2), str(mac_master), "--out", str(mac_dir / f"icon_{points}x{points}@2x.png")], check=True, stdout=subprocess.DEVNULL)

PY

iconutil --convert icns "$mac_iconset" --output "$repo_root/Assets/CamMic.icns"
swift "$repo_root/scripts/validate-icons.swift" "$master" "$mac_master" "$mac_iconset" "$repo_root/Assets/CamMic.icns"
echo "Generated opaque iOS AppIcon and transparent rounded macOS CamMic.icns from the shared SVG master $svg"
