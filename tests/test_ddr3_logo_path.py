"""Behavioural tests for the Console DDR-backed moving-logo path."""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]


def run_iverilog(testbench: str, *sources: Path) -> str:
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
                *(str(source) for source in sources),
                str(testbench_path),
            ],
            cwd=REPO_ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
        if compile_result.returncode:
            raise AssertionError(compile_result.stderr)
        simulation_result = subprocess.run(
            ["vvp", str(simulation_path)],
            cwd=REPO_ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
        if simulation_result.returncode:
            raise AssertionError(
                simulation_result.stdout + simulation_result.stderr
            )
        return simulation_result.stdout


class Ddr3LogoPathTest(unittest.TestCase):
    def test_engine_pairs_writes_and_refills_both_banks(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            logo_path = Path(temporary_directory) / "logo.mem"
            logo_path.write_text(
                "\n".join(f"{(index * 3) & 0xff:02x}" for index in range(64))
                + "\n",
                encoding="utf-8",
            )
            output = run_iverilog(
                rf"""
`timescale 1ns/1ps
module testbench;
    reg clock = 0;
    reg reset = 1;
    reg calibration_complete = 0;
    reg request_toggle = 0;
    reg request_bank = 0;
    wire completion_toggle;
    wire completion_bank;
    wire logo_ready;
    wire buffer_write_enable;
    wire buffer_write_bank;
    wire [8:0] buffer_write_address;
    wire [255:0] buffer_write_data;
    reg command_ready = 0;
    wire [2:0] command;
    wire command_enable;
    wire [28:0] address;
    reg write_data_ready = 0;
    wire [255:0] write_data;
    wire write_data_enable;
    wire write_data_end;
    wire [31:0] write_data_mask;
    reg [255:0] read_data = 0;
    reg read_data_valid = 0;
    wire burst;
    wire [2:0] status;
    reg [255:0] memory [0:1];
    reg [7:0] source_pixels [0:63];
    reg pending_read = 0;
    reg pending_index = 0;
    integer cycles = 0;
    integer writes = 0;
    integer reads = 0;
    integer buffer_writes = 0;

    always #5 clock = ~clock;

    nexttang_ddr3_logo_engine #(
        .LOGO_FILE("{logo_path}"),
        .LOGO_BEATS(2),
        .LOGO_BASE_ADDRESS(0),
        .CALIBRATION_TIMEOUT_CYCLES(20),
        .TRANSACTION_TIMEOUT_CYCLES(20),
        .WRITE_DRAIN_CYCLES(2)
    ) dut (
        .clock(clock), .reset(reset),
        .calibration_complete(calibration_complete),
        .reload_request_toggle(request_toggle),
        .reload_request_bank(request_bank),
        .completion_toggle(completion_toggle),
        .completion_bank(completion_bank),
        .logo_ready(logo_ready),
        .buffer_write_enable(buffer_write_enable),
        .buffer_write_bank(buffer_write_bank),
        .buffer_write_address(buffer_write_address),
        .buffer_write_data(buffer_write_data),
        .controller_command_ready(command_ready),
        .controller_command(command),
        .controller_command_enable(command_enable),
        .controller_address(address),
        .controller_write_data_ready(write_data_ready),
        .controller_write_data(write_data),
        .controller_write_data_enable(write_data_enable),
        .controller_write_data_end(write_data_end),
        .controller_write_data_mask(write_data_mask),
        .controller_read_data(read_data),
        .controller_read_data_valid(read_data_valid),
        .controller_burst(burst), .status(status)
    );

    always @(posedge clock) begin
        if (buffer_write_enable) begin
            if (buffer_write_data !== memory[buffer_write_address])
                $fatal(1, "buffer beat %0d did not match DDR data",
                       buffer_write_address);
            if (buffer_writes < 2 && buffer_write_bank != 0)
                $fatal(1, "initial refill targeted the wrong bank");
            if (buffer_writes >= 2 && buffer_write_bank != 1)
                $fatal(1, "second refill targeted the wrong bank");
            buffer_writes = buffer_writes + 1;
        end
    end

    always @(negedge clock) begin
        cycles = cycles + 1;
        command_ready = 0;
        write_data_ready = 0;
        read_data_valid = 0;

        if (pending_read) begin
            pending_read = 0;
            read_data = memory[pending_index];
            read_data_valid = 1;
        end

        if (cycles < 7) begin
            command_ready = cycles[0];
            write_data_ready = !cycles[0];
            #1;
            if (command == 3'b000 &&
                (command_enable || write_data_enable))
                $fatal(1, "write was not held for paired readiness");
        end else begin
            command_ready = 1;
            write_data_ready = 1;
            #1;
            if (command_enable && command == 3'b000) begin
                if (!write_data_enable)
                    $fatal(1, "write command had no data pair");
                memory[address[3]] = write_data;
                writes = writes + 1;
            end
            if (write_data_enable &&
                !(command_enable && command == 3'b000))
                $fatal(1, "write data had no command pair");
            if (command_enable && command == 3'b001) begin
                pending_index = address[3];
                pending_read = 1;
                reads = reads + 1;
            end
        end
    end

    initial begin
        $readmemh("{logo_path}", source_pixels);
        repeat (3) @(posedge clock);
        reset = 0;
        repeat (2) @(posedge clock);
        calibration_complete = 1;

        wait (completion_toggle == 1);
        repeat (2) @(posedge clock);
        if (!logo_ready || completion_bank != 0 || writes != 2 ||
            reads != 2 || buffer_writes != 2)
            $fatal(1, "initial DDR logo load did not complete");

        request_bank = 1;
        request_toggle = 1;
        wait (completion_toggle == 0);
        repeat (2) @(posedge clock);
        if (completion_bank != 1 || reads != 4 || buffer_writes != 4)
            $fatal(1, "second DDR logo load did not complete");
        if (!write_data_end || write_data_mask != 0 || burst || status != 3)
            $fatal(1, "fixed controls or final status were wrong");
        $display("DDR_LOGO_ENGINE_PASS");
        $finish;
    end
endmodule
""",
                REPO_ROOT / "rtl" / "memory" / "nexttang_ddr3_logo_engine.v",
            )
        self.assertIn("DDR_LOGO_ENGINE_PASS", output)

    def test_framebuffer_keeps_banks_independent_across_clocks(self) -> None:
        output = run_iverilog(
            r"""
`timescale 1ns/1ps
module testbench;
    reg write_clock = 0;
    reg read_clock = 0;
    reg write_enable = 0;
    reg write_bank = 0;
    reg [8:0] write_address = 0;
    reg [255:0] write_data = 0;
    reg read_bank = 0;
    reg [13:0] read_address = 0;
    wire [7:0] read_data;

    always #3 write_clock = ~write_clock;
    always #5 read_clock = ~read_clock;

    nexttang_logo_framebuffer dut (
        .write_clock(write_clock), .write_enable(write_enable),
        .write_bank(write_bank), .write_address(write_address),
        .write_data(write_data), .read_clock(read_clock),
        .read_bank(read_bank), .read_address(read_address),
        .read_data(read_data)
    );

    task write_pixel_beat;
        input bank;
        input [7:0] value;
        begin
            @(negedge write_clock);
            write_bank = bank;
            write_address = 9'd1;
            write_data = 0;
            write_data[5 * 8 +: 8] = value;
            write_enable = 1;
            @(negedge write_clock);
            write_enable = 0;
        end
    endtask

    initial begin
        write_pixel_beat(0, 8'h35);
        write_pixel_beat(1, 8'hca);
        read_address = 37;
        read_bank = 0;
        repeat (2) @(posedge read_clock);
        #1;
        if (read_data != 8'h35)
            $fatal(1, "bank zero returned %02x", read_data);
        read_bank = 1;
        repeat (2) @(posedge read_clock);
        #1;
        if (read_data != 8'hca)
            $fatal(1, "bank one returned %02x", read_data);
        $display("LOGO_FRAMEBUFFER_PASS");
        $finish;
    end
endmodule
""",
            REPO_ROOT / "rtl" / "video" / "nexttang_logo_framebuffer.v",
        )
        self.assertIn("LOGO_FRAMEBUFFER_PASS", output)

    def test_motion_requires_a_fresh_ddr_completion(self) -> None:
        output = run_iverilog(
            r"""
`timescale 1ns/1ps
module testbench;
    reg pixel_clock = 0;
    reg reset = 1;
    reg completion_toggle = 0;
    reg completion_bank = 0;
    wire request_toggle;
    wire request_bank;
    wire read_bank;
    wire [13:0] read_address;
    reg [7:0] read_data = 8'he3;
    wire logo_available;
    wire [7:0] red;
    wire [7:0] green;
    wire [7:0] blue;
    wire hsync;
    wire vsync;
    wire data_enable;
    wire [8:0] horizontal_position;
    wire [8:0] vertical_position;
    reg [8:0] first_left;
    reg [8:0] first_top;

    always #1 pixel_clock = ~pixel_clock;

    nexttang_ddr_logo_video #(
        .H_ACTIVE(320), .H_FRONT(1), .H_SYNC(1), .H_BACK(1),
        .V_ACTIVE(272), .V_FRONT(1), .V_SYNC(1), .V_BACK(1),
        .H_BITS(9), .V_BITS(9)
    ) dut (
        .pixel_clock(pixel_clock), .reset(reset),
        .completion_toggle(completion_toggle),
        .completion_bank(completion_bank),
        .reload_request_toggle(request_toggle),
        .reload_request_bank(request_bank),
        .framebuffer_read_bank(read_bank),
        .framebuffer_read_address(read_address),
        .framebuffer_read_data(read_data),
        .logo_available(logo_available),
        .red(red), .green(green), .blue(blue),
        .hsync(hsync), .vsync(vsync), .data_enable(data_enable),
        .horizontal_position(horizontal_position),
        .vertical_position(vertical_position)
    );

    task finish_frame;
        begin
            wait (dut.horizontal_counter == 322 &&
                  dut.vertical_counter == 274);
            @(posedge pixel_clock);
            #1;
        end
    endtask

    initial begin
        repeat (3) @(posedge pixel_clock);
        reset = 0;
        first_left = dut.logo_left;
        first_top = dut.logo_top;
        completion_toggle = 1;
        completion_bank = 0;
        finish_frame();
        if (!logo_available || read_bank != 0 ||
            request_toggle != 1 || request_bank != 1)
            $fatal(1, "first DDR frame was not consumed");
        if (dut.logo_left == first_left || dut.logo_top == first_top)
            $fatal(1, "fresh DDR frame did not move the logo");

        first_left = dut.logo_left;
        first_top = dut.logo_top;
        finish_frame();
        if (dut.logo_left != first_left || dut.logo_top != first_top)
            $fatal(1, "logo moved without a fresh DDR frame");

        completion_toggle = 0;
        completion_bank = 1;
        finish_frame();
        if (read_bank != 1 || request_toggle != 0 || request_bank != 0)
            $fatal(1, "second DDR frame was not consumed");
        if (dut.logo_left == first_left || dut.logo_top == first_top)
            $fatal(1, "second DDR frame did not move the logo");
        $display("DDR_LOGO_MOTION_PASS");
        $finish;
    end
endmodule
""",
            REPO_ROOT / "rtl" / "video" / "nexttang_ddr_logo_video.v",
        )
        self.assertIn("DDR_LOGO_MOTION_PASS", output)


if __name__ == "__main__":
    unittest.main()
