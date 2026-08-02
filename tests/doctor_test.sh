#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd -- "$script_dir/.." && pwd -P)

if "$repo_root/scripts/doctor.sh" --mode invalid >/dev/null 2>&1; then
    printf '%s\n' 'doctor test: invalid mode unexpectedly succeeded' >&2
    exit 1
fi

"$repo_root/scripts/doctor.sh" --mode repo --strict >/dev/null
"$repo_root/scripts/doctor.sh" --mode oss >/dev/null

if "$repo_root/scripts/synth.sh" \
    --toolchain oss --target nano20k --profile debug-full >/dev/null 2>&1; then
    printf '%s\n' 'doctor test: unsupported target/profile unexpectedly succeeded' >&2
    exit 1
fi

if "$repo_root/scripts/synth.sh" \
    --toolchain oss --target console138k --profile release >/dev/null 2>&1; then
    printf '%s\n' 'doctor test: missing board driver unexpectedly succeeded' >&2
    exit 1
fi

printf '%s\n' 'doctor/synthesis dispatch tests: PASS'
