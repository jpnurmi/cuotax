#!/usr/bin/env bash
set -euo pipefail

gnome_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
repo_dir=$(cd -- "$gnome_dir/.." && pwd)
extension_dir="$gnome_dir/extension"
out_dir=${1:-"$repo_dir/dist/gnome"}

mkdir -p "$out_dir"
gnome-extensions pack "$extension_dir" \
  --extra-source=backend.js \
  --extra-source=quota.js \
  --out-dir="$out_dir" \
  --force
