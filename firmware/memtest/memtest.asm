; SPDX-License-Identifier: GPL-3.0-or-later
; Copyright (C) 2026 NextTang contributors
;
; Main-memory soak test for the ZX Next core on a board whose main memory makes
; the CPU wait, such as the Console 138K's DDR3.
;
; Each pass runs at the next CPU speed (3.5, 7, 14, 28 MHz, then round again)
; and does three things through the MMU, as NextZXOS uses memory:
;
;   1. Fills every 8 KiB page of the 2 MiB space with a pattern made from the
;      address, the page and the pass, then reads every page back. Writing all
;      pages before checking any catches pages that alias onto each other.
;   2. Copies a checksum routine into main memory and runs it there, so
;      instruction fetches wait on main memory, and compares its answer with
;      the same sum worked out from this ROM.
;   3. Copies 8 KiB from one page to another with the zxnDMA and compares.
;   4. Writes a byte and reads it straight back, 8 KiB at a time over a few
;      pages, which is what a write that is accepted but not yet visible would
;      get wrong.
;
; The screen shows one attribute cell per page: green when the page has always
; read back correctly, red once it has not. The bottom row holds the DMA and
; code-fetch and read-after-write checks and the pass count in binary. The border stays green while
; everything has passed and turns red, for good, at the first failure; the
; board's status UART reports the border colour.
;
; Pages 10 and 11 (RAM bank 5) hold the screen, the stack and these variables,
; so they are not tested.

        org     $0000

NEXTREG_SELECT  equ $243b
NEXTREG_DATA    equ $253b
DMA_PORT        equ $6b
ATTRIBUTES      equ $5800
ULA_PALETTE_ENTRIES equ 32
PAGES           equ 224                 ; 8 KiB pages in 2 MiB above the ROMs
SKIP_FIRST      equ 10                  ; bank 5
SKIP_LAST       equ 11
CODE_PAGE       equ $20                 ; where the checksum routine runs
DMA_SOURCE_PAGE equ $30
DMA_TARGET_PAGE equ $31
WINDOW          equ $e000               ; slot 7, the page under test
CODE_WINDOW     equ $c000               ; slot 6

; Variables, in bank 5 above the attributes.
FAILED          equ $5b00               ; non-zero once anything has failed
PASS            equ $5b01
SEED            equ $5b02
ROM_SUM         equ $5b04               ; two bytes

ATTR_OK         equ %01100000           ; bright, green paper
ATTR_BAD        equ %01010000           ; bright, red paper
ATTR_ON         equ %01111000           ; bright, white paper
ATTR_OFF        equ %00000000
ROW_23          equ ATTRIBUTES + 23 * 32
BORDER_OK       equ 4
BORDER_BAD      equ 2

start:
        di
        ld      sp,$6000
        ld      a,BORDER_OK
        out     ($fe),a

        ; The Next's palette RAM powers up empty; load the ULA's 32 entries.
        ld      bc,NEXTREG_SELECT
        ld      a,$43
        out     (c),a
        inc     b
        xor     a
        out     (c),a
        dec     b
        ld      a,$40
        out     (c),a
        inc     b
        xor     a
        out     (c),a
        dec     b
        ld      a,$41
        out     (c),a
        inc     b
        ld      hl,ula_palette
        ld      d,ULA_PALETTE_ENTRIES
.palette:
        ld      a,(hl)
        out     (c),a
        inc     hl
        dec     d
        jr      nz,.palette

        ; Clear the bitmap so only attributes show, and the attributes to
        ; black.
        ld      hl,$4000
        ld      de,$4001
        ld      bc,$1800 + $300 - 1
        ld      (hl),0
        ldir

        xor     a
        ld      (FAILED),a
        ld      (PASS),a
        ld      (SEED),a

        ; The sum the copied routine must reproduce.
        call    rom_checksum_body
        ld      (ROM_SUM),hl

pass_loop:
        ; CPU speed for this pass: 0 to 3.
        ld      a,(PASS)
        and     3
        ld      e,a
        ld      bc,NEXTREG_SELECT
        ld      a,$07
        out     (c),a
        inc     b
        out     (c),e

        call    fill_pages
        call    check_pages
        call    code_fetch_test
        call    dma_test
        call    read_after_write_test

        ; Pass count in binary across the right half of the bottom row.
        ld      a,(PASS)
        inc     a
        ld      (PASS),a
        ld      hl,ROW_23 + 16
        ld      b,8
.bits:
        rlca
        ld      c,ATTR_OFF
        jr      nc,.bit_off
        ld      c,ATTR_ON
.bit_off:
        ld      (hl),c
        inc     hl
        djnz    .bits

        ld      a,(SEED)
        add     a,$35
        ld      (SEED),a
        jr      pass_loop

; ---------------------------------------------------------------------------
; Map page A into slot 7.
; ---------------------------------------------------------------------------
map_window:
        push    bc
        ld      bc,NEXTREG_SELECT
        push    af
        ld      a,$57
        out     (c),a
        pop     af
        inc     b
        out     (c),a
        pop     bc
        ret

; ---------------------------------------------------------------------------
; Write every page: byte = low address xor high address xor page xor seed.
; ---------------------------------------------------------------------------
fill_pages:
        ld      d,0                     ; d = page
.page:
        ld      a,d
        cp      SKIP_FIRST
        jr      z,.next
        cp      SKIP_LAST
        jr      z,.next
        call    map_window
        ld      a,(SEED)
        xor     d
        ld      e,a                     ; e = page xor seed
        ld      hl,WINDOW
.byte:
        ld      a,l
        xor     h
        xor     e
        ld      (hl),a
        inc     hl
        ld      a,h
        or      a
        jr      nz,.byte                ; until hl wraps from $ffff to 0
.next:
        inc     d
        ld      a,d
        cp      PAGES
        jr      nz,.page
        ret

; ---------------------------------------------------------------------------
; Read every page back and colour its attribute cell.
; ---------------------------------------------------------------------------
check_pages:
        ld      d,0
.page:
        ld      a,d
        cp      SKIP_FIRST
        jr      z,.next
        cp      SKIP_LAST
        jr      z,.next
        call    map_window
        ld      a,(SEED)
        xor     d
        ld      e,a
        ld      hl,WINDOW
        ld      c,0                     ; c = errors in this page, saturating
.byte:
        ld      a,l
        xor     h
        xor     e
        cp      (hl)
        jr      z,.same
        ld      c,1
.same:
        inc     hl
        ld      a,h
        or      a
        jr      nz,.byte
        ; Attribute cell for page d. A cell once red stays red.
        ld      h,ATTRIBUTES >> 8
        ld      l,d
        ld      a,c
        or      a
        jr      nz,.bad
        ld      a,(hl)
        cp      ATTR_BAD
        jr      z,.next
        ld      (hl),ATTR_OK
        jr      .next
.bad:
        ld      (hl),ATTR_BAD
        call    fail
.next:
        inc     d
        ld      a,d
        cp      PAGES
        jr      nz,.page
        ret

; ---------------------------------------------------------------------------
; Copy the checksum routine to main memory, run it there, compare.
; ---------------------------------------------------------------------------
code_fetch_test:
        ld      bc,NEXTREG_SELECT
        ld      a,$56
        out     (c),a
        inc     b
        ld      a,CODE_PAGE
        out     (c),a
        ld      hl,rom_checksum_body
        ld      de,CODE_WINDOW
        ld      bc,rom_checksum_end - rom_checksum_body
        ldir
        call    CODE_WINDOW
        ld      de,(ROM_SUM)
        or      a
        sbc     hl,de
        ld      hl,ROW_23 + 1
        jr      result_cell

; ---------------------------------------------------------------------------
; Write each byte of four pages and read it straight back.
; ---------------------------------------------------------------------------
read_after_write_test:
        ld      d,$40                   ; pages $40 to $43
.page:
        ld      a,d
        call    map_window
        ld      hl,WINDOW
        ld      a,(SEED)
        ld      e,a
.byte:
        ld      a,l
        add     a,e
        xor     d
        ld      (hl),a
        cp      (hl)                    ; the read straight after the write
        jr      nz,.differs
        inc     hl
        ld      a,h
        or      a
        jr      nz,.byte
        inc     d
        ld      a,d
        cp      $44
        jr      nz,.page
        ld      hl,ROW_23 + 2
        xor     a
        jr      result_cell
.differs:
        ld      hl,ROW_23 + 2
        or      1
        jr      result_cell

; ---------------------------------------------------------------------------
; zxnDMA: fill page DMA_SOURCE_PAGE through slot 6, copy it to
; DMA_TARGET_PAGE in slot 7, compare.
; ---------------------------------------------------------------------------
dma_test:
        ld      bc,NEXTREG_SELECT
        ld      a,$56
        out     (c),a
        inc     b
        ld      a,DMA_SOURCE_PAGE
        out     (c),a
        ld      a,DMA_TARGET_PAGE
        call    map_window
        ; Source: address-dependent bytes; target: cleared.
        ld      hl,CODE_WINDOW
        ld      a,(SEED)
        ld      e,a
.fill:
        ld      a,l
        add     a,h
        xor     e
        ld      (hl),a
        ld      a,h
        add     a,$20
        ld      d,a
        xor     a
        push    hl
        ld      h,d
        ld      (hl),a
        pop     hl
        inc     hl
        ld      a,h
        cp      $e0
        jr      nz,.fill

        ld      hl,dma_program
        ld      b,dma_program_end - dma_program
        ld      c,DMA_PORT
        otir

        ld      hl,CODE_WINDOW
        ld      de,WINDOW
        ld      bc,$2000
.compare:
        ld      a,(de)
        cp      (hl)
        jr      nz,.differs
        inc     hl
        inc     de
        dec     bc
        ld      a,b
        or      c
        jr      nz,.compare
        ld      hl,ROW_23 + 0
        xor     a                       ; z: passed
        jr      result_cell
.differs:
        ld      hl,ROW_23 + 0
        or      1                       ; nz: failed
        ; fall through

; z: mark cell hl green unless it is already red; nz: mark it red and fail.
result_cell:
        jr      nz,.bad
        ld      a,(hl)
        cp      ATTR_BAD
        ret     z
        ld      (hl),ATTR_OK
        ret
.bad:
        ld      (hl),ATTR_BAD
        ; fall through

fail:
        ld      a,1
        ld      (FAILED),a
        ld      a,BORDER_BAD
        out     ($fe),a
        ret

; ---------------------------------------------------------------------------
; Sum of the first 4 KiB of this ROM in hl. Position-independent: it is also
; copied to main memory and run there.
; ---------------------------------------------------------------------------
rom_checksum_body:
        ld      hl,0
        ld      de,0
        ld      bc,$1000
.sum:
        ld      a,(de)
        add     a,l
        ld      l,a
        jr      nc,.no_carry
        inc     h
.no_carry:
        inc     de
        dec     bc
        ld      a,b
        or      c
        jr      nz,.sum
        ret
rom_checksum_end:

; zxnDMA: copy 8 KiB from CODE_WINDOW to WINDOW, memory to memory, both
; incrementing, in continuous mode.
dma_program:
        db      $83                     ; disable
        db      $c3                     ; reset
        db      %01111101               ; WR0: A to B, address and length follow
        dw      CODE_WINDOW
        dw      $2000
        db      %01010100               ; WR1: port A memory, incrementing, timing follows
        db      %00000010               ; timing: 2 cycles
        db      %01010000               ; WR2: port B memory, incrementing, timing follows
        db      %00000010
        db      %10101101               ; WR4: continuous, port B address follows
        dw      WINDOW
        db      %10000010               ; WR5: stop at end of block
        db      $cf                     ; load
        db      $87                     ; enable
dma_program_end:

; The Spectrum's 16 colours, then the same 16 for the flash/bright half.
ula_palette:
        db      $00, $02, $a0, $a2, $14, $16, $b4, $b6
        db      $00, $03, $e0, $e7, $1c, $1f, $fc, $ff
        db      $00, $02, $a0, $a2, $14, $16, $b4, $b6
        db      $00, $03, $e0, $e7, $1c, $1f, $fc, $ff

        ds      $2000 - $, $ff
