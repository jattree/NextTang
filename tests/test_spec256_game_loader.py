"""Behavioural regressions for the runtime Spec256 game-pack loader."""

from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
import zlib


REPO_ROOT = Path(__file__).resolve().parents[1]
LOADER_RTL = REPO_ROOT / "rtl" / "input" / "nexttang_spec256_game_loader.v"

BASE_PAYLOAD_BYTES = 590_592
BACKGROUND_BYTES = 64_000
HEADER = struct.Struct("<8sHHIIB4BHHHB")


def make_pack(
    *,
    corrupt_crc: bool = False,
    backgrounds: int = 0,
    claim_backgrounds: int | None = None,
) -> bytes:
    """Build a version 2 pack.

    `claim_backgrounds` lets a test declare a count that disagrees with the
    bytes actually present, which is what a truncated transfer looks like.
    """
    length = BASE_PAYLOAD_BYTES + backgrounds * BACKGROUND_BYTES
    payload = bytes(index & 0xFF for index in range(length))
    crc = zlib.crc32(payload)
    if corrupt_crc:
        crc ^= 1
    header = HEADER.pack(
        b"NTSP256\0",
        2,
        HEADER.size,
        len(payload),
        crc,
        2,
        18,
        19,
        0,
        0,
        2000,
        140,
        300,
        backgrounds if claim_backgrounds is None else claim_backgrounds,
    )
    return header + payload


class Spec256GameLoaderTests(unittest.TestCase):
    def run_loader(
        self,
        pack: bytes,
        *,
        truncate: int = 0,
        expected_loads: int = 0,
        expect_fault: bool = False,
        stored_background_bytes: int = 0,
    ) -> subprocess.CompletedProcess[str]:
        testbench = r"""
`timescale 1ns/1ps
module testbench;
    localparam integer STREAM_BYTES = __STREAM_BYTES__;
    reg clock = 0;
    reg reset = 1;
    reg [7:0] stream [0:STREAM_BYTES-1];
    reg [7:0] byte_data = 0;
    reg byte_valid = 0;
    wire hold_reset, ready, fault;
    wire boot_we;
    wire [13:0] boot_address;
    wire main_we;
    wire [15:0] main_address;
    wire [7:0] graphics_ram_we;
    wire [15:0] graphics_ram_address;
    wire [7:0] graphics_rom_we;
    wire [13:0] graphics_rom_address;
    wire palette_we;
    wire [7:0] palette_index;
    wire [23:0] palette_data;
    wire [7:0] write_data;
    wire background_we;
    wire [15:0] background_address;
    wire background_valid;
    integer background_count = 0;
    wire [2:0] launch_key_count;
    wire [7:0] launch_key_0, launch_key_1, launch_key_2, launch_key_3;
    wire [15:0] launch_start_delay_ms, launch_hold_ms, launch_gap_ms;

    integer index;
    integer boot_count = 0;
    integer main_count = 0;
    integer graphics_ram_count = 0;
    integer graphics_rom_count = 0;
    integer palette_count = 0;

    always #5 clock = !clock;

    nexttang_spec256_game_loader dut (
        .clock(clock), .reset(reset),
        .byte_data(byte_data), .byte_valid(byte_valid),
        .hold_reset(hold_reset), .ready(ready), .fault(fault),
        .boot_write_enable(boot_we), .boot_write_address(boot_address),
        .main_write_enable(main_we), .main_write_address(main_address),
        .graphics_ram_write_enable(graphics_ram_we),
        .graphics_ram_write_address(graphics_ram_address),
        .graphics_rom_write_enable(graphics_rom_we),
        .graphics_rom_write_address(graphics_rom_address),
        .palette_write_enable(palette_we), .palette_write_index(palette_index),
        .palette_write_data(palette_data),
        .background_write_enable(background_we),
        .background_write_address(background_address),
        .background_valid(background_valid),
        .write_data(write_data),
        .launch_key_count(launch_key_count),
        .launch_key_0(launch_key_0), .launch_key_1(launch_key_1),
        .launch_key_2(launch_key_2), .launch_key_3(launch_key_3),
        .launch_start_delay_ms(launch_start_delay_ms),
        .launch_hold_ms(launch_hold_ms), .launch_gap_ms(launch_gap_ms)
    );

    always @(posedge clock) begin
        if (background_we) begin
            if (background_address !== background_count[15:0])
                $fatal(1, "background address %h at count %0d",
                       background_address, background_count);
            background_count <= background_count + 1;
        end
        if (boot_we) begin
            if (boot_address !== boot_count[13:0])
                $fatal(1, "boot address %h at count %0d", boot_address, boot_count);
            boot_count <= boot_count + 1;
        end
        if (main_we) begin
            if (main_address !== (16'h4000 + (main_count % 49152)))
                $fatal(1, "main address %h at count %0d", main_address, main_count);
            main_count <= main_count + 1;
        end
        if (|graphics_ram_we) begin
            if (graphics_ram_we !==
                (8'b1 << ((graphics_ram_count % 393216) / 49152)))
                $fatal(1, "graphics RAM lane %b at count %0d", graphics_ram_we, graphics_ram_count);
            if (graphics_ram_address !== (16'h4000 + (graphics_ram_count % 49152)))
                $fatal(1, "graphics RAM address %h at count %0d", graphics_ram_address, graphics_ram_count);
            graphics_ram_count <= graphics_ram_count + 1;
        end
        if (|graphics_rom_we) begin
            if (graphics_rom_we !==
                (8'b1 << ((graphics_rom_count % 131072) / 16384)))
                $fatal(1, "graphics ROM lane %b at count %0d", graphics_rom_we, graphics_rom_count);
            if (graphics_rom_address !== (graphics_rom_count % 16384))
                $fatal(1, "graphics ROM address %h at count %0d", graphics_rom_address, graphics_rom_count);
            graphics_rom_count <= graphics_rom_count + 1;
        end
        if (palette_we) begin
            if (palette_index !== palette_count[7:0])
                $fatal(1, "palette index %h at count %0d", palette_index, palette_count);
            palette_count <= palette_count + 1;
        end
    end

    initial begin
        $readmemh("pack.hex", stream);
        repeat (3) @(posedge clock);
        reset = 0;
        if (!hold_reset || ready || fault)
            $fatal(1, "invalid reset state");
        for (index = 0; index < STREAM_BYTES; index = index + 1) begin
            @(negedge clock);
            byte_data = stream[index];
            byte_valid = 1;
            @(negedge clock);
            byte_valid = 0;
        end
        repeat (3) @(posedge clock);
        if (__EXPECT_READY__) begin
            if (!ready || hold_reset || fault)
                $fatal(1, "valid pack did not release: ready=%b hold=%b fault=%b", ready, hold_reset, fault);
            if (boot_count != 16384 * __LOAD_COUNT__ ||
                main_count != 49152 * __LOAD_COUNT__ ||
                graphics_ram_count != 393216 * __LOAD_COUNT__ ||
                graphics_rom_count != 131072 * __LOAD_COUNT__ ||
                palette_count != 256 * __LOAD_COUNT__ ||
                background_count != __BACKGROUND_BYTES__ * __LOAD_COUNT__)
                $fatal(1, "wrong write counts %0d %0d %0d %0d %0d %0d",
                       boot_count, main_count, graphics_ram_count,
                       graphics_rom_count, palette_count, background_count);
            if (background_valid !== (__BACKGROUND_BYTES__ != 0))
                $fatal(1, "background_valid=%b for %0d stored bytes",
                       background_valid, __BACKGROUND_BYTES__);
            if (launch_key_count != 2 || launch_key_0 != 18 || launch_key_1 != 19 ||
                launch_start_delay_ms != 2000 || launch_hold_ms != 140 ||
                launch_gap_ms != 300)
                $fatal(1, "launch metadata mismatch");
        end else if (!hold_reset || ready || (__EXPECT_FAULT__ && !fault)) begin
            $fatal(1, "invalid pack escaped: ready=%b hold=%b fault=%b", ready, hold_reset, fault);
        end
        $finish;
    end
endmodule
"""
        stream = pack[: len(pack) - truncate if truncate else len(pack)]
        testbench = (
            testbench.replace("__STREAM_BYTES__", str(len(stream)))
            .replace("__EXPECT_READY__", "1" if expected_loads else "0")
            .replace("__EXPECT_FAULT__", "1" if expect_fault else "0")
            .replace("__LOAD_COUNT__", str(expected_loads))
            .replace("__BACKGROUND_BYTES__", str(stored_background_bytes))
        )
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            (root / "pack.hex").write_text(
                "\n".join(f"{byte:02x}" for byte in stream) + "\n",
                encoding="ascii",
            )
            testbench_path = root / "testbench.v"
            simulation = root / "simulation"
            testbench_path.write_text(testbench, encoding="ascii")
            compile_result = subprocess.run(
                ["iverilog", "-g2012", "-o", simulation, LOADER_RTL, testbench_path],
                cwd=root, check=False, capture_output=True, text=True,
            )
            self.assertEqual(compile_result.returncode, 0, compile_result.stderr)
            return subprocess.run(
                ["vvp", simulation], cwd=root, check=False,
                capture_output=True, text=True,
            )

    def test_complete_pack_maps_every_region_and_releases_reset(self) -> None:
        result = self.run_loader(make_pack(), expected_loads=1)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_bad_crc_never_releases_reset(self) -> None:
        result = self.run_loader(make_pack(corrupt_crc=True), expect_fault=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_truncated_pack_never_releases_reset(self) -> None:
        result = self.run_loader(make_pack(), truncate=1)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_one_background_is_stored_and_marked_valid(self) -> None:
        result = self.run_loader(
            make_pack(backgrounds=1), expected_loads=1,
            stored_background_bytes=64_000,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_extra_backgrounds_are_checked_but_only_the_first_is_stored(self) -> None:
        """Four backgrounds is Knight Lore; the device holds one."""
        result = self.run_loader(
            make_pack(backgrounds=4), expected_loads=1,
            stored_background_bytes=64_000,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_a_count_that_disagrees_with_the_length_is_refused(self) -> None:
        result = self.run_loader(
            make_pack(backgrounds=1, claim_backgrounds=2), expect_fault=True
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_more_backgrounds_than_the_format_allows_is_refused(self) -> None:
        result = self.run_loader(
            make_pack(backgrounds=0, claim_backgrounds=9), expect_fault=True
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_second_pack_rearms_same_core_without_fpga_reset(self) -> None:
        pack = make_pack()
        result = self.run_loader(pack + pack, expected_loads=2)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
