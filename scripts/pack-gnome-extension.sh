#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
extension_dir="$repo_dir/src"
out_dir=${1:-"$repo_dir/dist"}

mkdir -p "$out_dir"
gnome-extensions pack "$extension_dir" \
  --extra-source=backend.js \
  --extra-source=quota.js \
  --out-dir="$out_dir" \
  --force
