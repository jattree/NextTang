`default_nettype none
`timescale 1ns / 1ps
module testbench;

parameter INJECT_IDLE_DIP = 0;
parameter INJECT_UNDECIDED_SPEED = 0;
parameter DEVICE_LOW_SPEED = 0;
parameter CONFIG_LEADING_SHORT = 0;

reg host_clock = 0;
always #8.3333 host_clock = ~host_clock;

// Keep the device on an independent nominal 60 MHz clock so the test does not
// accidentally rely on a shared simulation edge.
reg device_clock = 0;
initial forever #8.333 device_clock = ~device_clock;

reg reset = 1;
initial begin
  repeat (10) @(posedge host_clock);
  reset <= 0;
end

wire dp;
wire dm;
generate
  if (DEVICE_LOW_SPEED) begin : low_speed_pullup
    pulldown board_dp_pulldown (dp);
    pullup keyboard_pullup (dm);
  end else begin : full_speed_pullup
    pullup keyboard_pullup (dp);
    pulldown board_dm_pulldown (dm);
  end
endgenerate

wire host_dp_out;
wire host_dm_out;
wire host_output_enable;
assign dp = host_output_enable ? host_dp_out : 1'bz;
assign dm = host_output_enable ? host_dm_out : 1'bz;

// Reproduce the board failure: one raw D+ sample is pulled low immediately
// before each pre-enumeration branch instruction. The three-sample receiver
// filter rejects the single sample, but the old speed latch read dpi[0]
// directly during the following S_BX cycle.
reg idle_dip = 0;
initial if (INJECT_IDLE_DIP) begin
  wait (!reset);
  forever begin
    @(negedge host_clock);
    if (dut.ukp.state == 0 && dut.ukp.inst == 9 && !dut.connected &&
        !host_output_enable && !keyboard.dev_oe) begin
    idle_dip = 1;
    @(posedge host_clock);
    #1;
    idle_dip = 0;
    end
  end
end
assign dp = idle_dip ? 1'b0 : 1'bz;

// Exercise the attachment boundary directly: the speed branch can run before
// the majority filter has accumulated a non-zero decision. An undecided
// filter result must not be committed as low speed.
initial if (INJECT_UNDECIDED_SPEED) begin
  wait (!reset);
  wait (dut.ukp.state == 5 && dut.ukp.inst == 0 &&
        !dut.connected && !dut.ukp.speed_detected);
  force dut.ukp.dsum = 0;
  @(posedge host_clock);
  #1;
  release dut.ukp.dsum;
end

wire [9:0] rom_address;
wire [3:0] rom_data;
wire rom_enable;
wire [1:0] device_type;
wire full_report;
wire connection_error;
wire [7:0] modifiers;
wire [7:0] key0;
wire [7:0] key1;
wire [63:0] raw_report;
wire [63:0] hid_registers;
wire [63:0] config_snapshot;
wire config_snapshot_valid;
wire full_speed;

usb_hid_host #(
  .FULL_SPEED(1),
  .KEYBOARD_SUPPORT(1),
  .MOUSE_SUPPORT(1),
  .GAME_SUPPORT(1)
) dut (
  .clk(host_clock), .reset(reset), .cs(1'b1),
  .usb_dm_i(dm), .usb_dp_i(dp),
  .usb_dm_o(host_dm_out), .usb_dp_o(host_dp_out),
  .usb_oe(host_output_enable),
  .typ(device_type), .full_report(full_report),
  .connerr(connection_error), .busy(),
  .key_modifiers(modifiers), .key_0(key0), .key_1(key1),
  .key_2(), .key_3(), .key_4(), .key_5(),
  .mouse_btn(), .mouse_dx(), .mouse_dy(),
  .game_l(), .game_r(), .game_u(), .game_d(),
  .game_a(), .game_b(), .game_x(), .game_y(),
  .game_sel(), .game_sta(), .game_extra(),
  .dbg_hid_report(raw_report), .dbg_hid_regs(hid_registers),
  .dbg_config_snapshot(config_snapshot),
  .dbg_config_snapshot_valid(config_snapshot_valid),
  .dbg_full_speed(full_speed),
  .rom_addr(rom_address), .rom_dout(rom_data), .rom_en(rom_enable)
);

usb_hid_host_dual_rom #(
  .MEMORY_FILE("rtl/input/usb_hid_host_rom.mem")
) microcode (
  .clk(host_clock),
  .addra(rom_address), .douta(rom_data), .ena(rom_enable),
  .addrb(10'b0), .doutb(), .enb(1'b0)
);

integer setup_seen;
integer endpoint_zero_reads;
integer endpoint_one_reads;
usb_full_speed_keyboard_model #(
  .LOW_SPEED(DEVICE_LOW_SPEED),
  .CONFIG_LEADING_SHORT(CONFIG_LEADING_SHORT)
) keyboard (
  .clk(device_clock), .dp(dp), .dm(dm),
  .setup_seen(setup_seen),
  .in0_seen(endpoint_zero_reads),
  .in1_seen(endpoint_one_reads)
);

integer report_count = 0;
reg snapshot_seen = 0;
reg snapshot_speed = 0;
reg [63:0] captured_snapshot = 0;
always @(posedge host_clock)
  if (full_report && dut.connected)
    report_count = report_count + 1;

always @(posedge host_clock)
  if (config_snapshot_valid) begin
    snapshot_seen <= 1;
    snapshot_speed <= full_speed;
    captured_snapshot <= config_snapshot;
  end

initial begin
  #6000000;
  if (!dut.connected)
    $fatal(1, "full-speed keyboard did not enumerate");
  if (connection_error)
    $fatal(1, "host reported a connection error");
  if ({dut.regs[1], dut.regs[0]} != 16'h258a)
    $fatal(1, "wrong VID: %04x", {dut.regs[1], dut.regs[0]});
  if ({dut.regs[3], dut.regs[2]} != 16'h0049)
    $fatal(1, "wrong PID: %04x", {dut.regs[3], dut.regs[2]});
  if ({dut.regs[4], dut.regs[5], dut.regs[6]} != 24'h030101)
    $fatal(1, "wrong boot interface: %02x %02x %02x",
           dut.regs[4], dut.regs[5], dut.regs[6]);
  if (device_type != 2'd1)
    $fatal(1, "device was not classified as a keyboard: %0d", device_type);
  if (!snapshot_seen || snapshot_speed != !DEVICE_LOW_SPEED)
    $fatal(1, "configuration snapshot had wrong speed: %0d", snapshot_speed);
  if (captured_snapshot != 64'h0103010000040001)
    $fatal(1, "wrong configuration snapshot: %016x", captured_snapshot);
  if (key0 != 8'h04 || key1 != 8'h00 || modifiers != 8'h00)
    $fatal(1, "wrong boot report: modifiers=%02x key0=%02x key1=%02x",
           modifiers, key0, key1);
  if (setup_seen < 5 || endpoint_zero_reads < 4 ||
      endpoint_one_reads < 1 || report_count < 1)
    $fatal(1, "enumeration was incomplete: setup=%0d ep0=%0d ep1=%0d reports=%0d",
           setup_seen, endpoint_zero_reads, endpoint_one_reads, report_count);
  $display("USB_FULL_SPEED_KEYBOARD_PASS setup=%0d ep0=%0d ep1=%0d reports=%0d",
           setup_seen, endpoint_zero_reads, endpoint_one_reads, report_count);
  $finish;
end

endmodule
`default_nettype wire
