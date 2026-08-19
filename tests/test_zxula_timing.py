"""Pin the imported 48K ULA timing before its raster enters the framebuffer."""

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
TIMING_RTL = REPO_ROOT / "rtl" / "video" / "zxula_timing.vhd"


class ZxulaTimingTest(unittest.TestCase):
    def test_48k_50hz_raster_and_hdmi_window(self) -> None:
        testbench = r"""
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity testbench is end entity;

architecture sim of testbench is
    signal clk28, clk7 : std_logic := '0';
    signal hblank_n, vblank_n, hsync_n, vsync_n, frame_sync : std_logic;
    signal hdmi_pixel_en, hdmi_frame_lock : std_logic;
    signal hc, vc, cvc, whc, wvc, phc : unsigned(8 downto 0);
    signal sc : std_logic_vector(1 downto 0);
    signal int_ula, int_line : std_logic;
begin
    clk28 <= not clk28 after 5 ns;
    clk7 <= not clk7 after 20 ns;

    dut : entity work.zxula_timing
        port map (
            i_CLK_28 => clk28, i_50_60 => '0', i_timing => "000",
            i_cu_offset => x"00", i_CLK_7 => clk7,
            o_vblank_n => vblank_n, o_hblank_n => hblank_n,
            o_hsync_n => hsync_n, o_vsync_n => vsync_n,
            o_frame_sync => frame_sync, o_hdmi_pixel_en => hdmi_pixel_en,
            o_hdmi_frame_lock => hdmi_frame_lock,
            o_hc_ula => hc, o_vc_ula => vc, o_vc_cu => cvc,
            o_whc => whc, o_wvc => wvc, o_phc => phc, center => '1',
            o_sc => sc, i_inten_ula_n => '0', i_inten_line => '0',
            i_int_line => (others => '0'), o_int_ula => int_ula,
            o_int_line => int_line
        );

    process (clk7)
        variable started : boolean := false;
        variable cycles : natural := 0;
        variable active : natural := 0;
        variable active_lines : natural := 0;
        variable active_run : natural := 0;
        variable previous_active : std_logic := '0';
    begin
        if rising_edge(clk7) then
            if frame_sync = '1' then
                if started then
                    assert cycles = 448 * 312
                        report "48K raster cycle count was " & integer'image(cycles)
                        severity failure;
                    assert active = 360 * 288
                        report "HDMI active pixel count was " & integer'image(active)
                        severity failure;
                    assert active_lines = 288
                        report "HDMI active line count was " & integer'image(active_lines)
                        severity failure;
                    report "ZXULA_TIMING_PASS";
                    stop;
                end if;
                started := true;
                cycles := 0;
                active := 0;
                active_lines := 0;
            end if;

            if started then
                cycles := cycles + 1;
                if hdmi_pixel_en = '1' then
                    active := active + 1;
                    active_run := active_run + 1;
                elsif previous_active = '1' then
                    assert active_run = 360
                        report "HDMI active line width was " & integer'image(active_run)
                        severity failure;
                    active_lines := active_lines + 1;
                    active_run := 0;
                end if;
            end if;
            previous_active := hdmi_pixel_en;
        end if;
    end process;
end architecture;
"""
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            tb = work / "testbench.vhd"
            tb.write_text(testbench, encoding="utf-8")
            for source in (TIMING_RTL, tb):
                analysed = subprocess.run(
                    ["ghdl", "-a", "--std=08", "-fsynopsys",
                     f"--workdir={work}", str(source)],
                    cwd=REPO_ROOT, check=False, capture_output=True, text=True,
                )
                self.assertEqual(analysed.returncode, 0, analysed.stderr)
            result = subprocess.run(
                ["ghdl", "-r", "--std=08", "-fsynopsys",
                 f"--workdir={work}", "testbench", "--stop-time=20ms"],
                cwd=work, check=False, capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("ZXULA_TIMING_PASS", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
