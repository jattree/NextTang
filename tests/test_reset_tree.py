"""Behavioural tests for asynchronous assertion and per-domain reset release."""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
RESET_RTL = REPO_ROOT / "rtl" / "reset" / "nexttang_reset_tree.v"
RESET_RELEASE_RTL = REPO_ROOT / "rtl" / "reset" / "nexttang_reset_release.v"


class ResetTreeTest(unittest.TestCase):
    def test_domain_dependencies_and_release(self) -> None:
        testbench = r"""
`timescale 1ns/1ps
module testbench;
    reg system_clock = 0;
    reg machine_clock = 0;
    reg pixel_clock = 0;
    reg force_reset = 1;
    reg system_clock_locked = 0;
    reg machine_clock_locked = 0;
    reg video_clock_locked = 0;
    reg memory_calibrated = 0;
    reg memory_fault = 0;
    wire system_reset;
    wire machine_reset;
    wire pixel_reset;

    always #2 system_clock = ~system_clock;
    always #3 machine_clock = ~machine_clock;
    always #5 pixel_clock = ~pixel_clock;

    nexttang_reset_tree #(.RELEASE_STAGES(3)) dut (
        .system_clock(system_clock), .machine_clock(machine_clock),
        .pixel_clock(pixel_clock), .force_reset(force_reset),
        .system_clock_locked(system_clock_locked),
        .machine_clock_locked(machine_clock_locked),
        .video_clock_locked(video_clock_locked),
        .memory_calibrated(memory_calibrated), .memory_fault(memory_fault),
        .system_reset(system_reset), .machine_reset(machine_reset),
        .pixel_reset(pixel_reset)
    );

    task wait_system_release;
        begin
            repeat (2) begin
                @(posedge system_clock); #1;
                if (!system_reset) $fatal(1, "system reset released early");
            end
            @(posedge system_clock); #1;
            if (system_reset) $fatal(1, "system reset did not release");
        end
    endtask

    task wait_machine_release;
        begin
            repeat (2) begin
                @(posedge machine_clock); #1;
                if (!machine_reset) $fatal(1, "machine reset released early");
            end
            @(posedge machine_clock); #1;
            if (machine_reset) $fatal(1, "machine reset did not release");
        end
    endtask

    task wait_pixel_release;
        begin
            repeat (2) begin
                @(posedge pixel_clock); #1;
                if (!pixel_reset) $fatal(1, "pixel reset released early");
            end
            @(posedge pixel_clock); #1;
            if (pixel_reset) $fatal(1, "pixel reset did not release");
        end
    endtask

    initial begin
        #1;
        if (!system_reset || !machine_reset || !pixel_reset)
            $fatal(1, "reset tree did not start asserted");

        system_clock_locked = 1;
        machine_clock_locked = 1;
        video_clock_locked = 1;
        memory_calibrated = 1;
        force_reset = 0;

        fork
            wait_system_release();
            wait_machine_release();
            wait_pixel_release();
        join

        #1 force_reset = 1;
        #1;
        if (!system_reset || !machine_reset || !pixel_reset)
            $fatal(1, "force reset was not asserted asynchronously");

        force_reset = 0;
        fork
            wait_system_release();
            wait_machine_release();
            wait_pixel_release();
        join

        #1 memory_calibrated = 0;
        #1;
        if (!machine_reset || system_reset || pixel_reset)
            $fatal(1, "memory calibration affected the wrong domains");

        memory_calibrated = 1;
        wait_machine_release();

        #1 memory_fault = 1;
        #1;
        if (!machine_reset || system_reset || pixel_reset)
            $fatal(1, "memory fault affected the wrong domains");

        memory_fault = 0;
        wait_machine_release();

        #1 video_clock_locked = 0;
        #1;
        if (!pixel_reset || system_reset || machine_reset)
            $fatal(1, "video lock affected the wrong domains");

        video_clock_locked = 1;
        wait_pixel_release();

        #1 system_clock_locked = 0;
        #1;
        if (!system_reset || machine_reset || pixel_reset)
            $fatal(1, "system lock affected the wrong domains");

        $display("RESET_TREE_PASS");
        $finish;
    end
endmodule
"""

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
                    str(RESET_RELEASE_RTL),
                    str(RESET_RTL),
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
            self.assertIn("RESET_TREE_PASS", simulation_result.stdout)


if __name__ == "__main__":
    unittest.main()
