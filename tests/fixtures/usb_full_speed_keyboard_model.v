// Reactive full-/low-speed USB device used by the HID-host regression.
//
// It models the descriptors of the 258a:0049 composite gaming keyboard seen
// on the Console bench. EP0 is eight bytes, so the 18-byte configuration read
// is delivered as 8/8/2 bytes rather than as one unrealistic test packet.
`default_nettype none
`timescale 1ns / 1ps
module usb_full_speed_keyboard_model #(
  parameter LOW_SPEED = 0,
  parameter CONFIG_LEADING_SHORT = 0,
  parameter TURNAROUND = LOW_SPEED ? 270 : 34
) (
  input  wire clk,
  inout  wire dp,
  inout  wire dm,
  output integer setup_seen,
  output integer in0_seen,
  output integer in1_seen
);

reg [7:0] devdesc [0:17];
reg [7:0] cfgdesc [0:58];
reg [7:0] repdesc [0:8];
reg [7:0] report  [0:7];

integer k;
initial begin
  devdesc[0]=8'h12; devdesc[1]=8'h01; devdesc[2]=8'h10; devdesc[3]=8'h01;
  devdesc[4]=8'h00; devdesc[5]=8'h00; devdesc[6]=8'h00; devdesc[7]=8'h08;
  devdesc[8]=8'h8a; devdesc[9]=8'h25; devdesc[10]=8'h49; devdesc[11]=8'h00;
  devdesc[12]=8'h10; devdesc[13]=8'h01; devdesc[14]=8'h01; devdesc[15]=8'h02;
  devdesc[16]=8'h00; devdesc[17]=8'h01;

  // Configuration, boot-keyboard interface, HID and endpoint, followed by a
  // second HID interface matching the physical composite keyboard.
  cfgdesc[0]=8'h09; cfgdesc[1]=8'h02; cfgdesc[2]=8'h3b; cfgdesc[3]=8'h00;
  cfgdesc[4]=8'h02; cfgdesc[5]=8'h01; cfgdesc[6]=8'h00; cfgdesc[7]=8'ha0;
  cfgdesc[8]=8'h32;
  cfgdesc[9]=8'h09; cfgdesc[10]=8'h04; cfgdesc[11]=8'h00; cfgdesc[12]=8'h00;
  cfgdesc[13]=8'h01; cfgdesc[14]=8'h03; cfgdesc[15]=8'h01; cfgdesc[16]=8'h01;
  cfgdesc[17]=8'h00;
  cfgdesc[18]=8'h09; cfgdesc[19]=8'h21; cfgdesc[20]=8'h11; cfgdesc[21]=8'h01;
  cfgdesc[22]=8'h00; cfgdesc[23]=8'h01; cfgdesc[24]=8'h22; cfgdesc[25]=8'h41;
  cfgdesc[26]=8'h00;
  cfgdesc[27]=8'h07; cfgdesc[28]=8'h05; cfgdesc[29]=8'h81; cfgdesc[30]=8'h03;
  cfgdesc[31]=8'h08; cfgdesc[32]=8'h00; cfgdesc[33]=8'h01;
  cfgdesc[34]=8'h09; cfgdesc[35]=8'h04; cfgdesc[36]=8'h01; cfgdesc[37]=8'h00;
  cfgdesc[38]=8'h01; cfgdesc[39]=8'h03; cfgdesc[40]=8'h01; cfgdesc[41]=8'h02;
  cfgdesc[42]=8'h00;
  cfgdesc[43]=8'h09; cfgdesc[44]=8'h21; cfgdesc[45]=8'h11; cfgdesc[46]=8'h01;
  cfgdesc[47]=8'h00; cfgdesc[48]=8'h01; cfgdesc[49]=8'h22; cfgdesc[50]=8'h4a;
  cfgdesc[51]=8'h00;
  cfgdesc[52]=8'h07; cfgdesc[53]=8'h05; cfgdesc[54]=8'h82; cfgdesc[55]=8'h03;
  cfgdesc[56]=8'h08; cfgdesc[57]=8'h00; cfgdesc[58]=8'h01;

  for (k = 0; k < 9; k = k + 1)
    repdesc[k] = 8'h05 + k[7:0];

  report[0]=8'h00; report[1]=8'h00; report[2]=8'h04; report[3]=8'h00;
  report[4]=8'h00; report[5]=8'h00; report[6]=8'h00; report[7]=8'h00;

  setup_seen = 0;
  in0_seen = 0;
  in1_seen = 0;
end

reg dev_oe = 0;
localparam integer BIT_CLOCKS = LOW_SPEED ? 40 : 5;

reg dev_dp = LOW_SPEED ? 0 : 1;
reg dev_dm = LOW_SPEED ? 1 : 0;
assign dp = dev_oe ? dev_dp : 1'bz;
assign dm = dev_oe ? dev_dm : 1'bz;

// Decode host packets. The model resynchronises on each transition and samples
// the middle of a five-clock full-speed or forty-clock low-speed bit cell.
reg  [7:0] rxbuf [0:15];
integer    rxlen = 0;
reg        rx_active = 0;
reg  [5:0] rx_phase = 0;
reg        rx_prev = 1;
reg  [2:0] rx_ones = 0;
reg  [3:0] rx_bit = 0;
reg  [7:0] rx_data = 0;
reg  [1:0] rx_se0 = 0;
reg        packet_done = 0;

wire physical_full_j = (dp === 1'b1) && (dm === 1'b0);
wire physical_low_j = (dp === 1'b0) && (dm === 1'b1);
wire line_j = LOW_SPEED ? physical_low_j : physical_full_j;
wire line_k = LOW_SPEED ? physical_full_j : physical_low_j;
wire line_se0 = (dp === 1'b0) && (dm === 1'b0);
reg  line_state = 1;
reg  line_state_d = 1;

always @(*) begin
  if (line_j) line_state = 1;
  else if (line_k) line_state = 0;
  else line_state = line_state_d;
end

always @(posedge clk) begin
  line_state_d <= line_state;
  packet_done <= 0;

  if (line_se0)
    rx_se0 <= (rx_se0 == 2'd3) ? 2'd3 : rx_se0 + 1;
  else
    rx_se0 <= 0;

  if (!rx_active) begin
    if (!dev_oe && line_state == 0 && line_state_d == 1) begin
      rx_active <= 1;
      rx_phase <= 1;
      rx_prev <= 1;
      rx_ones <= 0;
      rx_bit <= 0;
      rx_data <= 0;
      rxlen <= 0;
    end
  end else begin
    if (rx_se0 >= 2) begin
      rx_active <= 0;
      packet_done <= 1;
    end else if (line_state != line_state_d) begin
      rx_phase <= 1;
    end else if (rx_phase == BIT_CLOCKS - 1) begin
      rx_phase <= 0;
    end else begin
      rx_phase <= rx_phase + 1;
    end

    if (rx_active && rx_phase == BIT_CLOCKS / 2 && rx_se0 < 2) begin
      if (rx_ones == 6) begin
        rx_ones <= 0;
        rx_prev <= line_state;
      end else begin
        if (line_state == rx_prev) begin
          rx_data <= {1'b1, rx_data[7:1]};
          rx_ones <= rx_ones + 1;
        end else begin
          rx_data <= {1'b0, rx_data[7:1]};
          rx_ones <= 0;
        end
        rx_prev <= line_state;
        if (rx_bit == 7) begin
          rx_bit <= 0;
          rxbuf[rxlen] <= (line_state == rx_prev) ?
                          {1'b1, rx_data[7:1]} : {1'b0, rx_data[7:1]};
          rxlen <= rxlen + 1;
        end else begin
          rx_bit <= rx_bit + 1;
        end
      end
    end
  end
end

reg        tx_prev;
reg  [2:0] tx_ones;
reg [15:0] tx_crc;
reg  [7:0] txpayload [0:63];

task tx_bit(input value);
  integer c;
  begin
    if (value == 1'b0) begin
      tx_prev = ~tx_prev;
      tx_ones = 0;
    end else begin
      tx_ones = tx_ones + 1;
    end
    dev_dp = LOW_SPEED ? ~tx_prev : tx_prev;
    dev_dm = LOW_SPEED ? tx_prev : ~tx_prev;
    for (c = 0; c < BIT_CLOCKS; c = c + 1) @(negedge clk);
    if (tx_ones == 6) begin
      tx_prev = ~tx_prev;
      tx_ones = 0;
      dev_dp = LOW_SPEED ? ~tx_prev : tx_prev;
      dev_dm = LOW_SPEED ? tx_prev : ~tx_prev;
      for (c = 0; c < BIT_CLOCKS; c = c + 1) @(negedge clk);
    end
  end
endtask

task tx_byte(input [7:0] value);
  integer b;
  begin
    for (b = 0; b < 8; b = b + 1)
      tx_bit(value[b]);
  end
endtask

task crc_byte(input [7:0] value);
  integer b;
  begin
    for (b = 0; b < 8; b = b + 1)
      if ((value[b] ^ tx_crc[0]) == 1'b1)
        tx_crc = (tx_crc >> 1) ^ 16'hA001;
      else
        tx_crc = tx_crc >> 1;
  end
endtask

task tx_start;
  begin
    tx_prev = 1;
    tx_ones = 0;
    dev_dp = LOW_SPEED ? 0 : 1;
    dev_dm = LOW_SPEED ? 1 : 0;
    dev_oe = 1;
    @(negedge clk);
    tx_byte(8'h80);
  end
endtask

task tx_eop;
  integer c;
  begin
    dev_dp = 0;
    dev_dm = 0;
    for (c = 0; c < BIT_CLOCKS * 2; c = c + 1) @(negedge clk);
    dev_dp = LOW_SPEED ? 0 : 1;
    dev_dm = LOW_SPEED ? 1 : 0;
    for (c = 0; c < BIT_CLOCKS; c = c + 1) @(negedge clk);
    dev_oe = 0;
    @(negedge clk);
  end
endtask

task send_handshake(input [7:0] pid);
  begin
    tx_start;
    tx_byte(pid);
    tx_eop;
  end
endtask

task send_data(input [7:0] pid, input integer count);
  integer b;
  begin
    tx_crc = 16'hffff;
    for (b = 0; b < count; b = b + 1)
      crc_byte(txpayload[b]);
    tx_crc = ~tx_crc;
    tx_start;
    tx_byte(pid);
    for (b = 0; b < count; b = b + 1)
      tx_byte(txpayload[b]);
    tx_byte(tx_crc[7:0]);
    tx_byte(tx_crc[15:8]);
    tx_eop;
  end
endtask

localparam PID_OUT   = 8'he1;
localparam PID_IN    = 8'h69;
localparam PID_SOF   = 8'ha5;
localparam PID_SETUP = 8'h2d;
localparam PID_DATA0 = 8'hc3;
localparam PID_DATA1 = 8'h4b;
localparam PID_ACK   = 8'hd2;

reg [6:0] dev_addr = 0;
reg [6:0] pending_addr = 0;
reg       addr_pending = 0;
reg [3:0] last_ep = 0;
reg [6:0] last_addr = 0;
reg       in_stage = 0;
integer   in_ptr = 0;
integer   in_len = 0;
integer   in_remaining = 0;
reg       in_toggle = 0;
reg [7:0] setup [0:7];
integer   src = 0;
integer   ep1_toggle = 0;
integer   n;
integer   chunk;
reg       config_leading_short_pending = 0;

always @(posedge packet_done) begin
  if (rxlen >= 2 && rxbuf[0] == 8'h80) begin
    case (rxbuf[1])
      PID_SOF: ;
      PID_SETUP: begin
        last_addr = rxbuf[2][6:0];
        last_ep = {rxbuf[3][2:0], rxbuf[2][7]};
      end
      PID_IN: begin
        last_addr = rxbuf[2][6:0];
        last_ep = {rxbuf[3][2:0], rxbuf[2][7]};
        if (last_addr == dev_addr) begin
          if (last_ep == 0) begin
            in0_seen = in0_seen + 1;
            if (in_stage) begin
              if (CONFIG_LEADING_SHORT && src == 2 &&
                  config_leading_short_pending) begin
                // Match the packet sequence captured from both Console USB
                // roots: a two-byte configuration header followed by a new
                // packet beginning at descriptor offset zero. The short
                // packet still counts against the setup request's wLength.
                chunk = 2;
              end else begin
                chunk = in_remaining;
                if (chunk > 8)
                  chunk = 8;
              end
              for (n = 0; n < chunk; n = n + 1)
                case (src)
                  1: txpayload[n] = devdesc[in_ptr + n];
                  2: txpayload[n] = cfgdesc[in_ptr + n];
                  default: txpayload[n] = repdesc[in_ptr + n];
                endcase
              repeat (TURNAROUND) @(posedge clk);
              send_data(in_toggle ? PID_DATA1 : PID_DATA0, chunk);
              in_toggle = ~in_toggle;
              if (CONFIG_LEADING_SHORT && src == 2 &&
                  config_leading_short_pending)
                config_leading_short_pending = 0;
              else
                in_ptr = in_ptr + chunk;
              in_remaining = in_remaining - chunk;
              if (in_remaining <= 0)
                in_stage = 0;
            end else begin
              repeat (TURNAROUND) @(posedge clk);
              send_data(PID_DATA1, 0);
              if (addr_pending) begin
                dev_addr = pending_addr;
                addr_pending = 0;
              end
            end
          end else begin
            in1_seen = in1_seen + 1;
            for (n = 0; n < 8; n = n + 1)
              txpayload[n] = report[n];
            repeat (TURNAROUND) @(posedge clk);
            send_data(ep1_toggle ? PID_DATA1 : PID_DATA0, 8);
            ep1_toggle = ~ep1_toggle;
          end
        end
      end
      PID_OUT: begin
        last_addr = rxbuf[2][6:0];
        last_ep = {rxbuf[3][2:0], rxbuf[2][7]};
      end
      PID_DATA0, PID_DATA1: begin
        if (last_addr == dev_addr && rxlen >= 12) begin
          setup_seen = setup_seen + 1;
          for (n = 0; n < 8; n = n + 1)
            setup[n] = rxbuf[n + 2];
          in_ptr = 0;
          in_remaining = 0;
          in_toggle = 1;
          in_stage = 0;
          config_leading_short_pending = 0;
          if (setup[0] == 8'h80 && setup[1] == 8'h06) begin
            in_len = {setup[7], setup[6]};
            in_stage = 1;
            if (setup[3] == 8'h01) begin
              src = 1;
              if (in_len > 18)
                in_len = 18;
            end else begin
              src = 2;
              config_leading_short_pending = CONFIG_LEADING_SHORT;
              if (in_len > 59)
                in_len = 59;
            end
            in_remaining = in_len;
          end else if (setup[0] == 8'h81 && setup[1] == 8'h06) begin
            src = 3;
            in_len = {setup[7], setup[6]};
            if (in_len > 9)
              in_len = 9;
            in_remaining = in_len;
            in_stage = 1;
          end else if (setup[1] == 8'h05) begin
            pending_addr = setup[2][6:0];
            addr_pending = 1;
          end
          repeat (TURNAROUND) @(posedge clk);
          send_handshake(PID_ACK);
        end else if (last_addr == dev_addr && rxlen >= 4) begin
          repeat (TURNAROUND) @(posedge clk);
          send_handshake(PID_ACK);
        end
      end
      default: ;
    endcase
  end
end

endmodule
`default_nettype wire
