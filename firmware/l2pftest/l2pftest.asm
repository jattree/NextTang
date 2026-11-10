; SPDX-License-Identifier: GPL-3.0-or-later
; Copyright (C) 2026 NextTang contributors
;
; Simulation boot ROM for the Layer 2 lookahead check (tb_zxnext_trace with
; CHECK_LAYER2_PF): Layer 2 on at once, with scroll offsets, cycling 256 x 192,
; 320 x 256 and 640 x 256 every frame or so. The picture is whatever memory
; holds; the check compares the addresses the core reads with the ones its
; lookahead announced. Each resolution change lands mid-frame on purpose, so
; the few announcements made just before it are expected to be wrong.

        device  zxspectrumnext
        org     $0000

        di
        nextreg $07,0                   ; 3.5 MHz
        nextreg $12,8                   ; Layer 2 from bank 8
        nextreg $16,37                  ; scroll x
        nextreg $71,0
        nextreg $17,5                   ; scroll y
        nextreg $18,0                   ; clip window: full
        nextreg $18,255
        nextreg $18,0
        nextreg $18,255
        ld      bc,$123b
        ld      a,%00000010             ; Layer 2 visible
        out     (c),a
        ld      e,0                     ; resolution 0, 1, 2
mode:   ld      a,e
        swapnib                         ; resolution in bits 5:4
        nextreg $70,a
        ld      hl,2700                 ; about one frame at 3.5 MHz
wait:   dec     hl
        ld      a,h
        or      l
        jr      nz,wait
        inc     e
        ld      a,e
        cp      3
        jr      nz,mode
        ld      e,0
        jr      mode

        ds      $2000 - $, 0           ; pad to the 8 KiB boot ROM
