#!/usr/bin/env bash
# Run Spec256's graphical lanes in follow mode beside the whole ZX Next core.
#
# tests/sim/zxnext/tb_zxnext_trace.vhd, in enables mode with SPEC256_LANES,
# runs the clock test ROM (firmware/clocktest/clocktest.asm: every CPU speed,
# switches out of 28 MHz and back, interrupts, contention, I/O and main memory
# accesses) with rtl/cpu/nexttang_zxnext_spec256_lanes.vhd attached. At every
# instruction boundary each lane's registers must equal the CPU's, and their
# bus strobes must never differ. Two runs: memory that answers at once, and
# memory that holds the CPU as the Console's DDR3 path does, with a long wait
# every 50 accesses. Each takes some minutes with GHDL's mcode backend; they
# run in parallel.
#
# Usage: tests/sim/zxnext/run_spec256_follow.sh [CYCLES]
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)
cycles=${1:-9000000}
out="$repo_root/build/sim/spec256-follow"
flags=(--std=08 -frelaxed -fsynopsys)

command -v ghdl >/dev/null || { echo "run_spec256_follow: ghdl is not installed" >&2; exit 2; }
command -v sjasmplus >/dev/null || { echo "run_spec256_follow: sjasmplus is not installed" >&2; exit 2; }

[[ -d "$out" ]] && rm -r -- "${out:?}"
mkdir -p "$out/work"

python3 "$repo_root/scripts/build_diagnostic_boot.py" \
    --source "$repo_root/firmware/clocktest/clocktest.asm" \
    --output "$out/bootrom.vhd"

mapfile -t core_sources < <(
    "$repo_root/boards/console138k/build_zxnext.sh" --profile diagnostic --print-sources |
        grep -E '\.vhd$' | grep -v nexttang_diagnostic_bootrom
)
ghdl -i "${flags[@]}" --workdir="$out/work" "$out/bootrom.vhd" "${core_sources[@]}" \
    "$repo_root/rtl/clock/nexttang_zxnext_cpu_enables.vhd" \
    "$repo_root/tests/sim/zxnext/cpu_clock_reference_pkg.vhd" \
    "$repo_root/rtl/cpu/nexttang_zxnext_spec256_lanes.vhd" \
    "$repo_root/tests/sim/zxnext/tb_zxnext_trace.vhd"
ghdl -m "${flags[@]}" --workdir="$out/work" tb_zxnext_trace >/dev/null

run() {
    local name=$1; shift
    (cd "$out/work" &&
        ghdl -r "${flags[@]}" --workdir=. tb_zxnext_trace -gCYCLES="$cycles" -gMODE=enables \
            -gSPEC256_LANES=true -gTRACE_FILE="$out/$name.trace" "$@" --ieee-asserts=disable \
            >"$out/$name.log" 2>&1) || { echo "run_spec256_follow: $name failed, see $out/$name.log" >&2; return 1; }
}

run instant &
run waits -gWAIT_CYCLES=17 -gLONG_EVERY=50 -gLONG_WAIT_CYCLES=300 &
status=0
wait %1 || status=1
wait %2 || status=1

for name in instant waits; do
    line=$(grep -h "SPEC256_FOLLOW" "$out/$name.log" || true)
    echo "$name: ${line:-no SPEC256_FOLLOW line}"
    grep -h "SPEC256_MISMATCH" "$out/$name.log" | head -4 || true
    [[ "$line" == *"mismatched 0 desync '0'"* ]] || status=1
    boundaries=$(sed -n 's/.*boundaries \([0-9]*\).*/\1/p' <<<"$line")
    (( ${boundaries:-0} > 100000 )) || status=1
done
exit "$status"
