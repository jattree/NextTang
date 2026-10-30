; SPDX-License-Identifier: GPL-3.0-or-later
; Copyright (C) 2026 NextTang contributors
;
; .SPEC256 "GAME.256" - load a Spec256 game into the NextTang core.
;
; A .256 (the format of Alberto Conde's SPEC256_MISTER, shared with it as
; agreed) holds a 128K Spectrum's memory with eight colour planes per byte,
; the CPU state and optional blocks. This command reads one from the SD card
; and feeds the core's Spec256 loader (boards/console138k/
; nexttang_console138k_zxnext.v) through NextREG 0x3E, the same command
; language tools/spec256/send_next.py sends over the debug UART, in the same
; order, byte for byte:
;
;   H, S1, U flags, C cfg, [Y rules], Z mode, W planes for 0x4000-0xFFFF
;   (banks 5, 2, 0), [W ROM font], Q palette, [B background], G start
;
; It also writes the game's own memory and CPU state from the .256 as a .z80
; (version 3) snapshot, /tmp/SPEC256.Z80 on the system drive, exactly as
; tools/spec256/z80_from_256.py does: the master's byte of each address (the
; ninth), banks 5, 2 and 0 for a 48K game (7FFD bit 5) and all eight for a
; 128K one, the registers (PC 0x0072 means the start is on the stack), the
; border, 7FFD and the AY state (AYS1). The browser line in browser.cfg then
; starts it with NextZXOS's snapshot loader, so a game needs only its .256;
; colour starts at the game's first instruction. Every file write happens
; before G arms colour mode. The palette is SPEC256.RGB (512 bytes, RGB333,
; low byte first), looked for in the current folder and then as
; /dot/SPEC256.RGB on the system drive.
;
; Blocks follow the format's rules: a block without its magic is absent, a
; file may end after any block (1179680 bytes at least), OPT1's level must
; not exceed this core's (1), and tagged blocks after OPT1 (tag, length,
; data) are walked to check their lengths and otherwise skipped.
;
; Interrupts stay off while bytes stream, so nothing changes the selected
; NextREG between OUTs; the register is selected again after every file read.

        opt     --zxnext
        org     $2000

F_OPEN          equ $9a
F_CLOSE         equ $9b
F_READ          equ $9d
F_WRITE         equ $9e
F_SEEK          equ $9f
F_FSTAT         equ $a1
FA_READ         equ $01
FA_CREATE       equ $0e             ; write, create or truncate
Z80_HEADER      equ 86              ; version 3: 30 + 2 + 54

NR_SELECT       equ $243b
NR_ACCESS       equ $253b
NR_SPEED        equ $07
NR_DATA         equ $3e             ; loader byte; reads the interface ID
NR_CTRL         equ $3f             ; bit 0 own the loader, bit 7 abort
SPEC256_ID      equ $a1
CORE_LEVEL      equ 1

RECORDS         equ 256             ; .256 records (9 bytes) per chunk
CHUNK           equ RECORDS * 9

; Read COUNT bytes at file offset HI:LO into DEST.
        macro   READ_AT hi, lo, count, dest
        ld      bc,hi
        ld      de,lo
        call    seek
        ld      hl,dest
        ld      bc,count
        call    read_exact
        endm

; Carry clear when the file holds at least HI:LO bytes.
        macro   NEED hi, lo
        ld      bc,hi
        ld      de,lo
        call    size_below
        endm

start:
        ld      (entry_sp),sp
        ld      a,i                         ; P/V = IFF2: were interrupts on?
        ld      a,0
        jp      po,.di
        inc     a
.di:    ld      (interrupts),a
        ld      a,h
        or      l
        jp      z,usage
        call    parse_name
        jp      c,usage

        ld      a,NR_DATA
        call    nr_read
        cp      SPEC256_ID
        ld      hl,msg_no_core
        jp      nz,fail_early

        ld      a,NR_SPEED                  ; 28 MHz while loading
        call    nr_read
        and     3
        ld      (speed),a
        ld      a,NR_SPEED
        ld      e,3
        call    nr_write

        call    load_palette

        ld      a,'*'
        ld      hl,name
        ld      b,FA_READ
        rst     $08
        db      F_OPEN
        ld      hl,msg_open
        jp      c,fail
        ld      (handle),a
        ld      a,1
        ld      (opened),a
        ld      a,(handle)
        ld      hl,stat
        rst     $08
        db      F_FSTAT
        ld      hl,msg_read
        jp      c,fail

        NEED    $0012,$0020                 ; registers, 7FFD and CFG at least
        ld      hl,msg_not256
        jp      c,fail
        call    check_opt1
        call    walk_tagged_blocks
        call    show_credits

        READ_AT $0012,$0000,29,regs         ; registers, then 7FFD
        READ_AT $0012,$001d,3,cfg
        xor     a
        ld      (rul+4),a                   ; RUL1 absent unless read below
        NEED    $0015,$1a74
        jr      c,.no_rul1
        READ_AT $0015,$1a2c,72,rul
.no_rul1:
        ld      hl,rul
        ld      de,magic_rul1
        call    same_magic
        jr      nz,.rul1_off
        ld      a,(rul+4)
        cp      1
        jr      z,.rul1_on
.rul1_off:
        ld      hl,rul+5                    ; flags, count, ZX-Poly mode = 0
        ld      (hl),0
        inc     hl
        ld      (hl),0
        inc     hl
        ld      (hl),0
.rul1_on:
        call    start_pc
        call    read_ay
        call    build_header

        ld      a,'$'                       ; the snapshot for NextZXOS
        ld      hl,snapshot_name
        ld      b,FA_CREATE
        rst     $08
        db      F_OPEN
        ld      hl,msg_write
        jp      c,fail
        ld      (out_handle),a
        ld      a,1
        ld      (out_opened),a
        ld      hl,z80_header
        ld      bc,Z80_HEADER
        call    write_out

        di
        ld      a,NR_CTRL                   ; own the loader, from idle
        ld      e,$81
        call    nr_write
        ld      a,NR_CTRL
        ld      e,$01
        call    nr_write
        ld      a,1
        ld      (owned),a

        ld      a,'H'
        call    send_byte
        ld      hl,str_s1
        call    send_string
        ld      a,'U'
        call    send_byte
        ld      a,(rul+5)
        call    send_hex
        ld      a,'C'
        call    send_byte
        ld      hl,cfg
        ld      b,3
.cfg:   ld      a,(hl)
        call    send_hex
        inc     hl
        djnz    .cfg
        ld      a,(rul+6)                   ; rules only when RUL1 has some
        or      a
        jr      z,.no_rules
        ld      a,'Y'
        call    send_byte
        ld      hl,rul+8
        ld      de,64
        call    send_block
.no_rules:
        ld      a,'Z'
        call    send_byte
        ld      a,(rul+7)
        and     7
        call    send_nibble

        ld      hl,str_planes
        call    send_string
        call    send_planes

        NEED    $0015,$1a2c                 ; GRX1 complete
        jr      c,.no_font
        READ_AT $0015,$0228,4,buffer
        ld      hl,buffer
        ld      de,magic_grx1
        call    same_magic
        jr      nz,.no_font
        ld      hl,str_font
        call    send_string
        ld      a,3                         ; 6144 bytes, 3 x 2048
        ld      (count),a
.font:  ld      hl,buffer
        ld      bc,2048
        call    read_exact
        ld      hl,buffer
        ld      de,2048
        call    send_block
        ld      a,(count)
        dec     a
        ld      (count),a
        jr      nz,.font
.no_font:

        ld      a,'Q'
        call    send_byte
        ld      hl,palette
        ld      de,512
        call    send_block

        NEED    $0012,$c020                 ; background complete
        jr      c,.no_background
        call    background_used
        jr      z,.no_background
        ld      a,'B'
        call    send_byte
        ld      bc,$0012
        ld      de,$0020
        call    seek
        ld      a,24                        ; 49152 bytes, 24 x 2048
        ld      (count),a
.background:
        ld      hl,buffer
        ld      bc,2048
        call    read_exact
        ld      hl,buffer
        ld      de,2048
        call    send_block
        ld      a,(count)
        dec     a
        ld      (count),a
        jr      nz,.background
.no_background:

        ld      a,(regs+28)                 ; 128K: the other five banks
        and     $20
        call    z,write_other_banks
        ld      a,(out_handle)
        rst     $08
        db      F_CLOSE
        ld      hl,msg_write
        jp      c,fail
        xor     a
        ld      (out_opened),a

        ld      a,'G'
        call    send_byte
        ld      a,(pc+1)
        call    send_hex
        ld      a,(pc)
        call    send_hex

        ld      a,NR_CTRL                   ; the UART may have it again
        ld      e,0
        call    nr_write
        xor     a
        ld      (owned),a
        call    finish
        ld      hl,msg_done
        call    print
        or      a
        ret

; ---------------------------------------------------------------- planes

; Plane words for 0x4000-0xFFFF: banks 5, 2 and 0, each 16384 records of
; eight plane bytes and the master's byte; the master's byte is skipped.
send_planes:
        ld      hl,bank_offsets
        ld      a,3
.bank:  ld      (banks_left),a
        ld      e,(hl)
        inc     hl
        ld      d,(hl)
        inc     hl
        ld      c,(hl)
        inc     hl
        ld      b,(hl)
        inc     hl
        ld      a,(hl)                      ; .z80 page: 48K, then 128K
        inc     hl
        ld      (page_48k),a
        ld      a,(hl)
        inc     hl
        ld      (bank_next),hl
        push    bc
        push    de
        ld      e,a
        ld      a,(regs+28)
        and     $20
        ld      a,e
        jr      z,.page
        ld      a,(page_48k)
.page:  call    write_page_header
        pop     de
        pop     bc
        call    seek
        ld      a,16384 / RECORDS
        ld      (count),a
.chunk: ld      hl,buffer
        ld      bc,CHUNK
        call    read_exact                  ; leaves 0x3E selected, DI
        ld      hl,buffer
        ld      bc,NR_ACCESS
        ld      d,RECORDS & $ff
.record:
        rept    8
        ld      a,(hl)
        inc     hl
        out     (c),a
        endr
        inc     hl
        dec     d
        jr      nz,.record
        call    write_masters
        ld      a,(count)
        dec     a
        ld      (count),a
        jr      nz,.chunk
        ld      hl,(bank_next)
        ld      a,(banks_left)
        dec     a
        jr      nz,.bank
        ret

; Each bank: its offset in the .256, its .z80 page in a 48K and a 128K file.
bank_offsets:
        dd      5 * 147456
        db      8, 5 + 3
        dd      2 * 147456
        db      4, 2 + 3
        dd      0
        db      5, 0 + 3

; ------------------------------------------------------------ the snapshot

; The master's bytes of the 256 records in the buffer, to the snapshot.
write_masters:
        ld      hl,buffer + 8
        ld      de,masters
        ld      bc,(RECORDS & $ff) << 8 | 9 ; B: 256 records, C: their size
.byte:  ld      a,(hl)
        ld      (de),a
        inc     de
        ld      a,l
        add     a,c
        ld      l,a
        jr      nc,.next
        inc     h
.next:  djnz    .byte
        ld      hl,masters
        ld      bc,RECORDS
        jp      write_out

; An uncompressed .z80 page: length 0xFFFF, page A.
write_page_header:
        ld      hl,page_header
        ld      (hl),$ff
        inc     hl
        ld      (hl),$ff
        inc     hl
        ld      (hl),a
        ld      hl,page_header
        ld      bc,3
        jp      write_out

; A 128K game's banks 1, 3, 4, 6 and 7: the master's bytes only.
write_other_banks:
        ld      hl,other_banks
        ld      a,5
.bank:  ld      (banks_left),a
        ld      a,(hl)
        inc     hl
        ld      (bank_next),hl
        push    af
        add     a,3
        call    write_page_header
        pop     af
        add     a,a                         ; offset = bank x 147456
        add     a,a
        ld      e,a
        ld      d,0
        ld      hl,bank_bases
        add     hl,de
        call    load32
        call    seek
        ld      a,16384 / RECORDS
        ld      (count),a
.chunk: ld      hl,buffer
        ld      bc,CHUNK
        call    read_exact
        call    write_masters
        ld      a,(count)
        dec     a
        ld      (count),a
        jr      nz,.chunk
        ld      hl,(bank_next)
        ld      a,(banks_left)
        dec     a
        jr      nz,.bank
        ret

other_banks:
        db      1, 3, 4, 6, 7

; Write BC bytes from HL to the snapshot; anything less is an error. Leaves
; interrupts off and NextREG 0x3E selected.
write_out:
        push    bc
        ld      a,(out_handle)
        rst     $08
        db      F_WRITE
        pop     de
        ld      hl,msg_write
        jp      c,fail
        ld      a,b
        cp      d
        jp      nz,fail
        ld      a,c
        cp      e
        jp      nz,fail
        di
        jp      select_data

; AYS1 (21 bytes at 1383028): magic, the selected register, R0-R15; ay_in
; is 1 when it is present and not all zero.
read_ay:
        xor     a
        ld      (ay_in),a
        NEED    $0015,$1a89
        ret     c
        READ_AT $0015,$1a74,21,ays1
        ld      hl,ays1
        ld      de,magic_ays1
        call    same_magic
        ret     nz
        ld      hl,ays1 + 4
        ld      b,17
.byte:  ld      a,(hl)
        or      a
        jr      nz,.state
        inc     hl
        djnz    .byte
        ret
.state: ld      a,1
        ld      (ay_in),a
        ret

; The .z80 version 3 header, as z80_from_256.py builds it.
build_header:
        ld      hl,z80_header
        ld      de,z80_header + 1
        ld      bc,Z80_HEADER - 1
        ld      (hl),0
        ldir
        ld      ix,z80_header
        ld      a,(regs+1)                  ; A, F
        ld      (ix+0),a
        ld      a,(regs+0)
        ld      (ix+1),a
        ld      hl,(regs+10)                ; BC
        ld      (z80_header+2),hl
        ld      hl,(regs+14)                ; HL
        ld      (z80_header+4),hl
        ld      hl,(game_sp)
        ld      (z80_header+8),hl
        ld      a,(regs+4)                  ; I
        ld      (ix+10),a
        ld      a,(regs+5)                  ; R: low 7 bits, bit 7 in flags1
        ld      c,a
        and     $7f
        ld      (ix+11),a
        ld      a,c
        rlca
        and     1
        ld      c,a
        ld      a,(regs+27)                 ; border
        and     7
        add     a,a
        or      c
        ld      (ix+12),a
        ld      hl,(regs+12)                ; DE
        ld      (z80_header+13),hl
        ld      hl,(regs+18)                ; BC'
        ld      (z80_header+15),hl
        ld      hl,(regs+20)                ; DE'
        ld      (z80_header+17),hl
        ld      hl,(regs+22)                ; HL'
        ld      (z80_header+19),hl
        ld      a,(regs+3)                  ; A', F'
        ld      (ix+21),a
        ld      a,(regs+2)
        ld      (ix+22),a
        ld      hl,(regs+24)                ; IY
        ld      (z80_header+23),hl
        ld      hl,(regs+16)                ; IX
        ld      (z80_header+25),hl
        ld      a,(regs+26)                 ; IFF1, IFF2, IM
        ld      c,a
        rrca
        rrca
        and     1
        ld      (ix+27),a
        ld      (ix+28),a
        ld      a,c
        and     3
        ld      (ix+29),a
        ld      (ix+30),54                  ; the extended header's length
        ld      hl,(pc)
        ld      (z80_header+32),hl
        ld      a,(regs+28)                 ; 48K: mode 0, AY flag if a state
        and     $20
        jr      z,.k128
        ld      a,(ay_in)
        or      a
        jr      z,.ay
        ld      (ix+37),$04
        jr      .ay
.k128:  ld      (ix+34),4
        ld      a,(regs+28)
        ld      (ix+35),a
.ay:    ld      a,(ay_in)
        or      a
        ret     z
        ld      a,(ays1+4)
        and     $0f
        ld      (ix+38),a
        ld      hl,ays1+5
        ld      de,z80_header+39
        ld      bc,16
        ldir
        ret

; Z when every byte of the background is 0 (no background).
background_used:
        ld      bc,$0012
        ld      de,$0020
        call    seek
        ld      a,24
        ld      (count),a
.chunk: ld      hl,buffer
        ld      bc,2048
        call    read_exact
        ld      hl,buffer
        ld      de,2048
.byte:  ld      a,(hl)
        or      a
        jr      nz,.used
        inc     hl
        dec     de
        ld      a,d
        or      e
        jr      nz,.byte
        ld      a,(count)
        dec     a
        ld      (count),a
        jr      nz,.chunk
        xor     a                           ; Z: none
        ret
.used:  or      1                           ; NZ
        ret

; ------------------------------------------------------------- the start

; The game's first instruction: PC, or, when PC is 0x0072 (the ROM's RETN,
; as make256 stores a snapshot taken in the NMI), the address on the stack.
start_pc:
        ld      hl,(regs+6)
        ld      (game_sp),hl
        ld      hl,(regs+8)
        ld      (pc),hl
        ld      de,$0072
        or      a
        sbc     hl,de
        ret     nz
        ld      hl,(regs+6)                 ; SP
        push    hl
        call    master_byte
        ld      (pc),a
        pop     hl
        inc     hl
        push    hl
        call    master_byte
        ld      (pc+1),a
        pop     hl                          ; the RETN's pop
        inc     hl
        ld      (game_sp),hl
        ret

; A = the master's byte at Spectrum address HL (RAM, the 128K paging of
; the snapshot's 7FFD for 0xC000).
master_byte:
        ld      a,h
        rlca
        rlca
        and     3
        ld      de,msg_bad
        jp      z,fail_de                   ; the stack in the ROM
        ld      b,5
        dec     a
        jr      z,.bank
        ld      b,2
        dec     a
        jr      z,.bank
        ld      a,(regs+28)
        and     7
        ld      b,a
.bank:  ld      a,h                         ; offset in the bank
        and     $3f
        ld      h,a
        ld      a,b                         ; offset = bank base + 9 x + 8
        add     a,a
        add     a,a
        ld      e,a
        ld      d,0
        push    hl
        ld      hl,bank_bases
        add     hl,de
        ld      de,work
        ld      bc,4
        ldir
        pop     de                          ; DE = offset in the bank
        ld      b,9
.add:   push    bc
        ld      hl,work
        call    add16_to32
        pop     bc
        djnz    .add
        ld      de,8
        ld      hl,work
        call    add16_to32
        ld      hl,work
        call    load32
        call    seek
        ld      hl,buffer
        ld      bc,1
        call    read_exact
        ld      a,(buffer)
        ret

bank_bases:
        dd      0 * 147456, 1 * 147456, 2 * 147456, 3 * 147456
        dd      4 * 147456, 5 * 147456, 6 * 147456, 7 * 147456

; ------------------------------------------------------------ the blocks

; OPT1 (256 bytes at 1383117): byte 4 is the core level the game needs.
check_opt1:
        NEED    $0015,$1bcd
        ret     c
        READ_AT $0015,$1acd,5,buffer
        ld      hl,buffer
        ld      de,magic_opt1
        call    same_magic
        ret     nz
        ld      a,(buffer+4)
        cp      CORE_LEVEL + 1
        ret     c
        ld      hl,msg_level
        jp      fail

; Blocks after OPT1: four-byte tag, four-byte little-endian length, data.
; None is used yet; each must fit in the file.
walk_tagged_blocks:
        ld      hl,opt1_end
        ld      de,position
        ld      bc,4
        ldir
.block: ld      hl,stat+7                   ; left = size - position
        ld      de,left
        ld      bc,4
        ldir
        ld      hl,left
        ld      de,position
        call    sub32
        ret     c                           ; a file ending inside OPT1
        ld      hl,left
        call    is_zero32
        ret     z
        ld      hl,left                     ; at least a tag and a length
        ld      de,eight
        call    sub32
        ld      hl,msg_truncated
        jp      c,fail
        ld      hl,position
        call    load32
        call    seek
        ld      hl,buffer
        ld      bc,8
        call    read_exact
        ld      hl,position
        ld      de,eight
        call    add32
        ld      hl,left                     ; the data must fit
        ld      de,buffer+4
        call    sub32
        ld      hl,msg_truncated
        jp      c,fail
        ld      hl,position
        ld      de,buffer+4
        call    add32
        jr      .block

opt1_end:
        dd      1383373
eight:  dd      8

; CRD1 (68 bytes at 1383049): two lines of 32 characters, the game and its
; colouring.
show_credits:
        NEED    $0015,$1acd
        ret     c
        READ_AT $0015,$1a89,68,buffer
        ld      hl,buffer
        ld      de,magic_crd1
        call    same_magic
        ret     nz
        ld      hl,buffer+4
        call    .line
.line:  ld      b,32
.char:  ld      a,(hl)
        inc     hl
        cp      ' '
        jr      c,.space
        cp      $7f
        jr      c,.show
.space: ld      a,' '
.show:  push    hl
        push    bc
        rst     $10
        pop     bc
        pop     hl
        djnz    .char
        ld      a,13
        push    hl
        rst     $10
        pop     hl
        ret

; ----------------------------------------------------------- the palette

load_palette:
        ld      a,'*'
        ld      hl,palette_here
        ld      b,FA_READ
        rst     $08
        db      F_OPEN
        jr      nc,.open
        ld      a,'$'
        ld      hl,palette_system
        ld      b,FA_READ
        rst     $08
        db      F_OPEN
        ld      hl,msg_palette
        jp      c,fail
.open:  push    af
        ld      hl,palette
        ld      bc,512
        rst     $08
        db      F_READ
        pop     de
        push    af                          ; carry from the read
        push    bc
        ld      a,d
        rst     $08
        db      F_CLOSE
        pop     bc
        pop     af
        ld      hl,msg_palette
        jp      c,fail
        ld      a,b
        cp      2                           ; 512 bytes
        jp      nz,fail
        ld      a,c
        or      a
        jp      nz,fail
        ret

palette_here:   db "SPEC256.RGB",0
palette_system: db "/dot/SPEC256.RGB",0

; -------------------------------------------------------------- the file

; Seek to BC:DE from the start.
seek:   ld      a,(handle)
        ld      l,0
        rst     $08
        db      F_SEEK
        ld      hl,msg_read
        jp      c,fail
        ret

; Read BC bytes to HL; anything less is an error. Leaves interrupts off and
; NextREG 0x3E selected.
read_exact:
        push    bc
        ld      a,(handle)
        rst     $08
        db      F_READ
        pop     de
        ld      hl,msg_read
        jp      c,fail
        ld      a,b
        cp      d
        jp      nz,fail
        ld      a,c
        cp      e
        jp      nz,fail
        di
        jp      select_data

; Carry set when the file is shorter than BC:DE bytes.
size_below:
        ld      hl,stat+7
        ld      a,(hl)
        sub     e
        inc     hl
        ld      a,(hl)
        sbc     a,d
        inc     hl
        ld      a,(hl)
        sbc     a,c
        inc     hl
        ld      a,(hl)
        sbc     a,b
        ret

; ------------------------------------------------------------ the loader

select_data:
        push    bc
        ld      bc,NR_SELECT
        ld      a,NR_DATA
        out     (c),a
        pop     bc
        ret

; One loader byte.
send_byte:
        push    bc
        push    af
        call    select_data
        pop     af
        ld      bc,NR_ACCESS
        out     (c),a
        pop     bc
        ret

; DE bytes from HL.
send_block:
        call    select_data
        ld      bc,NR_ACCESS
.byte:  ld      a,(hl)
        inc     hl
        out     (c),a
        dec     de
        ld      a,d
        or      e
        jr      nz,.byte
        ret

; A zero-terminated string from HL.
send_string:
        ld      a,(hl)
        or      a
        ret     z
        call    send_byte
        inc     hl
        jr      send_string

; A as two lower-case hex digits, as send_next.py writes them.
send_hex:
        push    af
        rrca
        rrca
        rrca
        rrca
        call    send_nibble
        pop     af
send_nibble:
        and     $0f
        add     a,'0'
        cp      '9' + 1
        jr      c,.digit
        add     a,'a' - '9' - 1
.digit: jp      send_byte

; A = NextREG A.
nr_read:
        ld      bc,NR_SELECT
        out     (c),a
        inc     b
        in      a,(c)
        ret

; NextREG A = E.
nr_write:
        ld      bc,NR_SELECT
        out     (c),a
        inc     b
        out     (c),e
        ret

; ------------------------------------------------------------ arithmetic

; Z when the four bytes at HL match those at DE.
same_magic:
        ld      b,4
.byte:  ld      a,(de)
        cp      (hl)
        ret     nz
        inc     hl
        inc     de
        djnz    .byte
        ret

; BC:DE = the 32-bit number at HL.
load32: ld      e,(hl)
        inc     hl
        ld      d,(hl)
        inc     hl
        ld      c,(hl)
        inc     hl
        ld      b,(hl)
        ret

; (HL) += (DE), 32 bits.
add32:  ld      b,4
        or      a
.byte:  ld      a,(de)
        adc     a,(hl)
        ld      (hl),a
        inc     hl
        inc     de
        djnz    .byte
        ret

; (HL) -= (DE), 32 bits; carry when it went below zero.
sub32:  ld      b,4
        or      a
.byte:  ld      a,(de)
        ld      c,a
        ld      a,(hl)
        sbc     a,c
        ld      (hl),a
        inc     hl
        inc     de
        djnz    .byte
        ret

; (HL) += DE, 32 bits.
add16_to32:
        ld      a,(hl)
        add     a,e
        ld      (hl),a
        inc     hl
        ld      a,(hl)
        adc     a,d
        ld      (hl),a
        inc     hl
        ld      a,(hl)
        adc     a,0
        ld      (hl),a
        inc     hl
        ld      a,(hl)
        adc     a,0
        ld      (hl),a
        ret

; Z when the 32 bits at HL are 0.
is_zero32:
        ld      a,(hl)
        inc     hl
        or      (hl)
        inc     hl
        or      (hl)
        inc     hl
        or      (hl)
        ret

; ------------------------------------------------------------ the name

; The file name from HL: quoted, or up to a space, ':' or the line's end.
parse_name:
.skip:  ld      a,(hl)
        cp      ' '
        jr      nz,.first
        inc     hl
        jr      .skip
.first: ld      de,name
        ld      b,0
        cp      '"'
        jr      nz,.char
        inc     hl
        ld      b,'"'
.char:  ld      a,(hl)
        or      a
        jr      z,.end
        cp      13
        jr      z,.end
        cp      b
        jr      z,.end
        inc     b
        dec     b
        jr      nz,.keep                    ; quoted: spaces and ':' are part
        cp      ' '
        jr      z,.end
        cp      ':'
        jr      z,.end
.keep:  ld      (de),a
        inc     de
        inc     hl
        ld      a,e
        cp      low (name + 255)
        jr      nz,.char
.end:   xor     a
        ld      (de),a
        ld      a,(name)
        or      a
        ret     nz
        scf
        ret

; ------------------------------------------------------------ the ending

usage:  ld      hl,msg_usage
        call    print
        or      a
        ret

; Errors: HL is the message (last character with bit 7 set).
fail_de:
        ex      de,hl
fail:   ld      sp,(entry_sp)
        push    hl
        ld      a,(owned)                   ; leave the core as before
        or      a
        jr      z,.not_owned
        ld      a,NR_CTRL
        ld      e,$81
        call    nr_write
        ld      a,'H'
        call    send_byte
        ld      a,NR_CTRL
        ld      e,0
        call    nr_write
.not_owned:
        call    finish
        pop     hl
        xor     a
        scf
        ret
fail_early:
        xor     a
        scf
        ret

; Close the file, restore the speed and interrupts.
finish: ld      a,(out_opened)
        or      a
        jr      z,.no_out
        ld      a,(out_handle)
        rst     $08
        db      F_CLOSE
        xor     a
        ld      (out_opened),a
.no_out:
        ld      a,(opened)
        or      a
        jr      z,.closed
        ld      a,(handle)
        rst     $08
        db      F_CLOSE
        xor     a
        ld      (opened),a
.closed:
        ld      a,NR_SPEED
        ld      hl,speed
        ld      e,(hl)
        call    nr_write
        ld      a,(interrupts)
        or      a
        ret     z
        ei
        ret

; Print a message whose last character has bit 7 set.
print:  ld      a,(hl)
        push    hl
        and     $7f
        rst     $10
        pop     hl
        bit     7,(hl)
        inc     hl
        jr      z,print
        ret

str_s1:         db "S1",0
str_planes:     db "W4000c000",0
str_font:       db "W3d000300",0
magic_rul1:     db "RUL1"
magic_grx1:     db "GRX1"
magic_crd1:     db "CRD1"
magic_opt1:     db "OPT1"
magic_ays1:     db "AYS1"
snapshot_name:  db "/tmp/SPEC256.Z80",0

msg_usage:      db ".SPEC256 \"GAME.256\"",13
                db "Loads a Spec256 game's colour",13
                db "into the NextTang core and writes",13
                db "/tmp/SPEC256.Z80 to start it.",13
                db ".256 format: Alberto Conde",13
                db "(SPEC256_MISTER)",13 | $80
msg_done:       db "Colour loaded",13 | $80
msg_write:      db "Cannot write /tmp/SPEC256.Z8", '0' | $80
msg_no_core:    db "No Spec256 cor", 'e' | $80
msg_open:       db "Cannot open the .25", '6' | $80
msg_read:       db ".256 read erro", 'r' | $80
msg_not256:     db "Not a .256 fil", 'e' | $80
msg_level:      db "Needs a newer Spec256 cor", 'e' | $80
msg_truncated:  db ".256 block cut shor", 't' | $80
msg_bad:        db "Bad .256 stac", 'k' | $80
msg_palette:    db "SPEC256.RGB not foun", 'd' | $80

handle:         db 0
owned:          db 0
speed:          db 0
interrupts:     db 0
count:          db 0
banks_left:     db 0
opened:         db 0
out_opened:     db 0
out_handle:     db 0
ay_in:          db 0
page_48k:       db 0
game_sp:        dw 0
page_header:    ds 3
ays1:           ds 21
z80_header:     ds Z80_HEADER
masters:        ds RECORDS
bank_next:      dw 0
entry_sp:       dw 0
pc:             dw 0
regs:           ds 29
cfg:            ds 3
rul:            ds 72
stat:           ds 11
position:       ds 4
left:           ds 4
work:           ds 4
name:           ds 256
palette:        ds 512
buffer:         ds CHUNK

        assert  $ <= $4000, "the dot command must fit $2000-$3FFF"
