// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
`default_nettype none
module nexttang_loader_overlay (
 input wire clock,input wire enable,input wire ready,input wire error,input wire[2:0]diagnostic_code,
 input wire[10:0]x,input wire[9:0]y,
 input wire[5:0]selection,input wire[5:0]file_count,output reg[5:0]display_entry,
 output reg[5:0]display_name_index,input wire[7:0]display_name_data,
 input wire[7:0]display_name_length,output reg overlay_enable,
 output reg[7:0]red,green,blue);
 localparam integer X0=320,Y0=120,WIDTH=640,HEIGHT=480;
 // Break the HDMI-counter-to-font path before coordinate decoding.  The name
 // RAM query and glyph selection both use these delayed coordinates, so their
 // existing two-pixel alignment remains intact while placement gets a full
 // pixel period for the subtract/range/character logic.
 reg[10:0]x_q=0;reg[9:0]y_q=0;reg enable_q=0;
 always@(posedge clock)begin x_q<=x;y_q<=y;enable_q<=enable;end
 wire panel=enable_q&&x_q>=X0&&x_q<X0+WIDTH&&y_q>=Y0&&y_q<Y0+HEIGHT;
 wire[10:0]lx=x_q-X0;wire[9:0]ly=y_q-Y0;wire[5:0]first=selection>23?selection-23:0;
 wire in_list=ly>=64&&ly<448;wire[4:0]row=(ly-64)>>4;wire[5:0]entry=first+row;
 wire[5:0]column=lx>=32?(lx-32)>>4:0;wire[5:0]query_column=lx>=30?(lx-30)>>4:0;
 wire selected=in_list&&entry==selection;reg[7:0]character_next;
 reg[2:0]font_row_next,font_column_next;reg[7:0]background_red_next,
 background_green_next,background_blue_next;reg panel_next,selected_next;
 reg[7:0]character=8'h20;reg[2:0]font_row=0,font_column=0;
 reg[7:0]background_red=0,background_green=0,background_blue=0;
 reg panel_q=0,selected_q=0;wire glyph_pixel;
 nexttang_loader_font font(.character(character),.row(font_row),.column(font_column),.pixel(glyph_pixel));
 always@(*)begin
  // Stop the hidden menu from making the live HDMI raster sweep the catalog
  // name RAM throughout gameplay.  This preserves the established menu
  // pipeline and costs no additional pixel-clock register stage.
  display_entry=enable?entry:0;display_name_index=enable?query_column:0;
  character_next=8'h20;
  font_row_next=(ly-66)>>1;font_column_next=(lx-36)>>1;panel_next=panel;selected_next=selected;
  background_red_next=8'h08;background_green_next=8'h0c;background_blue_next=8'h20;
  if(panel)begin
   if(ly<56)begin background_red_next=8'h18;background_green_next=8'h28;background_blue_next=8'h58;
    if(ly>=20&&ly<36&&lx>=192&&lx<448)begin font_row_next=(ly-20)>>1;font_column_next=(lx-196)>>1;
     case((lx-192)>>4)0:character_next="N";1:character_next="E";2:character_next="X";
      3:character_next="T";4:character_next="T";5:character_next="A";6:character_next="N";
      7:character_next="G";8:character_next=" ";9:character_next="L";10:character_next="O";
      11:character_next="A";12:character_next="D";13:character_next="E";
      14:character_next="R";default:character_next=" ";endcase end
   end else if(error)begin
    if(ly>=220&&ly<236&&lx>=224&&lx<416)begin font_row_next=(ly-220)>>1;font_column_next=(lx-228)>>1;
     case((lx-224)>>4)0:character_next="E";1:character_next="R";2:character_next="R";
      3:character_next="O";4:character_next="R";5:character_next=" ";
      6:character_next=diagnostic_code==0?"C":diagnostic_code==1?"S":diagnostic_code==2?"S":
                       diagnostic_code==3?"D":diagnostic_code==4?"R":
                       diagnostic_code==5?"G":diagnostic_code==6?"S":"F";
      7:character_next=diagnostic_code==0?"A":diagnostic_code==1?"D":diagnostic_code==2?"I":
                       diagnostic_code==3?"I":diagnostic_code==4?"D":
                       diagnostic_code==5?"A":diagnostic_code==6?"P":"I";
      8:character_next=diagnostic_code==0?"T":diagnostic_code==1?" ":diagnostic_code==2?"G":
                       diagnostic_code==3?"R":diagnostic_code==4?" ":
                       diagnostic_code==5?"M":diagnostic_code==6?"C":"L";
      9:character_next=diagnostic_code==2?" ":diagnostic_code==3?" ":
                       diagnostic_code==5?" ":" ";default:character_next=" ";endcase end
   end else if(!ready)begin
    if(ly>=220&&ly<236&&lx>=240&&lx<400)begin font_row_next=(ly-220)>>1;font_column_next=(lx-244)>>1;
     case((lx-240)>>4)0:character_next="R";1:character_next="E";2:character_next="A";
      3:character_next="D";4:character_next="I";5:character_next="N";6:character_next="G";
      7:character_next=".";8:character_next=".";9:character_next=".";default:character_next=" ";endcase end
   end else if(in_list&&entry<=file_count)begin
    if(selected)begin background_red_next=8'h18;background_green_next=8'h58;background_blue_next=8'ha0;end
    if(lx>=32&&column<display_name_length)character_next=display_name_data;end
  end
 end
 always@(posedge clock)begin character<=character_next;font_row<=font_row_next;font_column<=font_column_next;
  background_red<=background_red_next;background_green<=background_green_next;
  background_blue<=background_blue_next;panel_q<=panel_next;selected_q<=selected_next;end
 always@(*)begin overlay_enable=panel_q;red=background_red;green=background_green;blue=background_blue;
  if(glyph_pixel)begin red=8'hff;green=selected_q?8'hf0:8'hff;blue=selected_q?8'h90:8'hff;end end
endmodule
`default_nettype wire
