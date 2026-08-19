"""Behavioural tests for the BL616 keyboard path.

A USB keyboard on the board's USB-A ports is read by the factory TangCore
firmware on the BL616, which sends PS/2 scan codes to the FPGA over a UART.
These cover the three pieces that turns into key matrix bits.
"""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
RECEIVER_RTL = REPO_ROOT / "rtl" / "input" / "nexttang_uart_receiver.v"
KEYBOARD_RTL = REPO_ROOT / "rtl" / "input" / "nexttang_bl616_keyboard.v"
MATRIX_RTL = REPO_ROOT / "rtl" / "input" / "nexttang_ps2_matrix.v"
KEY_MATRIX_RTL = REPO_ROOT / "rtl" / "input" / "nexttang_keyboard_matrix.v"


def run(testbench: str, *sources: Path) -> str:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        (root / "testbench.v").write_text(testbench, encoding="utf-8")
        build = subprocess.run(
            ["iverilog", "-g2012", "-o", str(root / "sim"),
             str(root / "testbench.v"), *[str(s) for s in sources]],
            cwd=root, capture_output=True, text=True, check=False)
        if build.returncode:
            raise AssertionError(build.stdout + build.stderr)
        result = subprocess.run([str(root / "sim")], cwd=root,
                                capture_output=True, text=True, check=False)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)
        return result.stdout


class UartReceiverTests(unittest.TestCase):
    def test_receives_a_byte_at_the_configured_baud(self) -> None:
        # Ten clocks per bit keeps the simulation short while still exercising
        # the mid-bit sampling.
        testbench = r"""
`timescale 1ns/1ps
module testbench;
    reg clock = 0;
    reg reset = 1;
    reg line = 1;
    wire [7:0] data;
    wire data_valid;
    integer i;
    integer received = 0;
    reg [7:0] last = 0;

    always #5 clock = ~clock;

    nexttang_uart_receiver #(.CLOCK_HZ(1000), .BAUD_RATE(100)) dut (
        .clock(clock), .reset(reset), .receive(line),
        .data(data), .data_valid(data_valid)
    );

    always @(posedge clock) if (data_valid) begin
        received = received + 1;
        last = data;
    end

    task send(input [7:0] value);
        integer b;
        begin
            line = 0;                       // start bit
            repeat (10) @(posedge clock);
            for (b = 0; b < 8; b = b + 1) begin
                line = value[b];            // least significant first
                repeat (10) @(posedge clock);
            end
            line = 1;                       // stop bit
            repeat (10) @(posedge clock);
        end
    endtask

    initial begin
        repeat (4) @(posedge clock);
        reset = 0;
        repeat (4) @(posedge clock);
        send(8'h5a);
        send(8'ha5);
        repeat (40) @(posedge clock);
        if (received != 2)
            $fatal(1, "expected two bytes, saw %0d", received);
        if (last !== 8'ha5)
            $fatal(1, "second byte was %02x", last);
        $display("UART_PASS received=%0d last=%02x", received, last);
        $finish;
    end
endmodule
"""
        self.assertIn("UART_PASS received=2 last=a5", run(testbench, RECEIVER_RTL))


class Bl616KeyboardTests(unittest.TestCase):
    def frame_testbench(self, body: str, expect: str) -> str:
        return r"""
`timescale 1ns/1ps
module testbench;
    reg clock = 0;
    reg reset = 1;
    reg line = 1;
    wire [7:0] scancode;
    wire scancode_valid;
    integer i;
    integer count = 0;
    reg [7:0] codes [0:15];

    always #5 clock = ~clock;

    nexttang_bl616_keyboard #(.CLOCK_HZ(1000), .BAUD_RATE(100)) dut (
        .clock(clock), .reset(reset), .receive(line),
        .scancode(scancode), .scancode_valid(scancode_valid)
    );

    always @(posedge clock) if (scancode_valid) begin
        codes[count] = scancode;
        count = count + 1;
    end

    task send(input [7:0] value);
        integer b;
        begin
            line = 0;
            repeat (10) @(posedge clock);
            for (b = 0; b < 8; b = b + 1) begin
                line = value[b];
                repeat (10) @(posedge clock);
            end
            line = 1;
            repeat (10) @(posedge clock);
        end
    endtask

    initial begin
        repeat (4) @(posedge clock);
        reset = 0;
        repeat (4) @(posedge clock);
""" + body + r"""
        repeat (60) @(posedge clock);
""" + expect + r"""
        $finish;
    end
endmodule
"""

    def test_scancode_frame_yields_its_bytes(self) -> None:
        body = """
        send(8'haa); send(8'h00); send(8'h03);   // sync, length 3
        send(8'h0c);                             // command: scan codes
        send(8'h1c); send(8'h4d);                // two codes
"""
        expect = """
        if (count != 2) $fatal(1, "expected two codes, saw %0d", count);
        if (codes[0] !== 8'h1c || codes[1] !== 8'h4d)
            $fatal(1, "codes were %02x %02x", codes[0], codes[1]);
        $display("FRAME_PASS count=%0d", count);
"""
        output = run(self.frame_testbench(body, expect), KEYBOARD_RTL, RECEIVER_RTL)
        self.assertIn("FRAME_PASS count=2", output)

    def test_other_commands_are_skipped_without_losing_sync(self) -> None:
        # An overlay text frame must be counted past, or the scan codes in the
        # next frame would be read as part of it.
        body = """
        send(8'haa); send(8'h00); send(8'h03);
        send(8'h04); send(8'h05); send(8'h06);   // move cursor, not keys
        send(8'haa); send(8'h00); send(8'h02);
        send(8'h0c); send(8'h29);                // then a real scan code
"""
        expect = """
        if (count != 1) $fatal(1, "expected one code, saw %0d", count);
        if (codes[0] !== 8'h29) $fatal(1, "code was %02x", codes[0]);
        $display("SKIP_PASS count=%0d code=%02x", count, codes[0]);
"""
        output = run(self.frame_testbench(body, expect), KEYBOARD_RTL, RECEIVER_RTL)
        self.assertIn("SKIP_PASS count=1 code=29", output)


class Ps2MatrixTests(unittest.TestCase):
    def run_codes(self, codes: str, checks: str) -> str:
        testbench = r"""
`timescale 1ns/1ps
module testbench;
    reg clock = 0;
    reg reset = 1;
    reg [7:0] code = 0;
    reg valid = 0;
    wire [39:0] keys;

    always #5 clock = ~clock;

    nexttang_ps2_matrix dut (
        .clock(clock), .reset(reset),
        .scancode(code), .scancode_valid(valid), .keys(keys)
    );

    // Driven on the falling edge so the design sees exactly one rising edge
    // with the strobe high. Driving on the rising edge races it and the code
    // gets sampled twice, which re-presses a key straight after its release.
    task press(input [7:0] value);
        begin
            @(negedge clock); code = value; valid = 1;
            @(negedge clock); valid = 0;
            @(negedge clock);
        end
    endtask

    initial begin
        repeat (2) @(posedge clock);
        reset = 0;
        repeat (2) @(posedge clock);
""" + codes + r"""
        #1;
""" + checks + r"""
        $finish;
    end
endmodule
"""
        return run(testbench, MATRIX_RTL)

    def test_a_letter_presses_and_releases_its_matrix_bit(self) -> None:
        # A is row 1 column 0, so bit 5.
        output = self.run_codes(
            "        press(8'h1c);",
            """
        if (keys[5] !== 1'b1) $fatal(1, "A did not press, keys=%010x", keys);
        if (keys != 40'h20) $fatal(1, "other keys moved, keys=%010x", keys);
        $display("PRESS_PASS keys=%010x", keys);
""")
        self.assertIn("PRESS_PASS", output)

        output = self.run_codes(
            "        press(8'h1c); press(8'hf0); press(8'h1c);",
            """
        if (keys != 0) $fatal(1, "A did not release, keys=%010x", keys);
        $display("RELEASE_PASS keys=%010x", keys);
""")
        self.assertIn("RELEASE_PASS", output)

    def test_enter_and_shift_land_on_the_right_bits(self) -> None:
        # ENTER is row 6 column 0 (bit 30), caps shift is bit 0.
        output = self.run_codes(
            "        press(8'h5a); press(8'h12);",
            """
        if (!keys[30]) $fatal(1, "enter missing, keys=%010x", keys);
        if (!keys[0]) $fatal(1, "caps shift missing, keys=%010x", keys);
        $display("ENTER_PASS keys=%010x", keys);
""")
        self.assertIn("ENTER_PASS", output)

    def test_cursor_left_is_caps_shift_with_five(self) -> None:
        # The ROM wants caps shift and 5, and releasing the arrow must not
        # release a caps shift that is genuinely held.
        output = self.run_codes(
            "        press(8'he0); press(8'h6b);",
            """
        if (!keys[0]) $fatal(1, "caps shift missing, keys=%010x", keys);
        if (!keys[19]) $fatal(1, "the 5 key missing, keys=%010x", keys);
        $display("ARROW_PASS keys=%010x", keys);
""")
        self.assertIn("ARROW_PASS", output)

        output = self.run_codes(
            """
        press(8'h12);
        press(8'he0); press(8'h6b);
        press(8'he0); press(8'hf0); press(8'h6b);
""",
            """
        if (!keys[0]) $fatal(1, "held shift was released with the arrow");
        if (keys[19]) $fatal(1, "the 5 key stayed down");
        $display("HOLD_PASS keys=%010x", keys);
""")
        self.assertIn("HOLD_PASS", output)


if __name__ == "__main__":
    unittest.main()
