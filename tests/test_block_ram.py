"""The block RAM's contract is what the processor and the display rely on.

The module exists because this device cannot give read-during-write forwarding
on a memory the tool maps as single-port. That constraint is invisible in the
Verilog, so it is worth pinning: a later edit that "fixes" the read path to
forward would build fine here and then behave differently on the device.

The second port is read-only and independently clocked, which is what lets the
display read screen memory at the pixel rate while the processor writes it.
"""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
RAM_RTL = REPO_ROOT / "rtl" / "memory" / "nexttang_block_ram.v"


def run_testbench(body: str, initial_image: bytes | None = None) -> str:
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory)
        if initial_image is not None:
            image_path = path / "initial.mem"
            image_path.write_text(
                "".join(f"{byte:02x}\n" for byte in initial_image),
                encoding="utf-8",
            )
            body = body.replace("IMAGE_FILE", str(image_path))
        (path / "testbench.v").write_text(body, encoding="utf-8")
        compiled = subprocess.run(
            ["iverilog", "-g2012", "-Wall", "-s", "testbench",
             "-o", str(path / "sim.vvp"), str(RAM_RTL), str(path / "testbench.v")],
            cwd=REPO_ROOT, check=False, capture_output=True, text=True)
        if compiled.returncode:
            raise AssertionError(compiled.stderr)
        result = subprocess.run(["vvp", str(path / "sim.vvp")],
                                cwd=REPO_ROOT, check=False,
                                capture_output=True, text=True)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)
        return result.stdout


HARNESS = r"""
`timescale 1ns/1ps
module testbench;
    reg clock = 0;
    reg port_b_clock = 0;
    reg write_enable = 0;
    reg [7:0] write_address = 0;
    reg [7:0] write_data = 0;
    wire [7:0] read_data;
    reg [7:0] port_b_address = 0;
    wire [7:0] port_b_data;

    nexttang_block_ram #(.ADDRESS_BITS(8), .DATA_BITS(8)) dut (
        .clock(clock), .write_enable(write_enable),
        .write_address(write_address), .write_data(write_data),
        .read_data(read_data),
        .port_b_clock(port_b_clock), .port_b_address(port_b_address),
        .port_b_data(port_b_data)
    );

    task write(input [7:0] address, input [7:0] value);
        begin
            @(negedge clock);
            write_address = address; write_data = value; write_enable = 1;
            @(posedge clock);
            @(negedge clock);
            write_enable = 0;
        end
    endtask
BODY
endmodule
"""


class BlockRamTest(unittest.TestCase):
    def test_optional_image_initialises_both_read_ports(self) -> None:
        harness = HARNESS.replace(
            "#(.ADDRESS_BITS(8), .DATA_BITS(8))",
            '#(.ADDRESS_BITS(8), .DATA_BITS(8), .IMAGE("IMAGE_FILE"))',
        )
        output = run_testbench(harness.replace("BODY", """
    always #5 clock = ~clock;
    always #3 port_b_clock = ~port_b_clock;
    initial begin
        write_address = 8'h42;
        port_b_address = 8'h42;
        repeat (3) @(posedge clock);
        repeat (3) @(posedge port_b_clock);
        if (read_data !== 8'hA5 || port_b_data !== 8'hA5)
            $fatal(1, "initial image was not visible on both ports");
        $display("IMAGE_OK");
        $finish;
    end
"""), bytes([0] * 0x42 + [0xA5] + [0] * (256 - 0x43)))
        self.assertIn("IMAGE_OK", output)

    def test_a_written_byte_reads_back_on_the_processor_port(self) -> None:
        output = run_testbench(HARNESS.replace("BODY", """
    always #5 clock = ~clock;
    initial begin
        write(8'h42, 8'hA5);
        @(negedge clock); write_address = 8'h42;
        @(posedge clock); @(posedge clock);
        if (read_data !== 8'hA5)
            $fatal(1, "read back %02x, expected a5", read_data);
        $display("READBACK_OK");
        $finish;
    end
"""))
        self.assertIn("READBACK_OK", output)

    def test_the_read_port_does_not_forward_a_simultaneous_write(self) -> None:
        # The device cannot do this, so the model must not either. A model that
        # forwards would let a simulation pass on logic the hardware breaks.
        output = run_testbench(HARNESS.replace("BODY", """
    always #5 clock = ~clock;
    initial begin
        write(8'h10, 8'h11);
        @(negedge clock);
        write_address = 8'h10; write_data = 8'h99; write_enable = 1;
        @(posedge clock);
        @(negedge clock); write_enable = 0;
        // read_data must still hold whatever preceded the write, never 8'h99.
        if (read_data === 8'h99)
            $fatal(1, "read port forwarded the in-flight write");
        $display("NO_FORWARD_OK");
        $finish;
    end
"""))
        self.assertIn("NO_FORWARD_OK", output)

    def test_the_second_port_reads_on_its_own_clock(self) -> None:
        # Port B is clocked far faster than the write port here, which is the
        # arrangement the display uses against the processor.
        output = run_testbench(HARNESS.replace("BODY", """
    always #20 clock = ~clock;
    always #1 port_b_clock = ~port_b_clock;
    initial begin
        write(8'h07, 8'h5C);
        port_b_address = 8'h07;
        @(posedge port_b_clock); @(posedge port_b_clock);
        if (port_b_data !== 8'h5C)
            $fatal(1, "port b read %02x, expected 5c", port_b_data);
        $display("PORT_B_OK");
        $finish;
    end
"""))
        self.assertIn("PORT_B_OK", output)


if __name__ == "__main__":
    unittest.main()
