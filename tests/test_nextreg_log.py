"""The NextREG log must record writes and dump them between status lines.

rtl/smoke/nexttang_nextreg_log.v copies NextREG writes and the main video and
paging port writes, and sends the copy over the UART it shares with the status
reporter, starting only once that reporter has gone quiet.
"""

from pathlib import Path
import unittest

from test_machine_clocks import run_testbench

REPO_ROOT = Path(__file__).resolve().parents[1]
LOG_RTL = REPO_ROOT / "rtl" / "smoke" / "nexttang_nextreg_log.v"

TESTBENCH = r"""
`timescale 1ns/1ps
module testbench;
    reg clock = 0;
    reg reset = 1;
    reg nr_write = 0;
    reg [7:0] nr_register = 0;
    reg [7:0] nr_data = 0;
    reg iorq_n = 1, wr_n = 1, m1_n = 1;
    reg [15:0] address = 0;
    reg [7:0] data = 0;
    reg other_transmit = 1;
    wire sending, transmit;

    nexttang_nextreg_log #(
        .CLOCK_HZ(8), .BAUD_RATE(1), .PERIOD_CLOCKS(100), .QUIET_CLOCKS(20)
    ) dut (
        .clock(clock), .reset(reset),
        .nr_write(nr_write), .nr_register(nr_register), .nr_data(nr_data),
        .iorq_n(iorq_n), .wr_n(wr_n), .m1_n(m1_n), .address(address), .data(data),
        .other_transmit(other_transmit), .sending(sending), .transmit(transmit)
    );

    always #5 clock = !clock;

    task automatic nextreg(input [7:0] register, input [7:0] value);
        begin
            @(negedge clock);
            nr_register = register; nr_data = value; nr_write = 1;
            @(negedge clock);
            nr_write = 0;
        end
    endtask

    // A copper write followed straight away by the CPU's: the strobe stays
    // high for two cycles and each cycle is its own write.
    task automatic back_to_back(input [7:0] first_register, input [7:0] first_value,
                                input [7:0] second_register, input [7:0] second_value);
        begin
            @(negedge clock);
            nr_register = first_register; nr_data = first_value; nr_write = 1;
            @(negedge clock);
            nr_register = second_register; nr_data = second_value;
            @(negedge clock);
            nr_write = 0;
        end
    endtask

    task automatic port_write(input [15:0] port, input [7:0] value);
        begin
            @(negedge clock);
            address = port; data = value; iorq_n = 0; wr_n = 0;
            repeat (2) @(negedge clock);
            iorq_n = 1; wr_n = 1;
        end
    endtask

    reg [7:0] received;
    integer i;
    always begin
        @(negedge transmit);
        repeat (4) @(posedge clock);
        for (i = 0; i < 8; i = i + 1) begin
            repeat (8) @(posedge clock);
            received[i] = transmit;
        end
        repeat (8) @(posedge clock);
        $write("%c", received);
    end

    initial begin
        repeat (3) @(negedge clock);
        reset = 0;
        nextreg(8'h15, 8'h21);
        nextreg(8'h69, 8'h80);
        nextreg(8'hff, 8'h5a);
        nextreg(8'h15, 8'h23);
        back_to_back(8'h12, 8'h09, 8'h57, 8'h44);
        port_write(16'h123b, 8'h02);
        port_write(16'h7ffd, 8'h10);
        port_write(16'h40ff, 8'h3e);
        // The other transmitter is busy until well past the period, so the
        // dump must wait for it to go quiet.
        other_transmit = 0;
        repeat (300) @(negedge clock);
        if (sending) $fatal(1, "dumped while the status line was busy");
        other_transmit = 1;
        repeat (40) @(negedge clock);
        if (!sending) $fatal(1, "did not start after the status line ended");
        repeat ((16 * 53 + 54 + 16 * 85) * 84 + 400) @(posedge clock);
        $display("");
        $display("LOG_DONE");
        $finish;
    end
endmodule
"""


class NextregLogTest(unittest.TestCase):
    def test_log_records_writes_and_waits_for_quiet(self) -> None:
        output = run_testbench(TESTBENCH, LOG_RTL)
        self.assertIn("LOG_DONE", output)
        lines = {line.split()[0]: line.split()[1:] for line in output.splitlines()
                 if line.startswith(("NR", "NP", "NW"))}
        self.assertEqual(len([key for key in lines if key.startswith("NR")]), 16)
        self.assertEqual(lines["NR1"][5], "23")      # 0x15, the later write
        self.assertEqual(lines["NR6"][9], "80")      # 0x69
        self.assertEqual(lines["NRf"][15], "5a")     # 0xff
        self.assertEqual(lines["NR0"][0], "00")
        self.assertEqual(lines["NP"], ["123b=02", "7ffd=10", "dffd=00", "1ffd=00",
                                       "00ff=3e", "nn=0006"])
        history = [entry for row in range(16) for entry in lines[f"NW{row:x}"]]
        self.assertEqual(len(history), 256)
        # Oldest first: 250 never-written entries, then the six writes in order.
        self.assertEqual(history[-6:], ["1521", "6980", "ff5a", "1523", "1209", "5744"])
        self.assertEqual(set(history[:-6]), {"0000"})
        self.assertEqual(lines["NR1"][2], "09")      # 0x12, first of the pair
        self.assertEqual(lines["NR5"][7], "44")      # 0x57, second of the pair


if __name__ == "__main__":
    unittest.main()
