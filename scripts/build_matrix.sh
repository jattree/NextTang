#!/usr/bin/env bash
# Build every board and profile of the ZX Spectrum Next core and check each
# closes timing, before any hardware hand-off.
#
# Vendor tools are needed, so this is not part of `make check`. Each row runs
# its board's own build driver into OUTPUT/<board>-<profile>; the drivers
# already refuse stale outputs, vendor errors and timing violations. Rows a
# board cannot build yet are reported as PLANNED, never as passing:
#
#   console138k diagnostic        built
#   console138k diagnostic-ddr3   built, needs --vendor-source
#   nano20k     skeleton          PLANNED: sources listed and elaborated only
#   console60k  -                 PLANNED: no shell yet (build-only target)
#
# Usage: scripts/build_matrix.sh --output ABSOLUTE_EMPTY_DIRECTORY
#            [--vendor-source ABSOLUTE_DIRECTORY] [--boot-image ABSOLUTE_FILE]
#            [--only BOARD[-PROFILE]] [--list]
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

output_dir=
vendor_source=${NEXTTANG_VENDOR_SOURCE:-}
boot_image=
only=
list_only=0

usage() {
    sed -n '/^# Usage:/,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'
}

while (($#)); do
    case "$1" in
        --output|--vendor-source|--boot-image|--only)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            case "$1" in
                --output) output_dir=$2 ;;
                --vendor-source) vendor_source=$2 ;;
                --boot-image) boot_image=$2 ;;
                --only) only=$2 ;;
            esac
            shift 2
            ;;
        --list) list_only=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'build matrix: unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

# board profile kind
rows=(
    "console138k diagnostic build"
    "console138k diagnostic-ddr3 build"
    "nano20k skeleton planned-elaborate"
    "console60k - planned"
)

if ((list_only)); then
    printf '%s\n' "${rows[@]}"
    exit 0
fi

if [[ "$output_dir" != /* || ! -d "$output_dir" ]]; then
    printf '%s\n' 'build matrix: --output must be an existing absolute directory' >&2
    exit 2
fi
if [[ -n $(find "$output_dir" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
    printf 'build matrix: output directory is not empty: %s\n' "$output_dir" >&2
    exit 2
fi

summary="$output_dir/summary.txt"
failed=0

record() {
    printf '%-12s %-16s %-10s %s\n' "$1" "$2" "$3" "$4" | tee -a "$summary"
}

record BOARD PROFILE RESULT DETAIL
for row in "${rows[@]}"; do
    read -r board profile kind <<<"$row"
    if [[ -n "$only" && "$only" != "$board" && "$only" != "$board-$profile" ]]; then
        continue
    fi
    case "$kind" in
        build)
            driver="$repo_root/boards/$board/build_zxnext.sh"
            row_dir="$output_dir/$board-$profile"
            mkdir -p "$row_dir"
            arguments=(--toolchain vendor --profile "$profile" --output "$row_dir")
            if [[ "$profile" == *ddr3* ]]; then
                if [[ -z "$vendor_source" ]]; then
                    record "$board" "$profile" SKIP "needs --vendor-source (or NEXTTANG_VENDOR_SOURCE)"
                    continue
                fi
                arguments+=(--vendor-source "$vendor_source")
            fi
            [[ -z "$boot_image" ]] || arguments+=(--boot-image "$boot_image")
            if "$driver" "${arguments[@]}" >"$row_dir.log" 2>&1; then
                slack=$(grep -E '^timing check: setup' "$row_dir.log" | tail -1 | sed 's/.*worst slack //')
                hold=$(grep -E '^timing check: hold' "$row_dir.log" | tail -1 | sed 's/.*worst slack //')
                record "$board" "$profile" PASS "setup slack $slack, hold slack $hold"
            else
                record "$board" "$profile" FAIL "see $row_dir.log"
                failed=1
            fi
            ;;
        planned-elaborate)
            driver="$repo_root/boards/$board/build_zxnext.sh"
            plan="$output_dir/$board-$profile.sources"
            if ! "$driver" --profile "$profile" --print-sources >"$plan" 2>"$plan.err"; then
                record "$board" "$profile" FAIL "sources do not resolve, see $plan.err"
                failed=1
                continue
            fi
            verilator="${NEXTTANG_OSS_CAD_SUITE:+$NEXTTANG_OSS_CAD_SUITE/bin/}verilator"
            if ! command -v "$verilator" >/dev/null 2>&1; then
                record "$board" "$profile" PLANNED "sources resolve; verilator not found, not elaborated"
                continue
            fi
            mapfile -t verilog < <(tail -n +2 "$plan" | grep -E '\.(v|sv)$' | grep -v '/rtl/video/hdmi/' || true)
            if "$verilator" --lint-only -Wno-fatal -Wno-TIMESCALEMOD -Wno-MODMISSING \
                    --top-module "$(head -1 "$plan")" \
                    "$repo_root/rtl/lint/nexttang_gowin_primitive_stubs.v" "${verilog[@]}" \
                    >"$output_dir/$board-$profile.lint" 2>&1; then
                record "$board" "$profile" PLANNED "skeleton elaborates; no image is built"
            else
                record "$board" "$profile" FAIL "skeleton does not elaborate, see $output_dir/$board-$profile.lint"
                failed=1
            fi
            ;;
        planned)
            record "$board" "$profile" PLANNED "no shell yet"
            ;;
    esac
done

exit "$failed"
