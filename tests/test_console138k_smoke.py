"""Behavioural regression tests for the Console 138K smoke-test HDL."""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
RTL_ROOT = REPO_ROOT / "rtl" / "smoke"


class Console138kSmokeTest(unittest.TestCase):
    def run_iverilog(self, testbench: str, *sources: str) -> str:
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_path = Path(temporary_directory)
            testbench_path = temporary_path / "testbench.v"
            simulation_path = temporary_path / "simulation.vvp"
            testbench_path.write_text(testbench, encoding="utf-8")

            compile_result = subprocess.run(
                [
                    "iverilog",
                    "-g2012",
                    "-Wall",
                    "-s",
                    "testbench",
                    "-o",
                    str(simulation_path),
                    *(str(RTL_ROOT / source) for source in sources),
                    str(testbench_path),
                ],
                cwd=REPO_ROOT,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(compile_result.returncode, 0, compile_result.stderr)

            simulation_result = subprocess.run(
                ["vvp", str(simulation_path)],
                cwd=REPO_ROOT,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(simulation_result.returncode, 0, simulation_result.stdout)
            return simulation_result.stdout

    def test_video_timing_and_colour_bars(self) -> None:
        output = self.run_iverilog(
            r"""
`timescale 1ns/1ps
module testbench;
    reg pixel_clk = 0;
    reg reset = 1;
    wire [7:0] red;
    wire [7:0] green;
    wire [7:0] blue;
    wire hsync;
    wire vsync;
    wire data_enable;
    wire [3:0] horizontal_position;
    wire [3:0] vertical_position;
    integer cycles = 0;

    always #5 pixel_clk = ~pixel_clk;

    nexttang_video_pattern #(
        .H_ACTIVE(8), .H_FRONT(2), .H_SYNC(2), .H_BACK(2),
        .V_ACTIVE(4), .V_FRONT(1), .V_SYNC(1), .V_BACK(1),
        .H_BITS(4), .V_BITS(4)
    ) dut (
        .pixel_clk(pixel_clk), .reset(reset),
        .red(red), .green(green), .blue(blue),
        .hsync(hsync), .vsync(vsync), .data_enable(data_enable),
        .horizontal_position(horizontal_position),
        .vertical_position(vertical_position)
    );

    always @(posedge pixel_clk) begin
        if (!reset) begin
            cycles = cycles + 1;
            if (cycles > 3) begin
                if (data_enable !== ((horizontal_position < 8) && (vertical_position < 4)))
                    $fatal(1, "data-enable mismatch at %0d,%0d", horizontal_position, vertical_position);
                if (hsync !== ((horizontal_position >= 10) && (horizontal_position < 12)))
                    $fatal(1, "horizontal-sync mismatch at %0d", horizontal_position);
                if (vsync !== ((vertical_position >= 5) && (vertical_position < 6)))
                    $fatal(1, "vertical-sync mismatch at %0d", vertical_position);
                if (data_enable && horizontal_position == 0 && {red, green, blue} !== 24'hffffff)
                    $fatal(1, "first colour bar is not white");
                if (data_enable && horizontal_position == 7 && {red, green, blue} !== 24'h000000)
                    $fatal(1, "last colour bar is not black");
            end
            if (cycles == 200) begin
                $display("VIDEO_PASS");
                $finish;
            end
        end
    end

    initial begin
        repeat (3) @(posedge pixel_clk);
        reset <= 0;
    end
endmodule
""",
            "nexttang_logo_rom.v",
            "nexttang_video_pattern.v",
        )
        self.assertIn("VIDEO_PASS", output)

    def test_uart_repeats_identifiable_heartbeat(self) -> None:
        output = self.run_iverilog(
            r"""
`timescale 1ns/1ps
module testbench;
    reg clock = 0;
    reg reset = 1;
    wire transmit;
    integer byte_index;
    integer bit_index;
    reg [7:0] received;
    reg [7:0] expected [0:20];

    always #5 clock = ~clock;

    nexttang_uart_heartbeat #(
        .CLOCK_HZ(100),
        .BAUD_RATE(10),
        .GAP_CLOCKS(20)
    ) dut (.clock(clock), .reset(reset), .transmit(transmit));

    initial begin
        expected[0] = "N"; expected[1] = "E"; expected[2] = "X";
        expected[3] = "T"; expected[4] = "T"; expected[5] = "A";
        expected[6] = "N"; expected[7] = "G"; expected[8] = " ";
        expected[9] = "1"; expected[10] = "3"; expected[11] = "8";
        expected[12] = "K"; expected[13] = " "; expected[14] = "S";
        expected[15] = "M"; expected[16] = "O"; expected[17] = "K";
        expected[18] = "E"; expected[19] = 8'h0d; expected[20] = 8'h0a;
        repeat (3) @(posedge clock);
        reset <= 0;

        for (byte_index = 0; byte_index < 21; byte_index = byte_index + 1) begin
            @(negedge transmit);
            repeat (15) @(posedge clock);
            received = 0;
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                received[bit_index] = transmit;
                repeat (10) @(posedge clock);
            end
            if (received !== expected[byte_index])
                $fatal(1, "UART byte %0d: received %02x expected %02x", byte_index, received, expected[byte_index]);
            if (transmit !== 1'b1)
                $fatal(1, "UART stop bit was not high");
        end
        $display("UART_PASS");
        $finish;
    end
endmodule
""",
            "nexttang_uart_heartbeat.v",
        )
        self.assertIn("UART_PASS", output)

    def test_uart_fractional_divider_holds_requested_baud(self) -> None:
        output = self.run_iverilog(
            r"""
`timescale 1ns/1ps
module testbench;
    reg clock = 0;
    reg reset = 1;
    wire transmit;
    integer frame_clocks;

    always #5 clock = ~clock;

    nexttang_uart_heartbeat #(
        .CLOCK_HZ(27),
        .BAUD_RATE(2),
        .GAP_CLOCKS(2)
    ) dut (.clock(clock), .reset(reset), .transmit(transmit));

    initial begin
        repeat (3) @(posedge clock);
        reset <= 0;

        @(negedge transmit);
        frame_clocks = 0;
        while (dut.message_index == 0) begin
            @(posedge clock);
            frame_clocks = frame_clocks + 1;
            #1;
        end

        if (frame_clocks != 135)
            $fatal(1, "UART frame used %0d clocks, expected 135", frame_clocks);

        $display("UART_FRACTIONAL_PASS");
        $finish;
    end
endmodule
""",
            "nexttang_uart_heartbeat.v",
        )
        self.assertIn("UART_FRACTIONAL_PASS", output)

    def test_logo_moves_once_per_frame(self) -> None:
        output = self.run_iverilog(
            r"""
`timescale 1ns/1ps
module testbench;
    reg pixel_clk = 0;
    reg reset = 1;
    wire [7:0] red;
    wire [7:0] green;
    wire [7:0] blue;
    wire hsync;
    wire vsync;
    wire data_enable;
    wire [8:0] horizontal_position;
    wire [8:0] vertical_position;
    reg [8:0] initial_left;
    reg [8:0] initial_top;

    always #1 pixel_clk = ~pixel_clk;

    nexttang_video_pattern #(
        .H_ACTIVE(320), .H_FRONT(1), .H_SYNC(1), .H_BACK(1),
        .V_ACTIVE(272), .V_FRONT(1), .V_SYNC(1), .V_BACK(1),
        .H_BITS(9), .V_BITS(9)
    ) dut (
        .pixel_clk(pixel_clk), .reset(reset),
        .red(red), .green(green), .blue(blue),
        .hsync(hsync), .vsync(vsync), .data_enable(data_enable),
        .horizontal_position(horizontal_position),
        .vertical_position(vertical_position)
    );

    initial begin
        repeat (3) @(posedge pixel_clk);
        reset <= 0;
        initial_left = dut.logo_left;
        initial_top = dut.logo_top;
        repeat (323 * 275 + 10) @(posedge pixel_clk);
        if (dut.logo_left === initial_left || dut.logo_top === initial_top)
            $fatal(1, "logo did not move at the frame boundary");
        $display("LOGO_MOTION_PASS");
        $finish;
    end
endmodule
""",
            "nexttang_logo_rom.v",
            "nexttang_video_pattern.v",
        )
        self.assertIn("LOGO_MOTION_PASS", output)

    def test_logo_source_has_full_rgb332_range(self) -> None:
        pixels = (RTL_ROOT / "nexttang_logo_128x128_rgb332.mem").read_text(
            encoding="utf-8"
        ).splitlines()
        self.assertEqual(len(pixels), 128 * 128)
        values = {int(pixel, 16) for pixel in pixels}
        self.assertGreater(len(values), 32)
        self.assertIn(0, values)


if __name__ == "__main__":
    unittest.main()
