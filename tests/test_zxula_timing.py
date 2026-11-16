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


EXACT_BENCH = r"""
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity exact_bench is
    generic (HZ60 : std_logic := '0'; TIMING : std_logic_vector(2 downto 0) := "000"; EXACT : std_logic := '1';
             NFRAMES : natural := 32);
end entity;

architecture sim of exact_bench is
    signal clk28, clk7 : std_logic := '0';
    signal frame_sync, hdmi_pixel_en, int_ula : std_logic;
    signal done : boolean := false;
begin
    clk28 <= not clk28 after 5 ns when not done;
    clk7 <= not clk7 after 20 ns when not done;

    dut : entity work.zxula_timing
        port map (
            i_CLK_28 => clk28, i_50_60 => HZ60, i_timing => TIMING, i_frame_exact => EXACT,
            i_cu_offset => x"00", i_CLK_7 => clk7,
            o_frame_sync => frame_sync, o_hdmi_pixel_en => hdmi_pixel_en,
            center => '1', i_inten_ula_n => '0', i_inten_line => '0',
            i_int_line => (others => '0'), o_int_ula => int_ula);

    process (clk7)
        variable frames, cycles, pixels, ints : natural := 0;
        variable int_prev : std_logic := '0';
        variable l : line;
    begin
        if rising_edge(clk7) then
            cycles := cycles + 1;
            if hdmi_pixel_en = '1' then pixels := pixels + 1; end if;
            if int_ula = '1' and int_prev = '0' then ints := ints + 1; end if;
            int_prev := int_ula;
            if frame_sync = '1' then
                if frames > 0 then
                    write(l, string'("FRAME ") & integer'image(cycles) & string'(" ") &
                          integer'image(pixels) & string'(" ") & integer'image(ints));
                    writeline(output, l);
                end if;
                frames := frames + 1; cycles := 0; pixels := 0; ints := 0;
                if frames = NFRAMES + 2 then done <= true; end if;
            end if;
        end if;
    end process;
end architecture;
"""


class ZxulaExactFrameTest(unittest.TestCase):
    """i_frame_exact: every frame one CEA HDMI frame long on average, in
    frames of an even number of 7 MHz pixels."""

    def frames(self, hz60: str, timing: str, exact: str = "'1'", count: int = 32):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "bench.vhd").write_text(EXACT_BENCH, encoding="ascii")
            flags = ["--std=08", "-frelaxed", "-fsynopsys", f"--workdir={directory}"]
            for command in (["ghdl", "-a", *flags, str(TIMING_RTL), "bench.vhd"],
                            ["ghdl", "-e", *flags, "exact_bench"],
                            ["ghdl", "-r", *flags, "exact_bench", f"-gHZ60={hz60}", f"-gTIMING={timing}",
                             f"-gEXACT={exact}", f"-gNFRAMES={count}", "--ieee-asserts=disable"]):
                done = subprocess.run(command, cwd=root, capture_output=True, text=True, check=False)
                self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        return [tuple(map(int, line.split()[1:])) for line in done.stdout.splitlines() if line.startswith("FRAME")]

    def test_frames_are_exact_hdmi_frames(self) -> None:
        # 25/24 of the pixel clock: 864 x 625 x 25 / 24 / 4 and 858 x 525 x 25 / 24 / 4 pixels at 7 MHz
        # 32 frames, the whole pattern, for 48K; 4 frames for the other
        # timings, which share the pattern and differ in their lines.
        for hz60, timing, base, count, total, window in (
                ("'0'", "000", 140624, 32, 140625 * 32, 360 * 288),          # 48K 50 Hz
                ("'1'", "000", 117304, 32, 3753750, 360 * 240),              # 48K 60 Hz
                ("'0'", "010", 140624, 4, 140625 * 4, 360 * 288),            # 128K 50 Hz
                ("'0'", "011", 140624, 4, 140625 * 4, 360 * 288),            # +3 50 Hz
                ("'1'", "010", 117304, 4, None, 360 * 240)):                 # 128K 60 Hz
            with self.subTest(hz60=hz60, timing=timing):
                frames = self.frames(hz60, timing, count=count)
                self.assertGreaterEqual(len(frames), count)
                lengths = [f[0] for f in frames[:count]]
                self.assertTrue(set(lengths) <= {base, base + 2}, set(lengths))
                if total is not None:
                    self.assertEqual(sum(lengths), total)
                self.assertEqual({f[1] for f in frames}, {window})   # the whole HDMI window, every frame
                self.assertEqual({f[2] for f in frames}, {1})        # one frame interrupt, every frame

    def test_original_frames_without_it_and_for_pentagon(self) -> None:
        self.assertEqual({f[0] for f in self.frames("'0'", "000", "'0'", 2)}, {448 * 312})
        self.assertEqual({f[0] for f in self.frames("'0'", "010", "'0'", 2)}, {456 * 311})
        self.assertEqual({f[0] for f in self.frames("'0'", "100", "'1'", 2)}, {448 * 320})   # Pentagon keeps its frame
