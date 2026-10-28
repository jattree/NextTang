"""Layer 2 kept outside the memory the board serves must show as transparent.

rtl/video/layer2.vhd takes a map of the 16 KiB units of memory it can read.
The Console 138K serves Layer 2 from a block RAM copy of banks 8 to 12 and 18
to 22, and whatever that copy returns for other banks is not reliably
transparent once the palette or 640x256 mode is in play. The test runs one
Layer 2 with the board's map and one with the default, on banks 8, 16 and 18,
and counts the pixels each enables.
"""

from pathlib import Path
import subprocess
import tempfile
import unittest

REPO_ROOT = Path(__file__).resolve().parents[1]
LAYER2_RTL = REPO_ROOT / "rtl" / "video" / "layer2.vhd"

TESTBENCH = r"""
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity testbench is
end entity;

architecture sim of testbench is
    signal clock_28 : std_logic := '0';
    signal clock_7 : std_logic := '0';
    signal sc : unsigned(1 downto 0) := "00";
    signal hc : unsigned(8 downto 0) := (others => '0');
    signal vc : unsigned(8 downto 0) := to_unsigned(10, 9);
    signal bank : std_logic_vector(6 downto 0) := "0001000";
    signal windowed_en, open_en : std_logic;
    signal done : boolean := false;
begin
    clock_28 <= not clock_28 after 5 ns when not done;
    clock_7 <= not clock_7 after 20 ns when not done;

    process (clock_28) begin
        if rising_edge(clock_28) then
            sc <= sc + 1;
        end if;
    end process;

    process (clock_7) begin
        if rising_edge(clock_7) then
            if hc = 319 then
                hc <= (others => '0');
            else
                hc <= hc + 1;
            end if;
        end if;
    end process;

    windowed: entity work.layer2
        generic map (
            -- SRAM units 24 to 28 and 34 to 38: banks 8 to 12 and 18 to 22.
            g_unit_visible => (24 to 28 => '1', 34 to 38 => '1', others => '0')
        )
        port map (
            i_CLK_7 => clock_7, i_CLK_28 => clock_28, i_sc => std_logic_vector(sc),
            i_phc => std_logic_vector(hc), i_pvc => std_logic_vector(vc),
            i_whc => std_logic_vector(hc), i_wvc => std_logic_vector(vc),
            i_layer2_en => '1', i_resolution => "00", i_palette_offset => "0000",
            i_scroll_x => (others => '0'), i_scroll_y => (others => '0'),
            i_clip_x1 => x"00", i_clip_x2 => x"ff", i_clip_y1 => x"00", i_clip_y2 => x"bf",
            i_layer2_active_bank => bank,
            o_layer2_sram_addr => open, o_layer2_req_t => open,
            i_layer2_sram_di => x"00",
            o_layer2_en => windowed_en, o_layer2_pixel => open
        );

    unwindowed: entity work.layer2
        port map (
            i_CLK_7 => clock_7, i_CLK_28 => clock_28, i_sc => std_logic_vector(sc),
            i_phc => std_logic_vector(hc), i_pvc => std_logic_vector(vc),
            i_whc => std_logic_vector(hc), i_wvc => std_logic_vector(vc),
            i_layer2_en => '1', i_resolution => "00", i_palette_offset => "0000",
            i_scroll_x => (others => '0'), i_scroll_y => (others => '0'),
            i_clip_x1 => x"00", i_clip_x2 => x"ff", i_clip_y1 => x"00", i_clip_y2 => x"bf",
            i_layer2_active_bank => bank,
            o_layer2_sram_addr => open, o_layer2_req_t => open,
            i_layer2_sram_di => x"00",
            o_layer2_en => open_en, o_layer2_pixel => open
        );

    process
        variable windowed_count, open_count : natural;

        procedure count_line is
        begin
            windowed_count := 0;
            open_count := 0;
            -- Settle the pipeline, then count one whole line.
            for i in 1 to 8 loop
                wait until rising_edge(clock_7);
            end loop;
            for i in 1 to 320 loop
                wait until rising_edge(clock_7);
                if windowed_en = '1' then windowed_count := windowed_count + 1; end if;
                if open_en = '1' then open_count := open_count + 1; end if;
            end loop;
        end procedure;
    begin
        bank <= "0001000";          -- bank 8, inside the window
        count_line;
        report "BANK8 " & integer'image(windowed_count) & " " & integer'image(open_count);
        assert open_count > 200 and windowed_count = open_count
            report "bank 8 should show the same line in both" severity failure;

        bank <= "0010000";          -- bank 16, outside it
        count_line;
        report "BANK16 " & integer'image(windowed_count) & " " & integer'image(open_count);
        assert windowed_count = 0
            report "bank 16 must be hidden by the window" severity failure;
        assert open_count > 200
            report "without a window bank 16 must still show" severity failure;

        bank <= "0010010";          -- bank 18, the second range
        count_line;
        report "BANK18 " & integer'image(windowed_count) & " " & integer'image(open_count);
        assert open_count > 200 and windowed_count = open_count
            report "bank 18 should show the same line in both" severity failure;

        report "LAYER2_WINDOW_PASS";
        done <= true;
        wait;
    end process;
end architecture;
"""


class Layer2WindowTest(unittest.TestCase):
    def test_layer2_outside_the_window_is_transparent(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            tb = work / "testbench.vhd"
            tb.write_text(TESTBENCH, encoding="utf-8")
            for source in (LAYER2_RTL, tb):
                analysed = subprocess.run(
                    ["ghdl", "-a", "--std=08", "-fsynopsys",
                     f"--workdir={work}", str(source)],
                    cwd=REPO_ROOT, check=False, capture_output=True, text=True,
                )
                self.assertEqual(analysed.returncode, 0, analysed.stderr)
            result = subprocess.run(
                ["ghdl", "-r", "--std=08", "-fsynopsys",
                 f"--workdir={work}", "testbench", "--stop-time=1ms"],
                cwd=work, check=False, capture_output=True, text=True,
            )
            output = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, output)
            self.assertIn("LAYER2_WINDOW_PASS", output)


if __name__ == "__main__":
    unittest.main()
