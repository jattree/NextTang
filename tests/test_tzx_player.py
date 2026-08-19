"""Behavioural tests for the bounded TZX pulse player."""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
ROM_RTL = REPO_ROOT / "rtl" / "memory" / "nexttang_rom.v"
PLAYER_RTL = REPO_ROOT / "rtl" / "input" / "nexttang_tzx_player.v"


class TzxPlayerTests(unittest.TestCase):
    def run_player(self, tape: bytes, expected_toggles: int, expect_fault: int) -> str:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            (root / "tape.mem").write_text(
                "".join(f"{value:02x}\n" for value in tape), encoding="ascii"
            )
            testbench = f"""
`timescale 1ns/1ps
module testbench;
    reg clock = 0;
    reg reset = 1;
    reg start = 0;
    wire ear, active, finished, fault, fault_unsupported;
    wire [7:0] current_block;
    wire [16:0] byte_position;
    integer toggles = 0;
    reg previous_ear = 0;

    always #5 clock = ~clock;
    always @(posedge clock) begin
        previous_ear <= ear;
        if (ear != previous_ear)
            toggles <= toggles + 1;
    end

    nexttang_tzx_player #(
        .CLOCK_HZ(1000),
        .TZX_BYTES({len(tape)}),
        .IMAGE("tape.mem"),
        .STANDARD_PILOT_LENGTH(2),
        .STANDARD_SYNC1_LENGTH(2),
        .STANDARD_SYNC2_LENGTH(2),
        .STANDARD_ZERO_LENGTH(2),
        .STANDARD_ONE_LENGTH(3),
        .HEADER_PILOT_PULSES(3),
        .DATA_PILOT_PULSES(2)
    ) dut (
        .clock(clock), .reset(reset), .start(start), .ear(ear),
        .active(active), .finished(finished), .fault(fault),
        .fault_unsupported(fault_unsupported),
        .current_block(current_block), .byte_position(byte_position)
    );

    initial begin
        repeat (2) @(posedge clock);
        reset = 0;
        start = 1;
        repeat (2000) begin
            @(posedge clock);
            if (finished) begin
                #1;
                if (fault != {expect_fault})
                    $fatal(1, "fault result was wrong");
                if (toggles != {expected_toggles})
                    $fatal(1, "pulse count was wrong: %0d", toggles);
                $display("PASS toggles=%0d block=%02x position=%0d", toggles,
                         current_block, byte_position);
                $finish;
            end
        end
        $fatal(1, "player did not finish");
    end
endmodule
"""
            testbench_path = root / "testbench.v"
            testbench_path.write_text(testbench, encoding="utf-8")
            simulation = root / "simulation"
            compile_result = subprocess.run(
                [
                    "iverilog",
                    "-g2012",
                    "-o",
                    str(simulation),
                    str(ROM_RTL),
                    str(PLAYER_RTL),
                    str(testbench_path),
                ],
                cwd=root,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                compile_result.returncode,
                0,
                compile_result.stdout + compile_result.stderr,
            )
            result = subprocess.run(
                ["vvp", str(simulation)],
                cwd=root,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return result.stdout

    def test_standard_speed_header_block_and_pause(self) -> None:
        tape = (
            b"ZXTape!\x1a\x01\x14"
            b"\x30\x02ok"
            b"\x10\x02\x00\x01\x00\x00"
        )
        output = self.run_player(tape, expected_toggles=22, expect_fault=0)
        self.assertIn("PASS toggles=22", output)

    def test_turbo_block_honours_pilot_and_used_bit_count(self) -> None:
        turbo_header = (
            (2).to_bytes(2, "little")
            + (2).to_bytes(2, "little")
            + (2).to_bytes(2, "little")
            + (2).to_bytes(2, "little")
            + (3).to_bytes(2, "little")
            + (2).to_bytes(2, "little")
            + b"\x03"
            + b"\x00\x00"
            + b"\x01\x00\x00"
        )
        tape = b"ZXTape!\x1a\x01\x14\x11" + turbo_header + b"\xa0"
        output = self.run_player(tape, expected_toggles=10, expect_fault=0)
        self.assertIn("PASS toggles=10", output)

    def test_standard_pulses_are_the_lengths_the_rom_decodes(self) -> None:
        # The other tests count edges. The ROM decodes the interval between
        # them, so run at the shipped pulse lengths and measure. Only the pilot
        # count is shortened. The payload is 0x01 because a byte with one bit
        # set also pins the bit order: seven short pairs then one long pair.
        data = b"\x00\x01"
        parity = 0
        for byte in data:
            parity ^= byte
        block = data + bytes([parity])
        tape = (
            b"ZXTape!\x1a\x01\x14"
            + b"\x10"
            + (10).to_bytes(2, "little")
            + len(block).to_bytes(2, "little")
            + block
        )

        widths = self.measure_widths(tape)
        pilot = widths[1:6]
        self.assertTrue(
            all(abs(width - 2168) <= 4 for width in pilot),
            f"pilot pulses were {pilot}",
        )

        sync = widths[6:8]
        self.assertAlmostEqual(sync[0], 667, delta=4)
        self.assertAlmostEqual(sync[1], 735, delta=4)

        # Flag 0x00 is sixteen short pulses, then 0x01 is fourteen short and
        # two long, which is only true most significant bit first.
        bits = widths[8:40]
        self.assertTrue(
            all(abs(width - 855) <= 8 for width in bits[:30]),
            f"zero bits were {bits[:30]}",
        )
        self.assertTrue(
            all(abs(width - 1710) <= 8 for width in bits[30:32]),
            f"the set bit was {bits[30:32]}",
        )

    def test_no_pulse_is_shorter_than_the_shortest_real_one(self) -> None:
        # The last pulse of a block had been clipped by the pause forcing the
        # line low straight after it, which emitted a two cycle pulse. The ROM
        # counts that as an edge, and it lands on the parity byte, so the block
        # loads its payload and is then rejected.
        data = b"\x00\x01\x02\x03"
        parity = 0
        for byte in data:
            parity ^= byte
        block = data + bytes([parity])
        tape = (
            b"ZXTape!\x1a\x01\x14"
            + b"\x10"
            + (50).to_bytes(2, "little")
            + len(block).to_bytes(2, "little")
            + block
        )

        # The real pilots are 8063 and 3223 pulses, both odd, so the line ends
        # a block high. An even pilot hides the fault, because forcing it low
        # is then a no-op.
        widths = self.measure_widths(tape, header_pilot=7)
        # The first interval is the run up to the first edge, not a pulse.
        pulses = widths[1:]
        self.assertTrue(pulses, "the player emitted nothing")
        shortest = min(pulses)
        self.assertGreaterEqual(
            shortest, 600,
            f"emitted a {shortest} cycle pulse; the shortest real one is the "
            f"667 cycle sync, so this is a clipped edge",
        )

    def measure_widths(self, tape: bytes, header_pilot: int = 6) -> list[int]:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            (root / "tape.mem").write_text(
                "".join(f"{value:02x}\n" for value in tape), encoding="ascii"
            )
            testbench = f"""
`timescale 1ns/1ps
module testbench;
    reg clock = 0;
    reg reset = 1;
    reg start = 0;
    wire ear, active, finished, fault, fault_unsupported;
    wire [7:0] current_block;
    wire [16:0] byte_position;
    integer cycles = 0;
    integer last_edge = 0;
    reg previous_ear = 0;

    always #5 clock = ~clock;

    nexttang_tzx_player #(
        .CLOCK_HZ(3500000),
        .TZX_BYTES({len(tape)}),
        .IMAGE("tape.mem"),
        .HEADER_PILOT_PULSES({header_pilot}),
        .DATA_PILOT_PULSES(4)
    ) dut (
        .clock(clock), .reset(reset), .start(start), .ear(ear),
        .active(active), .finished(finished), .fault(fault),
        .fault_unsupported(fault_unsupported),
        .current_block(current_block), .byte_position(byte_position)
    );

    always @(posedge clock) begin
        cycles <= cycles + 1;
        previous_ear <= ear;
        if (ear != previous_ear) begin
            $display("WIDTH %0d", cycles - last_edge);
            last_edge <= cycles;
        end
    end

    initial begin
        repeat (2) @(posedge clock);
        reset = 0;
        start = 1;
        repeat (400000) begin
            @(posedge clock);
            if (finished) begin
                $display("DONE");
                $finish;
            end
        end
        $fatal(1, "player did not finish");
    end
endmodule
"""
            (root / "testbench.v").write_text(testbench, encoding="utf-8")
            simulation = root / "simulation"
            compiled = subprocess.run(
                ["iverilog", "-g2012", "-o", str(simulation), str(ROM_RTL),
                 str(PLAYER_RTL), str(root / "testbench.v")],
                cwd=root, check=False, capture_output=True, text=True,
            )
            self.assertEqual(
                compiled.returncode, 0, compiled.stdout + compiled.stderr
            )
            result = subprocess.run(
                ["vvp", str(simulation)], cwd=root, check=False,
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stdout)
            return [
                int(line.split()[1])
                for line in result.stdout.splitlines()
                if line.startswith("WIDTH ")
            ]

    def test_unsupported_block_fails_closed(self) -> None:
        tape = b"ZXTape!\x1a\x01\x14\x12"
        output = self.run_player(tape, expected_toggles=0, expect_fault=1)
        self.assertIn("block=12", output)


if __name__ == "__main__":
    unittest.main()
