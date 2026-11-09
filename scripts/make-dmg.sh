#!/bin/zsh
# Universal build packed as dist/Paceline-<version>.dmg (the app + an Applications link).
# Not notarized yet: on another Mac, macOS asks to allow it in
# System Settings → Privacy & Security → Open Anyway.
set -euo pipefail

SRC="${0:A:h:h}"
WORK="${PACELINE_WORK:-$HOME/Library/Caches/Paceline}"
"$SRC/scripts/build-app.sh" --universal

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$SRC/Resources/Info.plist")
STAGE="$WORK/dmg"
rm -rf "$STAGE"
mkdir -p "$STAGE" "$SRC/dist"
cp -R "$WORK/Paceline.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

OUT="$SRC/dist/Paceline-$VERSION.dmg"
rm -f "$OUT"
hdiutil create -volname "Paceline $VERSION" -srcfolder "$STAGE" -format UDZO -fs HFS+ "$OUT" -quiet
rm -rf "$STAGE"
echo "$OUT ($(du -h "$OUT" | cut -f1))"
