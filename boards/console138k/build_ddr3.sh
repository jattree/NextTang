#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd -- "$script_dir/../.." && pwd -P)

toolchain=
profile=
vendor_source=
output_dir=

usage() {
    printf '%s\n' \
        'usage: boards/console138k/build_ddr3.sh --toolchain vendor --profile diagnostic --vendor-source ABSOLUTE_DIRECTORY --output ABSOLUTE_DIRECTORY'
}

while (($#)); do
    case "$1" in
        --toolchain|--profile|--vendor-source|--output)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            case "$1" in
                --toolchain) toolchain=$2 ;;
                --profile) profile=$2 ;;
                --vendor-source) vendor_source=$2 ;;
                --output) output_dir=$2 ;;
            esac
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'console138k DDR3 build: unknown argument: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ "$toolchain" != vendor ]]; then
    printf 'console138k DDR3 build: toolchain not implemented: %s\n' \
        "$toolchain" >&2
    exit 2
fi
if [[ "$profile" != diagnostic ]]; then
    printf 'console138k DDR3 build: profile not implemented: %s\n' \
        "$profile" >&2
    exit 2
fi
for directory_option in vendor_source output_dir; do
    directory_value=${!directory_option}
    if [[ "$directory_value" != /* ]]; then
        printf 'console138k DDR3 build: --%s must be an absolute path\n' \
            "${directory_option//_/-}" >&2
        exit 2
    fi
    if [[ ! -d "$directory_value" ]]; then
        printf 'console138k DDR3 build: directory does not exist: %s\n' \
            "$directory_value" >&2
        exit 2
    fi
done
if [[ -n $(find "$output_dir" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
    printf 'console138k DDR3 build: output directory is not empty: %s\n' \
        "$output_dir" >&2
    exit 2
fi

vendor_files=(
    "$vendor_source/ddr3_memory_interface/ddr3_memory_interface.v"
    "$vendor_source/gowin_pll/gowin_pll.v"
    "$vendor_source/gowin_pll/gowin_pll_mod.v"
    "$vendor_source/pll_init.v"
)
for vendor_file in "${vendor_files[@]}"; do
    if [[ ! -s "$vendor_file" ]]; then
        printf 'console138k DDR3 build: required vendor source missing: %s\n' \
            "$vendor_file" >&2
        exit 2
    fi
done

project_tcl="$output_dir/nexttang_console138k_ddr3_diagnostic.tcl"
build_log="$output_dir/vendor-build.log"
base_name=nexttang_console138k_ddr3_diagnostic
bitstream="$output_dir/impl/pnr/$base_name.fs"
timing_report="$output_dir/impl/pnr/${base_name}_tr_content.html"

repo_source_files=(
    "$repo_root/rtl/smoke/nexttang_status_colour.v"
    "$repo_root/rtl/video/nexttang_tmds_encoder.v"
    "$repo_root/rtl/video/nexttang_video_timing.v"
    "$repo_root/rtl/memory/nexttang_ddr3_diagnostic.v"
    "$repo_root/boards/console138k/nexttang_console138k_pll.v"
    "$repo_root/boards/console138k/nexttang_console138k_ddr3_pll.v"
    "$repo_root/boards/console138k/nexttang_console138k_ddr3_diagnostic.v"
    "$repo_root/boards/console138k/console138k_ddr3.cst"
    "$repo_root/boards/console138k/console138k_ddr3.sdc"
)

cat >"$project_tcl" <<EOF
set_device -device_version C GW5AST-LV138PG484AC1/I0
set_option -top_module nexttang_console138k_ddr3_diagnostic
set_option -output_base_name $base_name
add_file {$vendor_source/ddr3_memory_interface/ddr3_memory_interface.v}
add_file {$vendor_source/gowin_pll/gowin_pll.v}
add_file {$vendor_source/gowin_pll/gowin_pll_mod.v}
add_file {$vendor_source/pll_init.v}
add_file {$repo_root/rtl/smoke/nexttang_status_colour.v}
add_file {$repo_root/rtl/video/nexttang_tmds_encoder.v}
add_file {$repo_root/rtl/video/nexttang_video_timing.v}
add_file {$repo_root/rtl/memory/nexttang_ddr3_diagnostic.v}
add_file {$repo_root/boards/console138k/nexttang_console138k_pll.v}
add_file {$repo_root/boards/console138k/nexttang_console138k_ddr3_pll.v}
add_file {$repo_root/boards/console138k/nexttang_console138k_ddr3_diagnostic.v}
add_file {$repo_root/boards/console138k/console138k_ddr3.cst}
add_file {$repo_root/boards/console138k/console138k_ddr3.sdc}
run all
EOF

(
    cd -- "$output_dir"
    QT_QPA_PLATFORM=${QT_QPA_PLATFORM:-offscreen} gw_sh "$project_tcl"
) 2>&1 | tee "$build_log"

if rg -n '(^|[^[:alpha:]])(ERROR|Error):' "$build_log" "$output_dir/impl" \
        --glob '*.log' --glob '*.txt'; then
    printf '%s\n' 'console138k DDR3 build: vendor error record found' >&2
    exit 1
fi

for required_file in \
    "$bitstream" \
    "$output_dir/impl/gwsynthesis/${base_name}_syn.rpt.html" \
    "$output_dir/impl/pnr/${base_name}.rpt.txt" \
    "$timing_report"; do
    if [[ ! -s "$required_file" ]]; then
        printf 'console138k DDR3 build: required output missing: %s\n' \
            "$required_file" >&2
        exit 1
    fi
done

python3 - "$timing_report" <<'PY'
from html.parser import HTMLParser
from pathlib import Path
import re
import sys


class TextCollector(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.parts: list[str] = []

    def handle_data(self, data: str) -> None:
        cleaned = " ".join(data.split())
        if cleaned:
            self.parts.append(cleaned)


collector = TextCollector()
collector.feed(Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace"))
report = " | ".join(collector.parts)
for analysis in ("Setup", "Hold"):
    match = re.search(
        rf"Numbers of {analysis} Violated Endpoints \| (\d+)", report
    )
    if match is None:
        raise SystemExit(f"timing check: missing {analysis.lower()} violation count")
    if int(match.group(1)) != 0:
        raise SystemExit(
            f"timing check: {match.group(1)} {analysis.lower()} endpoints violated"
        )
print("timing check: PASS (0 setup violations, 0 hold violations)")
PY

for source_file in "${repo_source_files[@]}"; do
    printf '%s  %s\n' \
        "$(sha256sum "$source_file" | awk '{print $1}')" \
        "${source_file#"$repo_root/"}"
done >"$output_dir/source-sha256.txt"

for vendor_file in "${vendor_files[@]}"; do
    printf '%s  %s\n' \
        "$(sha256sum "$vendor_file" | awk '{print $1}')" \
        "${vendor_file#"$vendor_source/"}"
done >"$output_dir/vendor-source-sha256.txt"

source_tree_state=clean
if [[ -n $(git -C "$repo_root" status --porcelain -- \
        boards/console138k rtl/memory rtl/smoke rtl/video) ]]; then
    source_tree_state=dirty
fi

{
    printf 'target=console138k-ddr3-diagnostic\n'
    printf 'device=GW5AST-LV138PG484AC1/I0\n'
    printf 'device_version=C\n'
    printf 'profile=%s\n' "$profile"
    printf 'toolchain=%s\n' "$toolchain"
    printf 'source_commit=%s\n' "$(git -C "$repo_root" rev-parse HEAD)"
    printf 'source_tree_state=%s\n' "$source_tree_state"
    printf 'built_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'bitstream_sha256=%s\n' \
        "$(sha256sum "$bitstream" | awk '{print $1}')"
} >"$output_dir/build-manifest.txt"

printf 'console138k DDR3 build: PASS\nbitstream: %s\n' "$bitstream"
