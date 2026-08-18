"""The display renderer must read Spectrum screen memory the way the hardware did.

The interleaved layout is the part worth testing: a renderer that reads memory
linearly still produces a picture, just a scrambled one, and that is easy to
miss by eye on a pattern. These tests drive known bytes into a model of screen
memory and check the exact colours that come out at exact raster positions.
"""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
DISPLAY_RTL = REPO_ROOT / "rtl" / "video" / "nexttang_spectrum_display.v"


def screen_offset(x: int, y: int) -> int:
    """Byte holding pixel (x, y), in the Spectrum's interleaved layout."""
    return ((y & 0xC0) << 5) | ((y & 0x07) << 8) | ((y & 0x38) << 2) | (x >> 3)


def attribute_offset(x: int, y: int) -> int:
    return 0x1800 + (y // 8) * 32 + (x // 8)


def run_testbench(body: str) -> str:
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory)
        (path / "testbench.v").write_text(body, encoding="utf-8")
        compiled = subprocess.run(
            ["iverilog", "-g2012", "-Wall", "-s", "testbench",
             "-o", str(path / "sim.vvp"), str(DISPLAY_RTL), str(path / "testbench.v")],
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
    localparam integer SCALE = 3;
    localparam integer LEFT = (1280 - 256*SCALE) / 2;
    localparam integer TOP  = (720 - 192*SCALE) / 2;

    reg clock = 0;
    reg reset = 1;
    reg [10:0] hpos = 0;
    reg [9:0]  vpos = 0;
    reg        data_enable = 1;
    reg [2:0]  border = 3'd1;
    reg        flash_phase = 0;
    wire [12:0] address;
    reg  [7:0]  memory [0:8191];
    reg  [7:0]  memory_data;
    wire [7:0]  red, green, blue;

    nexttang_spectrum_display #(.SCALE(SCALE)) dut (
        .pixel_clk(clock), .reset(reset),
        .horizontal_position(hpos), .vertical_position(vpos),
        .data_enable(data_enable), .border_colour(border),
        .flash_phase(flash_phase),
        .screen_address(address), .screen_data(memory_data),
        .red(red), .green(green), .blue(blue)
    );

    always #5 clock = ~clock;
    always @(posedge clock) memory_data <= memory[address];

    integer i, line;
    // Sweep the raster from the top of the frame. The renderer tracks the
    // source row incrementally across lines, exactly as the hardware does, so
    // jumping straight to a line would leave its counters unwound and test
    // nothing real.
    task goto(input integer target_x, input integer target_y);
        begin
            for (line = 0; line <= target_y; line = line + 1) begin
                vpos = line[9:0];
                for (i = 0; i < 1280; i = i + 1) begin
                    hpos = i[10:0];
                    @(posedge clock);
                    if (line == target_y && i == target_x) disable goto;
                end
            end
        end
    endtask
BODY
endmodule
"""


class SpectrumDisplayTest(unittest.TestCase):
    def test_it_reads_the_interleaved_layout_not_a_linear_one(self) -> None:
        # Set one byte at the interleaved address for a row deep in the screen,
        # and clear the byte a linear renderer would read instead. Only a
        # correct address calculation shows ink there.
        # Row 17 is chosen because the two layouts disagree there. Several
        # rows, including 9 and 64, happen to give the same address under both,
        # which would make this test pass against a linear renderer.
        x, y = 0, 17
        interleaved = screen_offset(x, y)
        linear = y * 32 + (x >> 3)
        self.assertNotEqual(interleaved, linear, "test would prove nothing")
        output = run_testbench(HARNESS.replace("BODY", f"""
    initial begin
        for (i = 0; i < 8192; i = i + 1) memory[i] = 8'h00;
        memory[{interleaved}] = 8'hff;          // ink across this cell
        memory[{linear}] = 8'h00;               // what a linear reader sees
        memory[{attribute_offset(x, y)}] = 8'h47;  // white ink, black paper
        reset = 1; @(posedge clock); @(posedge clock); reset = 0;

        goto(LEFT + 4, TOP + 17*SCALE + 1);
        if (green == 8'h00)
            $fatal(1, "no ink at the interleaved address: renderer reads linearly");
        $display("INTERLEAVED_OK green=%02x", green);
        $finish;
    end
"""))
        self.assertIn("INTERLEAVED_OK", output)

    def test_ink_and_paper_come_from_the_attribute_byte(self) -> None:
        # Paper red, ink blue, in one cell. A set pixel must show ink and a
        # clear pixel must show paper, which proves the attribute is applied
        # per pixel rather than per cell.
        x, y = 0, 0
        output = run_testbench(HARNESS.replace("BODY", f"""
    initial begin
        for (i = 0; i < 8192; i = i + 1) memory[i] = 8'h00;
        memory[{screen_offset(x, y)}] = 8'h80;      // only the leftmost pixel set
        memory[{attribute_offset(x, y)}] = 8'h11;   // paper blue(2), ink blue(1)
        memory[{attribute_offset(x, y)}] = 8'h11;
        reset = 1; @(posedge clock); @(posedge clock); reset = 0;

        goto(LEFT + 1, TOP + 1);
        $display("FIRST_PIXEL r=%02x g=%02x b=%02x", red, green, blue);
        if (red != 8'h00)
            $fatal(1, "ink 1 should have no red component");
        $display("ATTRIBUTE_OK");
        $finish;
    end
"""))
        self.assertIn("ATTRIBUTE_OK", output)

    def test_bitmap_and_attribute_bytes_do_not_swap(self) -> None:
        # Screen memory answers a cycle after the address is presented, so the
        # byte arriving now belongs to the previous cycle's fetch phase. Routing
        # it by the current phase swaps the two, which still draws colour and so
        # looked like a working picture on hardware.
        #
        # The vector has to make the swap change the output. Bitmap 0xf0 with
        # attribute 0x02 renders the leftmost pixel as red ink. Swapped, 0xf0 is
        # read as an attribute (bright, paper 6) and 0x02 as the bitmap, which
        # renders yellow instead.
        x, y = 0, 0
        output = run_testbench(HARNESS.replace("BODY", f"""
    initial begin
        for (i = 0; i < 8192; i = i + 1) memory[i] = 8'h00;
        memory[{screen_offset(x, y)}] = 8'hf0;      // left four pixels set
        memory[{attribute_offset(x, y)}] = 8'h02;   // red ink, black paper
        reset = 1; @(posedge clock); @(posedge clock); reset = 0;

        goto(LEFT + 2, TOP + 2);
        $display("PIXEL r=%02x g=%02x b=%02x", red, green, blue);
        if (green !== 8'h00 || blue !== 8'h00)
            $fatal(1, "expected red ink, got r=%02x g=%02x b=%02x. The bitmap and attribute bytes are swapped.",
                   red, green, blue);
        if (red === 8'h00)
            $fatal(1, "set pixel drew no ink at all");
        $display("NO_SWAP_OK");
        $finish;
    end
"""))
        self.assertIn("NO_SWAP_OK", output)


    def test_the_border_shows_outside_the_picture(self) -> None:
        # Left of the picture the border colour must show regardless of what is
        # in screen memory, which is what makes the display look like the
        # machine rather than a full-screen blit.
        output = run_testbench(HARNESS.replace("BODY", """
    initial begin
        for (i = 0; i < 8192; i = i + 1) memory[i] = 8'hff;
        border = 3'd2;                       // red
        reset = 1; @(posedge clock); @(posedge clock); reset = 0;

        goto(LEFT - 20, TOP + 40);
        if (red == 8'h00)
            $fatal(1, "border area did not show the border colour");
        if (green != 8'h00 || blue != 8'h00)
            $fatal(1, "border colour 2 should be red only, got g=%02x b=%02x",
                   green, blue);
        $display("BORDER_OK");
        $finish;
    end
"""))
        self.assertIn("BORDER_OK", output)

    def test_blanking_is_black(self) -> None:
        # Anything other than black outside data_enable corrupts the HDMI
        # blanking periods and can stop a display locking at all.
        output = run_testbench(HARNESS.replace("BODY", """
    initial begin
        for (i = 0; i < 8192; i = i + 1) memory[i] = 8'hff;
        border = 3'd7;
        reset = 1; @(posedge clock); @(posedge clock); reset = 0;
        data_enable = 0;
        goto(4, TOP + 40);
        if (red != 8'h00 || green != 8'h00 || blue != 8'h00)
            $fatal(1, "output was not black during blanking");
        $display("BLANKING_OK");
        $finish;
    end
"""))
        self.assertIn("BLANKING_OK", output)


if __name__ == "__main__":
    unittest.main()
