#!/usr/bin/env bash
# Check RZX recording and playback against the real core.
#
# tb_zxnext_trace.vhd runs the clock test ROM (firmware/clocktest/clocktest.asm:
# keyboard, port and NextREG reads, frame interrupts taken from HALT, all four
# CPU speeds) in enables mode, three times, dumping the CPU's M1, IORQ, RD,
# input register and R register each time:
#
#   record    normal inputs. rzx_check.py checks the frames against R and
#             against the recorder (rtl/debug/nexttang_rzx_logger.v) simulated
#             on the same signals, and writes them as the player's input.
#   control   every key down and EAR high, no playback: the frames must
#             differ from the recording, so the changed inputs matter.
#   replay    the same changed inputs, played from the recording through
#             rtl/debug/nexttang_rzx_player.vhd: the frames must be the
#             recording's, and the player must report no desync.
#   damaged   played from the recording with frame 2's last IN byte left
#             out: the player must report a desync during frame 2. (A wrong
#             fetch count would not show here: this ROM waits for each
#             interrupt in HALT, where one fetch more or less changes nothing,
#             as in any RZX replay.)
#
# About ten minutes per run with GHDL's mcode backend; control, replay and
# damaged run in parallel.
#
# Usage: tests/sim/zxnext/run_rzx_check.sh [CYCLES]
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)
cycles=${1:-4500000}
out="$repo_root/build/sim/rzx"
flags=(--std=08 -frelaxed -fsynopsys)
check="$repo_root/tests/sim/zxnext/rzx_check.py"

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
    "$repo_root/rtl/debug/nexttang_rzx_player.vhd" \
    "$repo_root/tests/sim/zxnext/cpu_clock_reference_pkg.vhd" \
    "$repo_root/tests/sim/zxnext/tb_zxnext_trace.vhd"
ghdl -m "${flags[@]}" --workdir="$out/lib" tb_zxnext_trace >/dev/null

run() {
    local name=$1; shift
    (cd "$out/lib" &&
        ghdl -r "${flags[@]}" --workdir=. tb_zxnext_trace -gCYCLES="$cycles" -gMODE=enables \
            -gTRACE_FILE="$out/trace-$name.txt" -gRZX_DUMP="$out/bus-$name.txt" "$@" \
            --ieee-asserts=disable >"$out/sim-$name.log" 2>&1) || {
        echo "run_rzx_check: $name simulation failed, see $out/sim-$name.log" >&2
        return 1
    }
}

status=0
run record
echo "== record"
python3 "$check" "$out/bus-record.txt" --keep "$out/logger" --write-stream "$out/stream.txt" || status=1

python3 - "$out/stream.txt" "$out/stream-damaged.txt" <<'PY'
import sys
data = [int(line, 16) for line in open(sys.argv[1]).read().split()]
position = 0
for _ in range(2):                       # skip frames 0 and 1
    position += 4 + (data[position + 2] | data[position + 3] << 8)
count = data[position + 2] | data[position + 3] << 8
del data[position + 4 + count - 1]       # frame 2's last IN byte
data[position + 2], data[position + 3] = (count - 1) & 0xFF, (count - 1) >> 8
open(sys.argv[2], "w").write("".join(f"{b:02x}\n" for b in data))
PY
run control -gRZX_PERTURB=true &
run replay -gRZX_PERTURB=true -gRZX_PLAY_FILE="$out/stream.txt" &
run damaged -gRZX_PLAY_FILE="$out/stream-damaged.txt" &
wait %1 || status=1
wait %2 || status=1
wait %3 || status=1
echo "== control (changed inputs, no playback)"
python3 "$check" "$out/bus-control.txt" --expect "$out/stream.txt" --expect-differ || status=1
echo "== replay (changed inputs, played from the recording)"
grep RZX_PLAY "$out/sim-replay.log" || status=1
grep -q "RZX_PLAY .* desync '0'" "$out/sim-replay.log" || status=1
python3 "$check" "$out/bus-replay.txt" --expect "$out/stream.txt" || status=1
echo "== damaged (frame 2's last IN byte left out)"
grep RZX_PLAY "$out/sim-damaged.log" || status=1
grep -q "RZX_PLAY frames 2 playing '0' desync '1'" "$out/sim-damaged.log" || status=1
echo "RZX_RUN $([[ $status == 0 ]] && echo PASS || echo FAIL)"
exit "$status"
