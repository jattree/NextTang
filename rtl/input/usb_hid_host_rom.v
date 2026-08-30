`default_nettype none
`timescale 1ns / 1ps
module usb_hid_host_rom #(
  parameter MEMORY_FILE = "usb_hid_host_rom.mem"
) (
  input wire clk,
  input wire [9:0] addr,
  output reg [3:0] dout,
  input wire en
);

reg [3:0] mem [0:1023];
initial $readmemh(MEMORY_FILE, mem);

always @(posedge clk)
  if (en) dout <= mem[addr];

endmodule
`default_nettype wire
