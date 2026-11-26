#!/usr/bin/env bash
# Builds ClaudeThermal.app with SwiftPM (no Xcode needed).
#
#   ./build.sh            build build/ClaudeThermal.app
#   ./build.sh run        build, then (re)launch it
#   ./build.sh install    build, copy to /Applications, delete the build/ copy, launch
#   ./build.sh dump       build, print the parsed usage numbers to the terminal
#   ./build.sh setup-statusline   let Claude Code share exact usage % with the app (no credentials)
#   ./build.sh release    universal app zipped into dist/ for GitHub Releases
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="ClaudeThermal"
APP="build/${APP_NAME}.app"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/${APP_NAME}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature: enough for SMAppService and notifications on your own Mac.
codesign --force --deep --sign - "$APP" >/dev/null
echo "Built $APP"

relaunch() {
  pkill -x "$APP_NAME" 2>/dev/null || true
  sleep 0.3
  open "$1"
  echo "Launched $1 — look for the pill in your menu bar."
}

setup_statusline() {
  # Installs the bridge and points Claude Code's status line at it. Never overwrites an
  # existing statusLine; backs up settings.json first.
  local claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  local settings="$claude_dir/settings.json"
  local target="$claude_dir/thermal/statusline.sh"
  mkdir -p "$claude_dir/thermal"
  install -m 755 scripts/statusline-bridge.sh "$target"
  echo "Installed $target"

  [ -f "$settings" ] || echo '{}' > "$settings"
  local existing
  existing=$(/usr/bin/jq -r '.statusLine.command // empty' "$settings")
  if [ -n "$existing" ] && [ "$existing" != "$target" ]; then
    echo "You already have a status line: $existing"
    echo "Leaving it alone. To feed ClaudeThermal too, pipe its input through $target first."
    return
  fi
  cp "$settings" "$settings.bak-claudethermal"
  /usr/bin/jq --arg cmd "$target" '.statusLine = {type: "command", command: $cmd}' "$settings" > "$settings.tmp" \
    && mv "$settings.tmp" "$settings"
  echo "Set statusLine in $settings (backup: $settings.bak-claudethermal)"
}

make_release() {
  # Universal (Apple silicon + Intel) app, zipped for GitHub Releases.
  local version
  version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
  swift build -c release --triple arm64-apple-macosx14.0
  swift build -c release --triple x86_64-apple-macosx14.0
  lipo -create \
    ".build/arm64-apple-macosx/release/${APP_NAME}" \
    ".build/x86_64-apple-macosx/release/${APP_NAME}" \
    -output "$APP/Contents/MacOS/${APP_NAME}"
  codesign --force --deep --sign - "$APP" >/dev/null
  mkdir -p dist
  local zip="dist/${APP_NAME}-${version}.zip"
  rm -f "$zip"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$zip"
  (cd dist && shasum -a 256 "$(basename "$zip")" | tee "$(basename "$zip").sha256")
  echo "Release archive: $zip ($(lipo -archs "$APP/Contents/MacOS/${APP_NAME}"))"
}

case "${1:-}" in
  setup-statusline) setup_statusline ;;
  release) make_release ;;
  run) relaunch "$APP" ;;
  install)
    pkill -x "$APP_NAME" 2>/dev/null || true
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "$APP" /Applications/
    # Keep only the installed copy, so macOS never sees two apps with the same bundle ID.
    rm -rf "$APP"
    rmdir build 2>/dev/null || true
    relaunch "/Applications/${APP_NAME}.app"
    ;;
  dump) "$APP/Contents/MacOS/${APP_NAME}" --dump ;;
  "") ;;
  *) echo "usage: $0 [run|install|dump|setup-statusline|release]"; exit 1 ;;
esac
