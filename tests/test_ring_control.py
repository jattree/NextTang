"""The rewind ring's board-side control (rtl/debug/nexttang_ring_control.v) with
models of the SPI master and debug slave, the block RAM banks and main memory:
after checkpoints and a rewind, memory (main and banks 5 and 7) and the CPU's
registers are the checkpoint's, and the report gives its recorder position."""

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
SOURCES = [REPO_ROOT / "rtl/debug" / name for name in
           ("nexttang_dirty_blocks.v", "nexttang_rewind_store.v", "nexttang_ring_control.v")]

BENCH = """
`timescale 1ns/1ps
module testbench;
    localparam BIT = 10;
    reg clock = 0; always #5 clock = ~clock;
    reg reset = 1, command_valid = 0; reg [7:0] command_byte = 0;
    wire busy, spi_take, spi_select, spi_byte_valid, c_take, c_request, c_read_n, tx;
    wire [7:0] spi_byte, c_write_data; wire [22:0] c_address;
    reg cpu_stopped = 0;
    reg [15:0] frames = 0, frame_fetches = 0, frame_reads = 0;
    reg write_valid = 0; reg [20:0] write_address = 0;
    reg bank_valid = 0; reg [20:0] bank_address = 0; reg [7:0] bank_data = 0;
    integer stale_seen = 0, good_seen = 0;
    reg spi_byte_ready = 0, spi_done = 0; reg [7:0] spi_reply = 0;
    reg [7:0] c_read_data = 0; reg c_ack = 0;
    wire spi_idle = !spi_select && !slave_busy;
    reg slave_busy = 0;

    nexttang_ring_control #(.CLOCK_HZ(1000000), .BAUD_RATE(100000), .RING_BITS(21), .TABLE_BITS(6)) dut (
        .clock(clock), .reset(reset), .command_valid(command_valid), .command_byte(command_byte), .busy(busy),
        .cpu_stopped(cpu_stopped), .frames(frames), .frame_fetches(frame_fetches), .frame_reads(frame_reads),
        .write_valid(write_valid), .write_address(write_address),
        .bank_valid(bank_valid), .bank_address(bank_address), .bank_data(bank_data), .c_free(1'b1),
        .spi_free(1'b1), .spi_take(spi_take), .spi_select(spi_select), .spi_byte_valid(spi_byte_valid),
        .spi_byte(spi_byte), .spi_byte_ready(spi_byte_ready), .spi_done(spi_done), .spi_reply(spi_reply),
        .spi_idle(spi_idle),
        .c_take(c_take), .c_request(c_request), .c_read_n(c_read_n), .c_address(c_address),
        .c_write_data(c_write_data), .c_read_data(c_read_data), .c_ack(c_ack), .tx(tx));

    // Main memory, the whole die. Port C answers two clocks after a request
    // and wants the request low before the next.
    reg [7:0] mem [0:8388607];
    reg c_pending = 0;
    always @(posedge clock) begin
        c_ack <= 0;
        if (c_request && !c_pending && !c_ack) c_pending <= 1;
        if (c_pending) begin
            if (c_read_n) mem[c_address] <= c_write_data;     // 0 reads, 1 writes, as port A's line
            c_read_data <= mem[c_address];
            c_ack <= 1; c_pending <= 0;
        end
        if (busy && dut.store_busy) begin
            if (dut.mirror_good) good_seen = good_seen + 1; else stale_seen = stale_seen + 1;
        end
    end

    // The SPI master and the debug slave behind it.
    reg [7:0] cpu [0:31];                 // registers 00 to 19, state at 1A
    reg [7:0] bram [0:65535];             // bank 5 at 0000, bank 7's first half at 8000
    reg [7:0] cmd [0:7]; integer n = 0; reg select_q = 0;
    always @(posedge clock) begin
        spi_byte_ready <= 0; spi_done <= 0;
        select_q <= spi_select;
        if (!spi_select) n = 0;
        if (spi_select && spi_byte_valid && !spi_byte_ready && !slave_busy) begin
            spi_byte_ready <= 1; slave_busy <= 1;
            cmd[n] = spi_byte;
            spi_reply <= 8'h00;
            if (n == 0 && spi_byte == 8'hA4) cpu_stopped <= #300 1;
            if (n == 0 && spi_byte == 8'hA5) cpu_stopped <= 0;
            if (cmd[0] == 8'hAD && n == 3) spi_reply <= cpu[cmd[1]];
            if (cmd[0] == 8'hAE && n == 2) begin
                if (cmd[1] == 8'h1B) cpu[26] = {cpu[26][7:3], spi_byte[2:0]};
                else if (cmd[1] < 26) cpu[cmd[1]] = spi_byte;
                else $display("FAIL register write to %02x", cmd[1]);
            end
            if (cmd[0] == 8'hA9 && n == 6) spi_reply <= bram[{cmd[1], cmd[2]}];
            if (cmd[0] == 8'hAA && n == 5) bram[{cmd[1], cmd[2]}] = spi_byte;
            if (!cpu_stopped && cmd[0] != 8'hA4) $display("FAIL command %02x with the CPU running", cmd[0]);
            n = n + 1;
        end
        if (slave_busy) begin spi_done <= 1; slave_busy <= 0; end
    end

    // UART receiver on tx.
    integer k; reg [7:0] rx;
    initial forever begin
        @(negedge tx);
        repeat (BIT / 2) @(posedge clock);
        for (k = 0; k < 8; k = k + 1) begin repeat (BIT) @(posedge clock); rx[k] = tx; end
        repeat (BIT) @(posedge clock);
        $write("%c", rx);
    end

    // The machine: writes land in main memory or in the block RAM banks.
    integer seed = 7;
    reg [20:0] spots [0:5];
    initial begin
        spots[0] = 21'h040000; spots[1] = 21'h054000; spots[2] = 21'h057f00;
        spots[3] = 21'h05c000; spots[4] = 21'h05e000; spots[5] = 21'h1fff00;
    end
    task machine_write(input [20:0] address, input [7:0] value); begin
        if (address[20:14] == 7'b0010101) bram[{2'b00, address[13:0]}] = value;
        else if (address[20:13] == 8'b00101110) bram[{3'b100, address[12:0]}] = value;
        else mem[address] = value;
        // the board gives the tracker every write, and the mirror the bank writes with their byte
        bank_valid <= address[20:14] == 7'b0010101 || address[20:13] == 8'b00101110;
        bank_address <= address; bank_data <= value;
        write_address <= address; write_valid <= 1; @(posedge clock); write_valid <= 0; bank_valid <= 0;
    end endtask
    function [7:0] machine_read(input [20:0] address);
        if (address[20:14] == 7'b0010101) machine_read = bram[{2'b00, address[13:0]}];
        else if (address[20:13] == 8'b00101110) machine_read = bram[{3'b100, address[12:0]}];
        else machine_read = mem[address];
    endfunction
    // Every other run writes at a 3.5 MHz CPU's pace, which the mirror keeps
    // up with; the rest back to back, which it cannot, so both ways of
    // reading the banks are used.
    integer run_number = 0;
    task run(input integer writes); integer w; begin
        run_number = run_number + 1;
        for (w = 0; w < writes; w = w + 1) begin
            machine_write(spots[{$random(seed)} % 6] + ({$random(seed)} % 512), $random(seed));
            if (run_number[0]) repeat (24) @(posedge clock);
        end
        repeat (24) @(posedge clock);
        for (w = 0; w < 26; w = w + 1) cpu[w] = $random(seed);
        cpu[26] = {2'b00, 2'b01, 1'b0, 3'b011} ^ ($random(seed) & 8'h07);
        frames = frames + 1 + ({$random(seed)} % 50); frame_fetches = $random(seed); frame_reads = {$random(seed)} % 40;
    end endtask
    task send(input [7:0] value); begin
        command_byte <= value; command_valid <= 1; @(posedge clock); command_valid <= 0; @(posedge clock);
    end endtask
    task finish_command; begin
        @(posedge clock); while (busy) @(posedge clock);
        repeat (2500) @(posedge clock);       // the report line: 19 characters of 100 clocks
    end endtask

    // What the machine looked like at each checkpoint.
    reg [7:0] seen_memory [0:8 * 6 * 512 - 1];
    reg [7:0] seen_cpu [0:8 * 32 - 1];
    reg [15:0] seen_frames [0:7], seen_fetches [0:7], seen_reads [0:7];
    integer s, j, bad;
    task remember(input integer which); begin
        for (s = 0; s < 6; s = s + 1) for (j = 0; j < 512; j = j + 1)
            seen_memory[(which * 6 + s) * 512 + j] = machine_read(spots[s] + j);
        for (j = 0; j < 27; j = j + 1) seen_cpu[which * 32 + j] = cpu[j];
        seen_frames[which] = frames; seen_fetches[which] = frame_fetches; seen_reads[which] = frame_reads;
    end endtask
    task compare(input integer which); begin
        bad = 0;
        for (s = 0; s < 6; s = s + 1) for (j = 0; j < 512; j = j + 1)
            if (machine_read(spots[s] + j) !== seen_memory[(which * 6 + s) * 512 + j]) bad = bad + 1;
        if (bad != 0) $display("FAIL %0d memory bytes differ from checkpoint %0d", bad, which);
        bad = 0;
        for (j = 0; j < 26; j = j + 1) if (cpu[j] !== seen_cpu[which * 32 + j]) bad = bad + 1;
        if (cpu[26][2:0] !== seen_cpu[which * 32 + 26][2:0]) bad = bad + 1;
        if (bad != 0) $display("FAIL %0d registers differ from checkpoint %0d", bad, which);
        if (!cpu_stopped) $display("FAIL the CPU runs after a rewind");
        $display("WANT %04x %04x %04x %02x", seen_frames[which], seen_fetches[which], seen_reads[which],
                 seen_cpu[which * 32 + 26]);
    end endtask

    integer i;
    initial begin
        for (i = 0; i < 8388608; i = i + 1) mem[i] = 0;
        for (i = 0; i < 65536; i = i + 1) bram[i] = i * 7;
        for (i = 0; i < 2097152; i = i + 4096) mem[i] = i >> 12;
        for (i = 0; i < 32; i = i + 1) cpu[i] = 0;
        repeat (4) @(posedge clock); reset <= 0;
        repeat (9000) @(posedge clock);
        // The host has the CPU stopped at the snapshot: prime.
        run(40); cpu_stopped = 1; remember(0);
        send("p"); finish_command; $display("");
        cpu_stopped = 0;
        // Three checkpoints with the CPU running; each stops and restarts it.
        run(60); send("g"); @(posedge clock); wait (cpu_stopped); remember(1); finish_command;
        if (cpu_stopped) $display("FAIL the CPU is not running after checkpoint 1");
        run(60); send("g"); @(posedge clock); wait (cpu_stopped); remember(2); finish_command;
        run(60); send("g"); @(posedge clock); wait (cpu_stopped); remember(3); finish_command;
        // More play, then back to the last checkpoint ...
        run(80);
        send("r"); send("0"); send("0"); finish_command; $display(""); compare(3);
        // ... on from there, then back two more ...
        cpu_stopped = 0; run(30);
        send("r"); send("0"); send("2"); finish_command; $display(""); compare(1);
        // ... a new checkpoint on that line, play, and back past everything.
        cpu_stopped = 0; run(50); send("g"); @(posedge clock); wait (cpu_stopped); remember(4); finish_command;
        run(20);
        send("r"); send("0"); send("0"); finish_command; $display(""); compare(4);
        cpu_stopped = 0; run(20);
        send("r"); send("3"); send("f"); finish_command; $display(""); compare(0);
        send("i"); finish_command; $display("");
        if (good_seen == 0 || stale_seen == 0) $display("FAIL mirror good %0d, stale %0d: one way was never used", good_seen, stale_seen);
        $display("END");
        $finish;
    end
    initial begin repeat (400000000) @(posedge clock); $display("FAIL timeout"); $finish; end
endmodule
"""


@unittest.skipUnless(shutil.which("iverilog") and shutil.which("vvp"), "iverilog not installed")
class RingControlTest(unittest.TestCase):
    def test_checkpoints_and_rewinds(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "tb.v").write_text(BENCH, encoding="ascii")
            compiled = subprocess.run(["iverilog", "-g2012", "-s", "testbench", "-o", "tb.vvp", *map(str, SOURCES), "tb.v"],
                                      cwd=root, capture_output=True, text=True)
            if compiled.returncode:
                raise AssertionError(compiled.stderr)
            done = subprocess.run(["vvp", "tb.vvp"], cwd=root, capture_output=True, text=True, timeout=3000)
        lines = [line for line in done.stdout.splitlines() if line.strip() and "$finish" not in line]
        self.assertEqual([line for line in lines if "FAIL" in line], [], done.stdout[-3000:])
        self.assertEqual(lines[-1], "END", done.stdout[-2000:])
        # Each rewind's report gives the position and state of the checkpoint
        # gone back to; the first number is the checkpoints still held.
        reports = [line for line in lines if line.startswith("i")]
        wants = [line.split()[1:] for line in lines if line.startswith("WANT")]
        self.assertEqual(len(reports), 6, lines)
        self.assertEqual([r[1:3] for r in reports], ["00", "03", "01", "02", "00", "00"])
        for report, want in zip(reports[1:5], wants):
            self.assertEqual([report[3:7], report[7:11], report[11:15], report[15:17]], [w.upper() for w in want])
            self.assertEqual(report[17], "0")
        self.assertEqual(reports[5][3:], reports[4][3:])


if __name__ == "__main__":
    unittest.main()
