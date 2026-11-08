#!/usr/bin/env bash
# Build the ZX Spectrum Next core for the Tang Nano 20K (v3923).
#
# PLANNED. The shell (nexttang_nano20k_zxnext.v) is a skeleton without
# clocks, main memory, video, input or audio, so there is nothing to build
# yet and this driver refuses to try. --print-sources lists what the shell
# elaborates from, so lint and the build matrix can check it holds together.
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd -- "$script_dir/../.." && pwd -P)

profile=
print_sources=0
while (($#)); do
    case "$1" in
        --profile) [[ $# -ge 2 ]] || exit 2; profile=$2; shift 2 ;;
        --toolchain|--output|--vendor-source|--boot-image) [[ $# -ge 2 ]] || exit 2; shift 2 ;;
        --print-sources) print_sources=1; shift ;;
        -h|--help)
            printf '%s\n' 'usage: boards/nano20k/build_zxnext.sh --profile skeleton --print-sources'
            exit 0 ;;
        *) printf 'nano20k zxnext build: unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done

[[ "$profile" == skeleton ]] || {
    printf 'nano20k zxnext build: profile not implemented: %s (only skeleton)\n' "$profile" >&2
    exit 2
}

# The machine's sources come from the Console driver's list, so the two
# boards cannot drift apart on what the shared machine is.
mapfile -t console_sources < <("$repo_root/boards/console138k/build_zxnext.sh" --profile diagnostic --print-sources)
source_files=()
for source_file in "${console_sources[@]}"; do
    case "$source_file" in
        */boards/*|*/rtl/video/*|*/rtl/memory/nexttang_block_ram.v|*/rtl/audio/nexttang_zxnext_audio_pcm.v|*/rtl/clock/nexttang_machine_clock_enables.v|*/rtl/reset/nexttang_reset_release.v) ;;
        *) source_files+=("$source_file") ;;
    esac
done
# The core's own video files are part of the machine.
for source_file in "${console_sources[@]}"; do
    case "$source_file" in
        */rtl/video/layer2.vhd|*/rtl/video/lores.vhd|*/rtl/video/sprites.vhd|*/rtl/video/tilemap.vhd|*/rtl/video/zxula_timing.vhd|*/rtl/video/zxula.vhd)
            source_files+=("$source_file") ;;
    esac
done
source_files+=(
    "$repo_root/boards/nano20k/nexttang_nano20k_zxnext.v"
    "$repo_root/boards/nano20k/nano20k_v3923.cst"
)

if ((print_sources)); then
    printf '%s\n' nexttang_nano20k_zxnext "${source_files[@]}"
    exit 0
fi

printf '%s\n' 'nano20k zxnext build: PLANNED, the shell is a skeleton and is not built yet' >&2
exit 2
