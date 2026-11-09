#!/bin/zsh
# Packs a built Paceline.app as Paceline.zip + Paceline.zip.sha256 ("<hash>  Paceline.zip"),
# the two assets "Install and Relaunch" needs on a release. Build first with --universal.
#   scripts/make-release-zip.sh [Paceline.app] [out dir]
set -euo pipefail

SRC="${0:A:h:h}"
APP="${1:-${PACELINE_WORK:-$HOME/Library/Caches/Paceline}/Paceline.app}"
OUT="${2:-$SRC/dist}"
[[ -d $APP && ${APP:t} == Paceline.app ]] || { echo "no Paceline.app at $APP" >&2; exit 1; }
codesign --verify --deep --strict "$APP"

mkdir -p "$OUT"
rm -f "$OUT/Paceline.zip" "$OUT/Paceline.zip.sha256"
# No resource forks or extended attributes: only the app's own files go in.
ditto -c -k --keepParent --norsrc --noextattr "$APP" "$OUT/Paceline.zip"
(cd "$OUT" && shasum -a 256 Paceline.zip > Paceline.zip.sha256 && shasum -a 256 -c Paceline.zip.sha256 >/dev/null)
echo "$OUT/Paceline.zip ($(du -h "$OUT/Paceline.zip" | cut -f1))"
cat "$OUT/Paceline.zip.sha256"
