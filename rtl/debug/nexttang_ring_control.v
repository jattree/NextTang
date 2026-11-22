// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 NextTang contributors
//
// The rewind ring on a board whose debugger is the FPGA-side SPI master
// (docs/replay-and-rewind.md, piece 4): checkpoints of the machine's memory
// and CPU registers, taken and gone back to on single-letter commands from
// the debug UART.
//
// It holds the dirty-block tracker and the checkpoint store, and reaches the
// machine the way a debugger does, with no change to the core:
//
//   - main memory, the copy, the undo ring and the checkpoints' notes (their
//     registers and place in the recording) through memory port C (the whole
//     SDRAM die; the Next's 2 MiB is its first quarter);
//   - bank 5 and the first half of bank 7, which the core keeps only in block
//     RAM: written through the debug slave's block RAM commands, a byte a
//     command, and read from a mirror kept in the SDRAM (below);
//   - the CPU's registers through the slave's register commands;
//   - stopping and resuming the CPU through the slave's pause and resume.
//
// The slave is driven through the board's SPI master, which this module
// takes for a command at a time (spi_take) while the UART link is idle. The
// host must send nothing else until a command here has finished.
//
// Commands (command_valid / command_byte):
//
//     p        prime: the first checkpoint. Every block is taken as written,
//              so the store's copy is made in full (about two seconds for the
//              2 MiB), and the registers and the recorder's position are
//              noted. Needed once at the start, and again after anything but
//              the machine has written its memory.
//     g        checkpoint: the CPU is stopped if it is running, the registers
//              and the recorder's position are noted, the blocks written
//              since the last checkpoint are saved, and the CPU goes on if it
//              was running.
//     r h h    rewind by the number of checkpoints given as two hex digits
//              (00: back to the last checkpoint). The CPU is stopped; memory
//              and registers become the checkpoint's; the CPU stays stopped.
//     i        report (below).
//
// p and r end with the report as well; g does not while the CPU was running,
// because during a recording the transmit line is the recorder's. (The
// letters are none of the hex digits, which the K command's key masks are
// made of.) The report is one line:
//
//     i HH FFFF TTTT RRRR SS V \n     (hex, no spaces)
//
//     HH    checkpoints that can still be gone back over
//     FFFF  the newest checkpoint's position: the recorder's frame count,
//     TTTT  the fetches and
//     RRRR  the port reads in the frame then under way
//     SS    its CPU state byte (00 IM IM 0 HALT IFF2 IFF1)
//     V     1: the store dropped everything at the last checkpoint (it was
//           bigger than the ring)
//
// A checkpoint's position is where a replay must take up after a rewind to
// it: the host gives the player that frame shortened by the fetches and port
// reads already made. The interrupt mode is not restored (the debug
// interface cannot write it); SS lets the host see whether it has changed.

`default_nettype none

module nexttang_ring_control #(
    parameter integer CLOCK_HZ = 28125000,
    parameter integer BAUD_RATE = 115200,
    parameter RING_BITS = 21,                  // 2 MiB of undo records at 0x400000
    parameter TABLE_BITS = 6,
    parameter [22:0] NOTES_BASE = 23'h600000   // the checkpoints' notes, above the ring
) (
    input  wire        clock,
    input  wire        reset,

    input  wire        command_valid,
    input  wire [7:0]  command_byte,
    output wire        busy,

    input  wire        cpu_stopped,
    input  wire [15:0] frames,
    input  wire [15:0] frame_fetches,
    input  wire [15:0] frame_reads,

    // the machine's own writes to main memory, for the tracker
    input  wire        write_valid,
    input  wire [20:0] write_address,
    // and its writes to the block RAM banks, with the byte, for the mirror
    input  wire        bank_valid,
    input  wire [20:0] bank_address,
    input  wire [7:0]  bank_data,

    // the SPI master to the debug slave
    input  wire        spi_free,        // nobody else is using it
    output reg         spi_take = 1'b0,
    output reg         spi_select = 1'b0,
    output reg         spi_byte_valid = 1'b0,
    output reg  [7:0]  spi_byte = 8'h00,
    input  wire        spi_byte_ready,
    input  wire        spi_done,
    input  wire [7:0]  spi_reply,
    input  wire        spi_idle,

    // memory port C, the whole die
    input  wire        c_free,          // the core is not using it
    output wire        c_take,
    output reg         c_request = 1'b0,
    output reg         c_read_n = 1'b1,
    output reg  [22:0] c_address = 23'd0,
    output reg  [7:0]  c_write_data = 8'h00,
    input  wire [7:0]  c_read_data,
    input  wire        c_ack,

    output wire        tx
);
    // ------------------------------------------------ tracker and store
    wire        scan_start, block_valid, block_ready, scan_done;
    wire [12:0] block;
    reg         store_prime = 1'b0, store_checkpoint = 1'b0, store_rewind = 1'b0;
    reg  [TABLE_BITS:0] back_steps = 0;
    wire        store_busy, store_done, store_overrun;
    wire [TABLE_BITS:0] held, went_back;
    wire        store_mem_request, store_mem_write;
    wire [22:0] store_mem_address;
    wire [7:0]  store_mem_write_data;
    // the checkpoint notes use the same way into memory, between the store's commands
    reg         note_request = 1'b0, note_write = 1'b0;
    reg  [22:0] note_address = 23'd0;
    reg  [7:0]  note_in = 8'h00;
    wire        mem_request = store_busy ? store_mem_request : note_request;
    wire        mem_write = store_busy ? store_mem_write : note_write;
    wire [22:0] mem_address = store_busy ? store_mem_address : note_address;
    wire [7:0]  mem_write_data = store_busy ? store_mem_write_data : note_in;
    reg  [7:0]  mem_read_data = 8'h00;
    reg         mem_ack = 1'b0;

    reg         refill = 1'b0;          // a prime starts from every block dirty
    nexttang_dirty_blocks #(.BLOCK_BITS(13)) tracker (
        .clock(clock), .reset(reset || refill),
        .write_valid_in(write_valid), .write_block_in(write_address[20:8]),
        .scan_start(scan_start), .block_valid(block_valid), .block(block), .block_ready(block_ready),
        .scan_done(scan_done), .scanning());

    nexttang_rewind_store #(
        .BLOCK_BITS(13), .RING_BITS(RING_BITS), .TABLE_BITS(TABLE_BITS), .ADDRESS_BITS(23),
        .LIVE_BASE(23'h000000), .COPY_BASE(23'h200000), .RING_BASE(23'h400000)
    ) store (
        .clock(clock), .reset(reset),
        .prime(store_prime), .checkpoint(store_checkpoint), .rewind(store_rewind), .back_steps(back_steps),
        .busy(store_busy), .done(store_done), .held(held), .went_back(went_back), .overrun(store_overrun),
        .scan_start(scan_start), .block_valid(block_valid), .block(block), .block_ready(block_ready),
        .scan_done(scan_done),
        .mem_request(store_mem_request), .mem_write(store_mem_write), .mem_address(store_mem_address),
        .mem_write_data(store_mem_write_data), .mem_read_data(mem_read_data), .mem_ack(mem_ack && store_busy));

    // ------------------------------------------------ one slave command
    // Every command used here is the first txn_count bytes of
    //     op, p1, p2, 00, 01, p3, 00
    // (register read AD r 00 00; register write AE r v 00; block RAM read
    // A9 hi lo 00 01 00 00; block RAM write AA hi lo 00 01 v; pause A4;
    // resume A5). The last byte's reply is kept.
    reg [7:0]  txn_op, txn_p1, txn_p2, txn_p3;
    reg [2:0]  txn_count;
    reg        txn_start;
    reg        txn_done = 1'b0;
    reg [7:0]  txn_reply = 8'h00;
    localparam T_IDLE = 3'd0, T_CLAIM = 3'd1, T_OFFER = 3'd2, T_REPLY = 3'd3, T_RELEASE = 3'd4, T_REST = 3'd5;
    reg [2:0]  txn_state = T_IDLE;
    reg [2:0]  txn_at = 3'd0;
    reg [2:0]  txn_last = 3'd0;
    reg [7:0]  txn_byte;
    always @* case (txn_at)
        3'd0: txn_byte = txn_op;
        3'd1: txn_byte = txn_p1;
        3'd2: txn_byte = txn_p2;
        3'd4: txn_byte = 8'h01;
        3'd5: txn_byte = txn_p3;
        default: txn_byte = 8'h00;
    endcase

    always @(posedge clock) begin
        txn_done <= 1'b0;
        case (txn_state)
            T_IDLE:
                if (txn_start) begin
                    txn_at <= 3'd0;
                    txn_last <= txn_count - 1'b1;
                    txn_state <= T_CLAIM;
                end
            T_CLAIM:                    // wait for the master to be nobody's and at rest
                if (spi_free && spi_idle) begin
                    spi_take <= 1'b1;
                    spi_select <= 1'b1;
                    txn_state <= T_OFFER;
                end
            T_OFFER: begin
                spi_byte <= txn_byte;
                spi_byte_valid <= 1'b1;
                if (spi_byte_valid && spi_byte_ready) begin
                    spi_byte_valid <= 1'b0;
                    txn_state <= T_REPLY;
                end
            end
            T_REPLY:
                if (spi_done) begin
                    txn_reply <= spi_reply;
                    txn_at <= txn_at + 1'b1;
                    txn_state <= txn_at == txn_last ? T_RELEASE : T_OFFER;
                end
            T_RELEASE: begin
                spi_select <= 1'b0;
                txn_state <= T_REST;
            end
            T_REST:                     // chip select has risen and the master is at rest
                if (!spi_select && spi_idle) begin
                    spi_take <= 1'b0;
                    txn_done <= 1'b1;
                    txn_state <= T_IDLE;
                end
            default: txn_state <= T_IDLE;
        endcase
        if (reset) begin
            txn_state <= T_IDLE;
            spi_take <= 1'b0;
            spi_select <= 1'b0;
            spi_byte_valid <= 1'b0;
            txn_done <= 1'b0;
        end
    end

    // ------------------------------------------------ the store's memory
    // Bank 5 is 8K pages 0A and 0B of the 2 MiB (0x54000-0x57FFF), the half
    // of bank 7 in block RAM is page 0E (0x5C000-0x5DFFF). The SDRAM at
    // those addresses is otherwise unused, and holds a mirror of the block
    // RAM here: every byte the machine writes to those banks (bank_valid)
    // is written there too, so a checkpoint reads them as fast as the rest.
    // The mirror is only as good as that writing: one byte can wait, and if
    // a second comes before the first has gone (a CPU faster than port C,
    // as in a 28 MHz replay) the mirror is marked stale. A stale mirror is
    // not read: the bytes come from the slave, a command each, and go into
    // the mirror on the way. Every block that can be stale has been written
    // since the last checkpoint, so the next prime, checkpoint or rewind
    // goes over all of them and the mirror is good again.
    wire        in_live = mem_address[22:21] == 2'b00;
    wire        in_bank5 = in_live && mem_address[20:14] == 7'b0010101;
    wire        in_bank7 = in_live && mem_address[20:13] == 8'b00101110;
    wire [15:0] bram_address = in_bank5 ? {2'b00, mem_address[13:0]} : {3'b100, mem_address[12:0]};
    wire        in_bank = in_bank5 || in_bank7;
    reg         mirror_good = 1'b0;
    reg         mirror_pending = 1'b0;      // a machine write waiting to go into the mirror
    reg [20:0]  mirror_address = 21'd0;
    reg [7:0]   mirror_data = 8'h00;
    reg         mirror_writing = 1'b0;
    localparam A_IDLE = 3'd0, A_PORT_C = 3'd1, A_SLAVE = 3'd2, A_GAP = 3'd3, A_MIRROR = 3'd4, A_FILL = 3'd5;
    reg [2:0]   access = A_IDLE;
    reg         access_txn_start = 1'b0;
    reg         access_txn = 1'b0;      // the command under way is the adapter's
    assign c_take = busy || mirror_writing;

    always @(posedge clock) begin
        mem_ack <= 1'b0;
        access_txn_start <= 1'b0;
        case (access)
            A_IDLE:
                if (mirror_pending) begin
                    // first, so that nothing reads the mirror a byte behind
                    if (c_free || busy) begin
                        mirror_writing <= 1'b1;
                        c_request <= 1'b1;
                        c_read_n <= 1'b1;
                        c_address <= {2'b00, mirror_address};
                        c_write_data <= mirror_data;
                        access <= A_MIRROR;
                    end
                end else if (mem_request && !mem_ack) begin
                    if (in_bank && (mem_write || !mirror_good)) begin
                        access_txn_start <= 1'b1;
                        access_txn <= 1'b1;
                        access <= A_SLAVE;
                    end else begin
                        c_request <= 1'b1;
                        c_read_n <= mem_write;      // the port's line is 0 for a read, 1 for a write
                        c_address <= mem_address;
                        c_write_data <= mem_write_data;
                        access <= A_PORT_C;
                    end
                end
            A_PORT_C:
                if (c_ack) begin
                    c_request <= 1'b0;
                    mem_read_data <= c_read_data;
                    mem_ack <= 1'b1;
                    access <= A_GAP;
                end
            A_MIRROR:
                if (c_ack) begin
                    c_request <= 1'b0;
                    mirror_pending <= 1'b0;
                    mirror_writing <= 1'b0;
                    access <= A_GAP;
                end
            A_SLAVE:                    // the byte to or from the block RAM, then into the mirror
                if (txn_done) begin
                    mem_read_data <= txn_reply;
                    access_txn <= 1'b0;
                    c_request <= 1'b1;
                    c_read_n <= 1'b1;
                    c_address <= mem_address;
                    c_write_data <= mem_write ? mem_write_data : txn_reply;
                    access <= A_FILL;
                end
            A_FILL:
                if (c_ack) begin
                    c_request <= 1'b0;
                    mem_ack <= 1'b1;
                    access <= A_GAP;
                end
            default:                    // the store drops its request on the ack
                access <= A_IDLE;
        endcase

        if (bank_valid) begin
            if (mirror_pending && !(access == A_MIRROR && c_ack))
                mirror_good <= 1'b0;    // one was still waiting: the mirror has missed a byte
            mirror_pending <= 1'b1;
            mirror_address <= bank_address;
            mirror_data <= bank_data;
        end
        if (refill)
            mirror_good <= 1'b0;        // a prime fills it
        if (store_done)
            mirror_good <= 1'b1;

        if (reset) begin
            access <= A_IDLE;
            access_txn <= 1'b0;
            c_request <= 1'b0;
            mem_ack <= 1'b0;
            mirror_good <= 1'b0;
            mirror_pending <= 1'b0;
            mirror_writing <= 1'b0;
        end
    end

    // ------------------------------------------------ commands
    // A checkpoint's notes, 64 bytes each at NOTES_BASE: the 27 register
    // bytes (numbers 00 to 1A), then from byte 32 the recorder's position,
    // six bytes. One slot more than the store's checkpoints: the one before
    // them (the prime, or the oldest dropped) is where a rewind past them
    // all lands.
    localparam SLOT_BITS = TABLE_BITS + 1;
    reg [SLOT_BITS-1:0] slot_next = 0;
    wire [SLOT_BITS-1:0] slot_newest = slot_next - 1'b1;
    function [22:0] note_at(input [SLOT_BITS-1:0] slot, input [5:0] index);
        note_at = NOTES_BASE + {slot, index};
    endfunction

    localparam C_IDLE = 5'd0, C_ARG1 = 5'd1, C_ARG2 = 5'd2, C_STOP = 5'd3, C_STOPPED = 5'd4,
               C_READ = 5'd5, C_READ_WAIT = 5'd6, C_POSITION = 5'd7, C_STORE = 5'd8, C_STORE_WAIT = 5'd9,
               C_WRITE = 5'd10, C_WRITE_SEND = 5'd11, C_WRITE_WAIT = 5'd12, C_RESUME = 5'd13,
               C_RESUME_WAIT = 5'd14, C_REPORT = 5'd15, C_REPORT_NOTE = 5'd16, C_SEND = 5'd17,
               C_NOTE = 5'd18;
    reg [4:0]  state = C_IDLE;
    reg [4:0]  after_note = C_IDLE;     // where to go when the note access is done
    reg [7:0]  note_out = 8'h00;
    reg [1:0]  what = 2'd0;             // 0 prime, 1 checkpoint, 2 rewind, 3 report only
    reg        was_running = 1'b0;
    reg [4:0]  register = 5'd0;
    reg [2:0]  step = 3'd0;
    reg [7:0]  argument = 8'h00;
    reg        dropped = 1'b0;          // the store's overrun, kept for the report
    reg [15:0] at_frames = 16'd0, at_fetches = 16'd0, at_reads = 16'd0;
    reg [7:0]  report_note [0:6];       // position and state of the newest checkpoint
    reg        control_txn_start = 1'b0;
    reg [7:0]  control_op = 8'h00, control_p1 = 8'h00, control_p2 = 8'h00;
    reg [2:0]  control_txn_count = 3'd0;
    reg        report_request = 1'b0;
    assign busy = state != C_IDLE;

    // The adapter's commands are made from the store's request, which stays
    // put until it is answered; the control's from its own registers.
    always @* begin
        txn_start = access_txn_start || control_txn_start;
        if (access_txn_start || access_txn) begin
            txn_op = mem_write ? 8'hAA : 8'hA9;
            txn_p1 = bram_address[15:8];
            txn_p2 = bram_address[7:0];
            txn_p3 = mem_write ? mem_write_data : 8'h00;
            txn_count = mem_write ? 3'd6 : 3'd7;
        end else begin
            txn_op = control_op;
            txn_p1 = control_p1;
            txn_p2 = control_p2;
            txn_p3 = 8'h00;
            txn_count = control_txn_count;
        end
    end

    function [3:0] digit(input [7:0] character);
        digit = character >= "a" ? character[3:0] + 4'd9 : character[3:0];
    endfunction
    function [7:0] hex(input [3:0] n);
        hex = n < 4'd10 ? 8'h30 + {4'd0, n} : 8'h37 + {4'd0, n};
    endfunction

    always @(posedge clock) begin
        store_prime <= 1'b0;
        store_checkpoint <= 1'b0;
        store_rewind <= 1'b0;
        control_txn_start <= 1'b0;
        report_request <= 1'b0;
        refill <= 1'b0;

        case (state)
            C_IDLE:
                if (command_valid) begin
                    was_running <= !cpu_stopped;
                    case (command_byte)
                        "p": begin what <= 2'd0; refill <= 1'b1; state <= C_STOP; end
                        "g": begin what <= 2'd1; state <= C_STOP; end
                        "r": begin what <= 2'd2; state <= C_ARG1; end
                        "i": begin what <= 2'd3; step <= 3'd0; state <= C_REPORT; end
                        default: ;
                    endcase
                end
            C_ARG1:
                if (command_valid) begin
                    argument[7:4] <= digit(command_byte);
                    state <= C_ARG2;
                end
            C_ARG2:
                if (command_valid) begin
                    argument[3:0] <= digit(command_byte);
                    state <= C_STOP;
                end

            // Stop the CPU if it runs.
            C_STOP:
                if (cpu_stopped)
                    state <= C_STOPPED;
                else begin
                    control_op <= 8'hA4;
                    control_txn_count <= 3'd1;
                    control_txn_start <= 1'b1;
                    state <= C_STOPPED;
                end
            C_STOPPED:
                if (cpu_stopped && txn_state == T_IDLE && !control_txn_start) begin
                    at_frames <= frames;
                    at_fetches <= frame_fetches;
                    at_reads <= frame_reads;
                    register <= 5'd0;
                    step <= 3'd0;
                    state <= what == 2'd2 ? C_STORE : C_READ;
                end

            // A byte of the notes read or written.
            C_NOTE:
                if (mem_ack) begin
                    note_request <= 1'b0;
                    note_out <= mem_read_data;
                    state <= after_note;
                end

            // Prime and checkpoint: the registers into the notes.
            C_READ: begin
                control_op <= 8'hAD;
                control_p1 <= {3'b000, register};
                control_p2 <= 8'h00;
                control_txn_count <= 3'd4;
                control_txn_start <= 1'b1;
                state <= C_READ_WAIT;
            end
            C_READ_WAIT:
                if (txn_done) begin
                    note_address <= note_at(slot_next, {1'b0, register});
                    note_in <= txn_reply;
                    note_write <= 1'b1;
                    note_request <= 1'b1;
                    state <= C_NOTE;
                    if (register == 5'd26) begin
                        step <= 3'd0;
                        after_note <= C_POSITION;
                    end else begin
                        register <= register + 1'b1;
                        after_note <= C_READ;
                    end
                end
            C_POSITION:
                if (step == 3'd6)
                    state <= C_STORE;
                else begin
                    note_address <= note_at(slot_next, {3'b100, step});
                    note_write <= 1'b1;
                    note_request <= 1'b1;
                    case (step)
                        3'd0: note_in <= at_frames[15:8];
                        3'd1: note_in <= at_frames[7:0];
                        3'd2: note_in <= at_fetches[15:8];
                        3'd3: note_in <= at_fetches[7:0];
                        3'd4: note_in <= at_reads[15:8];
                        default: note_in <= at_reads[7:0];
                    endcase
                    step <= step + 1'b1;
                    after_note <= C_POSITION;
                    state <= C_NOTE;
                end

            C_STORE: begin
                store_prime <= what == 2'd0;
                store_checkpoint <= what == 2'd1;
                store_rewind <= what == 2'd2;
                // the two digits allow up to FF, more than back_steps holds:
                // saturate, and the store clamps to what it holds (r80-rFF
                // used to lose bit 7 and rewind by 0-7F)
                back_steps <= (argument > {(TABLE_BITS+1){1'b1}}) ? {(TABLE_BITS+1){1'b1}} : argument[TABLE_BITS:0];
                state <= C_STORE_WAIT;
            end
            C_STORE_WAIT:
                if (store_done) begin
                    step <= 3'd0;
                    register <= 5'd0;
                    if (what == 2'd2) begin
                        slot_next <= slot_next - went_back[SLOT_BITS-1:0];
                        state <= C_WRITE;
                    end else begin
                        dropped <= store_overrun;
                        slot_next <= slot_next + 1'b1;
                        state <= what == 2'd1 && was_running ? C_RESUME : C_REPORT;
                    end
                end

            // Rewind: the newest checkpoint's registers back into the CPU,
            // numbers 00 to 19, then the state (HALT and the two IFFs).
            C_WRITE: begin
                note_address <= note_at(slot_newest, {1'b0, register});
                note_write <= 1'b0;
                note_request <= 1'b1;
                after_note <= C_WRITE_SEND;
                state <= C_NOTE;
            end
            C_WRITE_SEND: begin
                control_op <= 8'hAE;
                control_p1 <= register == 5'd26 ? 8'h1B : {3'b000, register};
                control_p2 <= register == 5'd26 ? {5'd0, note_out[2:0]} : note_out;
                control_txn_count <= 3'd4;
                control_txn_start <= 1'b1;
                state <= C_WRITE_WAIT;
            end
            C_WRITE_WAIT:
                if (txn_done) begin
                    if (register == 5'd26) begin
                        step <= 3'd0;
                        state <= C_REPORT;
                    end else begin
                        register <= register + 1'b1;
                        state <= C_WRITE;
                    end
                end

            C_RESUME: begin
                control_op <= 8'hA5;
                control_txn_count <= 3'd1;
                control_txn_start <= 1'b1;
                state <= C_RESUME_WAIT;
            end
            C_RESUME_WAIT:
                if (txn_done)
                    state <= C_IDLE;            // no report: the line may be the recorder's

            // The report: the newest checkpoint's position and state byte.
            C_REPORT: begin
                note_address <= step == 3'd6 ? note_at(slot_newest, 6'd26) : note_at(slot_newest, {3'b100, step});
                note_write <= 1'b0;
                note_request <= 1'b1;
                after_note <= C_REPORT_NOTE;
                state <= C_NOTE;
            end
            C_REPORT_NOTE: begin
                report_note[step] <= note_out;
                if (step == 3'd6)
                    state <= C_SEND;
                else begin
                    step <= step + 1'b1;
                    state <= C_REPORT;
                end
            end
            C_SEND: begin
                report_request <= 1'b1;
                state <= C_IDLE;
            end
            default: state <= C_IDLE;
        endcase

        if (reset) begin
            state <= C_IDLE;
            slot_next <= 0;
            dropped <= 1'b0;
            note_request <= 1'b0;
        end
    end

    // ------------------------------------------------ the report line
    // 19 characters: i, 17 hex digits (held, the six position bytes, the
    // state byte, the dropped flag), newline.
    localparam integer BIT_CLOCKS = CLOCK_HZ / BAUD_RATE;
    reg [4:0]  character = 5'd31;       // 0 to 18 while sending
    localparam integer BAUD_W = $clog2(BIT_CLOCKS);            // as wide as its limit, not 16 bits
    localparam [BAUD_W-1:0] BAUD_LAST = BIT_CLOCKS - 1;
    reg [BAUD_W-1:0] baud = {BAUD_W{1'b0}};
    reg [3:0]  bits = 4'd0;
    reg [9:0]  shift = 10'h3ff;
    wire [7:0] held_byte = {{(7 - TABLE_BITS){1'b0}}, held};
    wire [4:0] nibble_number = character - 5'd1;            // 0 to 16
    wire [7:0] nibble_byte = nibble_number[4:1] == 4'd0 ? held_byte : report_note[nibble_number[4:1] - 4'd1];
    wire [3:0] nibble = nibble_number == 5'd16 ? {3'b000, dropped}
                      : nibble_number[0] ? nibble_byte[3:0] : nibble_byte[7:4];
    wire [7:0] character_byte = character == 5'd0 ? "i" : character == 5'd18 ? 8'h0a : hex(nibble);
    always @(posedge clock) begin
        if (bits != 4'd0) begin
            if (baud == {BAUD_W{1'b0}}) begin
                shift <= {1'b1, shift[9:1]};
                bits <= bits - 4'd1;
                baud <= BAUD_LAST;
            end else
                baud <= baud - 1'b1;
        end else if (character <= 5'd18) begin
            shift <= {1'b1, character_byte, 1'b0};
            character <= character == 5'd18 ? 5'd31 : character + 5'd1;
            bits <= 4'd10;
            baud <= BAUD_LAST;
        end else if (report_request)
            character <= 5'd0;
        if (reset) begin
            character <= 5'd31;
            bits <= 4'd0;
            shift <= 10'h3ff;
        end
    end
    assign tx = shift[0];
endmodule

`default_nettype wire
