#!/bin/sh

set -eu

macos_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repo_dir=$(CDPATH= cd -- "$macos_dir/.." && pwd)
app="$repo_dir/dist/macos/CuotaX.app"
build_commit=$(git -C "$repo_dir" rev-parse --verify HEAD)

swift build --package-path "$macos_dir" -c release --product CuotaX
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$macos_dir/.build/release/CuotaX" "$app/Contents/MacOS/CuotaX"
cp "$macos_dir/Resources/Info.plist" "$app/Contents/Info.plist"
plutil -insert CuotaXBuildCommit -string "$build_commit" "$app/Contents/Info.plist"
codesign --force --sign - "$app"

echo "Built $app"
