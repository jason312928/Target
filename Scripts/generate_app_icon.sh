#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd -P -- "$script_dir/.." && pwd -P)"
source_svg="$repo_root/Target/Assets.xcassets/AppIcon.appiconset/TargetAppIcon.svg"
output_dir="$repo_root/Target/Assets.xcassets/AppIcon.appiconset"

if [ ! -f "$source_svg" ]; then
    printf 'error: missing icon source: %s\n' "$source_svg" >&2
    exit 1
fi

if ! command -v sips >/dev/null 2>&1; then
    printf 'error: sips is required to generate the macOS icon PNGs\n' >&2
    exit 1
fi

while IFS=' ' read -r filename pixels; do
    [ -n "$filename" ] || continue
    sips -s format png -z "$pixels" "$pixels" "$source_svg" --out "$output_dir/$filename" >/dev/null
done <<'SIZES'
icon_16x16.png 16
icon_16x16@2x.png 32
icon_32x32.png 32
icon_32x32@2x.png 64
icon_128x128.png 128
icon_128x128@2x.png 256
icon_256x256.png 256
icon_256x256@2x.png 512
icon_512x512.png 512
icon_512x512@2x.png 1024
SIZES

printf 'Generated AppIcon PNGs in %s\n' "$output_dir"
