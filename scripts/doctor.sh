#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd -- "$script_dir/.." && pwd -P)

# shellcheck source=../toolchain/versions.env
source "$repo_root/toolchain/versions.env"

mode=all
strict=0

usage() {
    printf '%s\n' 'usage: scripts/doctor.sh [--mode all|repo|vendor|oss] [--strict]'
}

while (($#)); do
    case "$1" in
        --mode)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            mode=$2
            shift 2
            ;;
        --strict)
            strict=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'doctor: unknown argument: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

case "$mode" in
    all|repo|vendor|oss) ;;
    *)
        printf 'doctor: unsupported mode: %s\n' "$mode" >&2
        exit 2
        ;;
esac

missing_required=0

check_tool() {
    local group=$1
    local name=$2
    local requirement=$3
    local hint=$4
    local resolved

    if resolved=$(command -v "$name" 2>/dev/null); then
        printf '[ok]      %-7s %-22s %s\n' "$group" "$name" "$resolved"
        return
    fi

    printf '[missing] %-7s %-22s %s\n' "$group" "$name" "$hint"
    if [[ "$requirement" == required ]]; then
        missing_required=$((missing_required + 1))
    fi
}

printf '%s\n' 'NextTang toolchain doctor'
printf 'lock-status=%s\n' "$NEXTTANG_TOOLCHAIN_LOCK_STATUS"
printf 'references: Gowin=%s build %s, OSS-CAD=%s, nextpnr>=%s\n\n' \
    "$NEXTTANG_GOWIN_EDA_VERSION" "$NEXTTANG_GOWIN_EDA_BUILD" \
    "$NEXTTANG_OSS_CAD_SUITE_RELEASE" "$NEXTTANG_NEXTPNR_MINIMUM_VERSION"

if [[ "$mode" == all || "$mode" == repo ]]; then
    check_tool repo bash required 'install Bash'
    check_tool repo git required 'install Git'
    check_tool repo make required 'install GNU Make'
    check_tool repo python3 required "install Python $NEXTTANG_PYTHON_SERIES"
    check_tool repo shellcheck optional 'recommended for shell linting'
    check_tool repo iverilog required \
        "Verilog testbenches; reference $NEXTTANG_IVERILOG_REFERENCE_VERSION"
    check_tool repo ghdl required \
        "VHDL testbenches; reference $NEXTTANG_GHDL_REFERENCE_VERSION"
    check_tool repo sjasmplus required \
        "diagnostic boot ROM; reference $NEXTTANG_SJASMPLUS_VERSION"
fi

if [[ "$mode" == all || "$mode" == vendor ]]; then
    printf '\nVendor path (%s build %s):\n' \
        "$NEXTTANG_GOWIN_EDA_VERSION" "$NEXTTANG_GOWIN_EDA_BUILD"
    check_tool vendor gw_sh required \
        'source the Gowin environment; see docs/toolchain.md'
    check_tool vendor gw_ide optional 'optional graphical IDE'
    check_tool vendor openFPGALoader optional 'recommended board programmer'
fi

if [[ "$mode" == all || "$mode" == oss ]]; then
    printf '\nOpen-source path (experimental, OSS CAD Suite %s):\n' \
        "$NEXTTANG_OSS_CAD_SUITE_RELEASE"
    check_tool oss yosys required 'source the OSS CAD Suite environment'
    check_tool oss nextpnr-himbaechel required 'requires GW5AST support'
    check_tool oss gowin_pack required 'provided by Project Apicula'
    check_tool oss ghdl required 'required for the VHDL-heavy upstream core'
    check_tool oss openFPGALoader required 'required for hardware programming'
    check_tool oss verilator optional 'recommended SystemVerilog simulator'
fi

printf '\nrequired tools missing: %d\n' "$missing_required"

if ((strict && missing_required)); then
    exit 1
fi
