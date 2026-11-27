#!/bin/sh
# Packages a built NOOP.app into a drag-to-Applications disk image.
# Usage: Tools/release/make_dmg.sh <path to NOOP.app> <version>   → NOOP-<version>.dmg in the current directory
set -eu
APP="$1"; VERSION="$2"
[ -d "$APP" ] || { echo "no app at $APP" >&2; exit 1; }
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/NOOP.app"          # ditto keeps the signature and extended attributes intact
ln -s /Applications "$STAGE/Applications"
OUT="NOOP-$VERSION.dmg"
rm -f "$OUT"
hdiutil create -volname "NOOP $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$OUT" >/dev/null
hdiutil verify "$OUT" >/dev/null
echo "$OUT"
