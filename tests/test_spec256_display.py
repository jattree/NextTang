"""Behavioural proof for the live Spec256 display memory path.

The important boundary is not the palette in isolation.  The renderer reads
eight independently registered Spectrum RAMs, and an off-by-one in that path
draws a perfectly stable but wrong neighbouring cell.  These tests therefore
instantiate the real renderer and the real RAM hierarchy together.
"""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
DISPLAY_RTL = REPO_ROOT / "rtl" / "video" / "nexttang_spec256_display.v"
RAM_RTL = REPO_ROOT / "rtl" / "memory" / "nexttang_spectrum_ram.v"
BLOCK_RAM_RTL = REPO_ROOT / "rtl" / "memory" / "nexttang_block_ram.v"


def run_testbench(body: str) -> str:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        testbench = root / "testbench.v"
        executable = root / "testbench.vvp"
        testbench.write_text(body, encoding="ascii")
        compiled = subprocess.run(
            [
                "iverilog",
                "-g2012",
                "-Wall",
                "-s",
                "testbench",
                "-o",
                str(executable),
                str(BLOCK_RAM_RTL),
                str(RAM_RTL),
                str(DISPLAY_RTL),
                str(testbench),
            ],
            cwd=REPO_ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
        if compiled.returncode:
            raise AssertionError(compiled.stderr)
        result = subprocess.run(
            ["vvp", str(executable)],
            cwd=REPO_ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)
        return result.stdout


HARNESS = r"""
`timescale 1ns/1ps
module testbench;
    localparam integer SCALE = 3;
    localparam integer LEFT = (1280 - 256*SCALE) / 2;
    localparam integer TOP = (720 - 192*SCALE) / 2;

    reg clock = 0;
    reg reset = 1;
    reg [10:0] hpos = 0;
    reg [9:0] vpos = TOP;
    wire [15:0] address;
    wire [63:0] memory_data;
    wire [7:0] palette_index;
    wire passthrough;
    wire [15:0] background_address;
    reg [7:0] background_memory [0:63999];
    reg [7:0] background_data = 8'h00;
    reg background_valid = 1'b0;
    integer bg;

    always #5 clock = ~clock;

    always @(posedge clock)
        background_data <= background_memory[background_address];

    nexttang_spec256_display #(.SCALE(SCALE)) display (
        .pixel_clock(clock),
        .reset(reset),
        .horizontal_position(hpos),
        .vertical_position(vpos),
        .data_enable(1'b1),
        .memory_address(address),
        .memory_data(memory_data),
        .background_address(background_address),
        .background_data(background_data),
        .background_valid(background_valid),
        .palette_index(palette_index),
        .passthrough(passthrough)
    );

    // 320x200 with the 256x192 paper centred, matching the file layout.
    task paint_background_columns;
        begin
            for (bg = 0; bg < 64000; bg = bg + 1)
                background_memory[bg] = 8'h00;
            // Row 0 of the paper is background row 4, starting at column 32.
            for (bg = 0; bg < 256; bg = bg + 1)
                background_memory[4 * 320 + 32 + bg] = 8'h40 + bg[7:0];
        end
    endtask

    genvar lane;
    generate
        for (lane = 0; lane < 8; lane = lane + 1) begin : lanes
            nexttang_spectrum_ram memory (
                .clock(clock),
                .write_enable(1'b0),
                .write_address(16'h0000),
                .write_data(8'h00),
                .read_data(),
                .port_b_clock(clock),
                .port_b_address(address),
                .port_b_data(memory_data[lane*8 +: 8])
            );
        end
    endgenerate

    integer clear_i;
    task clear_lanes;
        begin
            for (clear_i = 0; clear_i < 16384; clear_i = clear_i + 1) begin
                lanes[0].memory.bank_0.storage[clear_i] = 8'h00;
                lanes[1].memory.bank_0.storage[clear_i] = 8'h00;
                lanes[2].memory.bank_0.storage[clear_i] = 8'h00;
                lanes[3].memory.bank_0.storage[clear_i] = 8'h00;
                lanes[4].memory.bank_0.storage[clear_i] = 8'h00;
                lanes[5].memory.bank_0.storage[clear_i] = 8'h00;
                lanes[6].memory.bank_0.storage[clear_i] = 8'h00;
                lanes[7].memory.bank_0.storage[clear_i] = 8'h00;
            end
        end
    endtask

    task set_cell(input integer cell_index, input [7:0] colour);
        begin
            lanes[0].memory.bank_0.storage[cell_index] = colour[0] ? 8'hff : 8'h00;
            lanes[1].memory.bank_0.storage[cell_index] = colour[1] ? 8'hff : 8'h00;
            lanes[2].memory.bank_0.storage[cell_index] = colour[2] ? 8'hff : 8'h00;
            lanes[3].memory.bank_0.storage[cell_index] = colour[3] ? 8'hff : 8'h00;
            lanes[4].memory.bank_0.storage[cell_index] = colour[4] ? 8'hff : 8'h00;
            lanes[5].memory.bank_0.storage[cell_index] = colour[5] ? 8'hff : 8'h00;
            lanes[6].memory.bank_0.storage[cell_index] = colour[6] ? 8'hff : 8'h00;
            lanes[7].memory.bank_0.storage[cell_index] = colour[7] ? 8'hff : 8'h00;
        end
    endtask

    integer x;
BODY
endmodule
"""


class Spec256DisplayTests(unittest.TestCase):
    def test_adjacent_cells_use_their_own_registered_lane_data(self) -> None:
        """Every displayed cell must use the word fetched for that cell."""
        output = run_testbench(
            HARNESS.replace(
                "BODY",
                r"""
    initial begin
        // Each cell is a solid, unique palette index.  A one-cell pipeline
        // error is therefore observable at every boundary, not just as a
        // subtly shifted bitmap.
        set_cell(0, 8'h12);
        set_cell(1, 8'h34);
        set_cell(2, 8'h56);
        set_cell(3, 8'h78);

        repeat (2) @(posedge clock);
        reset = 0;

        for (x = 0; x < LEFT + 4*8*SCALE; x = x + 1) begin
            @(negedge clock);
            hpos = x[10:0];
            @(posedge clock);
            #1;
            if (x == LEFT + 4 && palette_index !== 8'h12)
                $fatal(1, "cell 0 expected 12, got %02x", palette_index);
            if (x == LEFT + 8*SCALE + 4 && palette_index !== 8'h34)
                $fatal(1, "cell 1 expected 34, got %02x", palette_index);
            if (x == LEFT + 2*8*SCALE + 4 && palette_index !== 8'h56)
                $fatal(1, "cell 2 expected 56, got %02x", palette_index);
            if (x == LEFT + 3*8*SCALE + 4 && palette_index !== 8'h78)
                $fatal(1, "cell 3 expected 78, got %02x", palette_index);
        end
        $display("REGISTERED_CELLS_OK");
        $finish;
    end
""",
            )
        )
        self.assertIn("REGISTERED_CELLS_OK", output)

    def test_lane_bits_form_the_expected_pixels_left_to_right(self) -> None:
        """Bit seven is the left pixel and lane zero is palette bit zero."""
        output = run_testbench(
            HARNESS.replace(
                "BODY",
                r"""
    initial begin
        lanes[0].memory.bank_0.storage[0] = 8'haa;
        lanes[1].memory.bank_0.storage[0] = 8'hcc;
        lanes[2].memory.bank_0.storage[0] = 8'hf0;
        lanes[3].memory.bank_0.storage[0] = 8'h0f;
        lanes[4].memory.bank_0.storage[0] = 8'h33;
        lanes[5].memory.bank_0.storage[0] = 8'h55;
        lanes[6].memory.bank_0.storage[0] = 8'h81;
        lanes[7].memory.bank_0.storage[0] = 8'h7e;

        repeat (2) @(posedge clock);
        reset = 0;

        for (x = 0; x < LEFT + 8*SCALE; x = x + 1) begin
            @(negedge clock);
            hpos = x[10:0];
            @(posedge clock);
            #1;
            if (x == LEFT + 1 && palette_index !== 8'h47)
                $fatal(1, "pixel 0 expected 47, got %02x", palette_index);
            if (x == LEFT + 1*SCALE + 1 && palette_index !== 8'ha6)
                $fatal(1, "pixel 1 expected a6, got %02x", palette_index);
            if (x == LEFT + 2*SCALE + 1 && palette_index !== 8'h95)
                $fatal(1, "pixel 2 expected 95, got %02x", palette_index);
            if (x == LEFT + 3*SCALE + 1 && palette_index !== 8'hb4)
                $fatal(1, "pixel 3 expected b4, got %02x", palette_index);
            if (x == LEFT + 4*SCALE + 1 && palette_index !== 8'h8b)
                $fatal(1, "pixel 4 expected 8b, got %02x", palette_index);
            if (x == LEFT + 5*SCALE + 1 && palette_index !== 8'haa)
                $fatal(1, "pixel 5 expected aa, got %02x", palette_index);
            if (x == LEFT + 6*SCALE + 1 && palette_index !== 8'h99)
                $fatal(1, "pixel 6 expected 99, got %02x", palette_index);
            if (x == LEFT + 7*SCALE + 1 && palette_index !== 8'h78)
                $fatal(1, "pixel 7 expected 78, got %02x", palette_index);
        end
        $display("PIXEL_ORDER_OK");
        $finish;
    end
""",
            )
        )
        self.assertIn("PIXEL_ORDER_OK", output)

    def test_passthrough_marks_only_the_unrecoloured_index(self) -> None:
        """0xFF asks for the ordinary screen; every other value does not.

        0xFE and 0x7F sit either side of the value in both the numeric and the
        bit-pattern sense, so a comparison built from the wrong lanes or a
        stray reduction-and would be caught here rather than on hardware.
        """
        output = run_testbench(
            HARNESS.replace(
                "BODY",
                r"""
    initial begin
        set_cell(0, 8'hff);
        set_cell(1, 8'hfe);
        set_cell(2, 8'h7f);
        set_cell(3, 8'h00);

        repeat (2) @(posedge clock);
        reset = 0;

        for (x = 0; x < LEFT + 32*SCALE; x = x + 1) begin
            @(negedge clock);
            hpos = x[10:0];
            @(posedge clock);
            #1;
            if (x == LEFT + 4*SCALE) begin
                if (passthrough !== 1'b1)
                    $fatal(1, "cell 0 (ff) must request passthrough");
                if (palette_index !== 8'hff)
                    $fatal(1, "cell 0 index expected ff, got %02x", palette_index);
            end
            if (x == LEFT + 12*SCALE && passthrough !== 1'b0)
                $fatal(1, "cell 1 (fe) must not request passthrough");
            if (x == LEFT + 20*SCALE && passthrough !== 1'b0)
                $fatal(1, "cell 2 (7f) must not request passthrough");
            if (x == LEFT + 28*SCALE && passthrough !== 1'b0)
                $fatal(1, "cell 3 (00) must not request passthrough");
        end
        $display("PASSTHROUGH_INDEX_OK");
        $finish;
    end
""",
            )
        )
        self.assertIn("PASSTHROUGH_INDEX_OK", output)

    def test_passthrough_is_low_outside_the_picture(self) -> None:
        """The border must never ask for the ordinary screen colour."""
        output = run_testbench(
            HARNESS.replace(
                "BODY",
                r"""
    initial begin
        set_cell(0, 8'hff);

        repeat (2) @(posedge clock);
        reset = 0;

        for (x = 0; x < LEFT; x = x + 1) begin
            @(negedge clock);
            hpos = x[10:0];
            @(posedge clock);
            #1;
            if (passthrough !== 1'b0)
                $fatal(1, "passthrough asserted in the border at x=%0d", x);
        end
        $display("PASSTHROUGH_BORDER_OK");
        $finish;
    end
""",
            )
        )
        self.assertIn("PASSTHROUGH_BORDER_OK", output)

    def test_background_shows_through_zero_pixels_on_the_right_column(self) -> None:
        """A zero pixel takes the background byte for its own column.

        The background is 320 wide with the paper inset 32 columns, and the
        read is issued two pixels early.  Either the inset or the lookahead
        being wrong shifts the image horizontally by a fixed amount, which
        looks plausible on a photograph and is exact here.
        """
        output = run_testbench(HARNESS.replace("BODY", r"""
    initial begin
        paint_background_columns();
        set_cell(0, 8'h00);   // wholly transparent, background must show
        set_cell(1, 8'h00);
        background_valid = 1;

        repeat (2) @(posedge clock);
        reset = 0;

        for (x = 0; x < LEFT + 16*SCALE; x = x + 1) begin
            @(negedge clock);
            hpos = x[10:0];
            @(posedge clock);
            #1;
            // Every clock of every scaled pixel, not just the settled middle
            // one.  The first clock of a source pixel is where a missing
            // lookahead shows, and sampling only the middle hides it.
            if (x >= LEFT) begin
                if (palette_index !== 8'h40 + ((x - LEFT) / SCALE))
                    $fatal(1, "column %0d clock %0d expected %02x, got %02x",
                           (x - LEFT) / SCALE, (x - LEFT) % SCALE,
                           8'h40 + ((x - LEFT) / SCALE), palette_index);
            end
        end
        $display("BACKGROUND_COLUMN_OK");
        $finish;
    end
"""))
        self.assertIn("BACKGROUND_COLUMN_OK", output)

    def test_a_drawn_pixel_covers_the_background(self) -> None:
        """Any non-zero value wins, including the passthrough sentinel."""
        output = run_testbench(HARNESS.replace("BODY", r"""
    initial begin
        paint_background_columns();
        set_cell(0, 8'h5a);   // ordinary recoloured pixel
        set_cell(1, 8'hff);   // passthrough sentinel
        background_valid = 1;

        repeat (2) @(posedge clock);
        reset = 0;

        for (x = 0; x < LEFT + 16*SCALE; x = x + 1) begin
            @(negedge clock);
            hpos = x[10:0];
            @(posedge clock);
            #1;
            if (x == LEFT + 4*SCALE && palette_index !== 8'h5a)
                $fatal(1, "recoloured pixel was replaced by the background: %02x",
                       palette_index);
            if (x == LEFT + 12*SCALE) begin
                if (palette_index !== 8'hff)
                    $fatal(1, "sentinel was replaced by the background: %02x",
                           palette_index);
                if (passthrough !== 1'b1)
                    $fatal(1, "background must not suppress passthrough");
            end
        end
        $display("DRAWN_COVERS_BACKGROUND_OK");
        $finish;
    end
"""))
        self.assertIn("DRAWN_COVERS_BACKGROUND_OK", output)

    def test_background_row_follows_the_scanline(self) -> None:
        """The row term is registered once per line, so it must track vpos.

        Scaled output repeats each source line three times, and the background
        row must change only when the source line does.  A row base that lags
        or fails to update draws the whole picture from one background row.
        """
        output = run_testbench(HARNESS.replace("BODY", r"""
    integer line;
    initial begin
        for (bg = 0; bg < 64000; bg = bg + 1)
            background_memory[bg] = 8'h00;
        // Give every background row its own value at the paper's first column.
        for (bg = 0; bg < 200; bg = bg + 1)
            background_memory[bg * 320 + 32] = 8'h80 + bg[7:0];
        clear_lanes();
        background_valid = 1;

        repeat (2) @(posedge clock);
        reset = 0;

        for (line = 0; line < 9; line = line + 1) begin
            vpos = TOP + line[9:0];
            for (x = 0; x < LEFT + SCALE; x = x + 1) begin
                @(negedge clock);
                hpos = x[10:0];
                @(posedge clock);
                #1;
                if (x == LEFT) begin
                    if (palette_index !== 8'h80 + 4 + (line / SCALE))
                        $fatal(1, "output line %0d expected background row %0d (%02x), got %02x",
                               line, 4 + (line / SCALE),
                               8'h80 + 4 + (line / SCALE), palette_index);
                end
            end
        end
        $display("BACKGROUND_ROW_OK");
        $finish;
    end
"""))
        self.assertIn("BACKGROUND_ROW_OK", output)

    def test_without_a_background_zero_stays_zero(self) -> None:
        """Packs carrying no background keep the previous behaviour exactly."""
        output = run_testbench(HARNESS.replace("BODY", r"""
    initial begin
        paint_background_columns();
        set_cell(0, 8'h00);
        background_valid = 0;

        repeat (2) @(posedge clock);
        reset = 0;

        for (x = 0; x < LEFT + 8*SCALE; x = x + 1) begin
            @(negedge clock);
            hpos = x[10:0];
            @(posedge clock);
            #1;
            if (x >= LEFT && palette_index !== 8'h00)
                $fatal(1, "index %02x leaked in with no background loaded",
                       palette_index);
        end
        $display("NO_BACKGROUND_OK");
        $finish;
    end
"""))
        self.assertIn("NO_BACKGROUND_OK", output)


if __name__ == "__main__":
    unittest.main()
