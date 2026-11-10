// NextTang: bus-master write engine for the Gowin GW5AST PCIe TL interface.
// One-shot: the host programs a window and presses GO; the engine writes
// [base, base+len) with a pattern using posted MWr TLPs and then stops.
// It never issues reads to the host.
//
// TL conventions as in nt_bar_completer.v and ../README.md: DW0 of a beat is
// data[255:224]; valid[7] covers DW0; payload bytes are byte-swapped relative
// to the CPU (CPU word 0x12345678 travels as lane value 0x78563412).
//
// Register map (BAR2 offset, 32-bit accesses only):
//   0x40 ID        RO  "NTDM" 0x4E54444D
//   0x44 CTRL      W   bit0 GO, bit1 CLEAR (idle only), bit2 ABORT;
//                      bit8 pattern mode (0 increment, 1 hashed). R: mode.
//   0x48 ADDR_LO   RW  bus address [31:0] (must be 4-byte aligned)
//   0x4C ADDR_HI   RW  bus address [63:32]
//   0x50 LEN       RW  bytes, multiple of 4, 1..MAX_LEN
//   0x54 PAYLOAD   RW  bytes per TLP: 64, 128, 256 or 512 (<= MAX_PAYLOAD)
//   0x58 SEED      RW  pattern seed
//   0x5C STATUS    RO  [0] DONE [1] BUSY [2] ERROR [15:8] error code
//                      [16] link up [17] posted credit ok
//   0x60 CYCLES    RO  TL clocks from GO to the last EOP accepted (+1)
//   0x64 BYTES     RO  payload bytes accepted by the hard core
//   0x68 TLPS      RO  TLPs accepted
//   0x6C MAXLEN    RO  hard length limit (bytes)
//   0x70 WAITCYC   RO  clocks a beat was offered while tx_wait was high
//   0x74 CREDCYC   RO  clocks a TLP start waited for posted credit
//   0x78 RUNS      RO  accepted GO count
//   0x7C LASTADDR  RO  address [31:0] of the last TLP started
//   other offsets in 0x40-0xFF read 0.
//
// Pattern word i (i = 0 at base, counting 32-bit words):
//   mode 0: seed + i
//   mode 1: x = seed + i; x ^= x << 13; x ^= x >> 17; x ^= x << 5
//           (one xorshift32 step of seed + i)
module nt_dma_writer #(
    parameter [31:0] MAX_LEN = 32'h0100_0000,   // 16 MiB
    parameter [10:0] MAX_PAYLOAD = 11'd512,
    parameter [3:0]  START_GAP = 4'd3           // idle clocks after each EOP
) (
    input wire clk,
    input wire rst_in,
    input wire link_up,
    input wire [12:0] cfg_busdev,
    input wire p_credit_ok,
    // register port from the BAR2 completer (word address within 0x00-0xFF)
    input wire reg_wr,
    input wire [5:0] reg_waddr,
    input wire [31:0] reg_wdata,
    input wire [5:0] reg_raddr,
    output reg [31:0] reg_rdata,
    // TL transmit (Gowin valid/wait)
    output reg tx_sop,
    output reg tx_eop,
    output reg [7:0] tx_valid,
    output reg [255:0] tx_data,
    input wire tx_wait
);
    localparam S_IDLE = 3'd0, S_PREP = 3'd1, S_CHECK = 3'd2, S_GAP = 3'd3,
               S_CREDIT = 3'd4, S_SEND = 3'd5, S_EOP = 3'd6;

    localparam [7:0] E_NONE = 8'd0, E_LEN_ZERO = 8'd1, E_LEN_MAX = 8'd2,
                     E_LEN_ALIGN = 8'd3, E_ADDR_ALIGN = 8'd4, E_PAYLOAD = 8'd5,
                     E_WRAP = 8'd6, E_BUSY = 8'd7, E_CLAMP = 8'd9,
                     E_ABORT = 8'd10;

    // Reset is registered here (timing); the top masks tx_valid with the
    // unregistered reset, so nothing leaves during the extra clock.
    reg rst = 1'b1;
    always @(posedge clk) rst <= rst_in;

    // programmed registers
    reg [31:0] r_addr_lo, r_addr_hi, r_len, r_seed;
    reg [10:0] r_payload;
    reg r_mode;
    // status
    reg done, busy, error;
    reg [7:0] err_code;
    reg [31:0] cycles, bytes_sent, tlps_sent, wait_cyc, cred_cyc, runs, last_addr;
    // latched window for the current GO
    reg [63:0] base, win_end, cur;
    reg [10:0] pay;
    reg mode;
    reg abort_req;
    // current TLP
    reg [2:0] state;
    reg [10:0] tlp_bytes;      // <= 512
    reg [7:0] dw_left;         // payload DWs not yet placed in a beat
    reg last_next;             // dw_left <= 8
    reg [3:0] gap;
    reg [23:0] rem_r;          // win_end - cur, saturated (len <= 16 MiB)
    reg [12:0] to4k_r;
    reg credit_r;              // registered posted-credit flag (timing)
    reg tx_any;                // registered |tx_valid (timing)
    // sb[k] = seed + index of the k-th next payload word
    reg [31:0] sb0, sb1, sb2, sb3, sb4, sb5, sb6, sb7;
    // GO is processed two clocks after the CTRL write, against validation
    // results registered from parameters that cannot change meanwhile.
    reg go_req, go_req2, go_mode, go_mode2;
    reg [7:0] go_err_r;
    reg [63:0] end_r;
    // per-TLP values computed during the gap (timing)
    reg [63:0] tlp_end_r;
    reg small_bad_r, range_bad_r, last_tlp_r;
    reg wide_r, first_is_last_r;
    reg [7:0] first_n_r, first_left_r;
    reg [7:0] first_mask_r;

    // The only use of tx_wait on the data path: one LUT to every enable.
    wire accept = tx_any && !tx_wait;

    function [31:0] swap_bytes;
        input [31:0] d;
        begin swap_bytes = {d[7:0], d[15:8], d[23:16], d[31:24]}; end
    endfunction
    function [31:0] shape;
        input m;
        input [31:0] x0;
        reg [31:0] x;
        begin
            x = x0;
            if (m) begin
                x = x ^ (x << 13);
                x = x ^ (x >> 17);
                x = x ^ (x << 5);
            end
            shape = swap_bytes(x);
        end
    endfunction
    wire [31:0] p0 = shape(mode, sb0), p1 = shape(mode, sb1),
                p2 = shape(mode, sb2), p3 = shape(mode, sb3),
                p4 = shape(mode, sb4), p5 = shape(mode, sb5),
                p6 = shape(mode, sb6), p7 = shape(mode, sb7);

    // ---- TLP header for the current address ----
    wire wide = |cur[63:32];          // 4-DW header only above 4 GiB
    wire [9:0] len_dw = {1'b0, tlp_bytes[10:2]}; // <= 128 DW
    wire [31:0] hdr0 = {wide_r ? 3'b011 : 3'b010, 5'b00000, 14'd0, len_dw};
    wire [31:0] hdr1 = {cfg_busdev, 3'b000, 8'd0,
                        (len_dw == 10'd1) ? 4'h0 : 4'hf, 4'hf};
    wire [7:0] first_dw = wide ? 8'd4 : 8'd5;
    wire first_is_last = {1'b0, len_dw} <= {3'b0, first_dw};
    wire [7:0] first_n = first_is_last ? len_dw[7:0] : first_dw;

    function [7:0] dw_mask;
        input [3:0] n;
        begin
            case (n)
                4'd0: dw_mask = 8'h00; 4'd1: dw_mask = 8'h80;
                4'd2: dw_mask = 8'hc0; 4'd3: dw_mask = 8'he0;
                4'd4: dw_mask = 8'hf0; 4'd5: dw_mask = 8'hf8;
                4'd6: dw_mask = 8'hfc; 4'd7: dw_mask = 8'hfe;
                default: dw_mask = 8'hff;
            endcase
        end
    endfunction

    wire [12:0] to4k = 13'd4096 - {1'b0, cur[11:0]};
    wire [63:0] rem64 = win_end - cur;
    wire [7:0] mid_n = last_next ? dw_left : 8'd8;

    // ---- register read mux ----
    always @(*) begin
        case (reg_raddr)
            6'h10: reg_rdata = 32'h4E54444D;
            6'h11: reg_rdata = {23'd0, r_mode, 8'd0};
            6'h12: reg_rdata = r_addr_lo;
            6'h13: reg_rdata = r_addr_hi;
            6'h14: reg_rdata = r_len;
            6'h15: reg_rdata = {21'd0, r_payload};
            6'h16: reg_rdata = r_seed;
            // A GO still in its two-clock pipeline already reads as BUSY.
            6'h17: reg_rdata = {14'd0, credit_r, link_up, err_code, 5'd0, error,
                                busy | go_req | go_req2, done & !(go_req | go_req2)};
            6'h18: reg_rdata = cycles;
            6'h19: reg_rdata = bytes_sent;
            6'h1a: reg_rdata = tlps_sent;
            6'h1b: reg_rdata = MAX_LEN;
            6'h1c: reg_rdata = wait_cyc;
            6'h1d: reg_rdata = cred_cyc;
            6'h1e: reg_rdata = runs;
            6'h1f: reg_rdata = last_addr;
            default: reg_rdata = 32'd0;
        endcase
    end

    // GO validation (on the programmed registers)
    wire [64:0] end65 = {1'b0, r_addr_hi, r_addr_lo} + {33'd0, r_len};
    wire pay_ok = (r_payload == 11'd64 || r_payload == 11'd128 ||
                   r_payload == 11'd256 || r_payload == 11'd512) &&
                  r_payload <= MAX_PAYLOAD;
    wire [7:0] go_err =
        (r_len == 32'd0)     ? E_LEN_ZERO :
        (r_len > MAX_LEN)    ? E_LEN_MAX :
        (|r_len[1:0])        ? E_LEN_ALIGN :
        (|r_addr_lo[1:0])    ? E_ADDR_ALIGN :
        !pay_ok              ? E_PAYLOAD :
        end65[64]            ? E_WRAP : E_NONE;

    wire params_locked = busy || go_req || go_req2;

    always @(posedge clk) begin
        if (rst) begin
            r_addr_lo <= 0; r_addr_hi <= 0; r_len <= 0; r_seed <= 0;
            r_payload <= 11'd128; r_mode <= 0;
            done <= 0; busy <= 0; error <= 0; err_code <= 0;
            cycles <= 0; bytes_sent <= 0; tlps_sent <= 0; wait_cyc <= 0;
            cred_cyc <= 0; runs <= 0; last_addr <= 0;
            base <= 0; win_end <= 0; cur <= 0; pay <= 0; mode <= 0;
            abort_req <= 0;
            state <= S_IDLE;
            tlp_bytes <= 0; dw_left <= 0; last_next <= 0; gap <= 0;
            rem_r <= 0; to4k_r <= 0; credit_r <= 0;
            sb0 <= 0; sb1 <= 0; sb2 <= 0; sb3 <= 0; sb4 <= 0; sb5 <= 0; sb6 <= 0; sb7 <= 0;
            go_req <= 0; go_req2 <= 0; go_mode <= 0; go_mode2 <= 0;
            go_err_r <= 0; end_r <= 0;
            tlp_end_r <= 0; small_bad_r <= 0; range_bad_r <= 0; last_tlp_r <= 0;
            wide_r <= 0; first_is_last_r <= 0; first_n_r <= 0; first_left_r <= 0;
            first_mask_r <= 0;
            tx_sop <= 0; tx_eop <= 0; tx_valid <= 0; tx_data <= 0; tx_any <= 0;
        end else begin
            credit_r <= p_credit_ok;
            go_err_r <= go_err;
            end_r <= end65[63:0];
            go_req2 <= go_req; go_mode2 <= go_mode;
            go_req <= 1'b0;

            // ---------------- GO (two clocks after the CTRL write) ----------------
            if (go_req2) begin
                if (busy) begin
                    // The running transfer continues inside its own window.
                    error <= 1'b1; err_code <= E_BUSY;
                end else if (go_err_r != E_NONE) begin
                    // A refused GO never touches the bus.
                    error <= 1'b1; err_code <= go_err_r; done <= 1'b0;
                end else begin
                    busy <= 1'b1; done <= 1'b0; error <= 1'b0;
                    err_code <= E_NONE;
                    base <= {r_addr_hi, r_addr_lo};
                    cur <= {r_addr_hi, r_addr_lo};
                    win_end <= end_r;
                    pay <= r_payload;
                    mode <= go_mode2;
                    sb0 <= r_seed;        sb1 <= r_seed + 32'd1;
                    sb2 <= r_seed + 32'd2; sb3 <= r_seed + 32'd3;
                    sb4 <= r_seed + 32'd4; sb5 <= r_seed + 32'd5;
                    sb6 <= r_seed + 32'd6; sb7 <= r_seed + 32'd7;
                    cycles <= 0; bytes_sent <= 0; tlps_sent <= 0;
                    wait_cyc <= 0; cred_cyc <= 0;
                    runs <= runs + 1'b1;
                    abort_req <= 1'b0;
                    state <= S_PREP;
                end
            end

            // ---------------- register writes ----------------
            if (reg_wr) begin
                case (reg_waddr)
                    6'h11: begin
                        if (reg_wdata[2] && busy) abort_req <= 1'b1;
                        if (reg_wdata[1] && !busy) begin
                            done <= 0; error <= 0; err_code <= 0;
                            cycles <= 0; bytes_sent <= 0; tlps_sent <= 0;
                            wait_cyc <= 0; cred_cyc <= 0;
                        end
                        if (!busy) r_mode <= reg_wdata[8];
                        if (reg_wdata[0]) begin
                            go_req <= 1'b1;
                            go_mode <= reg_wdata[8];
                        end
                    end
                    6'h12: if (!params_locked) r_addr_lo <= reg_wdata;
                    6'h13: if (!params_locked) r_addr_hi <= reg_wdata;
                    6'h14: if (!params_locked) r_len <= reg_wdata;
                    6'h15: if (!params_locked) r_payload <= reg_wdata[10:0];
                    6'h16: if (!params_locked) r_seed <= reg_wdata;
                    default: ;
                endcase
            end

            if (busy) cycles <= cycles + 1'b1;
            if (tx_any && tx_wait) wait_cyc <= wait_cyc + 1'b1;

            // ---------------- beat handshake (S_SEND only) ----------------
            if (accept) begin
                tx_sop <= 1'b0;
                if (tx_eop) begin
                    tx_eop <= 1'b0;
                    tx_valid <= 8'd0;
                    tx_any <= 1'b0;
                    state <= S_EOP;
                end else begin
                    tx_data <= {p0, p1, p2, p3, p4, p5, p6, p7};
                    tx_eop <= last_next;
                    tx_valid <= last_next ? dw_mask(dw_left[3:0]) : 8'hff;
                    dw_left <= dw_left - mid_n;
                    last_next <= (dw_left - mid_n) <= 8'd8;
                    sb0 <= sb0 + mid_n; sb1 <= sb1 + mid_n;
                    sb2 <= sb2 + mid_n; sb3 <= sb3 + mid_n;
                    sb4 <= sb4 + mid_n; sb5 <= sb5 + mid_n;
                    sb6 <= sb6 + mid_n; sb7 <= sb7 + mid_n;
                end
            end

            // ---------------- engine ----------------
            case (state)
                S_IDLE: ;
                S_PREP: begin
                    rem_r <= (|rem64[63:24]) ? 24'hffffff : rem64[23:0];
                    to4k_r <= to4k;
                    state <= S_CHECK;
                end
                S_CHECK: begin
                    if (abort_req) begin
                        busy <= 0; error <= 1; err_code <= E_ABORT; state <= S_IDLE;
                    end else begin
                        // n = min(pay, rem, bytes to the next 4 KiB boundary)
                        if ({13'd0, pay} <= rem_r && {2'b0, pay} <= to4k_r)
                            tlp_bytes <= pay;
                        else if ({11'd0, to4k_r} <= rem_r)
                            tlp_bytes <= to4k_r[10:0];
                        else
                            tlp_bytes <= rem_r[10:0];
                        state <= S_GAP;
                        gap <= START_GAP;
                    end
                end
                S_GAP: begin
                    // Hardware clamp, staged over the gap clocks:
                    // [cur, cur+n) inside [base, win_end), 0 < n <= pay,
                    // DW multiple, and no 4 KiB crossing.
                    if (gap == START_GAP) begin
                        tlp_end_r <= cur + {53'd0, tlp_bytes};
                        small_bad_r <= tlp_bytes == 11'd0 || tlp_bytes > pay ||
                                       {2'b0, tlp_bytes} > to4k_r || |tlp_bytes[1:0];
                        wide_r <= wide;
                        first_is_last_r <= first_is_last;
                        first_n_r <= first_n;
                        first_left_r <= len_dw[7:0] - first_n;
                        first_mask_r <= first_is_last ?
                            dw_mask((wide ? 4'd4 : 4'd3) + len_dw[3:0]) : 8'hff;
                    end
                    if (gap == START_GAP - 1)
                        range_bad_r <= cur < base || tlp_end_r > win_end;
                    if (gap == START_GAP - 2)
                        last_tlp_r <= tlp_end_r >= win_end;
                    if (gap != 0) gap <= gap - 1'b1;
                    else if (small_bad_r || range_bad_r) begin
                        busy <= 0; error <= 1; err_code <= E_CLAMP; state <= S_IDLE;
                    end else state <= S_CREDIT;
                end
                S_CREDIT: begin
                    if (!link_up || abort_req) begin
                        busy <= 0; error <= 1; err_code <= E_ABORT; state <= S_IDLE;
                    end else if (!credit_r) begin
                        cred_cyc <= cred_cyc + 1'b1;
                    end else begin
                        tx_sop <= 1'b1;
                        tx_any <= 1'b1;
                        last_addr <= cur[31:0];
                        if (wide_r)
                            tx_data <= {hdr0, hdr1, cur[63:32], cur[31:2], 2'b00,
                                        p0, p1, p2, p3};
                        else
                            tx_data <= {hdr0, hdr1, cur[31:2], 2'b00,
                                        p0, p1, p2, p3, p4};
                        tx_eop <= first_is_last_r;
                        tx_valid <= first_mask_r;
                        dw_left <= first_left_r;
                        last_next <= first_left_r <= 8'd8;
                        sb0 <= sb0 + first_n_r; sb1 <= sb1 + first_n_r;
                        sb2 <= sb2 + first_n_r; sb3 <= sb3 + first_n_r;
                        sb4 <= sb4 + first_n_r; sb5 <= sb5 + first_n_r;
                        sb6 <= sb6 + first_n_r; sb7 <= sb7 + first_n_r;
                        state <= S_SEND;
                    end
                end
                S_SEND: ;   // beats advance in the handshake block above
                S_EOP: begin
                    tlps_sent <= tlps_sent + 1'b1;
                    bytes_sent <= bytes_sent + tlp_bytes;
                    cur <= tlp_end_r;
                    if (last_tlp_r) begin
                        busy <= 1'b0; done <= 1'b1; state <= S_IDLE;
                    end else if (abort_req) begin
                        busy <= 0; error <= 1; err_code <= E_ABORT; state <= S_IDLE;
                    end else state <= S_PREP;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
