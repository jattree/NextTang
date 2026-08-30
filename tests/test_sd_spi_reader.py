"""Read-only SD SPI initialization and sector-stream regressions."""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
SPI_RTL = REPO_ROOT / "rtl/storage/nexttang_spi_byte_master.v"
SD_RTL = REPO_ROOT / "rtl/storage/nexttang_sd_spi_reader.v"


class SdSpiReaderTests(unittest.TestCase):
    def _run(self, bench: str, sources: list[Path]) -> str:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "testbench.sv"
            output = root / "testbench.vvp"
            source.write_text(bench, encoding="ascii")
            compiled = subprocess.run(
                ["iverilog", "-g2012", "-Wall", "-s", "testbench", "-o",
                 str(output), *(str(item) for item in sources), str(source)],
                cwd=REPO_ROOT, capture_output=True, text=True, check=False,
            )
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            run = subprocess.run(
                ["vvp", str(output)], cwd=REPO_ROOT,
                capture_output=True, text=True, check=False,
            )
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            return run.stdout

    def test_mode_zero_byte_transfer(self) -> None:
        output = self._run(r"""
`timescale 1ns/1ps
module testbench;
    reg clock = 0, reset = 1, start = 0, miso = 0;
    reg [7:0] transmit = 8'ha5;
    wire [7:0] received; wire busy, done, sclk, mosi;
    reg [7:0] captured = 0; integer bits = 0;
    always #5 clock = ~clock;
    always @(posedge sclk) begin
        captured = {captured[6:0], mosi};
        bits = bits + 1;
    end
    always @(negedge sclk) if (busy) miso = ~miso;
    nexttang_spi_byte_master #(.DIVIDER(2)) dut (
        .clock(clock), .reset(reset), .start(start), .fast(1'b0), .transmit(transmit),
        .received(received), .busy(busy), .done(done),
        .sclk(sclk), .mosi(mosi), .miso(miso));
    initial begin
        repeat (2) @(posedge clock); reset = 0;
        @(negedge clock); start = 1; @(negedge clock); start = 0;
        wait(done); #1;
        if (bits != 8 || captured != 8'ha5)
            $fatal(1, "SPI transmit mismatch bits=%0d data=%02x", bits, captured);
        $display("SPI_BYTE_PASS"); $finish;
    end
endmodule
""", [SPI_RTL])
        self.assertIn("SPI_BYTE_PASS", output)

    def test_sdhc_initialization_and_read_only_sector(self) -> None:
        output = self._run(r"""
`timescale 1ns/1ps
module testbench;
    reg clock = 0, reset = 1, read_start = 0, sd_miso = 1;
    reg [31:0] sector = 32'h00123456;
    wire ready, busy, error, byte_valid, read_done;
    wire [7:0] byte_data; wire [8:0] byte_offset;
    wire sd_clk, sd_mosi, sd_cs;
    integer seen = 0; integer expected = 0; integer commands = 0;
    reg [7:0] command [0:5]; integer i;
    always #5 clock = ~clock;

    nexttang_sd_spi_reader #(
        .CLOCK_HZ(100), .INIT_SPI_HZ(25), .DATA_SPI_HZ(25),
        .RESPONSE_LIMIT(64), .INIT_RETRIES(8)
    ) dut (
        .clock(clock), .reset(reset), .read_start(read_start), .sector(sector),
        .ready(ready), .busy(busy), .error(error),
        .byte_data(byte_data), .byte_offset(byte_offset),
        .byte_valid(byte_valid), .read_done(read_done),
        .sd_clk(sd_clk), .sd_mosi(sd_mosi), .sd_miso(sd_miso), .sd_cs(sd_cs));

    task receive_byte(output reg [7:0] value);
        integer bitno;
        begin
            value = 0;
            for (bitno = 7; bitno >= 0; bitno = bitno - 1) begin
                @(posedge sd_clk); value[bitno] = sd_mosi;
            end
        end
    endtask
    task send_byte(input [7:0] value);
        integer bitno;
        begin
            for (bitno = 7; bitno >= 0; bitno = bitno - 1) begin
                @(negedge sd_clk); sd_miso = value[bitno];
            end
            @(posedge sd_clk);
        end
    endtask
    task receive_command;
        begin
            wait(sd_cs);
            wait(!sd_cs);
            for (i = 0; i < 6; i = i + 1) receive_byte(command[i]);
            commands = commands + 1;
        end
    endtask

    // Minimal deterministic SDHC model. It recognizes every command emitted by
    // the DUT and never accepts or models a write command.
    initial begin : card
        wait(!reset);
        receive_command();
        if (command[0] != 8'h40) $fatal(1, "expected CMD0, got %02x", command[0]);
        // A real card may ignore or reject the first GO_IDLE frame while its
        // SPI interface settles.  The host must deselect and retry CMD0.
        send_byte(8'h05);
        receive_command();
        if (command[0] != 8'h40) $fatal(1, "expected retried CMD0, got %02x", command[0]);
        send_byte(8'h01);
        receive_command();
        if (command[0] != 8'h48) $fatal(1, "expected CMD8, got %02x", command[0]);
        send_byte(8'h01); send_byte(0); send_byte(0); send_byte(8'h01); send_byte(8'haa);
        receive_command();
        if (command[0] != 8'h77) $fatal(1, "expected CMD55");
        send_byte(8'h01);
        receive_command();
        if (command[0] != 8'h69 || command[1] != 8'h40) $fatal(1, "expected ACMD41 HCS");
        send_byte(8'h00);
        receive_command();
        if (command[0] != 8'h7a) $fatal(1, "expected CMD58");
        send_byte(8'h00); send_byte(8'h40); send_byte(0); send_byte(0); send_byte(0);
        wait(sd_cs);
        receive_command();
        if (command[0] != 8'h51) $fatal(1, "expected CMD17");
        if ({command[1],command[2],command[3],command[4]} != 32'h00123456)
            $fatal(1, "SDHC command used wrong sector argument");
        send_byte(8'h00); send_byte(8'hff); send_byte(8'hfe);
        for (i = 0; i < 512; i = i + 1) send_byte(i[7:0] ^ 8'h5a);
        send_byte(8'h12); send_byte(8'h34); send_byte(8'hff);
        sd_miso = 1;
    end

    always @(posedge clock) if (byte_valid) begin
        if (byte_offset != expected[8:0] || byte_data != (expected[7:0] ^ 8'h5a))
            $fatal(1, "sector byte mismatch at %0d: offset=%0d data=%02x",
                   expected, byte_offset, byte_data);
        expected = expected + 1; seen = seen + 1;
    end

    initial begin : host
        repeat (3) @(posedge clock); reset = 0;
        wait(ready || error); if (error) $fatal(1, "SD init failed");
        @(negedge clock); read_start = 1; @(negedge clock); read_start = 0;
        wait(read_done || error); if (error) $fatal(1, "sector read failed");
        if (seen != 512 || commands != 7)
            $fatal(1, "read contract mismatch bytes=%0d commands=%0d", seen, commands);
        $display("SD_SPI_READER_PASS"); $finish;
    end
    initial begin #2000000; $fatal(1, "timeout"); end
endmodule
""", [SPI_RTL, SD_RTL])
        self.assertIn("SD_SPI_READER_PASS", output)


if __name__ == "__main__":
    unittest.main()
