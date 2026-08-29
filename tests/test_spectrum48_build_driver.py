"""Contract tests for the Console 138K Spectrum 48K build driver."""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
BUILD_DRIVER = REPO_ROOT / "boards" / "console138k" / "build_spectrum48.sh"


class Spectrum48BuildDriverTests(unittest.TestCase):
    def run_driver(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(BUILD_DRIVER), *arguments],
            cwd=REPO_ROOT,
            check=False,
            capture_output=True,
            text=True,
        )

    def test_help_lists_all_profiles(self) -> None:
        result = self.run_driver("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "--profile release|ula|ula-tape|ula-tape-start-s1|ula-snapshot|spec256-snapshot|spec256-snapshot-audio|spec256-snapshot-audio-chuckie|spec256-runtime-audio|bl616-keyboard-test|keyboard-test|ula-ddr-upper|ula-ddr-upper-tape",
            result.stdout,
        )

    def test_spec256_runtime_profile_has_no_game_build_inputs(self) -> None:
        source = BUILD_DRIVER.read_text(encoding="utf-8")
        top = (
            REPO_ROOT
            / "boards"
            / "console138k"
            / "nexttang_console138k_spectrum48.v"
        )
        wrapper = (
            REPO_ROOT
            / "boards"
            / "console138k"
            / "nexttang_console138k_spectrum48_spec256_runtime_audio.sv"
        )
        runtime_pins = (
            REPO_ROOT
            / "boards"
            / "console138k"
            / "console138k_spectrum48_spec256_runtime_extra.cst"
        )
        runtime_timing = (
            REPO_ROOT
            / "boards"
            / "console138k"
            / "console138k_spectrum48_spec256_runtime.sdc"
        )

        self.assertIn("spec256-runtime-audio", source)
        self.assertIn("nexttang_spec256_game_loader.v", source)
        self.assertIn("nexttang_spec256_runtime_key_sequencer.v", source)
        self.assertIn("nexttang_spec256_runtime_input.v", source)
        self.assertIn(wrapper.name, source)
        wrapper_source = wrapper.read_text(encoding="utf-8")
        self.assertIn("NEXTTANG_SPEC256_RUNTIME", wrapper_source)
        self.assertIn("NEXTTANG_HDMI_AUDIO", wrapper_source)
        self.assertIn(runtime_pins.name, source)
        self.assertIn(
            'IO_LOC "game_pack_uart_rx" G21;',
            runtime_pins.read_text(encoding="utf-8"),
        )
        self.assertIn(
            '/IO_LOC "loopback_uart_rx"/ { next }',
            source,
            "the runtime constraint merge must release G21 from diagnostics",
        )
        self.assertIn(
            '/IO_PORT "loopback_uart_rx"/ { next }',
            source,
            "the runtime top has no diagnostic loopback port",
        )
        timing_source = runtime_timing.read_text(encoding="utf-8")
        self.assertIn("keyboard_keys_meta*", timing_source)
        self.assertNotIn("keyboard_scancode_meta*", timing_source)
        self.assertNotIn("keyboard_debug_meta*", timing_source)
        self.assertIn(
            ".receive(game_pack_uart_rx)",
            top.read_text(encoding="utf-8"),
        )
        self.assertIn(
            "nexttang_spec256_runtime_input runtime_input",
            top.read_text(encoding="utf-8"),
        )

    def test_spec256_runtime_uses_one_margin_safe_full_duplex_baud(self) -> None:
        top_source = (
            REPO_ROOT
            / "boards"
            / "console138k"
            / "nexttang_console138k_spectrum48.v"
        ).read_text(encoding="utf-8")
        uploader_source = (
            REPO_ROOT / "tools" / "spec256" / "load_gamepack.py"
        ).read_text(encoding="utf-8")

        self.assertIn("RUNTIME_UART_BAUD = 230400", top_source)
        self.assertIn(".BAUD_RATE(RUNTIME_UART_BAUD)", top_source)
        self.assertIn("UART_BAUD = 230_400", uploader_source)
        self.assertNotIn("STATUS_BAUD", uploader_source)

    def test_post_tape_s_profile_uses_the_optional_key_sequencer(self) -> None:
        source = BUILD_DRIVER.read_text(encoding="utf-8")
        top = (
            REPO_ROOT
            / "boards"
            / "console138k"
            / "nexttang_console138k_spectrum48.v"
        )
        wrapper = (
            REPO_ROOT
            / "boards"
            / "console138k"
            / "nexttang_console138k_spectrum48_ula_tape_s1.v"
        )

        self.assertIn('"$profile" != ula-tape-start-s1', source)
        self.assertIn("nexttang_post_tape_key_sequencer.v", source)
        self.assertIn(wrapper.name, source)
        self.assertIn(
            "NEXTTANG_SPECTRUM48_POST_TAPE_S1",
            wrapper.read_text(encoding="utf-8"),
        )
        self.assertIn(
            ".GAP_MS(4000)",
            top.read_text(encoding="utf-8"),
            "Chuckie Egg needs time to draw its player-count prompt after S",
        )

    def test_snapshot_profile_generates_private_ram_and_boot_images(self) -> None:
        source = BUILD_DRIVER.read_text(encoding="utf-8")
        wrapper = (
            REPO_ROOT
            / "boards"
            / "console138k"
            / "nexttang_console138k_spectrum48_ula_snapshot.v"
        )

        self.assertIn("--snapshot ABSOLUTE_SNA", source)
        self.assertIn("tools/spec256/snapshot.py", source)
        self.assertIn("snapshot-ram.mem", source)
        self.assertIn("snapshot-boot.mem", source)
        self.assertIn("nexttang_post_tape_key_sequencer.v", source)
        self.assertIn(wrapper.name, source)
        self.assertIn(
            "NEXTTANG_SPECTRUM48_USE_SNAPSHOT",
            wrapper.read_text(encoding="utf-8"),
        )
        top_source = (
            REPO_ROOT
            / "boards"
            / "console138k"
            / "nexttang_console138k_spectrum48.v"
        ).read_text(encoding="utf-8")
        self.assertIn(".KEY_ROW(3)", top_source)
        self.assertIn(".KEY_COLUMN(4)", top_source)

    def test_spec256_profile_requires_and_converts_private_graphics(self) -> None:
        source = BUILD_DRIVER.read_text(encoding="utf-8")
        wrapper = (
            REPO_ROOT
            / "boards"
            / "console138k"
            / "nexttang_console138k_spectrum48_spec256_snapshot.v"
        )

        self.assertIn('"$profile" != spec256-snapshot', source)
        self.assertIn("--gfx ABSOLUTE_GFX", source)
        self.assertIn("--palette ABSOLUTE_PALETTE", source)
        self.assertIn("tools/spec256/hardware.py", source)
        self.assertIn("spec256-ram.mem", source)
        self.assertIn("spec256-palette.mem", source)
        self.assertIn("nexttang_spec256_cpu_cluster.vhd", source)
        self.assertIn("nexttang_spec256_display.v", source)
        self.assertIn("console138k_spectrum48_spec256.sdc", source)
        self.assertIn(wrapper.name, source)
        wrapper_source = wrapper.read_text(encoding="utf-8")
        self.assertIn("NEXTTANG_SPECTRUM48_USE_SPEC256", wrapper_source)
        self.assertNotIn("NEXTTANG_SPECTRUM48_USE_ULA", wrapper_source)

    def test_spec256_audio_profile_is_isolated_from_the_video_only_target(self) -> None:
        source = BUILD_DRIVER.read_text(encoding="utf-8")
        wrapper = (
            REPO_ROOT
            / "boards"
            / "console138k"
            / "nexttang_console138k_spectrum48_spec256_snapshot_audio.sv"
        )

        self.assertIn("spec256-snapshot-audio", source)
        self.assertIn("nexttang_beeper_pcm.v", source)
        self.assertIn("rtl/video/hdmi/hdmi.sv", source)
        self.assertIn("nexttang_gowin_hdmi_serializer.sv", source)
        self.assertIn(wrapper.name, source)
        wrapper_source = wrapper.read_text(encoding="utf-8")
        self.assertIn("NEXTTANG_HDMI_AUDIO", wrapper_source)
        self.assertIn("NEXTTANG_SPECTRUM48_USE_SPEC256", wrapper_source)

    def test_spec256_chuckie_profile_uses_s_then_one_autostart(self) -> None:
        source = BUILD_DRIVER.read_text(encoding="utf-8")
        top_source = (
            REPO_ROOT
            / "boards"
            / "console138k"
            / "nexttang_console138k_spectrum48.v"
        ).read_text(encoding="utf-8")
        wrapper = (
            REPO_ROOT
            / "boards"
            / "console138k"
            / "nexttang_console138k_spectrum48_spec256_snapshot_audio_chuckie.sv"
        )

        self.assertIn("spec256-snapshot-audio-chuckie", source)
        self.assertIn(wrapper.name, source)
        wrapper_source = wrapper.read_text(encoding="utf-8")
        self.assertIn("NEXTTANG_SPEC256_AUTOSTART_CHUCKIE", wrapper_source)
        self.assertIn("NEXTTANG_HDMI_AUDIO", wrapper_source)
        self.assertIn("NEXTTANG_SPECTRUM48_USE_SPEC256", wrapper_source)
        self.assertIn(".KEY_ROW(1)", top_source)
        self.assertIn(".KEY_COLUMN(1)", top_source)
        self.assertIn(".SECOND_KEY_ROW(3)", top_source)
        self.assertIn(".SECOND_KEY_COLUMN(0)", top_source)

    def test_bl616_keyboard_profile_uses_mcu_uart_without_fabric_usb(self) -> None:
        source = BUILD_DRIVER.read_text(encoding="utf-8")
        wrapper = (
            REPO_ROOT
            / "boards"
            / "console138k"
            / "nexttang_console138k_spectrum48_bl616_keyboard_test.v"
        )

        self.assertIn('"$profile" != bl616-keyboard-test', source)
        self.assertIn(wrapper.name, source)
        wrapper_source = wrapper.read_text(encoding="utf-8")
        self.assertIn("NEXTTANG_SPECTRUM48_KEYBOARD_DIAGNOSTIC", wrapper_source)
        self.assertNotIn("NEXTTANG_SPECTRUM48_USB_KEYBOARD", wrapper_source)

    def test_keyboard_test_profile_has_a_dedicated_instrumented_top(self) -> None:
        source = BUILD_DRIVER.read_text(encoding="utf-8")
        self.assertIn('"$profile" != keyboard-test', source)
        self.assertIn(
            "nexttang_console138k_spectrum48_keyboard_test.v",
            source,
        )
        self.assertIn(
            "nexttang_console138k_spectrum48_keyboard_test",
            source,
        )

    def test_ddr_profile_requires_explicit_vendor_source(self) -> None:
        result = self.run_driver(
            "--toolchain",
            "vendor",
            "--profile",
            "ula-ddr-upper",
            "--output",
            "/tmp/nexttang-unused-build-output",
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("requires --vendor-source ABSOLUTE_DIRECTORY", result.stderr)

    def test_rejects_relative_output_before_running_vendor_tools(self) -> None:
        result = self.run_driver(
            "--toolchain",
            "vendor",
            "--profile",
            "ula",
            "--output",
            "relative/output",
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("--output must be an absolute path", result.stderr)

    def test_ula_manifest_hashes_textually_included_top(self) -> None:
        source = BUILD_DRIVER.read_text(encoding="utf-8")
        self.assertIn('hash_files=("${source_files[@]}")', source)
        self.assertIn(
            'hash_files+=(\n'
            '        "$repo_root/boards/console138k/'
            'nexttang_console138k_spectrum48.v"',
            source,
        )
        self.assertIn('sha256sum "${hash_files[@]}"', source)

    def test_ddr_profile_combines_constraints_and_hashes_vendor_inputs(self) -> None:
        source = BUILD_DRIVER.read_text(encoding="utf-8")
        self.assertIn("console138k_spectrum48_ula_ddr3_extra.cst", source)
        self.assertIn('>"$pin_constraints"', source)
        self.assertIn('printf \'add_file {%s}\\n\' "$pin_constraints"', source)
        self.assertIn("vendor-source-sha256.txt", source)

    def test_tape_profile_requires_absolute_user_supplied_input(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            vendor = root / "vendor"
            for relative in (
                "ddr3_memory_interface/ddr3_memory_interface.v",
                "gowin_pll/gowin_pll.v",
                "gowin_pll/gowin_pll_mod.v",
                "pll_init.v",
            ):
                path = vendor / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("// test\n", encoding="utf-8")

            result = self.run_driver(
                "--toolchain",
                "vendor",
                "--profile",
                "ula-ddr-upper-tape",
                "--vendor-source",
                str(vendor),
                "--tape",
                "relative/Cobra.tzx",
                "--output",
                str(root / "unused"),
            )

        self.assertEqual(result.returncode, 2)
        self.assertIn("requires --tape ABSOLUTE_TZX_OR_ZIP", result.stderr)

    def test_internal_ram_tape_profile_needs_a_tape_but_no_vendor_source(
        self,
    ) -> None:
        # The control for the DDR tape target takes the same user tape without
        # any generated vendor memory controller, so it must fail on a missing
        # tape rather than on a missing vendor source.
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            result = self.run_driver(
                "--toolchain",
                "vendor",
                "--profile",
                "ula-tape",
                "--output",
                str(root / "unused"),
            )

        self.assertEqual(result.returncode, 2)
        self.assertIn("requires --tape ABSOLUTE_TZX_OR_ZIP", result.stderr)

    def test_tape_profile_records_converter_and_input_manifest(self) -> None:
        source = BUILD_DRIVER.read_text(encoding="utf-8")
        self.assertIn("scripts/tzx_to_mem.py", source)
        self.assertIn("tape-input-sha256.txt", source)
        self.assertIn("nexttang_tzx_player.v", source)
        self.assertIn(
            "nexttang_console138k_spectrum48_ula_ddr3_tape.v",
            source,
        )

    def test_driver_pins_exact_console_device_and_checks_timing(self) -> None:
        source = BUILD_DRIVER.read_text(encoding="utf-8")
        self.assertIn(
            "set_device -device_version C GW5AST-LV138PG484AC1/I0",
            source,
        )
        self.assertIn("scripts/check_timing.py", source)


if __name__ == "__main__":
    unittest.main()
