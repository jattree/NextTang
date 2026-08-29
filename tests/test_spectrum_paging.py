"""Behavioural proof for the ZX Spectrum 128K memory map.

The paging port is easy to implement plausibly and wrongly.  The cases that
matter are the ones a 48K-shaped implementation gets away with until real 128K
software runs: partial port decoding, the lock that must survive every later
write, and bank 5 appearing at two addresses at once.
"""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
PAGING_RTL = REPO_ROOT / "rtl" / "memory" / "nexttang_spectrum_paging.v"


def run_testbench(body: str) -> str:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        testbench = root / "testbench.v"
        executable = root / "testbench.vvp"
        testbench.write_text(body, encoding="ascii")
        compiled = subprocess.run(
            ["iverilog", "-g2012", "-Wall", "-s", "testbench", "-o",
             str(executable), str(PAGING_RTL), str(testbench)],
            cwd=REPO_ROOT, check=False, capture_output=True, text=True,
        )
        if compiled.returncode:
            raise AssertionError(compiled.stderr)
        result = subprocess.run(
            ["vvp", str(executable)], cwd=REPO_ROOT,
            check=False, capture_output=True, text=True,
        )
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)
        return result.stdout


HARNESS = r"""
`timescale 1ns/1ps
module testbench;
    reg clock = 0;
    reg reset = 1;
    reg io_write = 0;
    reg [15:0] io_address = 16'h7ffd;
    reg [7:0] io_data = 8'h00;
    reg [15:0] cpu_address = 16'h0000;

    wire cpu_is_rom;
    wire [2:0] cpu_bank;
    wire rom_select;
    wire screen_bank;
    wire paging_locked;

    always #5 clock = ~clock;

    nexttang_spectrum_paging paging (
        .clock(clock), .reset(reset),
        .io_write(io_write), .io_address(io_address), .io_data(io_data),
        .cpu_address(cpu_address),
        .cpu_is_rom(cpu_is_rom), .cpu_bank(cpu_bank),
        .rom_select(rom_select), .screen_bank(screen_bank),
        .paging_locked(paging_locked)
    );

    task write_port(input [15:0] address, input [7:0] value);
        begin
            @(negedge clock);
            io_address = address; io_data = value; io_write = 1;
            @(posedge clock);
            @(negedge clock);
            io_write = 0;
        end
    endtask

    task expect_bank(input [15:0] address, input [2:0] want);
        begin
            cpu_address = address;
            #1;
            if (cpu_bank !== want)
                $fatal(1, "address %04x expected bank %0d, got %0d",
                       address, want, cpu_bank);
        end
    endtask
BODY
endmodule
"""


class SpectrumPagingTests(unittest.TestCase):
    def test_fixed_banks_never_move(self) -> None:
        """0x4000 is always bank 5 and 0x8000 always bank 2."""
        output = run_testbench(HARNESS.replace("BODY", r"""
    initial begin
        repeat (2) @(posedge clock);
        reset = 0;

        write_port(16'h7ffd, 8'h03);
        expect_bank(16'h4000, 3'd5);
        expect_bank(16'h7fff, 3'd5);
        expect_bank(16'h8000, 3'd2);
        expect_bank(16'hbfff, 3'd2);
        expect_bank(16'hc000, 3'd3);

        write_port(16'h7ffd, 8'h06);
        expect_bank(16'h4000, 3'd5);
        expect_bank(16'h8000, 3'd2);
        expect_bank(16'hc000, 3'd6);

        $display("FIXED_BANKS_OK");
        $finish;
    end
"""))
        self.assertIn("FIXED_BANKS_OK", output)

    def test_bank_five_can_appear_at_two_addresses(self) -> None:
        """Selecting bank 5 at 0xC000 aliases it with 0x4000, as on hardware."""
        output = run_testbench(HARNESS.replace("BODY", r"""
    initial begin
        repeat (2) @(posedge clock);
        reset = 0;

        write_port(16'h7ffd, 8'h05);
        expect_bank(16'h4000, 3'd5);
        expect_bank(16'hc000, 3'd5);

        $display("BANK_ALIAS_OK");
        $finish;
    end
"""))
        self.assertIn("BANK_ALIAS_OK", output)

    def test_port_is_decoded_on_a15_and_a1_only(self) -> None:
        """Any address with A15 and A1 low reaches the port; others must not.

        Software genuinely writes the paging port at addresses other than
        0x7FFD, so a full 16-bit compare looks correct and fails in the field.
        """
        output = run_testbench(HARNESS.replace("BODY", r"""
    initial begin
        repeat (2) @(posedge clock);
        reset = 0;

        // A15 = 0, A1 = 0 in all three, so all three must page.
        write_port(16'h7ffd, 8'h01);
        expect_bank(16'hc000, 3'd1);
        write_port(16'h1ffd, 8'h02);
        expect_bank(16'hc000, 3'd2);
        write_port(16'h0000, 8'h04);
        expect_bank(16'hc000, 3'd4);

        // A1 high, must be ignored.
        write_port(16'h7fff, 8'h07);
        expect_bank(16'hc000, 3'd4);
        // A15 high, must be ignored.
        write_port(16'hfffd, 8'h07);
        expect_bank(16'hc000, 3'd4);

        $display("PORT_DECODE_OK");
        $finish;
    end
"""))
        self.assertIn("PORT_DECODE_OK", output)

    def test_lock_bit_freezes_every_later_write(self) -> None:
        """Bit 5 latches the whole port until reset, not just the bank."""
        output = run_testbench(HARNESS.replace("BODY", r"""
    initial begin
        repeat (2) @(posedge clock);
        reset = 0;

        write_port(16'h7ffd, 8'h30);   // bank 0, ROM 1, locked
        if (!paging_locked) $fatal(1, "bit 5 must lock paging");
        if (!rom_select) $fatal(1, "ROM select was not captured with the lock");

        write_port(16'h7ffd, 8'h07);   // must be ignored entirely
        expect_bank(16'hc000, 3'd0);
        if (!rom_select) $fatal(1, "ROM select changed after the lock");
        if (!paging_locked) $fatal(1, "lock cleared itself");

        // Only a reset releases it.
        @(negedge clock); reset = 1;
        @(posedge clock); @(negedge clock); reset = 0;
        if (paging_locked) $fatal(1, "reset must release the lock");
        write_port(16'h7ffd, 8'h07);
        expect_bank(16'hc000, 3'd7);

        $display("LOCK_OK");
        $finish;
    end
"""))
        self.assertIn("LOCK_OK", output)

    def test_screen_and_rom_selects_follow_their_bits(self) -> None:
        """Bit 3 picks the displayed bank and bit 4 the ROM."""
        output = run_testbench(HARNESS.replace("BODY", r"""
    initial begin
        repeat (2) @(posedge clock);
        reset = 0;

        if (screen_bank !== 1'b0 || rom_select !== 1'b0)
            $fatal(1, "reset must select the editor ROM and bank 5 screen");

        write_port(16'h7ffd, 8'h08);
        if (screen_bank !== 1'b1) $fatal(1, "bit 3 must select the bank 7 screen");
        if (rom_select !== 1'b0) $fatal(1, "bit 3 must not disturb the ROM");

        write_port(16'h7ffd, 8'h10);
        if (rom_select !== 1'b1) $fatal(1, "bit 4 must select 48K BASIC");
        if (screen_bank !== 1'b0) $fatal(1, "bit 4 must not disturb the screen");

        $display("SELECTS_OK");
        $finish;
    end
"""))
        self.assertIn("SELECTS_OK", output)

    def test_rom_occupies_only_the_bottom_16k(self) -> None:
        output = run_testbench(HARNESS.replace("BODY", r"""
    initial begin
        repeat (2) @(posedge clock);
        reset = 0;

        cpu_address = 16'h0000; #1;
        if (!cpu_is_rom) $fatal(1, "0x0000 must be ROM");
        cpu_address = 16'h3fff; #1;
        if (!cpu_is_rom) $fatal(1, "0x3fff must be ROM");
        cpu_address = 16'h4000; #1;
        if (cpu_is_rom) $fatal(1, "0x4000 must be RAM");
        cpu_address = 16'hffff; #1;
        if (cpu_is_rom) $fatal(1, "0xffff must be RAM");

        $display("ROM_WINDOW_OK");
        $finish;
    end
"""))
        self.assertIn("ROM_WINDOW_OK", output)


if __name__ == "__main__":
    unittest.main()
