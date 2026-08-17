#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd -- "$script_dir/../.." && pwd -P)

toolchain=
profile=
output_dir=

usage() {
    printf '%s\n' 'usage: boards/console138k/build.sh --toolchain vendor --profile release --output ABSOLUTE_DIRECTORY'
}

while (($#)); do
    case "$1" in
        --toolchain|--profile|--output)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            case "$1" in
                --toolchain) toolchain=$2 ;;
                --profile) profile=$2 ;;
                --output) output_dir=$2 ;;
            esac
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'console138k build: unknown argument: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ "$toolchain" != vendor ]]; then
    printf 'console138k build: toolchain not implemented: %s\n' "$toolchain" >&2
    exit 2
fi
if [[ "$profile" != release ]]; then
    printf 'console138k build: profile not implemented: %s\n' "$profile" >&2
    exit 2
fi
if [[ "$output_dir" != /* ]]; then
    printf '%s\n' 'console138k build: --output must be an absolute path' >&2
    exit 2
fi
if [[ ! -d "$output_dir" ]]; then
    printf 'console138k build: output directory does not exist: %s\n' "$output_dir" >&2
    exit 2
fi
if [[ -n $(find "$output_dir" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
    printf 'console138k build: output directory is not empty: %s\n' "$output_dir" >&2
    exit 2
fi

project_tcl="$output_dir/nexttang_console138k_smoke.tcl"
build_log="$output_dir/vendor-build.log"
bitstream="$output_dir/impl/pnr/nexttang_console138k_smoke.fs"
timing_report="$output_dir/impl/pnr/nexttang_console138k_smoke_tr_content.html"
source_hashes="$output_dir/source-sha256.txt"

source_files=(
    "$repo_root/rtl/smoke/nexttang_logo_128x128_rgb332.mem"
    "$repo_root/rtl/smoke/nexttang_logo_rom.v"
    "$repo_root/rtl/smoke/nexttang_video_pattern.v"
    "$repo_root/rtl/smoke/nexttang_uart_heartbeat.v"
    "$repo_root/rtl/smoke/nexttang_clock_probe.v"
    "$repo_root/rtl/video/nexttang_tmds_encoder.v"
    "$repo_root/boards/console138k/nexttang_console138k_pll.v"
    "$repo_root/boards/console138k/nexttang_console138k_smoke.v"
    "$repo_root/boards/console138k/console138k.cst"
    "$repo_root/boards/console138k/console138k.sdc"
)

cp -- "$repo_root/rtl/smoke/nexttang_logo_128x128_rgb332.mem" "$output_dir/"

cat >"$project_tcl" <<EOF
set_device -device_version C GW5AST-LV138PG484AC1/I0
set_option -top_module nexttang_console138k_smoke
set_option -output_base_name nexttang_console138k_smoke
add_file {$repo_root/rtl/smoke/nexttang_logo_rom.v}
add_file {$repo_root/rtl/smoke/nexttang_video_pattern.v}
add_file {$repo_root/rtl/smoke/nexttang_uart_heartbeat.v}
add_file {$repo_root/rtl/smoke/nexttang_clock_probe.v}
add_file {$repo_root/rtl/video/nexttang_tmds_encoder.v}
add_file {$repo_root/boards/console138k/nexttang_console138k_pll.v}
add_file {$repo_root/boards/console138k/nexttang_console138k_smoke.v}
add_file {$repo_root/boards/console138k/console138k.cst}
add_file {$repo_root/boards/console138k/console138k.sdc}
run all
EOF

(
    cd -- "$output_dir"
    gw_sh "$project_tcl"
) 2>&1 | tee "$build_log"

if rg -n '(^|[^[:alpha:]])(ERROR|Error):' "$build_log" "$output_dir/impl" \
        --glob '*.log' --glob '*.txt'; then
    printf '%s\n' 'console138k build: vendor error record found' >&2
    exit 1
fi

for required_file in \
    "$bitstream" \
    "$output_dir/impl/gwsynthesis/nexttang_console138k_smoke_syn.rpt.html" \
    "$output_dir/impl/pnr/nexttang_console138k_smoke.rpt.txt" \
    "$timing_report"; do
    if [[ ! -s "$required_file" ]]; then
        printf 'console138k build: required output missing or empty: %s\n' "$required_file" >&2
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

for source_file in "${source_files[@]}"; do
    printf '%s  %s\n' \
        "$(sha256sum "$source_file" | awk '{print $1}')" \
        "${source_file#"$repo_root/"}"
done >"$source_hashes"

source_tree_state=clean
if [[ -n $(git -C "$repo_root" status --porcelain -- \
        boards/console138k rtl/smoke rtl/video) ]]; then
    source_tree_state=dirty
fi

{
    printf 'target=console138k\n'
    printf 'device=GW5AST-LV138PG484AC1/I0\n'
    printf 'device_version=C\n'
    printf 'profile=%s\n' "$profile"
    printf 'toolchain=%s\n' "$toolchain"
    printf 'source_commit=%s\n' "$(git -C "$repo_root" rev-parse HEAD)"
    printf 'source_tree_state=%s\n' "$source_tree_state"
    printf 'built_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'bitstream_sha256=%s\n' "$(sha256sum "$bitstream" | awk '{print $1}')"
} >"$output_dir/build-manifest.txt"

printf 'console138k build: PASS\nbitstream: %s\n' "$bitstream"
