#!/bin/sh

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app="$root/dist/CuotaX.app"

swift build --package-path "$root" -c release --product CuotaX
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$root/.build/release/CuotaX" "$app/Contents/MacOS/CuotaX"
cp "$root/macos/Info.plist" "$app/Contents/Info.plist"
codesign --force --sign - "$app"

echo "Built $app"
