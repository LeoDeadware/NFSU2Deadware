#!/bin/bash
# make_art.sh <default.xbe> <out.png>: the launcher window's art — the disc's title image (XBE $$XTIMAGE,
# 128x128) upscaled 4x (Real-ESRGAN when present, else sips) to 512x512. Built at install, never committed.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ICON="$HERE/../icon"; [[ -f "$ICON/xbe_title_image.py" ]] || ICON="$HERE"
ROOT="$(cd "$HERE/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/nfsu2_art.XXXXXX")"; trap 'rm -rf "$T"' EXIT
python3 -I "$ICON/xbe_title_image.py" "$1" "$T/t.png" >/dev/null
E="$ROOT/.cache/tools/realesrgan/x"; [[ -d "$E" ]] || E="$ROOT/../ROTKPort/.cache/tools/realesrgan/x"
if [[ -x "$E/realesrgan-ncnn-vulkan" ]] && "$E/realesrgan-ncnn-vulkan" -i "$T/t.png" -o "$T/x4.png" -m "$E/models" -n realesrgan-x4plus >/dev/null 2>&1; then
  cp "$T/x4.png" "$2"
else
  sips -z 512 512 "$T/t.png" --out "$2" >/dev/null
fi
echo "art -> $2"
