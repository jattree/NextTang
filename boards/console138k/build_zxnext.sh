#!/usr/bin/env bash
# Build the ZX Spectrum Next core for the Tang Console 138K.
#
# The `diagnostic` profile runs the pinned ZXNext core on the machine clock
# tree with the project's diagnostic boot ROM, a 64 KiB block RAM standing in
# for main memory, the core's video in the frame-safe 720p scaler and the status
# UART. It needs no ROM, firmware or vendor source.
#
# The `diagnostic-ddr3` profile is the same image with the whole 2 MB main
# memory in onboard DDR3, the SD socket on the core's SPI, and the two USB-A
# sockets as keyboard and joystick. It needs --vendor-source: the directory holding
# Sipeed's generated DDR3 controller, its Gowin_PLL wrapper and PLL_INIT, which
# carry no redistribution grant and stay outside Git.
#
# --boot-image FILE replaces the diagnostic boot ROM with an already-built
# image of at most 8 KiB, such as the Next's own boot loader from
# scripts/build_next_ipl.sh. FILE.notice must hold its licence and copyright
# notice, which the generated ROM carries.
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd -- "$script_dir/../.." && pwd -P)

toolchain=
profile=
output_dir=
vendor_source=
boot_image=
print_sources=0

usage() {
    printf '%s\n' 'usage: boards/console138k/build_zxnext.sh --toolchain vendor --profile diagnostic|diagnostic-ddr3 [--vendor-source ABSOLUTE_DIRECTORY] [--boot-image ABSOLUTE_FILE] --output ABSOLUTE_DIRECTORY'
    printf '%s\n' '       boards/console138k/build_zxnext.sh --profile PROFILE [--vendor-source ABSOLUTE_DIRECTORY] --print-sources'
}

while (($#)); do
    case "$1" in
        --toolchain|--profile|--output|--vendor-source|--boot-image)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            case "$1" in
                --toolchain) toolchain=$2 ;;
                --profile) profile=$2 ;;
                --output) output_dir=$2 ;;
                --vendor-source) vendor_source=$2 ;;
                --boot-image) boot_image=$2 ;;
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
        attempts=(2:1 2:2 1:1)
        ;;
    diagnostic-ddr3)
        base_name=nexttang_console138k_zxnext_ddr3
        constraints_base=console138k_zxnext_ddr3
        attempts=(1:1 2:2 2:1)
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

if [[ -n "$boot_image" ]]; then
    if [[ "$boot_image" != /* || ! -s "$boot_image" || ! -s "$boot_image.notice" ]]; then
        printf '%s\n' 'console138k zxnext build: --boot-image needs an absolute FILE and FILE.notice' >&2
        exit 2
    fi
    if [[ "$output_dir" != /* ]]; then
        printf '%s\n' 'console138k zxnext build: --boot-image needs an absolute --output' >&2
        exit 2
    fi
    boot_rom="$output_dir/bootrom.vhd"
else
    boot_rom="$repo_root/rtl/core/nexttang_diagnostic_bootrom.vhd"
fi

source_files=(
    "$repo_root/rtl/core/memory/nexttang_dpram2.vhd"
    "$repo_root/rtl/core/memory/nexttang_sdpram.vhd"
    "$boot_rom"
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
    "$repo_root/rtl/reset/nexttang_zxnext_core_reset.v"
    "$repo_root/rtl/clock/nexttang_zxnext_cpu_enables.vhd"
    "$repo_root/rtl/clock/nexttang_machine_clock_enables.v"
    "$repo_root/boards/console138k/nexttang_console138k_machine_pll.v"
    "$repo_root/boards/console138k/nexttang_console138k_machine_clock_tree.v"
    "$repo_root/boards/console138k/nexttang_console138k_pll.v"
    "$repo_root/rtl/memory/nexttang_block_ram.v"
    "$repo_root/rtl/video/nexttang_ula_capture.v"
    "$repo_root/rtl/video/nexttang_framebuffer_scaler.v"
    "$repo_root/rtl/video/nexttang_video_timing.v"
    "$repo_root/rtl/audio/nexttang_zxnext_audio_pcm.v"
    "$repo_root/rtl/video/hdmi/audio_clock_regeneration_packet.sv"
    "$repo_root/rtl/video/hdmi/audio_info_frame.sv"
    "$repo_root/rtl/video/hdmi/audio_sample_packet.sv"
    "$repo_root/rtl/video/hdmi/auxiliary_video_information_info_frame.sv"
    "$repo_root/rtl/video/hdmi/packet_assembler.sv"
    "$repo_root/rtl/video/hdmi/packet_picker.sv"
    "$repo_root/rtl/video/hdmi/source_product_description_info_frame.sv"
    "$repo_root/rtl/video/hdmi/tmds_channel.sv"
    "$repo_root/rtl/video/nexttang_gowin_hdmi_serializer.sv"
    "$repo_root/rtl/video/hdmi/hdmi.sv"
    "$repo_root/rtl/smoke/nexttang_debug_status_uart.v"
    "$repo_root/rtl/smoke/nexttang_m1_trace.v"
    "$repo_root/rtl/smoke/nexttang_memory_capture.v"
    "$repo_root/rtl/smoke/nexttang_nextreg_log.v"
    "$repo_root/rtl/input/nexttang_uart_receiver.v"
)
if [[ "$profile" == diagnostic-ddr3 ]]; then
    source_files+=(
        "$repo_root/rtl/memory/nexttang_cpu_memory_service.v"
        "$repo_root/rtl/memory/nexttang_memory_cdc_bridge.v"
        "$repo_root/rtl/memory/nexttang_byte_line_adapter.v"
        "$repo_root/rtl/memory/nexttang_cpu_memory_path.v"
        "$repo_root/rtl/memory/nexttang_cpu_line_cache.v"
        "$repo_root/rtl/memory/nexttang_zxnext_memory_port.v"
        "$repo_root/rtl/video/nexttang_layer2_mirror.v"
        "$repo_root/rtl/memory/nexttang_gowin_ddr3_ui_adapter.v"
        "$repo_root/boards/console138k/nexttang_console138k_ddr3_pll.v"
        "$vendor_source/ddr3_memory_interface/ddr3_memory_interface.v"
        "$vendor_source/gowin_pll/gowin_pll.v"
        "$vendor_source/gowin_pll/gowin_pll_mod.v"
        "$vendor_source/pll_init.v"
        "$repo_root/rtl/input/usb_hid_host.v"
        "$repo_root/rtl/input/usb_hid_host_dual_rom.v"
        "$repo_root/rtl/input/nexttang_usb_keyboard_matrix.v"
        "$repo_root/rtl/input/nexttang_usb_gamepad_kempston.v"
        "$repo_root/rtl/input/nexttang_keyboard_matrix.v"
        "$repo_root/boards/console138k/nexttang_console138k_usb_pll.v"
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

# The PLL counts a phase in VCO periods and the SDC states it in nanoseconds;
# nothing else ties the two together, and they drifted apart once already.
python3 "$repo_root/scripts/check_pll_phase.py" \
    "$repo_root/boards/console138k/$constraints_base.sdc" \
    "$repo_root/boards/console138k/nexttang_console138k_machine_pll.v" || exit 1
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
if [[ -n "$boot_image" ]]; then
    python3 "$repo_root/scripts/build_diagnostic_boot.py" --binary "$boot_image" \
        --notice-file "$boot_image.notice" --output "$boot_rom" || exit 1
    included_files+=("$boot_image" "$boot_image.notice")
fi
for source_file in "${source_files[@]}" "${included_files[@]}"; do
    [[ -s "$source_file" ]] || {
        printf 'console138k zxnext build: missing source: %s\n' "$source_file" >&2
        exit 1
    }
done

# The USB microcode ROM is read by relative name from the build directory.
if [[ "$profile" == diagnostic-ddr3 ]]; then
    cp "$repo_root/rtl/input/usb_hid_host_rom.mem" "$output_dir/usb_hid_host_rom.mem"
    included_files+=("$repo_root/rtl/input/usb_hid_host_rom.mem")
fi

project_tcl="$output_dir/$base_name.tcl"
build_log="$output_dir/build.log"
bitstream="$output_dir/impl/pnr/$base_name.fs"
timing_report="$output_dir/impl/pnr/$base_name.tr"
source_hashes="$output_dir/source-sha256.txt"

sha256sum "${source_files[@]}" "${included_files[@]}" >"$source_hashes"

# The core works on both edges of related clocks, and several of its
# half-cycle paths sit within a fraction of a nanosecond of 28 MHz. Which
# placement and router options close them changes as the design changes, so
# each profile lists PLACE:ROUTE pairs to try in order. A failed attempt keeps
# its reports under attempt-PLACE-ROUTE for inspection; the bitstream that
# passes stays in impl/.
attempt=0
for pair in "${attempts[@]}"; do
    attempt=$((attempt + 1))
    place_option=${pair%%:*}
    route_option=${pair##*:}
    {
        printf 'set_device -device_version C GW5AST-LV138PG484AC1/I0\n'
        printf 'set_option -top_module %s\n' "$base_name"
        printf 'set_option -output_base_name %s\n' "$base_name"
        printf 'set_option -vhdl_std vhd2008\n'
        printf 'set_option -verilog_std sysv2017\n'
        printf 'set_option -gen_text_timing_rpt 1\n'
        printf 'set_option -place_option %s\n' "$place_option"
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

    if grep -q '^ERROR' "$build_log"; then
        printf 'console138k zxnext build: vendor errors (see %s)\n' "$build_log" >&2
        exit 1
    fi
    if [[ ! -f "$bitstream" ]]; then
        printf 'console138k zxnext build: no bitstream produced (see %s)\n' "$build_log" >&2
        exit 1
    fi

    if python3 "$repo_root/scripts/check_timing.py" "$timing_report"; then
        printf 'console138k zxnext build: PASS with place option %s, route option %s\n' "$place_option" "$route_option"
        printf 'bitstream: %s\n' "$bitstream"
        exit 0
    fi

    if (( attempt < ${#attempts[@]} )); then
        printf 'console138k zxnext build: timing failed with place option %s, route option %s, trying the next\n' "$place_option" "$route_option" >&2
        mv "$output_dir/impl" "$output_dir/attempt-$place_option-$route_option"
        mv "$build_log" "$output_dir/attempt-$place_option-$route_option/build.log"
    fi
done

printf 'console138k zxnext build: timing failed with every option pair\n' >&2
exit 1
