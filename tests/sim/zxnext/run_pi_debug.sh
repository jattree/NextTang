#!/usr/bin/env bash
# Run the Pi debug interface checks against the real core.
#
# tb_zxnext_trace.vhd with PI_DEBUG drives the official debug slave as a Pi
# would, over SPI, while the clock test ROM runs: version, NextREG and memory
# access, pause, register writes, single steps, hardware breakpoints, a PC
# written while stopped, and the same after a state register write (which
# once cleared IR and made the CPU skip the first bytes at the new PC).
# Every check prints a PI_DEBUG line; a wrong value adds FAIL to it.
#
# About ten minutes with GHDL's mcode backend.
#
# Usage: tests/sim/zxnext/run_pi_debug.sh [CYCLES]
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)
cycles=${1:-4500000}
out="$repo_root/build/sim/pi-debug"
flags=(--std=08 -frelaxed -fsynopsys)

command -v ghdl >/dev/null || { echo "run_pi_debug: ghdl is not installed" >&2; exit 2; }
command -v sjasmplus >/dev/null || { echo "run_pi_debug: sjasmplus is not installed" >&2; exit 2; }

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
    "$repo_root/rtl/debug/nexttang_rzx_player.vhd" \
    "$repo_root/tests/sim/zxnext/cpu_clock_reference_pkg.vhd" \
    "$repo_root/tests/sim/zxnext/tb_zxnext_trace.vhd"
ghdl -m "${flags[@]}" --workdir="$out/lib" tb_zxnext_trace >/dev/null

(cd "$out/lib" &&
    ghdl -r "${flags[@]}" --workdir=. tb_zxnext_trace -gCYCLES="$cycles" -gMODE=enables \
        -gTRACE_FILE="$out/trace.txt" -gPI_DEBUG=true -gG_OPTION=65522 -gWAIT_CYCLES=20 --ieee-asserts=disable >"$out/sim.log" 2>&1) || true
grep "PI_DEBUG" "$out/sim.log" | grep -v "PI_DEBUG fetch" || true
if grep -q "PI_DEBUG DONE" "$out/sim.log" && ! grep -q "FAIL\|mismatch\|never" "$out/sim.log"; then
    echo "PI_DEBUG_RUN PASS"
else
    echo "PI_DEBUG_RUN FAIL, see $out/sim.log"
    exit 1
fi
