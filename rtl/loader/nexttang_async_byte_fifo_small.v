// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
`default_nettype none

// Small register-backed CDC FIFO for the BSRAM-saturated Spec256 profile.
// FAT32 backpressure keeps this deliberately short queue from overflowing.
module nexttang_async_byte_fifo_small (
 input wire write_clock,write_reset,write_clear,input wire[7:0]write_data,
 input wire write_enable,output wire write_full,output wire[6:0]write_level,
 input wire read_clock,read_reset,read_clear,output reg[7:0]read_data,
 output reg read_valid,input wire read_pop);
 (* syn_ramstyle = "registers" *) reg[7:0]memory[0:63];
 reg[6:0]wb=0,wg=0,rb=0,rg=0,rgw1=0,rgw2=0,wgr1=0,wgr2=0;
 wire[6:0]wbn=wb+1'b1;wire[6:0]wgn=(wbn>>1)^wbn;
 wire[6:0]full_compare={~rgw2[6:5],rgw2[4:0]};assign write_full=wgn==full_compare;
 function[6:0]g2b;input[6:0]g;integer i;begin g2b[6]=g[6];
  for(i=5;i>=0;i=i-1)g2b[i]=g2b[i+1]^g[i];end endfunction
 assign write_level=wb-g2b(rgw2);
 always@(posedge write_clock)begin
  if(write_reset||write_clear)begin wb<=0;wg<=0;rgw1<=0;rgw2<=0;end
  else begin rgw1<=rg;rgw2<=rgw1;if(write_enable&&!write_full)begin
   memory[wb[5:0]]<=write_data;wb<=wbn;wg<=wgn;end end end
 always@(posedge read_clock)begin
  if(read_reset||read_clear)begin rb<=0;rg<=0;wgr1<=0;wgr2<=0;read_data<=0;read_valid<=0;end
  else begin wgr1<=wg;wgr2<=wgr1;if(!read_valid||read_pop)begin
   if(rg!=wgr2)begin read_data<=memory[rb[5:0]];rb<=rb+1'b1;
    rg<=((rb+1'b1)>>1)^(rb+1'b1);read_valid<=1;end else read_valid<=0;end end end
endmodule
`default_nettype wire
