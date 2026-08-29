"""Behavioural proof for lane-local Spec256 memory and I/O reads."""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]


class Spec256InputMuxTests(unittest.TestCase):
    def test_graphical_lane_decodes_its_own_keyboard_port_address(self) -> None:
        testbench = r"""
`timescale 1ns/1ps
module testbench;
    reg [15:0] address;
    reg io_request;
    reg [39:0] keys;
    reg [4:0] joystick;
    reg tape_ear;
    reg [7:0] rom_data;
    reg [7:0] ram_data;
    wire [7:0] data;

    nexttang_spec256_input_mux dut (
        .address(address), .io_request(io_request), .keys(keys),
        .joystick(joystick), .tape_ear(tape_ear),
        .rom_data(rom_data), .ram_data(ram_data),
        .data(data)
    );

    initial begin
        keys = 40'b0;
        joystick = 5'b11001;
        tape_ear = 1'b0;
        rom_data = 8'h12;
        ram_data = 8'h34;

        io_request = 1'b0; address = 16'h1234; #1;
        if (data !== 8'h12) $fatal(1, "graphical ROM read used wrong source");

        address = 16'h8000; #1;
        if (data !== 8'h34) $fatal(1, "graphical RAM read used wrong source");

        io_request = 1'b1; address = 16'hffff; #1;
        if (data !== 8'hff) $fatal(1, "unknown graphical I/O read was not ff");

        address = 16'h001f; #1;
        if (data !== 8'h19)
            $fatal(1, "graphical Kempston read did not use shared joystick: %02x", data);

        // FE in the high byte selects keyboard row zero. Press its first key.
        keys[0] = 1'b1;
        address = 16'hfefe; #1;
        if (data !== 8'hbe)
            $fatal(1, "graphical keyboard read did not use lane address: %02x", data);

        tape_ear = 1'b1; #1;
        if (data !== 8'hfe) $fatal(1, "graphical EAR input was not shared");
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
                    "iverilog", "-g2012", "-o", str(output),
                    str(REPO_ROOT / "rtl/input/nexttang_keyboard_matrix.v"),
                    str(REPO_ROOT / "rtl/input/nexttang_spec256_input_mux.v"),
                    str(source),
                ],
                check=False, capture_output=True, text=True,
            )
            self.assertEqual(
                compile_result.returncode, 0,
                compile_result.stdout + compile_result.stderr,
            )
            result = subprocess.run(
                ["vvp", str(output)], check=False, capture_output=True, text=True
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
