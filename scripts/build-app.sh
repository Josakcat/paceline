#!/bin/zsh
# Builds Paceline.app from a copy outside iCloud Desktop (iCloud xattrs break codesign).
#   scripts/build-app.sh               build ~/Library/Caches/Paceline/Paceline.app (this Mac's arch)
#   scripts/build-app.sh --universal   Apple silicon + Intel in one binary
#   scripts/build-app.sh --install     also copy it to ~/Applications
set -euo pipefail

SRC="${0:A:h:h}"
# PACELINE_WORK moves the build folder (a release builds outside home, so no home path ends up in the binary).
WORK="${PACELINE_WORK:-$HOME/Library/Caches/Paceline}"
APP="$WORK/Paceline.app"
ARCHS=()
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --universal) ARCHS=(--arch arm64 --arch x86_64) ;;
    --install) INSTALL=1 ;;
  esac
done

mkdir -p "$WORK/src"
rsync -a --delete --exclude .build --exclude .git --exclude prototype --exclude dist "$SRC/" "$WORK/src/"
cd "$WORK/src"
swift build -c release --scratch-path "$WORK/build" "${ARCHS[@]}"
BIN="$(swift build -c release --scratch-path "$WORK/build" "${ARCHS[@]}" --show-bin-path)/Paceline"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Paceline"
cp "$WORK/src/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$WORK/src/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# The brand mint as the app's accent (buttons, switches, pop-ups); needs Xcode's actool.
if xcrun --find actool >/dev/null 2>&1; then
  xcrun actool "$WORK/src/Resources/Assets.xcassets" --compile "$APP/Contents/Resources" --platform macosx \
    --minimum-deployment-target 14.0 --output-partial-info-plist "$WORK/assets-info.plist" >/dev/null
else
  echo "actool not found (needs Xcode): the system accent colour stays"
fi
# Debug symbols name every object file by its build path; the app doesn't need them.
strip -S "$APP/Contents/MacOS/Paceline"
codesign --force --sign - "$APP"
echo "built $APP ($(lipo -archs "$APP/Contents/MacOS/Paceline"))"

if (( INSTALL )); then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Paceline.app"
  cp -R "$APP" "$HOME/Applications/"
  echo "installed $HOME/Applications/Paceline.app"
fi
