#!/usr/bin/env bash
#
# gen_hesper_icons.sh — regenerate every Hesper Remote icon asset from the
# canonical square app artwork at res/hesper-icon.svg (the Hesper symbol on a
# white background, supplied by the Hesper Brand System v1.0). Tray glyphs and
# the Android adaptive-icon foreground use the pre-rendered monochrome / primary
# Hesper mark PNGs (res/hesper-mark-*.png) — the mark is self-contained, so no
# path extraction is needed (unlike the former Atlas ribbon pipeline).
#
# Outputs (all overwritten in place): res/ core icons (png/ico/tray/scalable.svg),
# flutter/assets/ icon.png + icon.svg, flutter/macos AppIcon.icns, flutter/windows
# app_icon.ico, flutter/ios AppIcon.appiconset/*.png, Android launcher icons +
# adaptive background colour, fastlane store icon.
#
# Requirements: rsvg-convert (librsvg), magick (ImageMagick 7), python3.
#   iconutil is used for the .icns iconset on macOS; on Linux a magick ICNS
#   fallback runs instead (regenerate on macOS for a full iconset if needed).
#
# Usage: bash res/gen_hesper_icons.sh   (from anywhere; paths self-resolve)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SRC="${SCRIPT_DIR}/hesper-icon.svg"               # square app icon (symbol on white)
MARK_BLACK="${SCRIPT_DIR}/hesper-mark-mono-black.png"
MARK_WHITE="${SCRIPT_DIR}/hesper-mark-mono-white.png"
MARK_PRIMARY="${SCRIPT_DIR}/hesper-mark-primary.png"
BG_COLOUR="#FFFFFF"                               # app-icon background (matches hesper-icon.svg)

for tool in rsvg-convert magick python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: $tool not found" >&2; exit 1; }
done
for f in "$SRC" "$MARK_BLACK" "$MARK_WHITE" "$MARK_PRIMARY"; do
    [ -f "$f" ] || { echo "ERROR: missing source asset: $f" >&2; exit 1; }
done

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
render() { rsvg-convert -w "$1" -h "$1" "${3:-$SRC}" -o "$2"; }

# 1. res/ core engine icons (consumed by src/tray.rs, packaging, installers)
render 512  "${SCRIPT_DIR}/icon.png"
render 32   "${SCRIPT_DIR}/32x32.png"
render 64   "${SCRIPT_DIR}/64x64.png"
render 128  "${SCRIPT_DIR}/128x128.png"
render 256  "${SCRIPT_DIR}/128x128@2x.png"
render 1024 "${SCRIPT_DIR}/mac-icon.png"
cp "$SRC" "${SCRIPT_DIR}/scalable.svg"            # Linux hicolor scalable icon

for s in 16 24 32 48 64 128 256; do render "$s" "${TMP}/ico-${s}.png"; done
magick "${TMP}/ico-16.png" "${TMP}/ico-24.png" "${TMP}/ico-32.png" "${TMP}/ico-48.png" \
       "${TMP}/ico-64.png" "${TMP}/ico-128.png" "${TMP}/ico-256.png" "${SCRIPT_DIR}/icon.ico"
magick "${TMP}/ico-16.png" "${TMP}/ico-24.png" "${TMP}/ico-32.png" "${SCRIPT_DIR}/tray-icon.ico"

# 2. macOS menu-bar template glyphs — monochrome Hesper mark on transparency, 60x60.
magick "$MARK_BLACK" -resize 60x60 "${SCRIPT_DIR}/mac-tray-dark-x2.png"
magick "$MARK_WHITE" -resize 60x60 "${SCRIPT_DIR}/mac-tray-light-x2.png"

# 3. flutter/assets — in-app icon + vector master
render 512 "${ROOT}/flutter/assets/icon.png"
cp "$SRC" "${ROOT}/flutter/assets/icon.svg"

# 4. macOS AppIcon.icns — iconutil (full iconset) on macOS; magick fallback on Linux.
if command -v iconutil >/dev/null 2>&1; then
    ICONSET="${TMP}/AppIcon.iconset"; mkdir -p "$ICONSET"
    for s in 16 32 128 256 512; do
        render "$s"         "${ICONSET}/icon_${s}x${s}.png"
        render "$((s * 2))" "${ICONSET}/icon_${s}x${s}@2x.png"
    done
    iconutil -c icns "$ICONSET" -o "${ROOT}/flutter/macos/Runner/AppIcon.icns"
else
    # Linux: iconutil is macOS-only, so pack a valid ICNS container from PNGs.
    for s in 32 64 128 256 512 1024; do render "$s" "${TMP}/icns-${s}.png"; done
    python3 "${SCRIPT_DIR}/pack_icns.py" "${ROOT}/flutter/macos/Runner/AppIcon.icns" \
        ic11="${TMP}/icns-32.png"  ic12="${TMP}/icns-64.png"  ic07="${TMP}/icns-128.png" \
        ic13="${TMP}/icns-256.png" ic08="${TMP}/icns-256.png" ic14="${TMP}/icns-512.png" \
        ic09="${TMP}/icns-512.png" ic10="${TMP}/icns-1024.png"
fi

# 5. Windows runner icon
magick "${TMP}/ico-16.png" "${TMP}/ico-24.png" "${TMP}/ico-32.png" "${TMP}/ico-48.png" \
       "${TMP}/ico-64.png" "${TMP}/ico-128.png" "${TMP}/ico-256.png" \
       "${ROOT}/flutter/windows/runner/resources/app_icon.ico"

# 6. iOS AppIcon.appiconset — every PNG in Contents.json, flattened opaque (no alpha).
APPICONSET="${ROOT}/flutter/ios/Runner/Assets.xcassets/AppIcon.appiconset"
if [ -f "${APPICONSET}/Contents.json" ]; then
    python3 - "${APPICONSET}/Contents.json" > "${TMP}/ios-manifest.txt" <<'PY'
import json, sys
seen = {}
for img in json.load(open(sys.argv[1]))["images"]:
    px = round(float(img["size"].split("x")[0]) * int(img["scale"].rstrip("x")))
    seen[img["filename"]] = px
for name, px in seen.items():
    print(name, px)
PY
    while read -r name px; do
        render "$px" "${TMP}/ios-tmp.png"
        magick "${TMP}/ios-tmp.png" -background "$BG_COLOUR" -alpha remove -alpha off \
               "PNG24:${APPICONSET}/${name}"
    done < "${TMP}/ios-manifest.txt"
fi

# 7. Android launcher icons (legacy + round + adaptive foreground/background)
ANDROID_RES="${ROOT}/flutter/android/app/src/main/res"
if [ -d "$ANDROID_RES" ]; then
    DENSITIES=(mdpi hdpi xhdpi xxhdpi xxxhdpi)
    LAUNCHER_PX=(48 72 96 144 192)
    FOREGROUND_PX=(162 243 324 486 648)
    for i in "${!DENSITIES[@]}"; do
        d="${DENSITIES[$i]}"; lp="${LAUNCHER_PX[$i]}"; fp="${FOREGROUND_PX[$i]}"
        dir="${ANDROID_RES}/mipmap-${d}"; mkdir -p "$dir"
        render "$lp" "${dir}/ic_launcher.png"
        magick "${dir}/ic_launcher.png" \
            \( -size "${lp}x${lp}" xc:none -fill white \
               -draw "circle $((lp / 2)),$((lp / 2)) $((lp / 2)),0" \) \
            -alpha on -compose DstIn -composite "${dir}/ic_launcher_round.png"
        g=$(( fp * 66 / 100 ))
        magick "$MARK_PRIMARY" -resize "${g}x${g}" -background none -gravity center \
               -extent "${fp}x${fp}" "${dir}/ic_launcher_foreground.png"
    done
    cat > "${ANDROID_RES}/values/ic_launcher_background.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">#FFFFFF</color>
</resources>
XML
fi

# 8. fastlane store icon
if [ -d "${ROOT}/fastlane/metadata/android/en-US/images" ]; then
    render 512 "${ROOT}/fastlane/metadata/android/en-US/images/icon.png"
fi

echo "OK: Hesper Remote icon assets regenerated from ${SRC}"
