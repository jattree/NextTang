"""Posted writes in the Gowin DDR3 adapter must never let a read see old data.

The controller model below accepts a write and only applies it to its memory
some cycles later, up to VISIBILITY, the way the exact-C controller let a
following read return old data in hardware. It serves reads from whatever its
memory holds when the read is accepted. The adapter, with POSTED_WRITES set,
completes writes at once and must patch every read with pending writes to its
line. Random reads and byte writes over four lines are checked against the
data last written.

A second run gives the adapter a drain shorter than the controller's delay and
expects a stale read, so the check is shown able to fail.
"""

from pathlib import Path
import unittest

from test_machine_clocks import run_testbench

REPO_ROOT = Path(__file__).resolve().parents[1]
ADAPTER_RTL = REPO_ROOT / "rtl" / "memory" / "nexttang_gowin_ddr3_ui_adapter.v"


def testbench(drain: int, visibility: int, expect_stale: bool, seed: int = 1) -> str:
    return r"""
`timescale 1ns/1ps
module testbench;
    localparam integer DRAIN = %(drain)d;
    localparam integer VISIBILITY = %(visibility)d;
    reg clock = 0;
    reg reset = 1;
    reg line_request = 0;
    wire line_ready;
    reg line_write = 0;
    reg [16:0] line_address = 0;
    reg [127:0] line_write_data = 0;
    reg [15:0] line_write_enable = 0;
    wire line_response_valid;
    wire [127:0] line_read_data;
    reg controller_command_ready = 1;
    wire [2:0] controller_command;
    wire controller_command_enable;
    wire [28:0] controller_address;
    reg controller_write_data_ready = 1;
    wire [255:0] controller_write_data;
    wire controller_write_data_enable;
    wire controller_write_data_end;
    wire [31:0] controller_write_data_mask;
    reg [255:0] controller_read_data = 0;
    reg controller_read_data_valid = 0;
    wire controller_burst;

    always #5 clock = ~clock;

    nexttang_gowin_ddr3_ui_adapter #(
        .WRITE_DRAIN_CYCLES(DRAIN), .POSTED_WRITES(1), .PENDING_LINES(4)
    ) dut (
        .clock(clock), .reset(reset), .line_request(line_request),
        .line_ready(line_ready), .line_write(line_write),
        .line_address(line_address), .line_write_data(line_write_data),
        .line_write_enable(line_write_enable),
        .line_response_valid(line_response_valid),
        .line_read_data(line_read_data),
        .controller_command_ready(controller_command_ready),
        .controller_command(controller_command),
        .controller_command_enable(controller_command_enable),
        .controller_address(controller_address),
        .controller_write_data_ready(controller_write_data_ready),
        .controller_write_data(controller_write_data),
        .controller_write_data_enable(controller_write_data_enable),
        .controller_write_data_end(controller_write_data_end),
        .controller_write_data_mask(controller_write_data_mask),
        .controller_read_data(controller_read_data),
        .controller_read_data_valid(controller_read_data_valid),
        .controller_burst(controller_burst)
    );

    // ---------------------------------------------------- controller model
    // Two beats (four lines) of memory. Accepted writes wait in a queue and
    // land after a random delay of 1 to VISIBILITY cycles, in order.
    reg [255:0] memory [0:1];
    reg [255:0] queued_data [0:63];
    reg [31:0]  queued_mask [0:63];
    reg         queued_beat [0:63];
    integer     queued_due [0:63];
    integer queue_head = 0;
    integer queue_tail = 0;
    integer now = 0;
    integer read_due = -1;
    reg read_beat;
    integer byte_index;

    always @(posedge clock) begin
        now <= now + 1;
        controller_read_data_valid <= 1'b0;
        // Apply every queued write that is due, oldest first.
        while (queue_head != queue_tail && queued_due[queue_head %% 64] <= now) begin
            for (byte_index = 0; byte_index < 32; byte_index = byte_index + 1)
                if (!queued_mask[queue_head %% 64][byte_index])
                    memory[queued_beat[queue_head %% 64]][byte_index*8 +: 8] =
                        queued_data[queue_head %% 64][byte_index*8 +: 8];
            queue_head = queue_head + 1;
        end
        if (controller_command_enable && controller_write_data_enable) begin
            queued_data[queue_tail %% 64] = controller_write_data;
            queued_mask[queue_tail %% 64] = controller_write_data_mask;
            queued_beat[queue_tail %% 64] = controller_address[3];
            // In order: never due before the write ahead of it.
            queued_due[queue_tail %% 64] = now + 1 + ($urandom %% VISIBILITY);
            if (queue_tail != queue_head && queued_due[queue_tail %% 64] < queued_due[(queue_tail - 1) %% 64])
                queued_due[queue_tail %% 64] = queued_due[(queue_tail - 1) %% 64];
            queue_tail = queue_tail + 1;
        end else if (controller_command_enable) begin
            // The read sees memory as it is now.
            read_beat = controller_address[3];
            controller_read_data <= memory[controller_address[3]];
            read_due = now + 2 + ($urandom %% 6);
        end
        if (read_due == now) begin
            controller_read_data_valid <= 1'b1;
            read_due = -1;
        end
    end

    // ------------------------------------------------------ the CPU side
    reg [127:0] expected [0:3];
    integer step;
    integer line;
    integer stale = 0;
    integer seed;
    reg [127:0] data;
    reg [15:0] enable;

    initial begin
        seed = %(seed)d;
        step = $urandom(seed);
        memory[0] = 0;
        memory[1] = 0;
        expected[0] = 0; expected[1] = 0; expected[2] = 0; expected[3] = 0;
        repeat (3) @(posedge clock);
        reset = 0;
        for (step = 0; step < 4000; step = step + 1) begin
            line = $urandom %% 4;
            @(negedge clock);
            while (!line_ready) @(negedge clock);
            line_address = line;
            if ($urandom %% 2) begin
                data = {$urandom, $urandom, $urandom, $urandom};
                enable = 16'h0001 << ($urandom %% 16);
                line_write = 1;
                line_write_data = data;
                line_write_enable = enable;
                for (byte_index = 0; byte_index < 16; byte_index = byte_index + 1)
                    if (enable[byte_index])
                        expected[line][byte_index*8 +: 8] = data[byte_index*8 +: 8];
            end else begin
                line_write = 0;
            end
            line_request = 1;
            @(negedge clock);
            line_request = 0;
            while (!line_response_valid) @(negedge clock);
            if (!line_write && line_read_data !== expected[line]) begin
                stale = stale + 1;
                if (!%(expect_stale)d)
                    $fatal(1, "step %%0d: line %%0d read %%h, expected %%h",
                           step, line, line_read_data, expected[line]);
            end
            repeat ($urandom %% 4) @(negedge clock);
        end
        $display("STALE_READS %%0d", stale);
        $display("POSTED_WRITES_DONE");
        $finish;
    end
endmodule
""" % {"drain": drain, "visibility": visibility, "expect_stale": int(expect_stale), "seed": seed}


class GowinDdr3PostedWritesTest(unittest.TestCase):
    def test_reads_never_see_old_data(self) -> None:
        for seed in (1, 7, 1234):
            with self.subTest(seed=seed):
                output = run_testbench(
                    testbench(drain=48, visibility=40, expect_stale=False, seed=seed), ADAPTER_RTL)
                self.assertIn("POSTED_WRITES_DONE", output)
                self.assertIn("STALE_READS 0", output)

    def test_too_short_a_drain_is_caught(self) -> None:
        output = run_testbench(testbench(drain=4, visibility=40, expect_stale=True), ADAPTER_RTL)
        self.assertIn("POSTED_WRITES_DONE", output)
        self.assertNotIn("STALE_READS 0", output)


if __name__ == "__main__":
    unittest.main()
