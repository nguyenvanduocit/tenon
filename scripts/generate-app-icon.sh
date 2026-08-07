#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
repo_root=${script_dir:h}
design_dir="$repo_root/Design/AppIcon"
catalog_dir="$repo_root/Sources/TenonApp/Assets.xcassets/AppIcon.appiconset"
master_svg="$design_dir/TenonAppIcon.svg"
small_svg="$design_dir/TenonAppIcon-Small.svg"

if ! command -v sips >/dev/null 2>&1; then
  echo "sips is required to render the SVG master." >&2
  exit 1
fi

if ! command -v magick >/dev/null 2>&1; then
  echo "ImageMagick is required for optical-size exports: brew install imagemagick" >&2
  exit 1
fi

temp_dir=$(mktemp -d)
trap 'rm -rf "$temp_dir"' EXIT

sips -s format png "$master_svg" --out "$temp_dir/master.png" >/dev/null
magick -background none "$small_svg" "$temp_dir/small.png"

render_small_icon() {
  local source=$1
  local size=$2
  local output=$3

  magick \
    "$source" \
    -filter Lanczos \
    -resize "${size}x${size}" \
    -strip \
    "$catalog_dir/$output"
}

render_master_icon() {
  local size=$1
  local output=$2

  sips \
    -z "$size" "$size" \
    "$temp_dir/master.png" \
    --out "$catalog_dir/$output" \
    >/dev/null
}

mkdir -p "$catalog_dir"

render_small_icon "$temp_dir/small.png" 16 "icon_16x16.png"
render_small_icon "$temp_dir/small.png" 32 "icon_16x16@2x.png"
render_small_icon "$temp_dir/small.png" 32 "icon_32x32.png"
render_master_icon 64 "icon_32x32@2x.png"
render_master_icon 128 "icon_128x128.png"
render_master_icon 256 "icon_128x128@2x.png"
render_master_icon 256 "icon_256x256.png"
render_master_icon 512 "icon_256x256@2x.png"
render_master_icon 512 "icon_512x512.png"
render_master_icon 1024 "icon_512x512@2x.png"

cp "$catalog_dir/icon_512x512@2x.png" "$design_dir/TenonAppIcon-1024.png"

iconset_dir="$temp_dir/Tenon.iconset"
mkdir -p "$iconset_dir"
cp "$catalog_dir"/icon_*.png "$iconset_dir/"
iconutil -c icns "$iconset_dir" -o "$design_dir/Tenon.icns"

expected=(
  "icon_16x16.png:16"
  "icon_16x16@2x.png:32"
  "icon_32x32.png:32"
  "icon_32x32@2x.png:64"
  "icon_128x128.png:128"
  "icon_128x128@2x.png:256"
  "icon_256x256.png:256"
  "icon_256x256@2x.png:512"
  "icon_512x512.png:512"
  "icon_512x512@2x.png:1024"
)

for item in "${expected[@]}"; do
  filename=${item%%:*}
  size=${item##*:}
  dimensions=$(magick identify -format "%wx%h" "$catalog_dir/$filename")
  if [[ "$dimensions" != "${size}x${size}" ]]; then
    echo "$filename has $dimensions; expected ${size}x${size}" >&2
    exit 1
  fi

  corner_alpha=$(magick "$catalog_dir/$filename" -format '%[fx:round(255*u.p{0,0}.a)]' info:)
  if [[ "$corner_alpha" != "0" ]]; then
    echo "$filename has opaque corner pixels; expected transparent corners" >&2
    exit 1
  fi

  sample_x=$((size / 2))
  sample_y=$((size * 2 / 5))
  sample_red=$(magick "$catalog_dir/$filename" -format "%[fx:round(255*u.p{${sample_x},${sample_y}}.r)]" info:)
  if (( sample_red < 140 )); then
    echo "$filename lost the amber joint during rendering" >&2
    exit 1
  fi
done

echo "Generated Tenon AppIcon assets and $design_dir/Tenon.icns"
