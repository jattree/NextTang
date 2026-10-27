#!/usr/bin/env bash
# Compare the ZX Next core's behaviour with the CPU on its own clock and on
# clock_28 with enables.
#
# Three simulations of tests/sim/zxnext/tb_zxnext_trace.vhd run the clock
# test ROM (firmware/clocktest/clocktest.asm) and record every core output at
# every 28 MHz rising edge:
#
#   original    the core as it was at ORIGINAL_REV, with a real CPU clock
#   reference   the core in this tree, real CPU clock, enables left at '1'
#   enables     the core in this tree, i_CLK_CPU tied to clock_28, enables
#               from rtl/clock/nexttang_zxnext_cpu_enables.vhd
#
# original against reference shows the enable ports change nothing on their
# own; reference against enables shows what running the CPU on clock_28
# changes. Each run takes about ten minutes with GHDL's mcode backend; they run
# in parallel.
#
# Usage: tests/sim/zxnext/run_equivalence.sh [ORIGINAL_REV] [CYCLES]
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)
original_rev=${1:-2f7feee}
cycles=${2:-4500000}
out="$repo_root/build/sim/equivalence"
flags=(--std=08 -frelaxed -fsynopsys)

command -v ghdl >/dev/null || { echo "run_equivalence: ghdl is not installed" >&2; exit 2; }
command -v sjasmplus >/dev/null || { echo "run_equivalence: sjasmplus is not installed" >&2; exit 2; }

mkdir -p "$out"
for directory in original patched original_src; do
    [[ -d "$out/$directory" ]] && rm -r -- "${out:?}/$directory"
    mkdir -p "$out/$directory"
done

python3 "$repo_root/scripts/build_diagnostic_boot.py" \
    --source "$repo_root/firmware/clocktest/clocktest.asm" \
    --output "$out/bootrom.vhd"

mapfile -t core_sources < <(
    "$repo_root/boards/console138k/build_zxnext.sh" --profile diagnostic --print-sources |
        grep -E '\.vhd$' | grep -v nexttang_diagnostic_bootrom
)
sim_sources=(
    "$repo_root/rtl/clock/nexttang_zxnext_cpu_enables.vhd"
    "$repo_root/tests/sim/zxnext/cpu_clock_reference_pkg.vhd"
)

# The original core: each source as it was at ORIGINAL_REV, where it existed.
original_sources=()
for source in "${core_sources[@]}"; do
    relative=${source#"$repo_root"/}
    if git -C "$repo_root" cat-file -e "$original_rev:$relative" 2>/dev/null; then
        mkdir -p "$out/original_src/$(dirname -- "$relative")"
        git -C "$repo_root" show "$original_rev:$relative" >"$out/original_src/$relative"
        original_sources+=("$out/original_src/$relative")
    else
        original_sources+=("$source")
    fi
done
# The original core has no enable ports to connect.
grep -v -E 'i_CPU_CEN_[RF] => cen_[rf],' "$repo_root/tests/sim/zxnext/tb_zxnext_trace.vhd" \
    >"$out/original_src/tb_zxnext_trace.vhd"

ghdl -i "${flags[@]}" --workdir="$out/original" "$out/bootrom.vhd" "${original_sources[@]}" \
    "${sim_sources[@]}" "$out/original_src/tb_zxnext_trace.vhd"
ghdl -m "${flags[@]}" --workdir="$out/original" tb_zxnext_trace >/dev/null
ghdl -i "${flags[@]}" --workdir="$out/patched" "$out/bootrom.vhd" "${core_sources[@]}" \
    "${sim_sources[@]}" "$repo_root/tests/sim/zxnext/tb_zxnext_trace.vhd"
ghdl -m "${flags[@]}" --workdir="$out/patched" tb_zxnext_trace >/dev/null

run() {
    local library=$1 mode=$2 trace=$3
    (cd "$out/$library" &&
        ghdl -r "${flags[@]}" --workdir=. tb_zxnext_trace -gCYCLES="$cycles" \
            -gTRACE_FILE="$out/$trace" -gMODE="$mode" --ieee-asserts=disable \
            >"$out/$trace.log" 2>&1) || {
        echo "run_equivalence: $trace failed, see $out/$trace.log" >&2
        return 1
    }
}

run original reference trace_original.txt &
run patched reference trace_reference.txt &
run patched enables trace_enables.txt &
status=0
wait %1 || status=1
wait %2 || status=1
wait %3 || status=1
((status == 0)) || exit 1

compare="$repo_root/tests/sim/zxnext/compare_traces.py"
echo "original against reference:"
python3 "$compare" "$out/trace_original.txt" "$out/trace_reference.txt" || status=1
echo "reference against enables:"
python3 "$compare" "$out/trace_reference.txt" "$out/trace_enables.txt" || status=1
exit "$status"
