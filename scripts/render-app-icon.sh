#!/bin/sh
# Renders Blau's app icon (Blau/Resources/AppIcon.icon, an Icon Composer
# document) in every iOS appearance, so a change to the icon can be reviewed
# without a device (#82, docs/branding.md).
#
#   scripts/render-app-icon.sh [output-dir]      (default .build/AppIcon)
#
# Writes <generation>-<rendition>.png for the iOS 26 and iOS 27 designs and
# each rendition: Default (light), Dark, TintedLight, TintedDark, ClearLight
# and ClearDark. Fails if any rendition doesn't render.
#
# Environment:
#   ICON         the .icon document (default Blau/Resources/AppIcon.icon)
#   SIZE         edge length in pixels (default 1024)
#   GENERATIONS  design generations to render (default "26 27")
#   ICTOOL       Icon Composer's command-line renderer (default: the one in
#                the selected Xcode's Icon Composer.app; `xcrun ictool` is a
#                different tool that can't export images)

set -eu

ICON=${ICON:-Blau/Resources/AppIcon.icon}
OUT=${1:-.build/AppIcon}
SIZE=${SIZE:-1024}
GENERATIONS=${GENERATIONS:-26 27}
RENDITIONS="Default Dark TintedLight TintedDark ClearLight ClearDark"

if [ -z "${ICTOOL:-}" ]; then
    ICTOOL="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
fi

if [ ! -x "$ICTOOL" ]; then
    echo "error: Icon Composer's ictool not found at $ICTOOL (Xcode 26 or later; or set ICTOOL)" >&2
    exit 1
fi
if [ ! -f "$ICON/icon.json" ]; then
    echo "error: $ICON is not an Icon Composer document (no icon.json)" >&2
    exit 1
fi

mkdir -p "$OUT"
failures=0
for generation in $GENERATIONS; do
    for rendition in $RENDITIONS; do
        file="$OUT/ios$generation-$rendition.png"
        rm -f "$file"
        if ! "$ICTOOL" "$ICON" --export-image --output-file "$file" --platform iOS \
            --rendition "$rendition" --width "$SIZE" --height "$SIZE" --scale 1 \
            --design-generation "$generation" >/dev/null 2>&1; then
            echo "FAIL  iOS $generation $rendition: ictool failed" >&2
            failures=$((failures + 1))
            continue
        fi
        width=$(sips -g pixelWidth "$file" 2>/dev/null | awk '/pixelWidth/ { print $2 }')
        if [ "$width" != "$SIZE" ]; then
            echo "FAIL  iOS $generation $rendition: expected a ${SIZE}px image, got '${width:-none}'" >&2
            failures=$((failures + 1))
            continue
        fi
        echo "ok    iOS $generation $rendition -> $file"
    done
done

if [ "$failures" -ne 0 ]; then
    echo "$failures rendition(s) failed" >&2
    exit 1
fi
