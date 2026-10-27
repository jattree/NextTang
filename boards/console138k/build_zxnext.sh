#!/usr/bin/env bash
# Build the ZX Spectrum Next core for the Tang Console 138K.
#
# The `diagnostic` profile runs the pinned ZXNext core on the machine clock
# tree with the project's diagnostic boot ROM, a 64 KiB block RAM standing in
# for main memory, the core's video in the frame-safe 720p scaler and the status
# UART. It needs no ROM, firmware or vendor source.
#
# The `diagnostic-ddr3` profile is the same image with the whole 2 MB main
# memory in onboard DDR3. It needs --vendor-source: the directory holding
# Sipeed's generated DDR3 controller, its Gowin_PLL wrapper and PLL_INIT, which
# carry no redistribution grant and stay outside Git.
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd -- "$script_dir/../.." && pwd -P)

toolchain=
profile=
output_dir=
vendor_source=
print_sources=0

usage() {
    printf '%s\n' 'usage: boards/console138k/build_zxnext.sh --toolchain vendor --profile diagnostic|diagnostic-ddr3 [--vendor-source ABSOLUTE_DIRECTORY] --output ABSOLUTE_DIRECTORY'
    printf '%s\n' '       boards/console138k/build_zxnext.sh --profile PROFILE [--vendor-source ABSOLUTE_DIRECTORY] --print-sources'
}

while (($#)); do
    case "$1" in
        --toolchain|--profile|--output|--vendor-source)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            case "$1" in
                --toolchain) toolchain=$2 ;;
                --profile) profile=$2 ;;
                --output) output_dir=$2 ;;
                --vendor-source) vendor_source=$2 ;;
            esac
            shift 2
            ;;
        --print-sources) print_sources=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'console138k zxnext build: unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

case "$profile" in
    diagnostic)
        base_name=nexttang_console138k_zxnext
        constraints_base=console138k_zxnext
        route_option=1
        ;;
    diagnostic-ddr3)
        base_name=nexttang_console138k_zxnext_ddr3
        constraints_base=console138k_zxnext_ddr3
        route_option=2
        if [[ "$vendor_source" != /* || ! -d "$vendor_source" ]]; then
            printf '%s\n' 'console138k zxnext build: diagnostic-ddr3 requires --vendor-source ABSOLUTE_DIRECTORY' >&2
            exit 2
        fi
        ;;
    *)
        printf 'console138k zxnext build: profile not implemented: %s\n' "$profile" >&2
        exit 2
        ;;
esac

core_files=(
    rtl/audio/audio_mixer.vhd rtl/audio/i2s.vhd rtl/audio/i2s/i2s_receive.vhd
    rtl/audio/i2s/i2s_slave.vhd rtl/audio/i2s/i2s_transmit.vhd rtl/audio/soundrive.vhd
    rtl/audio/turbosound.vhd rtl/audio/ym2149.vhd
    rtl/device/copper.vhd rtl/device/ctc.vhd rtl/device/ctc_chan.vhd rtl/device/divmmc.vhd
    rtl/device/dma.vhd rtl/device/im2_control.vhd rtl/device/im2_device.vhd
    rtl/device/im2_peripheral.vhd rtl/device/multiface.vhd rtl/device/peripherals.vhd
    rtl/misc/debounce.vhd
    rtl/serial/fifop.vhd rtl/serial/spi_master.vhd rtl/serial/uart.vhd
    rtl/serial/uart_rx.vhd rtl/serial/uart_tx.vhd
    rtl/video/layer2.vhd rtl/video/lores.vhd rtl/video/sprites.vhd rtl/video/tilemap.vhd
    rtl/video/zxula_timing.vhd rtl/video/zxula.vhd
    rtl/zxnext.vhd
)

source_files=(
    "$repo_root/rtl/core/memory/nexttang_dpram2.vhd"
    "$repo_root/rtl/core/memory/nexttang_sdpram.vhd"
    "$repo_root/rtl/core/nexttang_diagnostic_bootrom.vhd"
    "$repo_root/rtl/cpu/t80n_pack.vhd"
    "$repo_root/rtl/cpu/t80n_alu.vhd"
    "$repo_root/rtl/cpu/t80n_mcode.vhd"
    "$repo_root/rtl/cpu/t80n.vhd"
    "$repo_root/rtl/cpu/t80na.vhd"
)
for core_file in "${core_files[@]}"; do
    source_files+=("$repo_root/$core_file")
done
source_files+=(
    "$repo_root/rtl/reset/nexttang_reset_release.v"
    "$repo_root/rtl/clock/nexttang_cpu_clock_contention.v"
    "$repo_root/rtl/clock/nexttang_machine_clock_enables.v"
    "$repo_root/boards/console138k/nexttang_console138k_machine_pll.v"
    "$repo_root/boards/console138k/nexttang_console138k_cpu_clock_mux.v"
    "$repo_root/boards/console138k/nexttang_console138k_machine_clock_tree.v"
    "$repo_root/boards/console138k/nexttang_console138k_pll.v"
    "$repo_root/rtl/memory/nexttang_block_ram.v"
    "$repo_root/rtl/video/nexttang_ula_capture.v"
    "$repo_root/rtl/video/nexttang_framebuffer_scaler.v"
    "$repo_root/rtl/video/nexttang_video_timing.v"
    "$repo_root/rtl/video/nexttang_tmds_encoder.v"
    "$repo_root/rtl/smoke/nexttang_debug_status_uart.v"
)
if [[ "$profile" == diagnostic-ddr3 ]]; then
    source_files+=(
        "$repo_root/rtl/memory/nexttang_cpu_memory_service.v"
        "$repo_root/rtl/memory/nexttang_memory_cdc_bridge.v"
        "$repo_root/rtl/memory/nexttang_byte_line_adapter.v"
        "$repo_root/rtl/memory/nexttang_cpu_memory_path.v"
        "$repo_root/rtl/memory/nexttang_zxnext_memory_port.v"
        "$repo_root/rtl/memory/nexttang_gowin_ddr3_ui_adapter.v"
        "$repo_root/boards/console138k/nexttang_console138k_ddr3_pll.v"
        "$vendor_source/ddr3_memory_interface/ddr3_memory_interface.v"
        "$vendor_source/gowin_pll/gowin_pll.v"
        "$vendor_source/gowin_pll/gowin_pll_mod.v"
        "$vendor_source/pll_init.v"
    )
fi
# The DDR3 wrapper textually includes the shared top, so both are build inputs
# even though Gowin receives only the wrapper.
included_files=()
if [[ "$profile" == diagnostic-ddr3 ]]; then
    source_files+=("$repo_root/boards/console138k/nexttang_console138k_zxnext_ddr3.v")
    included_files+=("$repo_root/boards/console138k/nexttang_console138k_zxnext.v")
else
    source_files+=("$repo_root/boards/console138k/nexttang_console138k_zxnext.v")
fi
source_files+=(
    "$repo_root/boards/console138k/$constraints_base.cst"
    "$repo_root/boards/console138k/$constraints_base.sdc"
    "$repo_root/boards/console138k/console138k_zxnext.gsc"
)

if ((print_sources)); then
    printf '%s\n' "${source_files[@]}"
    exit 0
fi

if [[ "$toolchain" != vendor ]]; then
    printf 'console138k zxnext build: toolchain not implemented: %s\n' "$toolchain" >&2
    exit 2
fi
if [[ "$output_dir" != /* ]]; then
    printf '%s\n' 'console138k zxnext build: --output must be an absolute path' >&2
    exit 2
fi
if [[ ! -d "$output_dir" ]]; then
    printf 'console138k zxnext build: output directory does not exist: %s\n' "$output_dir" >&2
    exit 2
fi
if [[ -n $(find "$output_dir" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
    printf 'console138k zxnext build: output directory is not empty: %s\n' "$output_dir" >&2
    exit 2
fi
for source_file in "${source_files[@]}" "${included_files[@]}"; do
    [[ -s "$source_file" ]] || {
        printf 'console138k zxnext build: missing source: %s\n' "$source_file" >&2
        exit 1
    }
done

project_tcl="$output_dir/$base_name.tcl"
build_log="$output_dir/build.log"
bitstream="$output_dir/impl/pnr/$base_name.fs"
timing_report="$output_dir/impl/pnr/$base_name.tr"
source_hashes="$output_dir/source-sha256.txt"

{
    printf 'set_device -device_version C GW5AST-LV138PG484AC1/I0\n'
    printf 'set_option -top_module %s\n' "$base_name"
    printf 'set_option -output_base_name %s\n' "$base_name"
    printf 'set_option -vhdl_std vhd2008\n'
    printf 'set_option -verilog_std sysv2017\n'
    printf 'set_option -gen_text_timing_rpt 1\n'
    # Measured on the complete core. Placement option 2 is what lets the CPU's
    # half-cycle paths meet 28 MHz. The router option is per profile: with
    # DDR3, option 2 gives +0.74 ns of setup margin where option 1 gives +0.27.
    printf 'set_option -place_option 2\n'
    printf 'set_option -route_option %s\n' "$route_option"
    for source_file in "${source_files[@]}"; do
        printf 'add_file {%s}\n' "$source_file"
    done
    printf 'run all\n'
} >"$project_tcl"

(
    cd -- "$output_dir"
    gw_sh "$project_tcl"
) 2>&1 | tee "$build_log" || {
    printf 'console138k zxnext build: FAIL (see %s)\n' "$build_log" >&2
    exit 1
}

sha256sum "${source_files[@]}" "${included_files[@]}" >"$source_hashes"

if grep -q '^ERROR' "$build_log"; then
    printf 'console138k zxnext build: vendor errors (see %s)\n' "$build_log" >&2
    exit 1
fi
if [[ ! -f "$bitstream" ]]; then
    printf 'console138k zxnext build: no bitstream produced (see %s)\n' "$build_log" >&2
    exit 1
fi

python3 "$repo_root/scripts/check_timing.py" "$timing_report" || exit 1

printf 'console138k zxnext build: PASS\n'
printf 'bitstream: %s\n' "$bitstream"
