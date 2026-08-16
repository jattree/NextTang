; SPDX-License-Identifier: GPL-3.0-or-later
; Copyright (C) 2026 NextTang contributors
;
; Original first-boot diagnostic. This code requires no Spectrum ROM,
; NextZXOS, NextBASIC or esxDOS service.

        org     $0000

start:
        di
        ld      sp,$ffff
        xor     a
        out     ($fe),a

        ; Alternating pixels prove CPU writes reach the ULA display memory.
        ld      hl,$4000
        ld      bc,$1800
        ld      d,$aa
pixel_loop:
        ld      a,d
        ld      (hl),a
        cpl
        ld      d,a
        inc     hl
        dec     bc
        ld      a,b
        or      c
        jr      nz,pixel_loop

        ; Changing attributes make the diagnostic recognisable on screen.
        ld      hl,$5800
        ld      bc,$0300
        ld      d,$47
attribute_loop:
        ld      a,d
        ld      (hl),a
        inc     d
        inc     hl
        dec     bc
        ld      a,b
        or      c
        jr      nz,attribute_loop

        ; Exercise a separate 16 KiB RAM window with an alternating pattern.
        ld      hl,$8000
        ld      bc,$4000
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

        ld      hl,$8000
        ld      bc,$4000
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

        ; Green border means the full read-back passed.
        ld      a,$04
        out     ($fe),a
memory_pass:
        jr      memory_pass

memory_fail:
        ; Red border leaves a persistent, video-only failure indication.
        ld      a,$02
        out     ($fe),a
        jr      memory_fail

        assert  $ < $1fe0
        defs    $1fe0-$,$ff
        db      "NEXTTANG DIAG 1",0
        defs    $2000-$,$ff

        assert  $ = $2000
