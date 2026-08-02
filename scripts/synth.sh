#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd -- "$script_dir/.." && pwd -P)

toolchain=
target=
profile=

usage() {
    printf '%s\n' 'usage: scripts/synth.sh --toolchain vendor|oss --target TARGET --profile PROFILE'
}

while (($#)); do
    case "$1" in
        --toolchain|--target|--profile)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            case "$1" in
                --toolchain) toolchain=$2 ;;
                --target) target=$2 ;;
                --profile) profile=$2 ;;
            esac
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'synth: unknown argument: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

case "$toolchain" in
    vendor|oss) ;;
    *) printf 'synth: unsupported toolchain: %s\n' "$toolchain" >&2; exit 2 ;;
esac

case "$target:$profile" in
    nano20k:release|console60k:release|console60k:debug-lite|console138k:release|console138k:debug-lite|console138k:debug-full) ;;
    *)
        printf 'synth: unsupported target/profile: %s/%s\n' "$target" "$profile" >&2
        exit 2
        ;;
esac

board_driver="$repo_root/boards/$target/build.sh"
output_dir="$repo_root/build/$toolchain/$target/$profile"

if [[ ! -x "$board_driver" ]]; then
    printf 'synth: no build driver exists yet for %s\n' "$target" >&2
    printf 'expected: %s\n' "$board_driver" >&2
    printf '%s\n' 'This is intentional while Milestones 1-2 are incomplete; no bitstream was produced.' >&2
    exit 2
fi

"$repo_root/scripts/doctor.sh" --mode "$toolchain" --strict
mkdir -p -- "$output_dir"
exec "$board_driver" --toolchain "$toolchain" --profile "$profile" --output "$output_dir"
