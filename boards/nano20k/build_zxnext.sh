#!/usr/bin/env bash
# Build the ZX Spectrum Next core for the Tang Nano 20K (v3923).
#
# Profiles: skeleton (lists sources only) and first (the Nano shell: clocks,
# SDRAM ports A, B and C, hdmi_frame HDMI with sound, the amplifier, keys and
# the debugger over the debug UART; see nexttang_nano20k_zxnext.v).
#   build_zxnext.sh --profile first --output ABSOLUTE_EMPTY_DIR [--boot-image FILE]
# --boot-image FILE replaces the diagnostic boot ROM with an image of at most
# 8 KiB, such as the Next's own boot loader from scripts/build_next_ipl.sh
# (FILE.notice holds its licence notice), as the Console's driver does.
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd -- "$script_dir/../.." && pwd -P)

profile=
output_dir=
boot_image=
place_option=1   # closes 28.125 MHz (worst slack +0.008 ns, 2026-11-11); 0 misses by 0.75 ns
route_option=2   # 2026-11-12, default image: place 1 / route 2 meets timing and boots NextZXOS
                 # every time. Timing met is not enough on this board: check a new build
                 # boots (the SD and SDRAM pins are not in the SDC; see the shell).
print_sources=0
# Defaults: the Nano image that boots every time (2026-11-12): HDMI picture, SD,
# keys and the debugger on the debug UART (which also reaches the BL616's USB
# serial), no sound. Builds with the core's sound hardware (--audio 1-3) met
# timing and mostly failed to boot NextZXOS on the board; see the shell.
audio=0          # --audio 0 none, 1 HDMI, 2 the on-board amplifier, 3 both (needs --status-line 0)
status_line=0    # --status-line 1: the debug status line (about 1,000 cells; use with --audio 0)
pi_pins=0        # --pi-pins 1: the Pi debug slave on a Pi Zero's SPI (header 25-28) instead
while (($#)); do
    case "$1" in
        --profile) [[ $# -ge 2 ]] || exit 2; profile=$2; shift 2 ;;
        --output) [[ $# -ge 2 ]] || exit 2; output_dir=$2; shift 2 ;;
        --place) [[ $# -ge 2 ]] || exit 2; place_option=$2; shift 2 ;;
        --route) [[ $# -ge 2 ]] || exit 2; route_option=$2; shift 2 ;;
        --boot-image) [[ $# -ge 2 ]] || exit 2; boot_image=$2; shift 2 ;;
        --audio) [[ $# -ge 2 && $2 == [0-3] ]] || exit 2; audio=$2; shift 2 ;;
        --status-line) [[ $# -ge 2 && $2 == [01] ]] || exit 2; status_line=$2; shift 2 ;;
        --pi-pins) [[ $# -ge 2 && $2 == [01] ]] || exit 2; pi_pins=$2; shift 2 ;;
        --toolchain|--vendor-source) [[ $# -ge 2 ]] || exit 2; shift 2 ;;
        --print-sources) print_sources=1; shift ;;
        -h|--help)
            printf '%s\n' 'usage: boards/nano20k/build_zxnext.sh --profile skeleton|first [--print-sources] [--output DIR]' \
                '       [--boot-image FILE] [--audio 0-3] [--status-line 0|1] [--pi-pins 0|1] [--place N] [--route N]'
            exit 0 ;;
        *) printf 'nano20k zxnext build: unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done

[[ "$profile" == skeleton || "$profile" == first ]] || {
    printf 'nano20k zxnext build: profile not implemented: %s (skeleton or first)\n' "$profile" >&2
    exit 2
}

# The machine's sources come from the Console driver's list, so the two
# boards cannot drift apart on what the shared machine is.
mapfile -t console_sources < <("$repo_root/boards/console138k/build_zxnext.sh" --profile diagnostic --print-sources)
source_files=()
for source_file in "${console_sources[@]}"; do
    case "$source_file" in
        */boards/*|*/rtl/video/*|*/rtl/memory/nexttang_block_ram.v|*/rtl/audio/nexttang_zxnext_audio_pcm.v|*/rtl/clock/nexttang_machine_clock_enables.v|*/rtl/reset/nexttang_reset_release.v) ;;
        *) source_files+=("$source_file") ;;
    esac
done
# The core's own video files are part of the machine.
for source_file in "${console_sources[@]}"; do
    case "$source_file" in
        */rtl/video/layer2.vhd|*/rtl/video/lores.vhd|*/rtl/video/sprites.vhd|*/rtl/video/tilemap.vhd|*/rtl/video/zxula_timing.vhd|*/rtl/video/zxula.vhd)
            source_files+=("$source_file") ;;
    esac
done
source_files+=(
    "$repo_root/rtl/reset/nexttang_reset_release.v"
    "$repo_root/rtl/clock/nexttang_machine_clock_enables.v"
    "$repo_root/rtl/memory/nexttang_sdr_sdram_service.v"
    "$repo_root/rtl/input/nexttang_keyboard_matrix.v"
    "$repo_root/rtl/video/hdmi_frame.vhd"
    "$repo_root/rtl/video/nexttang_tmds_encoder.v"
    "$repo_root/rtl/video/nexttang_hdmi_island_timing.v"
    "$repo_root/rtl/video/nexttang_hdmi_audio_out.sv"
    "$repo_root/rtl/video/hdmi/packet_picker.sv"
    "$repo_root/rtl/video/hdmi/packet_assembler.sv"
    "$repo_root/rtl/video/hdmi/audio_clock_regeneration_packet.sv"
    "$repo_root/rtl/video/hdmi/audio_sample_packet.sv"
    "$repo_root/rtl/video/hdmi/auxiliary_video_information_info_frame.sv"
    "$repo_root/rtl/video/hdmi/source_product_description_info_frame.sv"
    "$repo_root/rtl/video/hdmi/audio_info_frame.sv"
    "$repo_root/rtl/video/hdmi/tmds_channel.sv"
    "$repo_root/rtl/audio/nexttang_zxnext_audio_pcm.v"
    "$repo_root/rtl/audio/nexttang_i2s_transmitter.v"
    "$repo_root/boards/nano20k/nexttang_nano20k_zxnext.v"
    "$repo_root/boards/nano20k/nano20k_v3923.cst"
    "$repo_root/boards/nano20k/nano20k_zxnext.sdc"
    "$repo_root/boards/nano20k/nano20k_zxnext.gsc"
)
# the Console's list may already carry some of these
mapfile -t source_files < <(printf '%s\n' "${source_files[@]}" | awk '!seen[$0]++')

if ((print_sources)); then
    printf '%s\n' nexttang_nano20k_zxnext "${source_files[@]}"
    exit 0
fi

if [[ "$profile" == skeleton ]]; then
    printf '%s\n' 'nano20k zxnext build: the skeleton profile only lists sources (--print-sources)' >&2
    exit 2
fi
[[ "$output_dir" == /* && -d "$output_dir" ]] || {
    printf '%s\n' 'nano20k zxnext build: --output must be an existing absolute directory' >&2
    exit 2
}
[[ -z $(find "$output_dir" -mindepth 1 -maxdepth 1 -print -quit) ]] || {
    printf 'nano20k zxnext build: output directory is not empty: %s\n' "$output_dir" >&2
    exit 2
}
base_name=nexttang_nano20k_zxnext
if [[ -n "$boot_image" ]]; then
    [[ "$boot_image" == /* && -s "$boot_image" && -s "$boot_image.notice" ]] || {
        printf '%s\n' 'nano20k zxnext build: --boot-image needs an absolute FILE and FILE.notice' >&2
        exit 2
    }
    python3 "$repo_root/scripts/build_diagnostic_boot.py" --binary "$boot_image" \
        --notice-file "$boot_image.notice" --output "$output_dir/bootrom.vhd" || exit 1
    for i in "${!source_files[@]}"; do
        [[ "${source_files[$i]}" == */rtl/core/nexttang_diagnostic_bootrom.vhd ]] && source_files[i]="$output_dir/bootrom.vhd"
    done
fi
if [[ "$audio" != 0 && "$status_line" == 1 ]]; then
    printf '%s\n' 'nano20k zxnext build: sound and the status line do not fit together (--audio 0 or --status-line 0)' >&2
    exit 2
fi
# The build options are localparams in the shell; a copy carries the chosen values.
shell_source="$repo_root/boards/nano20k/nexttang_nano20k_zxnext.v"
sed -e "s/^    localparam integer AUDIO = [0-3];/    localparam integer AUDIO = $audio;/" \
    -e "s/^    localparam integer STATUS_LINE = [01];/    localparam integer STATUS_LINE = $status_line;/" \
    -e "s/^    localparam integer PI_SPI_PINS = [01];/    localparam integer PI_SPI_PINS = $pi_pins;/" \
    "$shell_source" >"$output_dir/nexttang_nano20k_zxnext.v"
for option in "AUDIO = $audio" "STATUS_LINE = $status_line" "PI_SPI_PINS = $pi_pins"; do
    grep -q "^    localparam integer $option;" "$output_dir/nexttang_nano20k_zxnext.v" || {
        printf 'nano20k zxnext build: could not set %s in the shell\n' "$option" >&2; exit 1; }
done
for i in "${!source_files[@]}"; do
    [[ "${source_files[$i]}" == "$shell_source" ]] && source_files[i]="$output_dir/nexttang_nano20k_zxnext.v"
done
# Without the status line its registers are gone, and so are the SDC lines naming them.
if [[ "$status_line" == 0 ]]; then
    sdc_source="$repo_root/boards/nano20k/nano20k_zxnext.sdc"
    grep -v 'machine/status_uart/' "$sdc_source" >"$output_dir/nano20k_zxnext.sdc"
    for i in "${!source_files[@]}"; do
        [[ "${source_files[$i]}" == "$sdc_source" ]] && source_files[i]="$output_dir/nano20k_zxnext.sdc"
    done
fi
printf 'audio=%s status_line=%s pi_pins=%s place=%s route=%s\n' "$audio" "$status_line" "$pi_pins" \
    "$place_option" "$route_option" >"$output_dir/build-options.txt"
sha256sum "${source_files[@]}" >"$output_dir/source-sha256.txt"
{
    printf 'set_device -device_version C GW2AR-LV18QN88C8/I7\n'
    printf 'set_option -top_module %s\n' "$base_name"
    printf 'set_option -output_base_name %s\n' "$base_name"
    printf 'set_option -vhdl_std vhd2008\n'
    printf 'set_option -verilog_std sysv2017\n'
    printf 'set_option -gen_text_timing_rpt 1\n'
    printf 'set_option -use_sspi_as_gpio 1\n'
    printf 'set_option -place_option %s\n' "$place_option"
    printf 'set_option -route_option %s\n' "$route_option"
    # SDRAM command, address and data registers in their I/O cells, so the
    # interface timing does not move with placement (see the shell's ODDR).
    printf 'set_option -ireg_in_iob 1\n'
    printf 'set_option -oreg_in_iob 1\n'
    printf 'set_option -ioreg_in_iob 1\n'
    for source_file in "${source_files[@]}"; do
        printf 'add_file {%s}\n' "$source_file"
    done
    printf 'run all\n'
} >"$output_dir/$base_name.tcl"
cd -- "$output_dir"
gw_sh "$base_name.tcl" >build.log 2>&1 || { tail -20 build.log >&2; exit 1; }
[[ -s "impl/pnr/$base_name.fs" ]] || { printf '%s\n' 'nano20k zxnext build: no bitstream' >&2; exit 1; }
printf 'nano20k zxnext build: %s\n' "$output_dir/impl/pnr/$base_name.fs"
