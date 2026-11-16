"""The rewind ring's checkpoint store (rtl/debug/nexttang_rewind_store.v) with the
dirty-block tracker, against a memory model: after any mix of machine writes,
checkpoints and rewinds, the live memory must be what it was at the checkpoint
gone back to."""

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
SOURCES = [REPO_ROOT / "rtl/debug/nexttang_dirty_blocks.v", REPO_ROOT / "rtl/debug/nexttang_rewind_store.v"]

BENCH = """
`timescale 1ns/1ps
module testbench;
    localparam BLOCK_BITS = 4;                  // 16 blocks: 4 KB of live memory
    localparam LIVE_BYTES = 1 << (BLOCK_BITS + 8);
    localparam RING_BITS = RING_BITS_VALUE;
    localparam TABLE_BITS = TABLE_BITS_VALUE;
    localparam SNAPS = 256;
    reg clock = 0; always #5 clock = ~clock;
    reg reset = 1, prime = 0, checkpoint = 0, rewind = 0;
    reg [TABLE_BITS:0] back_steps = 0;
    wire busy, done, overrun;
    wire [TABLE_BITS:0] held, went_back;
    reg write_valid = 0; reg [BLOCK_BITS-1:0] write_block = 0;
    wire scan_start, block_valid, block_ready, scan_done, scanning;
    wire [BLOCK_BITS-1:0] block;
    wire mem_request, mem_write; wire [15:0] mem_address; wire [7:0] mem_write_data;
    reg [7:0] mem_read_data = 0; reg mem_ack = 0;
    integer seed = SEED_VALUE;

    nexttang_dirty_blocks #(.BLOCK_BITS(BLOCK_BITS)) tracker (
        .clock(clock), .reset(reset), .write_valid_in(write_valid), .write_block_in(write_block),
        .scan_start(scan_start), .block_valid(block_valid), .block(block), .block_ready(block_ready),
        .scan_done(scan_done), .scanning(scanning));
    nexttang_rewind_store #(.BLOCK_BITS(BLOCK_BITS), .RING_BITS(RING_BITS), .TABLE_BITS(TABLE_BITS),
                            .ADDRESS_BITS(16), .LIVE_BASE(16'h0000), .COPY_BASE(16'h1000), .RING_BASE(16'h4000)) dut (
        .clock(clock), .reset(reset), .prime(prime), .checkpoint(checkpoint), .rewind(rewind),
        .back_steps(back_steps), .busy(busy), .done(done), .held(held), .went_back(went_back), .overrun(overrun),
        .scan_start(scan_start), .block_valid(block_valid), .block(block), .block_ready(block_ready),
        .scan_done(scan_done),
        .mem_request(mem_request), .mem_write(mem_write), .mem_address(mem_address),
        .mem_write_data(mem_write_data), .mem_read_data(mem_read_data), .mem_ack(mem_ack));

    // Memory: an access is answered one to three clocks after the request.
    reg [7:0] mem [0:65535];
    integer delay = 0;
    always @(posedge clock) begin
        mem_ack <= 0;
        if (mem_request && !mem_ack) begin
            if (delay == 0) begin
                if (mem_write) mem[mem_address] <= mem_write_data;
                mem_read_data <= mem[mem_address];
                mem_ack <= 1;
                delay <= $random(seed) & 3 ? 0 : 2;
            end else
                delay <= delay - 1;
        end
        if (mem_request && mem_write && mem_address >= 16'h4000 + (1 << RING_BITS)) begin
            $display("FAIL write outside the ring at %04x", mem_address);
        end
    end

    // The machine: writes to live memory, seen by the tracker.
    task machine_write(input [11:0] address, input [7:0] value); begin
        mem[address] = value;
        write_block <= address[11:8]; write_valid <= 1; @(posedge clock); write_valid <= 0;
    end endtask
    task command(input integer which, input integer steps); begin
        back_steps <= steps;
        prime <= which == 0; checkpoint <= which == 1; rewind <= which == 2;
        @(posedge clock); prime <= 0; checkpoint <= 0; rewind <= 0;
        @(posedge clock);
        while (busy) @(posedge clock);
        repeat (3) @(posedge clock);
    end endtask

    reg [7:0] snap [0:SNAPS * LIVE_BYTES - 1];
    integer taken = 0;                       // snapshots: 0 the prime, then one per checkpoint
    integer i, n, k, bad, round, steps, blocks, rewinds = 0, overruns = 0, most_held = 0;
    task save; begin
        for (i = 0; i < LIVE_BYTES; i = i + 1) snap[taken * LIVE_BYTES + i] = mem[i];
        taken = taken + 1;
    end endtask
    task check(input integer which, input [255:0] what); begin
        bad = 0;
        for (i = 0; i < LIVE_BYTES; i = i + 1) begin
            if (mem[i] !== snap[which * LIVE_BYTES + i]) bad = bad + 1;
            if (mem[16'h1000 + i] !== mem[i]) bad = bad + 1;
        end
        if (bad != 0) $display("FAIL %0s: %0d bytes differ from snapshot %0d (round %0d)", what, bad, which, round);
    end endtask

    initial begin repeat (40000000) @(posedge clock); $display("FAIL timeout"); $finish; end
    initial begin
        for (i = 0; i < 65536; i = i + 1) mem[i] = $random(seed);
        repeat (4) @(posedge clock); reset <= 0;
        repeat (40) @(posedge clock);
        command(0, 0); save;
        check(0, "after prime");
        for (round = 0; round < ROUNDS_VALUE; round = round + 1) begin
            // some writes, in a few blocks or in many
            blocks = ($random(seed) & 7) == 0 ? 16 : 1 + ($random(seed) & 3);
            n = $random(seed) & 31;
            for (k = 0; k < n; k = k + 1)
                machine_write({$random(seed)} % (blocks * 256), $random(seed));
            if (($random(seed) & 3) != 0) begin
                command(1, 0);
                if (overrun) begin
                    // nothing before this checkpoint can be gone back to
                    overruns = overruns + 1;
                    for (i = 0; i < LIVE_BYTES; i = i + 1) snap[i] = mem[i];
                    taken = 1;
                    if (held != 0) $display("FAIL held %0d after an overrun", held);
                end else
                    save;
                if (held > most_held) most_held = held;
                if (taken == SNAPS) begin $display("FAIL too many snapshots for the bench"); $finish; end
            end else begin
                steps = held == 0 ? 0 : {$random(seed)} % (held + 1);
                if (($random(seed) & 7) == 0) steps = steps + 3;      // more than there may be
                command(2, steps);
                if (steps > taken - 1) steps = taken - 1;
                if (went_back > steps) $display("FAIL went back %0d, asked %0d", went_back, steps);
                taken = taken - went_back;
                check(taken - 1, "after rewind");
                rewinds = rewinds + 1;
            end
            if (held > taken - 1) $display("FAIL holds %0d checkpoints, %0d were made", held, taken - 1);
        end
        $display("END rewinds=%0d overruns=%0d most_held=%0d", rewinds, overruns, most_held);
        $finish;
    end
endmodule
"""


def run(seed: int, ring_bits: int, table_bits: int, rounds: int) -> list[str]:
    bench = (BENCH.replace("SEED_VALUE", str(seed)).replace("RING_BITS_VALUE", str(ring_bits))
             .replace("TABLE_BITS_VALUE", str(table_bits)).replace("ROUNDS_VALUE", str(rounds)))
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        (root / "tb.v").write_text(bench, encoding="ascii")
        compiled = subprocess.run(["iverilog", "-g2012", "-s", "testbench", "-o", "tb.vvp", *map(str, SOURCES), "tb.v"],
                                  cwd=root, capture_output=True, text=True)
        if compiled.returncode:
            raise AssertionError(compiled.stderr)
        done = subprocess.run(["vvp", "tb.vvp"], cwd=root, capture_output=True, text=True, timeout=900)
    return [line for line in done.stdout.splitlines() if line.startswith(("FAIL", "END"))]


@unittest.skipUnless(shutil.which("iverilog") and shutil.which("vvp"), "iverilog not installed")
class RewindStoreTest(unittest.TestCase):
    def check(self, seed: int, ring_bits: int, table_bits: int, rounds: int = 120) -> dict[str, int]:
        lines = run(seed, ring_bits, table_bits, rounds)
        self.assertEqual([line for line in lines if line.startswith("FAIL")], [])
        self.assertTrue(lines and lines[-1].startswith("END"), lines)
        return {key: int(value) for key, value in (part.split("=") for part in lines[-1].split()[1:])}

    def test_roomy_ring(self) -> None:
        # Room for everything: only the table limits how far back it goes.
        for seed in (1, 2, 3):
            with self.subTest(seed=seed):
                end = self.check(seed, ring_bits=13, table_bits=3)
                self.assertGreater(end["rewinds"], 10)
                self.assertEqual(end["overruns"], 0)
                self.assertGreater(end["most_held"], 3)

    def test_small_ring_drops_the_oldest_checkpoints(self) -> None:
        # 2,048 bytes: seven records. Old checkpoints are dropped all the
        # time, and a checkpoint of all 16 blocks is more than the ring.
        seen_overrun = 0
        for seed in (4, 5, 6):
            with self.subTest(seed=seed):
                end = self.check(seed, ring_bits=11, table_bits=3)
                self.assertGreater(end["rewinds"], 10)
                seen_overrun += end["overruns"]
        self.assertGreater(seen_overrun, 0)

    def test_small_table(self) -> None:
        # Two checkpoints remembered at most.
        end = self.check(7, ring_bits=13, table_bits=1)
        self.assertEqual(end["most_held"], 2)


if __name__ == "__main__":
    unittest.main()
