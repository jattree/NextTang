#!/usr/bin/env bash
# Elaborate every Console 138K board profile and lint the Verilog it selects.
#
# `make test` compiles only what a testbench instantiates. The board tops are
# one 2,600-line file behind eighteen `ifdef` macros, selected by a per-profile
# wrapper that defines them and includes it, so most of those combinations are
# elaborated by nothing until a vendor build spends minutes on them. This gate
# elaborates all of them in seconds.
#
# The profile list and each profile's source list come from
# `build_spectrum48.sh --print-sources`, so they cannot drift from what the
# vendor build actually compiles.
#
# Two passes run per profile:
#   - Verilog/SystemVerilog, elaborated by Verilator. The imported VHDL and the
#     Gowin DDR3 macro become black boxes.
#   - VHDL, analysed by GHDL. Only three distinct VHDL file sets exist across
#     the twenty profiles, so the result is memoised by file list and GHDL runs
#     three times rather than twenty.
#
# Scope and its limits:
#   - The three Gowin hard primitives the project instantiates directly are
#     supplied by rtl/lint/nexttang_gowin_primitive_stubs.v, which is derived
#     from this repository's own instantiations and is never synthesised.
#   - This is a static check. It says nothing about timing, resources, or
#     whether a bitstream works. Neither pass looks at clock-domain crossings,
#     reset-domain crossings or reachable FSM states, so a missing synchroniser
#     or a dead state passes it cleanly.
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd -- "$script_dir/.." && pwd -P)
build_driver="$repo_root/boards/console138k/build_spectrum48.sh"
stubs="$repo_root/rtl/lint/nexttang_gowin_primitive_stubs.v"
include_dir="$repo_root/boards/console138k"

only_profile=
strict=0
while (($#)); do
    case "$1" in
        --profile)
            [[ $# -ge 2 ]] || { printf 'hdl-lint: --profile needs a value\n' >&2; exit 2; }
            only_profile=$2
            shift 2
            ;;
        --strict) strict=1; shift ;;
        -h|--help)
            printf '%s\n' 'usage: scripts/hdl_lint.sh [--profile PROFILE] [--strict]'
            printf '%s\n' '  default: fail on elaboration errors, report warning counts'
            printf '%s\n' '  --strict: fail on warnings too'
            exit 0
            ;;
        *) printf 'hdl-lint: unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done

# The OSS CAD Suite is the project's documented home for these tools, but it is
# not on PATH unless its environment has been sourced. Look there before
# giving up, so a developer who has followed the toolchain notes gets the gate
# without extra setup.
resolve_tool() {
    local name=$1 found
    found=$(command -v "$name" || true)
    if [[ -z "$found" && -n "${NEXTTANG_OSS_CAD_SUITE:-}" && \
          -x "$NEXTTANG_OSS_CAD_SUITE/bin/$name" ]]; then
        found="$NEXTTANG_OSS_CAD_SUITE/bin/$name"
    fi
    printf '%s' "$found"
}

verilator=$(resolve_tool verilator)
if [[ -z "$verilator" ]]; then
    printf '%s\n' 'verilator: SKIP (not installed; set NEXTTANG_OSS_CAD_SUITE or install verilator)'
    exit 0
fi

# GHDL is optional here for the same reason Verilator is: absent, the VHDL pass
# reports nothing rather than failing a run that is otherwise fine.
ghdl=$(resolve_tool ghdl)

if [[ ! -r "$stubs" ]]; then
    printf 'hdl-lint: missing primitive stubs: %s\n' "$stubs" >&2
    exit 1
fi

# One source of truth for the profile list: the driver's own usage line.
mapfile -t profiles < <(
    "$build_driver" --help \
        | sed -n 's/.*--profile \([a-z0-9|-]*\).*/\1/p' \
        | head -1 \
        | tr '|' '\n'
)
if ((${#profiles[@]} == 0)); then
    printf 'hdl-lint: could not read the profile list from %s\n' "$build_driver" >&2
    exit 1
fi
if [[ -n "$only_profile" ]]; then
    profiles=("$only_profile")
fi

# MODMISSING is the mechanism this gate depends on, not a defect: it is what
# turns the VHDL cores and the Gowin DDR3 macro into black boxes so the Verilog
# around them can still be elaborated. TIMESCALEMOD fires on every module in
# the project because one imported file (usb_hid_host.v) carries a timescale
# and nothing else does; that is a simulation concern, not a synthesis one.
verilator_flags=(
    --lint-only
    -Wno-MODMISSING
    -Wno-TIMESCALEMOD
    "+incdir+$include_dir"
)

# Structural checks that are off in Verilator's default set. Enabled by name
# rather than with -Wall, which additionally raises PROCASSINIT, UNUSEDSIGNAL,
# DEFPARAM, UNUSEDPARAM and PINCONNECTEMPTY -- some 450 further messages that
# say nothing about correctness here and would bury these.
#
#   SYNCASYNCNET     a net used as both synchronous and asynchronous reset
#   BLKSEQ           blocking assignment in a sequential block
#   UNDRIVEN         signal read but never driven
#   LATCH            unintended level-sensitive storage
#   CASEINCOMPLETE   case without full coverage or a default
#   CASEOVERLAP      case items that cannot all be reached
verilator_flags+=(
    -Wwarn-SYNCASYNCNET
    -Wwarn-BLKSEQ
    -Wwarn-UNDRIVEN
    -Wwarn-LATCH
    -Wwarn-CASEINCOMPLETE
    -Wwarn-CASEOVERLAP
)

# What this gate enforces by default is elaboration: a profile whose Verilog
# does not hold together is a failure, because that is the class of defect that
# currently costs a multi-minute vendor build to discover. The width and
# unconnected-pin warnings are counted and shown but do not fail the run --
# there are hundreds of them in imported and original code alike, and turning
# them all into blockers today would mean suppressing them wholesale, which
# buys nothing. `--strict` promotes them once that backlog is worked down.
if ((!strict)); then
    verilator_flags+=(-Wno-fatal)
fi

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/vhdl"

# Analyse one profile's VHDL and leave the warning text in $work/vhdl/<key>.
# Sources arrive in the order the vendor build compiles them, which is already
# dependency order, and each set gets its own library directory so one
# profile's analysis cannot bleed into another's. Memoised on the file list:
# the twenty profiles use only three distinct sets.
analyse_vhdl() {
    local key=$1; shift
    local cache="$work/vhdl/$key"
    [[ -f "$cache" ]] && return 0
    local library="$work/vhdl/lib-$key"
    mkdir -p "$library"
    # -frelaxed matches what the unit suite already uses for these sources.
    "$ghdl" -a --std=08 -frelaxed "--workdir=$library" -Wall "$@" \
        >"$cache" 2>&1 || true
}

failed=()
linted=0
vhdl_analysed=0
for profile in "${profiles[@]}"; do
    [[ -n "$profile" ]] || continue

    if ! "$build_driver" --profile "$profile" --print-sources >"$work/plan" 2>"$work/plan.err"; then
        printf '[fail]  %-28s could not resolve sources\n' "$profile"
        sed 's/^/          /' "$work/plan.err" >&2
        failed+=("$profile")
        continue
    fi

    top=$(head -1 "$work/plan")
    # rtl/video/hdmi is the imported hdl-util/hdmi library, kept verbatim under
    # its own MIT/Apache notices. Its localparams use int'/real' casts that
    # this linter cannot constant-fold, which is a limitation of the linter on
    # legal SystemVerilog rather than a defect: the vendor toolchain builds
    # these profiles. Excluding the directory leaves `hdmi` a black box and
    # keeps every profile elaborating, so the gate still covers all of the
    # code this project actually writes. Drop this filter if the upstream
    # limitation is lifted.
    mapfile -t sources < <(
        tail -n +2 "$work/plan" \
            | grep -E '\.(v|sv)$' \
            | grep -v '/rtl/video/hdmi/' || true
    )
    if ((${#sources[@]} == 0)); then
        printf '[fail]  %-28s no Verilog sources resolved\n' "$profile"
        failed+=("$profile")
        continue
    fi

    status=0
    "$verilator" "${verilator_flags[@]}" --top-module "$top" \
        "$stubs" "${sources[@]}" >"$work/out" 2>&1 || status=$?
    cat "$work/out" >>"$work/all"
    warnings=$(grep -c '^%Warning-' "$work/out" || true)

    # The VHDL pass reports and never changes the verdict, in either mode.
    # Its findings are almost all in imported cores, and a run that fails on
    # them would say nothing about whether this profile holds together.
    vhdl_warnings=0
    mapfile -t vhdl_sources < <(tail -n +2 "$work/plan" | grep -E '\.vhd$' || true)
    if [[ -n "$ghdl" ]] && ((${#vhdl_sources[@]})); then
        key=$(printf '%s\n' "${vhdl_sources[@]}" | md5sum | cut -c1-8)
        if [[ ! -f "$work/vhdl/$key" ]]; then
            analyse_vhdl "$key" "${vhdl_sources[@]}"
            cat "$work/vhdl/$key" >>"$work/all-vhdl"
            vhdl_analysed=$((vhdl_analysed + 1))
        fi
        vhdl_warnings=$(grep -c ':warning:' "$work/vhdl/$key" || true)
    fi

    if ((status == 0)); then
        printf '[ok]    %-30s %-46s %3d v/sv %3dw  %2d vhd %3dw\n' \
            "$profile" "$top" "${#sources[@]}" "$warnings" \
            "${#vhdl_sources[@]}" "$vhdl_warnings"
    else
        printf '[fail]  %-30s %-46s %3d v/sv %3dw  %2d vhd %3dw\n' \
            "$profile" "$top" "${#sources[@]}" "$warnings" \
            "${#vhdl_sources[@]}" "$vhdl_warnings"
        sed 's/^/          /' "$work/out" >&2
        failed+=("$profile")
    fi
    linted=$((linted + 1))
done

printf '\nhdl-lint: %d profile(s) elaborated, %d failed\n' "$linted" "${#failed[@]}"

if [[ -s "$work/all" ]]; then
    codes=$(grep -oE '^%(Warning|Error)-[A-Z0-9]+' "$work/all" | sort | uniq -c | sort -rn || true)
    if [[ -n "$codes" ]]; then
        printf '\nhdl-lint: Verilog findings, all profiles (a file shared by N profiles counts N times):\n'
        printf '%s\n' "$codes" | sed 's/^/  /'
        ((strict)) || printf '%s\n' '  not fatal without --strict'
    fi
fi

if [[ -z "$ghdl" ]]; then
    printf '\nhdl-lint: VHDL pass SKIP (ghdl not installed)\n'
elif [[ -s "$work/all-vhdl" ]]; then
    printf '\nhdl-lint: VHDL findings, %d distinct file set(s), counted once each:\n' \
        "$vhdl_analysed"
    grep -oE '\[-W[a-z-]+\]' "$work/all-vhdl" | sort | uniq -c | sort -rn | sed 's/^/  /'
    printf '  by file:\n'
    grep -oE '^[^:]+\.vhd' "$work/all-vhdl" \
        | sed "s|^$repo_root/||" | sort | uniq -c | sort -rn | sed 's/^/    /'
    printf '%s\n' '  reported only; the VHDL pass never changes the verdict'
fi

if ((${#failed[@]})); then
    printf 'hdl-lint: failing profiles: %s\n' "${failed[*]}" >&2
    exit 1
fi
