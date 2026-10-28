"""The ZXNext core's own reset requests must restart it, and a hard reset must boot.

The firmware soft-resets the machine after loading its ROMs and hard-resets it
after saving settings. Without rtl/reset/nexttang_zxnext_core_reset.v the
board ignored both.
"""

from pathlib import Path
import unittest

from test_machine_clocks import run_testbench

REPO_ROOT = Path(__file__).resolve().parents[1]
RESET_RTL = REPO_ROOT / "rtl" / "reset" / "nexttang_zxnext_core_reset.v"

TESTBENCH = r"""
`timescale 1ns/1ps
module testbench;
    reg clock_28 = 0;
    reg machine_reset = 1;
    reg soft_request = 0;
    reg hard_request = 0;
    reg [2:0] video_mode = 3'd0;
    wire core_reset;
    wire core_boot;

    nexttang_zxnext_core_reset dut (
        .clock_28(clock_28),
        .machine_reset(machine_reset),
        .soft_request(soft_request),
        .hard_request(hard_request),
        .video_mode(video_mode),
        .core_reset(core_reset),
        .core_boot(core_boot)
    );

    always #17.857 clock_28 = !clock_28;

    integer cycles;
    integer boot_cycles;

    task automatic pulse(input integer which);
        begin
            @(negedge clock_28);
            if (which == 0) soft_request = 1; else hard_request = 1;
            @(negedge clock_28);
            soft_request = 0;
            hard_request = 0;
        end
    endtask

    task automatic measure;
        begin
            cycles = 0;
            boot_cycles = 0;
            while (core_reset) begin
                cycles = cycles + 1;
                if (core_boot) boot_cycles = boot_cycles + 1;
                @(negedge clock_28);
            end
        end
    endtask

    initial begin
        repeat (4) @(negedge clock_28);
        if (!core_reset || !core_boot) $fatal(1, "board reset must reset and boot the core");
        machine_reset = 0;
        @(negedge clock_28);
        if (core_reset || core_boot) $fatal(1, "core still held after board reset");

        pulse(0);
        measure;
        if (cycles != 1023 || boot_cycles != 0)
            $fatal(1, "soft reset held %0d cycles, boot %0d", cycles, boot_cycles);

        pulse(1);
        measure;
        if (cycles != 1023 || boot_cycles != 1023)
            $fatal(1, "hard reset held %0d cycles, boot %0d", cycles, boot_cycles);
        if (core_boot) $fatal(1, "boot held after hard reset");

        @(negedge clock_28);
        video_mode = 3'd7;
        @(negedge clock_28);
        measure;
        if (cycles != 1023 || boot_cycles != 0)
            $fatal(1, "video change held %0d cycles, boot %0d", cycles, boot_cycles);

        repeat (5) @(negedge clock_28);
        if (core_reset) $fatal(1, "steady video mode must not reset");
        $display("CORE_RESET_PASS");
        $finish;
    end
endmodule
"""


class ZxnextCoreResetTest(unittest.TestCase):
    def test_soft_hard_and_video_resets(self) -> None:
        output = run_testbench(TESTBENCH, RESET_RTL)
        self.assertIn("CORE_RESET_PASS", output)


if __name__ == "__main__":
    unittest.main()
