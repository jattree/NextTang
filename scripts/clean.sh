#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd -- "$script_dir/.." && pwd -P)
build_dir="$repo_root/build"

if [[ -z "$repo_root" || "$repo_root" == "/" || "$build_dir" != "$repo_root/build" ]]; then
    printf '%s\n' 'clean: refusing unsafe build path' >&2
    exit 2
fi

if [[ ! -e "$build_dir" ]]; then
    printf '%s\n' 'clean: build directory is already absent'
    exit 0
fi

rm -rf -- "$build_dir"
printf 'clean: removed %s\n' "$build_dir"
