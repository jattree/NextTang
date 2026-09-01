#!/usr/bin/env bash
# Build the machine CPU bring-up image for the Console 138K.  The `ula`
# profile is a separate target that replaces only the ad-hoc display path with
# the imported ULA and frame-safe 720p scaler. The tape profile also accepts a
# user-supplied TZX or single-member TZX ZIP outside Git. The snapshot profile
# similarly resumes a private 48K SNA without copying it into the repository.
#
# This path mixes the imported VHDL T80 and, in the `ula` profile, the imported
# VHDL raster with the original Verilog platform shell.
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd -- "$script_dir/../.." && pwd -P)

toolchain=
profile=
vendor_source=
tape_file=
snapshot_file=
gfx_file=
rom_gfx_file=
palette_file=
output_dir=
print_sources=0

usage() {
    printf '%s\n' 'usage: boards/console138k/build_spectrum48.sh --toolchain vendor --profile release|ula|ula-tape|ula-usb-tape|ula-tape-start-s1|ula-snapshot|spec256-snapshot|spec256-snapshot-audio|spec256-snapshot-audio-chuckie|spec256-runtime-audio|bl616-keyboard-test|keyboard-test|ula-ddr-upper|ula-ddr-upper-tape|48k-usb-ddr-audio|128k-usb-ddr|48k-loader|128k-loader|spec256-loader|spec256-loader-romview|spec256-loader-bsrampalette|spec256-loader-ddr3 [--vendor-source ABSOLUTE_DIRECTORY] [--tape ABSOLUTE_TZX_OR_ZIP] [--snapshot ABSOLUTE_SNA] [--gfx ABSOLUTE_GFX] [--rom-gfx ABSOLUTE_ROM_GFX] [--palette ABSOLUTE_PALETTE] --output ABSOLUTE_DIRECTORY'
    printf '%s\n' '       boards/console138k/build_spectrum48.sh --profile PROFILE --print-sources'
}

while (($#)); do
    case "$1" in
        --print-sources) print_sources=1; shift ;;
        --toolchain|--profile|--vendor-source|--tape|--snapshot|--gfx|--rom-gfx|--palette|--output)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            case "$1" in
                --toolchain) toolchain=$2 ;;
                --profile) profile=$2 ;;
                --vendor-source) vendor_source=$2 ;;
                --tape) tape_file=$2 ;;
                --snapshot) snapshot_file=$2 ;;
                --gfx) gfx_file=$2 ;;
                --rom-gfx) rom_gfx_file=$2 ;;
                --palette) palette_file=$2 ;;
                --output) output_dir=$2 ;;
            esac
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'console138k spectrum build: unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

# --print-sources resolves the profile's source list and stops. It reads no
# input files and writes nothing, so the arguments that only matter to a real
# build are not required for it. `scripts/hdl_lint.sh` uses this so the lint
# file list is the build file list rather than a second copy that drifts.
if ((!print_sources)) && [[ "$toolchain" != vendor ]]; then
    printf 'console138k spectrum build: toolchain not implemented: %s\n' "$toolchain" >&2
    exit 2
fi
if [[ "$profile" != release && "$profile" != ula && \
      "$profile" != ula-tape && \
      "$profile" != ula-usb-tape && \
      "$profile" != ula-tape-start-s1 && \
      "$profile" != ula-snapshot && \
      "$profile" != spec256-snapshot && \
      "$profile" != spec256-snapshot-audio && \
      "$profile" != spec256-snapshot-audio-chuckie && \
      "$profile" != spec256-runtime-audio && \
      "$profile" != spec256-loader && \
      "$profile" != spec256-loader-romview && \
      "$profile" != spec256-loader-bsrampalette && \
      "$profile" != spec256-loader-ddr3 && \
      "$profile" != bl616-keyboard-test && \
      "$profile" != keyboard-test && \
      "$profile" != ula-ddr-upper && \
      "$profile" != ula-ddr-upper-tape && \
      "$profile" != 48k-usb-ddr-audio && \
      "$profile" != 128k-usb-ddr && \
      "$profile" != 48k-loader && "$profile" != 128k-loader ]]; then
    printf 'console138k spectrum build: profile not implemented: %s\n' "$profile" >&2
    exit 2
fi
if ((!print_sources)) && [[ ("$profile" == ula-snapshot || "$profile" == spec256-snapshot || \
       "$profile" == spec256-snapshot-audio || \
       "$profile" == spec256-snapshot-audio-chuckie) && \
      ("$snapshot_file" != /* || ! -f "$snapshot_file") ]]; then
    printf '%s\n' 'console138k spectrum build: snapshot profile requires --snapshot ABSOLUTE_SNA' >&2
    exit 2
fi
if ((!print_sources)) && [[ ("$profile" == spec256-snapshot || "$profile" == spec256-snapshot-audio || \
       "$profile" == spec256-snapshot-audio-chuckie) && \
      ("$gfx_file" != /* || ! -f "$gfx_file" || \
       "$rom_gfx_file" != /* || ! -f "$rom_gfx_file" || \
       "$palette_file" != /* || ! -f "$palette_file") ]]; then
    printf '%s\n' 'console138k spectrum build: spec256 profile requires --gfx ABSOLUTE_GFX, --rom-gfx ABSOLUTE_ROM_GFX and --palette ABSOLUTE_PALETTE' >&2
    exit 2
fi

vendor_files=()
if [[ "$profile" == ula-ddr-upper || \
      "$profile" == 48k-usb-ddr-audio || \
      "$profile" == 128k-usb-ddr || \
      "$profile" == 48k-loader || "$profile" == 128k-loader || \
      "$profile" == spec256-loader-ddr3 || \
      "$profile" == ula-ddr-upper-tape ]]; then
    if ((!print_sources)) && [[ "$vendor_source" != /* || ! -d "$vendor_source" ]]; then
        printf '%s\n' 'console138k spectrum build: DDR profile requires --vendor-source ABSOLUTE_DIRECTORY' >&2
        exit 2
    fi
    vendor_files=(
        "$vendor_source/ddr3_memory_interface/ddr3_memory_interface.v"
        "$vendor_source/gowin_pll/gowin_pll.v"
        "$vendor_source/gowin_pll/gowin_pll_mod.v"
        "$vendor_source/pll_init.v"
    )
    for vendor_file in "${vendor_files[@]}"; do
        if ((!print_sources)) && [[ ! -s "$vendor_file" ]]; then
            printf 'console138k spectrum build: required vendor source missing: %s\n' "$vendor_file" >&2
            exit 2
        fi
    done
fi
if ((!print_sources)) && [[ ("$profile" == ula-ddr-upper-tape || "$profile" == ula-tape || \
       "$profile" == ula-usb-tape || \
       "$profile" == ula-tape-start-s1) && \
      ("$tape_file" != /* || ! -f "$tape_file") ]]; then
    printf '%s\n' 'console138k spectrum build: tape profile requires --tape ABSOLUTE_TZX_OR_ZIP' >&2
    exit 2
fi
if ((!print_sources)) && [[ "$output_dir" != /* ]]; then
    printf '%s\n' 'console138k spectrum build: --output must be an absolute path' >&2
    exit 2
fi
if ((!print_sources)) && [[ ! -d "$output_dir" ]]; then
    printf 'console138k spectrum build: output directory does not exist: %s\n' "$output_dir" >&2
    exit 2
fi
if ((!print_sources)) && [[ -n $(find "$output_dir" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
    printf 'console138k spectrum build: output directory is not empty: %s\n' "$output_dir" >&2
    exit 2
fi

if [[ "$profile" == 48k-loader ]]; then
    base_name=nexttang_console138k_spectrum48_loader
    pin_constraints_base="$repo_root/boards/console138k/console138k_ddr3.cst"
    pin_constraints_extra="$repo_root/boards/console138k/console138k_classic_loader_extra.cst"
    timing_constraints="$repo_root/boards/console138k/console138k_spectrum128_usb_ddr3.sdc"
elif [[ "$profile" == 128k-loader ]]; then
    base_name=nexttang_console138k_spectrum128_loader
    pin_constraints_base="$repo_root/boards/console138k/console138k_ddr3.cst"
    pin_constraints_extra="$repo_root/boards/console138k/console138k_classic_loader_extra.cst"
    timing_constraints="$repo_root/boards/console138k/console138k_spectrum128_usb_ddr3.sdc"
elif [[ "$profile" == 48k-usb-ddr-audio ]]; then
    base_name=nexttang_console138k_spectrum48_usb_ddr3_audio
    pin_constraints_base="$repo_root/boards/console138k/console138k_ddr3.cst"
    pin_constraints_extra="$repo_root/boards/console138k/console138k_spectrum128_usb_ddr3_extra.cst"
    timing_constraints="$repo_root/boards/console138k/console138k_spectrum128_usb_ddr3.sdc"
elif [[ "$profile" == 128k-usb-ddr ]]; then
    base_name=nexttang_console138k_spectrum128_usb_ddr3
    pin_constraints_base="$repo_root/boards/console138k/console138k_ddr3.cst"
    pin_constraints_extra="$repo_root/boards/console138k/console138k_spectrum128_usb_ddr3_extra.cst"
    timing_constraints="$repo_root/boards/console138k/console138k_spectrum128_usb_ddr3.sdc"
elif [[ "$profile" == ula-ddr-upper-tape ]]; then
    base_name=nexttang_console138k_spectrum48_ula_ddr3_tape
    pin_constraints_base="$repo_root/boards/console138k/console138k_ddr3.cst"
    pin_constraints_extra="$repo_root/boards/console138k/console138k_spectrum48_ula_ddr3_extra.cst"
    timing_constraints="$repo_root/boards/console138k/console138k_spectrum48_ula_ddr3.sdc"
elif [[ "$profile" == ula-ddr-upper ]]; then
    base_name=nexttang_console138k_spectrum48_ula_ddr3
    pin_constraints_base="$repo_root/boards/console138k/console138k_ddr3.cst"
    pin_constraints_extra="$repo_root/boards/console138k/console138k_spectrum48_ula_ddr3_extra.cst"
    timing_constraints="$repo_root/boards/console138k/console138k_spectrum48_ula_ddr3.sdc"
elif [[ "$profile" == ula-tape-start-s1 ]]; then
    base_name=nexttang_console138k_spectrum48_ula_tape_s1
    pin_constraints_base="$repo_root/boards/console138k/console138k_spectrum48.cst"
    pin_constraints_extra=
    timing_constraints="$repo_root/boards/console138k/console138k_spectrum48_ula.sdc"
elif [[ "$profile" == ula-usb-tape ]]; then
    base_name=nexttang_console138k_spectrum48_ula_usb_tape
    pin_constraints_base="$repo_root/boards/console138k/console138k_spectrum48.cst"
    pin_constraints_extra="$repo_root/boards/console138k/console138k_spectrum48_keyboard_extra.cst"
    timing_constraints="$repo_root/boards/console138k/console138k_spectrum48_keyboard.sdc"
elif [[ "$profile" == ula-tape ]]; then
    base_name=nexttang_console138k_spectrum48_ula_tape
    pin_constraints_base="$repo_root/boards/console138k/console138k_spectrum48.cst"
    pin_constraints_extra=
    timing_constraints="$repo_root/boards/console138k/console138k_spectrum48_ula.sdc"
elif [[ "$profile" == spec256-loader-ddr3 ]]; then
    base_name=nexttang_console138k_spec256_loader_ddr3
    pin_constraints_base="$repo_root/boards/console138k/console138k_ddr3.cst"
    pin_constraints_extra="$repo_root/boards/console138k/console138k_spec256_loader_ddr3_extra.cst"
    timing_constraints="$repo_root/boards/console138k/console138k_spec256_loader_ddr3.sdc"
elif [[ "$profile" == spec256-loader-bsrampalette ]]; then
    # Bisect instrument: same platform and constraints as spec256-loader, with
    # the palette back in BSRAM. Same .cst/.sdc so the A/B is like for like.
    base_name=nexttang_console138k_spec256_loader_bsrampalette
    pin_constraints_base="$repo_root/boards/console138k/console138k_spectrum48.cst"
    pin_constraints_extra="$repo_root/boards/console138k/console138k_spec256_loader_extra.cst"
    timing_constraints="$repo_root/boards/console138k/console138k_spec256_loader.sdc"
elif [[ "$profile" == spec256-loader-romview ]]; then
    # Diagnostic sibling of spec256-loader: identical platform, identical
    # constraints, one extra define. Same pin and timing files by design, so a
    # capture from it is comparable with the ordinary loader's.
    base_name=nexttang_console138k_spec256_loader_romview
    pin_constraints_base="$repo_root/boards/console138k/console138k_spectrum48.cst"
    pin_constraints_extra="$repo_root/boards/console138k/console138k_spec256_loader_extra.cst"
    timing_constraints="$repo_root/boards/console138k/console138k_spec256_loader_romview.sdc"
elif [[ "$profile" == spec256-loader ]]; then
    base_name=nexttang_console138k_spec256_loader
    pin_constraints_base="$repo_root/boards/console138k/console138k_spectrum48.cst"
    pin_constraints_extra="$repo_root/boards/console138k/console138k_spec256_loader_extra.cst"
    timing_constraints="$repo_root/boards/console138k/console138k_spec256_loader.sdc"
elif [[ "$profile" == spec256-runtime-audio ]]; then
    base_name=nexttang_console138k_spectrum48_spec256_runtime_audio
    pin_constraints_base="$repo_root/boards/console138k/console138k_spectrum48.cst"
    pin_constraints_extra="$repo_root/boards/console138k/console138k_spectrum48_spec256_runtime_extra.cst"
    timing_constraints="$repo_root/boards/console138k/console138k_spectrum48_spec256_runtime.sdc"
elif [[ "$profile" == spec256-snapshot-audio || \
        "$profile" == spec256-snapshot-audio-chuckie ]]; then
    if [[ "$profile" == spec256-snapshot-audio-chuckie ]]; then
        base_name=nexttang_console138k_spectrum48_spec256_snapshot_audio_chuckie
    else
        base_name=nexttang_console138k_spectrum48_spec256_snapshot_audio
    fi
    pin_constraints_base="$repo_root/boards/console138k/console138k_spectrum48.cst"
    pin_constraints_extra="$repo_root/boards/console138k/console138k_spectrum48_keyboard_extra.cst"
    timing_constraints="$repo_root/boards/console138k/console138k_spectrum48_spec256.sdc"
elif [[ "$profile" == spec256-snapshot ]]; then
    base_name=nexttang_console138k_spectrum48_spec256_snapshot
    pin_constraints_base="$repo_root/boards/console138k/console138k_spectrum48.cst"
    pin_constraints_extra="$repo_root/boards/console138k/console138k_spectrum48_keyboard_extra.cst"
    timing_constraints="$repo_root/boards/console138k/console138k_spectrum48_spec256.sdc"
elif [[ "$profile" == ula-snapshot ]]; then
    base_name=nexttang_console138k_spectrum48_ula_snapshot
    pin_constraints_base="$repo_root/boards/console138k/console138k_spectrum48.cst"
    pin_constraints_extra=
    timing_constraints="$repo_root/boards/console138k/console138k_spectrum48_ula.sdc"
elif [[ "$profile" == bl616-keyboard-test ]]; then
    base_name=nexttang_console138k_spectrum48_bl616_keyboard_test
    pin_constraints_base="$repo_root/boards/console138k/console138k_spectrum48.cst"
    pin_constraints_extra=
    timing_constraints="$repo_root/boards/console138k/console138k_spectrum48_ula.sdc"
elif [[ "$profile" == keyboard-test ]]; then
    base_name=nexttang_console138k_spectrum48_keyboard_test
    pin_constraints_base="$repo_root/boards/console138k/console138k_spectrum48.cst"
    pin_constraints_extra="$repo_root/boards/console138k/console138k_spectrum48_keyboard_extra.cst"
    timing_constraints="$repo_root/boards/console138k/console138k_spectrum48_keyboard.sdc"
elif [[ "$profile" == ula ]]; then
    base_name=nexttang_console138k_spectrum48_ula
    pin_constraints_base="$repo_root/boards/console138k/console138k_spectrum48.cst"
    pin_constraints_extra=
    timing_constraints="$repo_root/boards/console138k/console138k_spectrum48_ula.sdc"
else
    base_name=nexttang_console138k_spectrum48
    pin_constraints_base="$repo_root/boards/console138k/console138k_spectrum48.cst"
    pin_constraints_extra=
    timing_constraints="$repo_root/boards/console138k/console138k_spectrum48.sdc"
fi

if ((!print_sources)) && [[ "$profile" == ula-ddr-upper-tape || "$profile" == ula-tape || \
      "$profile" == ula-usb-tape || \
      "$profile" == ula-tape-start-s1 ]]; then
    python3 "$repo_root/scripts/tzx_to_mem.py" \
        "$tape_file" "$output_dir/tape.mem" \
        --manifest "$output_dir/tape-input-sha256.txt" || exit 1
fi
if ((!print_sources)) && [[ "$profile" == keyboard-test || "$profile" == ula-usb-tape || \
      "$profile" == 48k-usb-ddr-audio || \
      "$profile" == 128k-usb-ddr || \
      "$profile" == 48k-loader || "$profile" == 128k-loader || \
      "$profile" == spec256-loader || \
      "$profile" == spec256-loader-romview || \
      "$profile" == spec256-loader-bsrampalette || \
      "$profile" == spec256-loader-ddr3 || \
      "$profile" == spec256-runtime-audio || \
      "$profile" == spec256-snapshot || \
      "$profile" == spec256-snapshot-audio || \
      "$profile" == spec256-snapshot-audio-chuckie ]]; then
    cp "$repo_root/rtl/input/usb_hid_host_rom.mem" \
        "$output_dir/usb_hid_host_rom.mem"
fi
if ((!print_sources)) && [[ "$profile" == ula-snapshot || "$profile" == spec256-snapshot || \
      "$profile" == spec256-snapshot-audio || \
      "$profile" == spec256-snapshot-audio-chuckie ]]; then
    python3 "$repo_root/tools/spec256/snapshot.py" \
        "$snapshot_file" \
        "$output_dir/snapshot-ram.mem" \
        "$output_dir/snapshot-boot.mem" \
        --manifest "$output_dir/snapshot-input-sha256.txt" || exit 1
fi
if ((!print_sources)) && [[ "$profile" == spec256-snapshot || "$profile" == spec256-snapshot-audio || \
      "$profile" == spec256-snapshot-audio-chuckie ]]; then
    python3 "$repo_root/tools/spec256/hardware.py" \
        "$snapshot_file" "$gfx_file" "$output_dir/spec256-ram.mem" \
        --rom-gfx "$rom_gfx_file" \
        --palette-source "$palette_file" \
        --palette-destination "$output_dir/spec256-palette.mem" \
        --manifest "$output_dir/spec256-input-sha256.txt" || exit 1
fi

if ((!print_sources)) && [[ -n "$pin_constraints_extra" ]]; then
    pin_constraints="$output_dir/$base_name.cst"
    {
        printf '%s\n' '// Generated from the two repository constraint sources below.'
        if [[ "$profile" == spec256-runtime-audio || \
              "$profile" == spec256-loader || \
              "$profile" == spec256-loader-romview || \
              "$profile" == spec256-loader-bsrampalette || \
              "$profile" == ula-usb-tape ]]; then
            # G21 is the runtime game-pack input for this profile.  The base
            # constraints use it for the diagnostic-only loopback input, which
            # is not a port on the runtime top and cannot share the package pin.
            awk '
                /IO_LOC "loopback_uart_rx"/ { next }
                /IO_PORT "loopback_uart_rx"/ { next }
                FNR == 1 && NR != 1 { print "" }
                { print }
            ' "$pin_constraints_base" "$pin_constraints_extra"
        else
            awk 'FNR == 1 && NR != 1 { print "" } { print }' \
                "$pin_constraints_base" "$pin_constraints_extra"
        fi
    } >"$pin_constraints"
else
    pin_constraints=$pin_constraints_base
fi

project_tcl="$output_dir/$base_name.tcl"
build_log="$output_dir/vendor-build.log"
bitstream="$output_dir/impl/pnr/$base_name.fs"
timing_report="$output_dir/impl/pnr/${base_name}_tr_content.html"
source_hashes="$output_dir/source-sha256.txt"

source_files=(
    "$repo_root/rtl/cpu/t80n_pack.vhd"
    "$repo_root/rtl/cpu/t80n_alu.vhd"
    "$repo_root/rtl/cpu/t80n_mcode.vhd"
    "$repo_root/rtl/cpu/t80n.vhd"
    "$repo_root/rtl/cpu/t80na.vhd"
    "$repo_root/rtl/memory/nexttang_block_ram.v"
    "$repo_root/rtl/memory/nexttang_spectrum_ram.v"
    "$repo_root/rtl/memory/nexttang_rom.v"
    "$repo_root/rtl/audio/nexttang_spectrum_beeper.v"
    "$repo_root/rtl/input/nexttang_keyboard_matrix.v"
    "$repo_root/rtl/input/nexttang_key_sequencer.v"
    "$repo_root/rtl/input/nexttang_uart_receiver.v"
    "$repo_root/rtl/input/nexttang_bl616_keyboard.v"
    "$repo_root/rtl/input/nexttang_ps2_matrix.v"
    "$repo_root/rtl/smoke/nexttang_debug_status_uart.v"
    "$repo_root/boards/console138k/nexttang_console138k_machine_pll.v"
    "$repo_root/boards/console138k/nexttang_console138k_pll.v"
    "$repo_root/rtl/video/nexttang_video_timing.v"
    "$repo_root/rtl/video/nexttang_tmds_encoder.v"
)

if [[ "$profile" == spec256-snapshot || "$profile" == spec256-snapshot-audio || \
      "$profile" == spec256-loader || \
      "$profile" == spec256-loader-romview || \
      "$profile" == spec256-loader-bsrampalette || \
      "$profile" == spec256-loader-ddr3 || \
      "$profile" == spec256-runtime-audio || \
      "$profile" == spec256-snapshot-audio-chuckie ]]; then
    source_files+=(
        "$repo_root/rtl/cpu/nexttang_spec256_cpu_cluster.vhd"
        "$repo_root/rtl/input/nexttang_post_tape_key_sequencer.v"
        "$repo_root/rtl/input/nexttang_spec256_input_mux.v"
        "$repo_root/rtl/input/usb_hid_host.v"
        "$repo_root/rtl/input/usb_hid_host_dual_rom.v"
        "$repo_root/rtl/input/nexttang_usb_keyboard_matrix.v"
        "$repo_root/rtl/input/nexttang_usb_gamepad_kempston.v"
        "$repo_root/boards/console138k/nexttang_console138k_usb_pll.v"
        "$repo_root/rtl/video/nexttang_spec256_display.v"
        "$repo_root/rtl/video/nexttang_spec256_palette.v"
        "$repo_root/rtl/video/nexttang_spec256_palette_distributed.v"
        # Resolves 0xFF passthrough pixels to the ordinary Spectrum colour.
        "$repo_root/rtl/video/nexttang_spectrum_display.v"
    )
    if [[ "$profile" == spec256-snapshot-audio || \
          "$profile" == spec256-loader || \
          "$profile" == spec256-loader-romview || \
          "$profile" == spec256-loader-bsrampalette || \
          "$profile" == spec256-loader-ddr3 || \
          "$profile" == spec256-runtime-audio || \
          "$profile" == spec256-snapshot-audio-chuckie ]]; then
        source_files+=(
            "$repo_root/rtl/audio/nexttang_beeper_pcm.v"
            "$repo_root/rtl/audio/nexttang_classic_audio_pcm.v"
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
        )
        if [[ "$profile" == spec256-loader || \
              "$profile" == spec256-loader-romview || \
              "$profile" == spec256-loader-bsrampalette || \
              "$profile" == spec256-loader-ddr3 ]]; then
            source_files+=(
                "$repo_root/rtl/input/usb_hid_host_rom.v"
                "$repo_root/rtl/input/nexttang_spec256_game_loader.v"
                "$repo_root/rtl/input/nexttang_spec256_runtime_key_sequencer.v"
                "$repo_root/rtl/input/nexttang_spec256_runtime_input.v"
                "$repo_root/rtl/storage/nexttang_spi_byte_master.v"
                "$repo_root/rtl/storage/nexttang_sd_spi_reader.v"
                "$repo_root/rtl/storage/nexttang_fat32_volume.v"
                "$repo_root/rtl/storage/nexttang_fat32_cluster_stream.v"
                "$repo_root/rtl/storage/nexttang_fat32_directory_entry.v"
                "$repo_root/rtl/storage/nexttang_fat32_directory.v"
                "$repo_root/rtl/storage/nexttang_fat32_storage.v"
                "$repo_root/rtl/loader/nexttang_async_byte_fifo.v"
                "$repo_root/rtl/loader/nexttang_async_byte_fifo_small.v"
                "$repo_root/rtl/loader/nexttang_loader_catalog.v"
                "$repo_root/rtl/loader/nexttang_loader_font.v"
                "$repo_root/rtl/loader/nexttang_loader_overlay.v"
            )
            if [[ "$profile" == spec256-loader-ddr3 ]]; then
                source_files+=(
                    "$repo_root/rtl/memory/nexttang_cpu_memory_service.v"
                    "$repo_root/rtl/memory/nexttang_memory_cdc_bridge.v"
                    "$repo_root/rtl/memory/nexttang_byte_line_adapter.v"
                    "$repo_root/rtl/memory/nexttang_cpu_memory_path.v"
                    "$repo_root/rtl/memory/nexttang_spec256_main_ddr_memory.v"
                    "$repo_root/rtl/memory/nexttang_distributed_ram.v"
                    "$repo_root/rtl/memory/nexttang_spec256_bootstrap_overlay.v"
                    "$repo_root/rtl/memory/nexttang_gowin_ddr3_ui_adapter.v"
                    "$repo_root/boards/console138k/nexttang_console138k_ddr3_pll.v"
                    "$repo_root/boards/console138k/nexttang_console138k_spec256_loader_ddr3.v"
                )
            elif [[ "$profile" == spec256-loader-bsrampalette ]]; then
                source_files+=(
                    "$repo_root/boards/console138k/nexttang_console138k_spec256_loader_bsrampalette.v"
                )
            elif [[ "$profile" == spec256-loader-romview ]]; then
                source_files+=(
                    "$repo_root/boards/console138k/nexttang_console138k_spec256_loader_romview.v"
                )
            else
                source_files+=(
                    "$repo_root/boards/console138k/nexttang_console138k_spec256_loader.v"
                )
            fi
        elif [[ "$profile" == spec256-runtime-audio ]]; then
            source_files+=(
                "$repo_root/rtl/input/usb_hid_host_rom.v"
                "$repo_root/rtl/input/nexttang_spec256_game_loader.v"
                "$repo_root/rtl/input/nexttang_spec256_runtime_key_sequencer.v"
                "$repo_root/rtl/input/nexttang_spec256_runtime_input.v"
                "$repo_root/boards/console138k/nexttang_console138k_spectrum48_spec256_runtime_audio.sv"
            )
        elif [[ "$profile" == spec256-snapshot-audio-chuckie ]]; then
            source_files+=(
                "$repo_root/boards/console138k/nexttang_console138k_spectrum48_spec256_snapshot_audio_chuckie.sv"
            )
        else
            source_files+=(
                "$repo_root/boards/console138k/nexttang_console138k_spectrum48_spec256_snapshot_audio.sv"
            )
        fi
    else
        source_files+=(
            "$repo_root/boards/console138k/nexttang_console138k_spectrum48_spec256_snapshot.v"
        )
    fi
elif [[ "$profile" == ula || "$profile" == ula-tape || \
      "$profile" == ula-usb-tape || \
      "$profile" == ula-tape-start-s1 || \
      "$profile" == ula-snapshot || \
      "$profile" == bl616-keyboard-test || \
      "$profile" == keyboard-test || \
      "$profile" == ula-ddr-upper || \
      "$profile" == ula-ddr-upper-tape || \
      "$profile" == 48k-usb-ddr-audio || \
      "$profile" == 128k-usb-ddr || \
      "$profile" == 48k-loader || "$profile" == 128k-loader ]]; then
    source_files+=(
        "$repo_root/rtl/video/zxula_timing.vhd"
        "$repo_root/rtl/video/zxula.vhd"
        "$repo_root/rtl/video/nexttang_ula_capture.v"
        "$repo_root/rtl/video/nexttang_framebuffer_scaler.v"
        "$repo_root/rtl/video/nexttang_ula_palette.v"
    )
    if [[ "$profile" == ula-ddr-upper || \
          "$profile" == 48k-usb-ddr-audio || \
          "$profile" == 128k-usb-ddr || \
          "$profile" == 48k-loader || "$profile" == 128k-loader || \
          "$profile" == ula-ddr-upper-tape ]]; then
        source_files+=(
            "$repo_root/rtl/memory/nexttang_cpu_memory_service.v"
            "$repo_root/rtl/memory/nexttang_memory_cdc_bridge.v"
            "$repo_root/rtl/memory/nexttang_byte_line_adapter.v"
            "$repo_root/rtl/memory/nexttang_cpu_memory_path.v"
            "$repo_root/rtl/memory/nexttang_spectrum48_split_memory.v"
            "$repo_root/rtl/memory/nexttang_gowin_ddr3_ui_adapter.v"
            "$repo_root/boards/console138k/nexttang_console138k_ddr3_pll.v"
        )
        if [[ "$profile" == 128k-usb-ddr || \
              "$profile" == 48k-usb-ddr-audio || \
              "$profile" == 48k-loader || "$profile" == 128k-loader ]]; then
            source_files+=(
                "$repo_root/rtl/memory/nexttang_spectrum_paging.v"
                "$repo_root/rtl/memory/nexttang_spectrum128_memory.v"
                "$repo_root/rtl/input/usb_hid_host.v"
                "$repo_root/rtl/input/usb_hid_host_dual_rom.v"
                "$repo_root/rtl/input/nexttang_usb_keyboard_matrix.v"
                "$repo_root/rtl/input/nexttang_usb_gamepad_kempston.v"
                "$repo_root/boards/console138k/nexttang_console138k_usb_pll.v"
                "$repo_root/rtl/audio/nexttang_ay8912.v"
                "$repo_root/rtl/audio/nexttang_classic_audio_pcm.v"
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
            )
            if [[ "$profile" == 48k-loader || "$profile" == 128k-loader ]]; then
                source_files+=(
                    "$repo_root/rtl/input/nexttang_load_key_sequencer.v"
                    "$repo_root/rtl/input/nexttang_post_tape_key_sequencer.v"
                    "$repo_root/rtl/input/nexttang_tzx_player.v"
                    "$repo_root/rtl/storage/nexttang_spi_byte_master.v"
                    "$repo_root/rtl/storage/nexttang_sd_spi_reader.v"
                    "$repo_root/rtl/storage/nexttang_fat32_volume.v"
                    "$repo_root/rtl/storage/nexttang_fat32_cluster_stream.v"
                    "$repo_root/rtl/storage/nexttang_fat32_directory_entry.v"
                    "$repo_root/rtl/storage/nexttang_fat32_directory.v"
                    "$repo_root/rtl/storage/nexttang_fat32_storage.v"
                    "$repo_root/rtl/loader/nexttang_async_byte_fifo.v"
                    "$repo_root/rtl/loader/nexttang_tzx_stream.v"
                    "$repo_root/rtl/loader/nexttang_tap_to_tzx_stream.v"
                    "$repo_root/rtl/loader/nexttang_classic_tape_loader.v"
                    "$repo_root/rtl/loader/nexttang_loader_catalog.v"
                    "$repo_root/rtl/loader/nexttang_loader_font.v"
                    "$repo_root/rtl/loader/nexttang_loader_overlay.v"
                )
                if [[ "$profile" == 128k-loader ]]; then
                    source_files+=("$repo_root/boards/console138k/nexttang_console138k_spectrum128_loader.v")
                else
                    source_files+=("$repo_root/boards/console138k/nexttang_console138k_spectrum48_loader.v")
                fi
            elif [[ "$profile" == 128k-usb-ddr ]]; then
                source_files+=("$repo_root/boards/console138k/nexttang_console138k_spectrum128_usb_ddr3.v")
            else
                source_files+=("$repo_root/boards/console138k/nexttang_console138k_spectrum48_usb_ddr3_audio.v")
            fi
        elif [[ "$profile" == ula-ddr-upper-tape ]]; then
            source_files+=(
                "$repo_root/rtl/input/nexttang_load_key_sequencer.v"
                "$repo_root/rtl/input/nexttang_tzx_player.v"
                "$repo_root/boards/console138k/nexttang_console138k_spectrum48_ula_ddr3_tape.v"
            )
        else
            source_files+=(
                "$repo_root/boards/console138k/nexttang_console138k_spectrum48_ula_ddr3.v"
            )
        fi
    elif [[ "$profile" == ula-tape-start-s1 ]]; then
        source_files+=(
            "$repo_root/rtl/input/nexttang_load_key_sequencer.v"
            "$repo_root/rtl/input/nexttang_post_tape_key_sequencer.v"
            "$repo_root/rtl/input/nexttang_tzx_player.v"
            "$repo_root/boards/console138k/nexttang_console138k_spectrum48_ula_tape_s1.v"
        )
    elif [[ "$profile" == ula-usb-tape ]]; then
        source_files+=(
            "$repo_root/rtl/input/nexttang_load_key_sequencer.v"
            "$repo_root/rtl/input/nexttang_tzx_player.v"
            "$repo_root/rtl/input/usb_hid_host.v"
            "$repo_root/rtl/input/usb_hid_host_dual_rom.v"
            "$repo_root/rtl/input/nexttang_usb_keyboard_matrix.v"
            "$repo_root/rtl/input/nexttang_usb_gamepad_kempston.v"
            "$repo_root/boards/console138k/nexttang_console138k_usb_pll.v"
            "$repo_root/boards/console138k/nexttang_console138k_spectrum48_ula_usb_tape.v"
        )
    elif [[ "$profile" == ula-tape ]]; then
        source_files+=(
            "$repo_root/rtl/input/nexttang_load_key_sequencer.v"
            "$repo_root/rtl/input/nexttang_tzx_player.v"
            "$repo_root/boards/console138k/nexttang_console138k_spectrum48_ula_tape.v"
        )
    elif [[ "$profile" == ula-snapshot ]]; then
        source_files+=(
            "$repo_root/rtl/input/nexttang_post_tape_key_sequencer.v"
            "$repo_root/boards/console138k/nexttang_console138k_spectrum48_ula_snapshot.v"
        )
    elif [[ "$profile" == bl616-keyboard-test ]]; then
        source_files+=(
            "$repo_root/boards/console138k/nexttang_console138k_spectrum48_bl616_keyboard_test.v"
        )
    elif [[ "$profile" == keyboard-test ]]; then
        source_files+=(
            "$repo_root/rtl/input/usb_hid_host.v"
            "$repo_root/rtl/input/usb_hid_host_dual_rom.v"
            "$repo_root/rtl/input/nexttang_usb_keyboard_matrix.v"
            "$repo_root/rtl/input/nexttang_usb_gamepad_kempston.v"
            "$repo_root/rtl/input/nexttang_usb_snapshot_uart.v"
            "$repo_root/boards/console138k/nexttang_console138k_usb_pll.v"
            "$repo_root/rtl/video/nexttang_spectrum_display.v"
            "$repo_root/boards/console138k/nexttang_console138k_spectrum48_keyboard_test.v"
        )
    else
        source_files+=(
            "$repo_root/boards/console138k/nexttang_console138k_spectrum48_ula.v"
        )
    fi
else
    source_files+=(
        "$repo_root/rtl/video/nexttang_spectrum_display.v"
        "$repo_root/boards/console138k/nexttang_console138k_spectrum48.v"
    )
fi

if ((print_sources)); then
    # Top module first, then one repository source per line, in the order Gowin
    # is given them. Vendor sources are deliberately omitted: they live outside
    # the repository and the lint blackboxes them.
    printf '%s\n' "$base_name"
    printf '%s\n' "${source_files[@]}"
    exit 0
fi

# The ULA wrapper textually includes the established Spectrum 48K top. Gowin
# only receives the wrapper as a source file, but the included top is still a
# build input and must be present in the reproducibility manifest.
hash_files=("${source_files[@]}")
hash_files+=("$pin_constraints_base" "$timing_constraints")
if [[ -n "$pin_constraints_extra" ]]; then
    hash_files+=("$pin_constraints_extra")
fi
if [[ "$profile" == spec256-snapshot || "$profile" == spec256-snapshot-audio || \
      "$profile" == spec256-loader || \
      "$profile" == spec256-loader-romview || \
      "$profile" == spec256-loader-bsrampalette || \
      "$profile" == spec256-loader-ddr3 || \
      "$profile" == spec256-runtime-audio || \
      "$profile" == spec256-snapshot-audio-chuckie || \
      "$profile" == ula || "$profile" == ula-tape || \
      "$profile" == ula-usb-tape || \
      "$profile" == ula-tape-start-s1 || \
      "$profile" == ula-snapshot || \
      "$profile" == bl616-keyboard-test || \
      "$profile" == keyboard-test || \
      "$profile" == ula-ddr-upper || \
      "$profile" == ula-ddr-upper-tape || \
      "$profile" == 48k-usb-ddr-audio || \
      "$profile" == 128k-usb-ddr || \
      "$profile" == 48k-loader || "$profile" == 128k-loader ]]; then
    hash_files+=(
        "$repo_root/boards/console138k/nexttang_console138k_spectrum48.v"
    )
fi
if [[ "$profile" == keyboard-test || "$profile" == ula-usb-tape || \
      "$profile" == 48k-usb-ddr-audio || \
      "$profile" == 128k-usb-ddr || \
      "$profile" == 48k-loader || "$profile" == 128k-loader || \
      "$profile" == spec256-loader || \
      "$profile" == spec256-loader-romview || \
      "$profile" == spec256-loader-bsrampalette || \
      "$profile" == spec256-loader-ddr3 || \
      "$profile" == spec256-runtime-audio || \
      "$profile" == spec256-snapshot || \
      "$profile" == spec256-snapshot-audio || \
      "$profile" == spec256-snapshot-audio-chuckie ]]; then
    hash_files+=("$repo_root/rtl/input/usb_hid_host_rom.mem")
fi
if [[ "$profile" == ula-ddr-upper-tape || "$profile" == ula-tape || \
      "$profile" == ula-usb-tape || \
      "$profile" == ula-tape-start-s1 ]]; then
    hash_files+=("$repo_root/scripts/tzx_to_mem.py")
fi
if [[ "$profile" == ula-snapshot || "$profile" == spec256-snapshot || \
      "$profile" == spec256-snapshot-audio || \
      "$profile" == spec256-snapshot-audio-chuckie ]]; then
    hash_files+=("$repo_root/tools/spec256/snapshot.py")
fi
if [[ "$profile" == spec256-snapshot || "$profile" == spec256-snapshot-audio || \
      "$profile" == spec256-snapshot-audio-chuckie ]]; then
    hash_files+=(
        "$repo_root/tools/spec256/gfx.py"
        "$repo_root/tools/spec256/render.py"
        "$repo_root/tools/spec256/hardware.py"
    )
fi

if [[ "$profile" == 128k-usb-ddr || "$profile" == 128k-loader ]]; then
    if [[ -z "${NEXTTANG_128K_ROM_0:-}" || ! -f "${NEXTTANG_128K_ROM_0}" || \
          -z "${NEXTTANG_128K_ROM_1:-}" || ! -f "${NEXTTANG_128K_ROM_1}" ]]; then
        printf '%s\n' 'console138k spectrum128 build: set NEXTTANG_128K_ROM_0 and NEXTTANG_128K_ROM_1 to 16K ROM images' >&2
        exit 2
    fi
    python3 "$repo_root/scripts/rom_to_mem.py" \
        "$NEXTTANG_128K_ROM_0" "$output_dir/48k.mem" \
        --expect-bytes 16384 || exit 1
    python3 "$repo_root/scripts/rom_to_mem.py" \
        "$NEXTTANG_128K_ROM_1" "$output_dir/128-1.mem" \
        --expect-bytes 16384 || exit 1
else
    if [[ -z "${NEXTTANG_48K_ROM:-}" || ! -f "${NEXTTANG_48K_ROM}" ]]; then
        printf 'console138k spectrum48 build: set NEXTTANG_48K_ROM to a 48K ROM image\n' >&2
        exit 2
    fi
    rom_image="$output_dir/48k.mem"
    python3 "$repo_root/scripts/rom_to_mem.py" "$NEXTTANG_48K_ROM" "$rom_image" \
        --expect-bytes 16384 || exit 1
fi

{
    printf 'set_device -device_version C GW5AST-LV138PG484AC1/I0\n'
    printf 'set_option -top_module %s\n' "$base_name"
    printf 'set_option -verilog_std sysv2017\n'
    printf 'set_option -output_base_name %s\n' "$base_name"
    printf 'set_option -vhdl_std vhd2008\n'
    # A plain-text timing report. The HTML one has to be tag-stripped before it
    # can be read, which is how a broken check went unnoticed for so long.
    printf 'set_option -gen_text_timing_rpt 1\n'
    if [[ "$profile" == spec256-loader-ddr3 ]]; then
        # This dense target contains one distributed 16 KiB graphical-ROM
        # lane. Let Arora V replicate its high-fanout address/decode resources
        # before routing rather than relying only on route-time fanout repair.
        printf 'set_option -replicate_resources 1\n'
    fi
    for vendor_file in "${vendor_files[@]}"; do
        printf 'add_file {%s}\n' "$vendor_file"
    done
    for source_file in "${source_files[@]}"; do
        printf 'add_file {%s}\n' "$source_file"
    done
    printf 'add_file {%s}\n' "$pin_constraints"
    printf 'add_file {%s}\n' "$timing_constraints"
    printf 'run all\n'
} >"$project_tcl"

(
    cd -- "$output_dir"
    QT_QPA_PLATFORM=${QT_QPA_PLATFORM:-offscreen} gw_sh "$project_tcl"
# Shown as it happens as well as kept. A vendor build takes minutes and a
# silent terminal gives no way to tell slow from stuck, which matters most on
# exactly the runs that are going wrong. pipefail carries gw_sh's status
# through the pipe.
) 2>&1 | tee "$build_log" || {
    printf 'console138k spectrum build: FAIL (see %s)\n' "$build_log" >&2
    exit 1
}

sha256sum "${hash_files[@]}" >"$source_hashes"
if ((${#vendor_files[@]})); then
    for vendor_file in "${vendor_files[@]}"; do
        printf '%s  %s\n' \
            "$(sha256sum "$vendor_file" | awk '{print $1}')" \
            "${vendor_file#"$vendor_source/"}"
    done >"$output_dir/vendor-source-sha256.txt"
fi

if [[ ! -f "$bitstream" ]]; then
    printf 'console138k spectrum build: no bitstream produced (see %s)\n' "$build_log" >&2
    exit 1
fi

python3 "$repo_root/scripts/check_timing.py" "$timing_report" || exit 1

printf 'console138k spectrum build: PASS\n'
printf 'bitstream: %s\n' "$bitstream"
