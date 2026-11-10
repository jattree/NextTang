; SPDX-License-Identifier: GPL-3.0-or-later
; Copyright (C) 2026 NextTang contributors
;
; A still Layer 2 picture for checking the display path on its own: 320 x 256
; from bank 8, every pixel x xor y (low byte of x), through an identity Layer 2
; palette, with the ULA off and a black fallback colour. The picture memory
; never changes after it is drawn, so any difference between captured frames
; comes from the display path. The views below then separate the stored byte
; from the colour it becomes, and the screen column from the memory address.
;
; In 320 x 256 Layer 2 is held column by column: byte x * 256 + y of the five
; banks from bank 8 is pixel (x, y). That is 8K pages 16 to 25.

        opt     --zxnext
        org     $0000

start:
        di
        ld      sp,$5ff0
        nextreg $07,3                   ; 28 MHz while drawing

        ; Identity palette: Layer 2 first palette, index n = RGB332 colour n.
        nextreg $43,%00010000
        nextreg $40,0
        xor     a
.palette:
        nextreg $41,a
        inc     a
        jr      nz,.palette

        nextreg $68,%10000000           ; ULA off
        nextreg $4a,0                   ; black where Layer 2 is transparent
        nextreg $14,$e3                 ; the usual transparent colour
        nextreg $12,8                   ; Layer 2 from bank 8
        nextreg $70,%00010000           ; 320 x 256
        nextreg $16,0                   ; no scroll
        nextreg $71,0
        nextreg $17,0
        nextreg $1c,%00000001           ; reset the Layer 2 clip index
        nextreg $18,0                   ; full clip window
        nextreg $18,159
        nextreg $18,0
        nextreg $18,255

        ; Fill pages 16 to 25 through slot 7 ($e000): 32 columns of 256 each.
        ld      c,0                     ; c = column (low byte of x)
        ld      b,16                    ; b = page
.page:
        ld      a,b
        nextreg $57,a
        ld      hl,$e000
.byte:
        ld      a,l                     ; y
        xor     c                       ; x xor y
        ld      (hl),a
        inc     l
        jr      nz,.byte
        inc     c                       ; next column
        inc     h
        jr      nz,.byte                ; until hl wraps past $ffff
        inc     b
        ld      a,b
        cp      26
        jr      nz,.page

        ld      bc,$123b
        ld      a,%00000010             ; Layer 2 visible
        out     (c),a

        ; Then round three views of the same memory, about four seconds each,
        ; with the border saying which:
        ;   black: 320 x 256, identity palette
        ;   blue:  320 x 256, palette rotated left three bits, so index bits
        ;          2 to 4 come out as red instead of green
        ;   red:   256 x 192 (row by row: the same bytes read across rather
        ;          than down), identity palette
.views:
        xor     a
        out     ($fe),a
        call    identity_palette
        nextreg $70,%00010000
        call    pause
        ld      a,1
        out     ($fe),a
        call    rotated_palette
        call    pause
        ld      a,2
        out     ($fe),a
        call    identity_palette
        nextreg $70,%00000000
        call    pause
        jr      .views

identity_palette:
        nextreg $43,%00010000
        nextreg $40,0
        xor     a
.identity:
        nextreg $41,a
        inc     a
        jr      nz,.identity
        ret

rotated_palette:
        nextreg $43,%00010000
        nextreg $40,0
        ld      b,0
.rotated:
        ld      a,b
        rlca
        rlca
        rlca
        nextreg $41,a
        inc     b
        jr      nz,.rotated
        ret

; About four seconds at 28 MHz.
pause:
        ld      d,0
.outer:
        ld      bc,0
.inner:
        dec     bc
        ld      a,b
        or      c
        jr      nz,.inner
        dec     d
        ld      a,d
        cp      256 - 64
        jr      nz,.outer
        ret

        ds      $2000 - $, $ff
