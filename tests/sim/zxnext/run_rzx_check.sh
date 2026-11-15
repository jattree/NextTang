#!/usr/bin/env bash
# Check the RZX input recorder (rtl/debug/nexttang_rzx_logger.v) against the
# real core.
#
# tb_zxnext_trace.vhd runs the clock test ROM (firmware/clocktest/clocktest.asm:
# keyboard, port and NextREG reads, frame interrupts taken from HALT, all four
# CPU speeds) in enables mode and dumps the CPU's M1, IORQ, RD, input register
# and R register; rzx_check.py then checks the frames against R and against
# the recorder simulated on the same signals. About ten minutes with GHDL's
# mcode backend.
#
# Usage: tests/sim/zxnext/run_rzx_check.sh [CYCLES]
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)
cycles=${1:-4500000}
out="$repo_root/build/sim/rzx"
flags=(--std=08 -frelaxed -fsynopsys)

command -v ghdl >/dev/null || { echo "run_rzx_check: ghdl is not installed" >&2; exit 2; }
command -v sjasmplus >/dev/null || { echo "run_rzx_check: sjasmplus is not installed" >&2; exit 2; }

[[ -d "$out/lib" ]] && rm -r -- "${out:?}/lib"
mkdir -p "$out/lib"
python3 "$repo_root/scripts/build_diagnostic_boot.py" \
    --source "$repo_root/firmware/clocktest/clocktest.asm" \
    --output "$out/bootrom.vhd"
mapfile -t core_sources < <(
    "$repo_root/boards/console138k/build_zxnext.sh" --profile diagnostic --print-sources |
        grep -E '\.vhd$' | grep -v nexttang_diagnostic_bootrom
)
ghdl -i "${flags[@]}" --workdir="$out/lib" "$out/bootrom.vhd" "${core_sources[@]}" \
    "$repo_root/rtl/clock/nexttang_zxnext_cpu_enables.vhd" \
    "$repo_root/tests/sim/zxnext/cpu_clock_reference_pkg.vhd" \
    "$repo_root/tests/sim/zxnext/tb_zxnext_trace.vhd"
ghdl -m "${flags[@]}" --workdir="$out/lib" tb_zxnext_trace >/dev/null
(cd "$out/lib" &&
    ghdl -r "${flags[@]}" --workdir=. tb_zxnext_trace -gCYCLES="$cycles" -gMODE=enables \
        -gTRACE_FILE="$out/trace.txt" -gRZX_DUMP="$out/bus.txt" --ieee-asserts=disable \
        >"$out/sim.log" 2>&1) || { echo "run_rzx_check: simulation failed, see $out/sim.log" >&2; exit 1; }
python3 "$repo_root/tests/sim/zxnext/rzx_check.py" "$out/bus.txt" --keep "$out/logger"
