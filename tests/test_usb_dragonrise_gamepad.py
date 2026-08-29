"""Decode the supplied DragonRise 0079:0006 pad's real HID report layout."""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]


class UsbDragonRiseGamepadTests(unittest.TestCase):
    def test_axes_and_face_buttons_use_the_supplied_pads_report_bytes(self) -> None:
        testbench = r"""
`timescale 1ns/1ps
module testbench;
    reg clk = 0;
    wire [1:0] typ;
    wire game_l, game_r, game_u, game_d;
    wire game_a, game_b, game_x, game_y;
    wire game_sel, game_sta;
    wire [3:0] game_extra;
    wire [9:0] rom_addr;
    wire rom_en;

    usb_hid_host dut (
        .clk(clk), .reset(1'b0), .cs(1'b1),
        .usb_dm_i(1'b0), .usb_dp_i(1'b0),
        .usb_dm_o(), .usb_dp_o(), .usb_oe(),
        .typ(typ), .full_report(), .connerr(), .busy(),
        .key_modifiers(), .key_0(), .key_1(), .key_2(),
        .key_3(), .key_4(), .key_5(),
        .mouse_btn(), .mouse_dx(), .mouse_dy(),
        .game_l(game_l), .game_r(game_r),
        .game_u(game_u), .game_d(game_d),
        .game_a(game_a), .game_b(game_b),
        .game_x(game_x), .game_y(game_y),
        .game_sel(game_sel), .game_sta(game_sta),
        .game_extra(game_extra),
        .dbg_hid_report(), .dbg_hid_regs(),
        .dbg_byte_strobe(), .dbg_packet_valid(),
        .dbg_config_snapshot(), .dbg_config_snapshot_valid(),
        .dbg_full_speed(), .dbg_speed_sample(),
        .rom_addr(rom_addr), .rom_dout(4'b0), .rom_en(rom_en)
    );

    task expect_controls;
        input [7:0] expected;
        begin
            #1;
            if ({game_y, game_x, game_b, game_a,
                 game_d, game_u, game_r, game_l} !== expected)
                $fatal(1, "controls were %08b, expected %08b",
                       {game_y, game_x, game_b, game_a,
                        game_d, game_u, game_r, game_l}, expected);
        end
    endtask

    initial begin
        // Captured idle report: 7f 7f 00 80 80 0f 00 00.
        // This pad exposes the primary X/Y axes in bytes 0/1 and its first
        // eight buttons in byte 2. Bytes 3/4 are the secondary axes.
        dut.typ = 2'd3;
        dut.regs[0] = 8'h79;
        dut.regs[1] = 8'h00;
        dut.regs[2] = 8'h06;
        dut.regs[3] = 8'h00;
        dut.dat[0] = 8'h7f;
        dut.dat[1] = 8'h7f;
        dut.dat[2] = 8'h00;
        dut.dat[3] = 8'h80;
        dut.dat[4] = 8'h80;
        dut.dat[5] = 8'h0f;
        dut.dat[6] = 8'h00;
        dut.dat[7] = 8'h00;
        expect_controls(8'b00000000);

        dut.dat[0] = 8'h00;
        expect_controls(8'b00000001);
        dut.dat[0] = 8'hff;
        expect_controls(8'b00000010);
        dut.dat[0] = 8'h7f;

        dut.dat[1] = 8'h00;
        expect_controls(8'b00000100);
        dut.dat[1] = 8'hff;
        expect_controls(8'b00001000);
        dut.dat[1] = 8'h7f;

        // SDL's established mapping for 0079:0006 is
        // Y/B/A/X = button indices 0/1/2/3.
        dut.dat[2] = 8'b00000001;
        expect_controls(8'b10000000);
        dut.dat[2] = 8'b00000010;
        expect_controls(8'b00100000);
        dut.dat[2] = 8'b00000100;
        expect_controls(8'b00010000);
        dut.dat[2] = 8'b00001000;
        expect_controls(8'b01000000);
    end
endmodule
"""
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)
            source = work / "testbench.v"
            output = work / "testbench.out"
            source.write_text(testbench, encoding="utf-8")
            compile_result = subprocess.run(
                [
                    "iverilog",
                    "-g2012",
                    "-o",
                    str(output),
                    str(REPO_ROOT / "rtl/input/usb_hid_host.v"),
                    str(source),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                compile_result.returncode,
                0,
                compile_result.stdout + compile_result.stderr,
            )
            result = subprocess.run(
                ["vvp", str(output)], check=False, capture_output=True, text=True
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
