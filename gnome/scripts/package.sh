#!/usr/bin/env bash
set -euo pipefail

gnome_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
repo_dir=$(cd -- "$gnome_dir/.." && pwd)
extension_dir="$gnome_dir/extension"
out_dir=${1:-"$repo_dir/dist/gnome"}
staging_dir=$(mktemp -d)
trap 'rm -rf "$staging_dir"' EXIT

build_commit=$(git -C "$repo_dir" rev-parse --verify HEAD)
cp -R "$extension_dir"/. "$staging_dir"
sed "s/BUILD_COMMIT = ''/BUILD_COMMIT = '$build_commit'/" \
  "$extension_dir/build.js" >"$staging_dir/build.js"

mkdir -p "$out_dir"
gnome-extensions pack "$staging_dir" \
  --extra-source=backend.js \
  --extra-source=build.js \
  --extra-source=quota.js \
  --extra-source=update.js \
  --out-dir="$out_dir" \
  --force
