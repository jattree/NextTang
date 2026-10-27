; SPDX-License-Identifier: GPL-3.0-or-later
; Copyright (C) 2026 NextTang contributors
;
; Clock-equivalence exercise for simulation. It runs the same sequence at each
; CPU speed so that the unmodified core and the core converted to clock
; enables can be traced side by side. It touches what the conversion changes:
; the CPU's falling-edge I/O read-back (border, keyboard, paging, Timex, AY,
; NextREG, SPI), contended memory at 3.5 MHz, interrupts taken from HALT, and
; speed changes themselves. Results go to RAM so every read shows on the bus.
;
; Nothing here is a test of the core's correctness: both cores run it, and the
; check is that they do the same thing on the same 28 MHz cycle.

        org     $0000

NEXTREG_SELECT  equ $243b
RESULTS         equ $8000               ; 16 bytes per speed
TICKS           equ $8100
SCREEN          equ $4000
SPI_SELECT      equ $e7
SPI_DATA        equ $eb

start:
        di
        ld      sp,$ffff
        xor     a
        out     ($fe),a
        im      1
        jp      main

; IM 1 lands here on every frame interrupt. Raw output does not fill a gap
; left by org, so the space is padded explicitly.
        ds      $0038 - $, $ff
frame_interrupt:
        push    af
        ld      a,(TICKS)
        inc     a
        ld      (TICKS),a
        pop     af
        ei
        ret

main:
        xor     a
        ld      (TICKS),a
        ld      ix,RESULTS
        ld      e,0                     ; CPU speed, 0 to 3

speed_loop:
        ld      bc,NEXTREG_SELECT       ; NextREG 7 selects the CPU speed
        ld      a,$07
        out     (c),a
        inc     b
        ld      a,e
        out     (c),a
        in      a,(c)                   ; read it back through the NextREG port
        ld      (ix+0),a

        call    exercise

        ld      bc,16
        add     ix,bc
        inc     e
        ld      a,e
        cp      4
        jr      nz,speed_loop

        ld      a,7                     ; white border: finished
        out     ($fe),a
        di
finished:
        halt
        jr      finished

exercise:
        ; Uncontended memory: write a pattern, then sum it back.
        ld      hl,$9000
        ld      b,64
.fill:
        ld      a,l
        xor     e
        ld      (hl),a
        inc     hl
        djnz    .fill
        ld      hl,$9000
        ld      b,64
        xor     a
.sum:
        add     a,(hl)
        inc     hl
        djnz    .sum
        ld      (ix+1),a

        ; Border out and keyboard in.
        ld      a,e
        inc     a
        out     ($fe),a
        ld      a,$00
        in      a,($fe)
        ld      (ix+2),a

        ; Paging: bank 1 at $c000, mark it, back to bank 0, read $c000.
        ld      bc,$7ffd
        ld      a,$01
        out     (c),a
        ld      a,e
        add     a,$a0
        ld      ($c000),a
        xor     a
        out     (c),a
        ld      a,($c000)
        ld      (ix+3),a

        ; Timex/floating bus port and AY register read-back.
        in      a,($ff)
        ld      (ix+4),a
        ld      bc,$fffd
        ld      a,$00                   ; AY register 0
        out     (c),a
        ld      b,$bf                   ; $bffd: data
        ld      a,e
        add     a,$30
        out     (c),a
        ld      b,$ff
        in      a,(c)
        ld      (ix+5),a

        ; SPI: select SD 0, exchange two bytes, deselect.
        ld      a,$fe
        out     (SPI_SELECT),a
        ld      a,$5a
        out     (SPI_DATA),a
        in      a,(SPI_DATA)
        ld      (ix+6),a
        ld      a,e
        out     (SPI_DATA),a
        in      a,(SPI_DATA)
        ld      (ix+7),a
        ld      a,$ff
        out     (SPI_SELECT),a

        ; Contended memory through the display: wait for the frame
        ; interrupt, then sweep screen memory for most of a frame. 1,536
        ; iterations of about 44 T-states covers the 192 display lines at
        ; 3.5 MHz.
        ei
        halt
        di
        ld      hl,SCREEN
        ld      bc,$0600
.sweep:
        ld      a,(hl)
        ld      (hl),c
        inc     hl
        dec     bc
        ld      a,b
        or      c
        jr      nz,.sweep

        ; Record the interrupts taken so far.
        ld      a,(TICKS)
        ld      (ix+8),a
        ret

        ds      $2000 - $, $ff
