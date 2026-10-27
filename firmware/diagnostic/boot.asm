; SPDX-License-Identifier: GPL-3.0-or-later
; Copyright (C) 2026 NextTang contributors
;
; Original first-boot diagnostic. This code requires no Spectrum ROM,
; NextZXOS, NextBASIC or esxDOS service.
;
; The screen is the proof. Every pixel is computed by the CPU and placed
; through the Spectrum's interleaved display layout, so a coherent picture
; cannot appear unless address arithmetic, conditional branching and memory
; access are all correct. A failure is visible as a broken pattern rather than
; as a colour nobody can interpret, and the attribute cycle keeps moving so a
; stalled processor is obvious at a glance.

        org     $0000

SCREEN          equ $4000
ATTRIBUTES      equ $5800
ATTRIBUTE_COUNT equ $0300
RAM_UNDER_TEST  equ $8000
RAM_TEST_BYTES  equ $4000
NEXTREG_SELECT  equ $243b
NEXTREG_DATA    equ $253b
ULA_PALETTE_ENTRIES equ 32

start:
        di
        ld      sp,$ffff
        xor     a
        out     ($fe),a

; ---------------------------------------------------------------------------
; Load the Next's ULA palette.
;
; The Next's palette RAM powers up empty on every platform, so until something
; writes it, every ULA colour is black. On a real Next the boot firmware loads
; it; here the diagnostic has to. A plain Spectrum ignores both ports, since
; neither has A0 low.
; ---------------------------------------------------------------------------
        ld      bc,NEXTREG_SELECT
        ld      a,$43                   ; palette control
        out     (c),a
        inc     b                       ; NEXTREG_DATA
        xor     a                       ; write the first ULA palette, auto-increment
        out     (c),a
        dec     b
        ld      a,$40                   ; palette index
        out     (c),a
        inc     b
        xor     a
        out     (c),a
        dec     b
        ld      a,$41                   ; 8-bit palette value
        out     (c),a
        inc     b
        ld      hl,ula_palette
        ld      d,ULA_PALETTE_ENTRIES
palette_loop:
        ld      a,(hl)
        out     (c),a                   ; the index advances on each write
        inc     hl
        dec     d
        jr      nz,palette_loop

; ---------------------------------------------------------------------------
; Draw a computed pattern across the whole bitmap.
;
; The value written is (x xor y), which produces a nested triangular figure.
; It is chosen because it is entirely computed: there is no image data in this
; ROM to copy, so what appears on screen is arithmetic made visible. The
; Spectrum's layout scatters consecutive screen rows across memory, so the
; address for each row has to be built from three separate parts of y. Getting
; the picture right therefore exercises exactly the behaviour worth proving.
;
; Screen address for row y, column x:
;   $4000 + ((y and $c0) << 5) + ((y and $07) << 8) + ((y and $38) << 2) + x
; ---------------------------------------------------------------------------
        ld      e,0                     ; e = y, the pixel row
row_loop:
        ; Build the row address in hl from the three fields of y.
        ld      a,e
        and     $c0                     ; third of the screen
        rrca
        rrca
        rrca                            ; (y and $c0) >> 3, i.e. << 5 into h
        ld      h,a
        ld      a,e
        and     $07                     ; pixel row within the character cell
        or      h
        or      $40                     ; screen base
        ld      h,a
        ld      a,e
        and     $38                     ; character row within the third
        rlca
        rlca                            ; (y and $38) << 2
        ld      l,a

        ld      d,0                     ; d = x, the byte column
column_loop:
        ld      a,d
        xor     e                       ; the pattern itself
        ld      (hl),a
        inc     l                       ; columns are contiguous within a row
        inc     d
        ld      a,d
        cp      32
        jr      nz,column_loop

        inc     e
        ld      a,e
        cp      192
        jr      nz,row_loop

; ---------------------------------------------------------------------------
; Verify a 16 KiB RAM window outside the display area.
;
; Done before the attribute cycle starts so a memory fault is reported rather
; than hidden behind a screen that looks alive.
; ---------------------------------------------------------------------------
        ld      hl,RAM_UNDER_TEST
        ld      bc,RAM_TEST_BYTES
        ld      d,$5a
memory_write_loop:
        ld      a,d
        ld      (hl),a
        cpl
        ld      d,a
        inc     hl
        dec     bc
        ld      a,b
        or      c
        jr      nz,memory_write_loop

        ld      hl,RAM_UNDER_TEST
        ld      bc,RAM_TEST_BYTES
        ld      d,$5a
memory_read_loop:
        ld      a,(hl)
        cp      d
        jr      nz,memory_fail
        ld      a,d
        cpl
        ld      d,a
        inc     hl
        dec     bc
        ld      a,b
        or      c
        jr      nz,memory_read_loop

; ---------------------------------------------------------------------------
; Colour the pattern, then keep cycling it forever.
;
; The cycle is the liveness indicator: a processor that has stopped leaves a
; still image, and a processor that is running produces visible movement
; without needing anything else on screen to interpret.
; ---------------------------------------------------------------------------
        ld      c,0                     ; c = animation phase
attribute_cycle:
        ld      hl,ATTRIBUTES
        ld      de,ATTRIBUTE_COUNT
        ld      b,c                     ; b walks the colour through the block
attribute_loop:
        ld      a,b
        rrca
        rrca                            ; slow the change across the screen
        and     $07
        jr      nz,attribute_colour     ; never pick ink 0 on paper 0
        ld      a,$07
attribute_colour:
        or      $40                     ; bright, black paper
        ld      (hl),a
        inc     hl
        inc     b
        dec     de
        ld      a,d
        or      e
        jr      nz,attribute_loop

        ; Pause so the movement is visible rather than a blur.
        ld      de,$4000
hold_loop:
        dec     de
        ld      a,d
        or      e
        jr      nz,hold_loop

        inc     c
        jr      attribute_cycle

; ---------------------------------------------------------------------------
; Memory failure. The screen is cleared to a solid, obviously wrong state and
; the border is left red, so a fault cannot be mistaken for the running
; pattern.
; ---------------------------------------------------------------------------
memory_fail:
        ld      a,$02
        out     ($fe),a
        ld      hl,SCREEN
        ld      bc,$1800
        ld      d,$ff
clear_loop:
        ld      (hl),d
        inc     hl
        dec     bc
        ld      a,b
        or      c
        jr      nz,clear_loop
        ld      hl,ATTRIBUTES
        ld      bc,ATTRIBUTE_COUNT
fail_attribute_loop:
        ld      (hl),$42                ; bright red ink on black
        inc     hl
        dec     bc
        ld      a,b
        or      c
        jr      nz,fail_attribute_loop
memory_fail_hold:
        jr      memory_fail_hold

; The Next's default ULA colours in RRRGGGBB: ink 0-7, bright ink 8-15, paper
; 16-23 and bright paper 24-31. The border uses the paper entries.
ula_palette:
        db      $00,$02,$a0,$a2,$14,$16,$b4,$b6
        db      $00,$03,$e0,$e7,$1c,$1f,$fc,$ff
        db      $00,$02,$a0,$a2,$14,$16,$b4,$b6
        db      $00,$03,$e0,$e7,$1c,$1f,$fc,$ff
        assert  $ - ula_palette = ULA_PALETTE_ENTRIES

        assert  $ < $1fe0
        defs    $1fe0-$,$ff
        db      "NEXTTANG DIAG 3",0
        defs    $2000-$,$ff

        assert  $ = $2000
