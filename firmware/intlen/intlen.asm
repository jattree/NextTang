; SPDX-License-Identifier: GPL-3.0-or-later
; Copyright (C) 2026 NextTang contributors
;
; intlen: how long the frame interrupt stays active, in T-states, at each CPU speed,
; measured by handlers of known length that are entered a second time if INT is still active
; when they return. Two runs: everything in bank 7's block RAM (page 14), everything in main RAM (page 40).
; Results: $A000 (page 14 run) and $A100 (page 40 run), [speed 0-3][pad 0-3][length 0-9] = interrupts
; counted in FRAMES frames (FRAMES = single every frame, 2*FRAMES = double every frame). $A200 = 1 when done,
; $A201 = NR 03, $A202 = NR 05.
; Run on the board through the debugger: load at $8000, PC $8000, SP $BF00, run to the label finish
; (about two minutes).
; Handler k (IM 1, at $0038 in the page mapped at slot 0): INC C or INC BC, k/2 NOPs, EI, RET.
; From the start of the acknowledge to the end of RET: 13 + (4 or 6) + 4*(k/2) + 4 + 10 = 31, 33, 35 ... 49 T.
; pad 0-3 shifts the main loop by 0, 1, 2 or 3 T (mod 4), so the HALT's fetches meet the INT edge at every offset.
        DEVICE ZXSPECTRUMNEXT
FRAMES  equ 16
RESULTS equ $1E00
        ORG $8000
start:  di
        ld sp,$BF00
        xor a
        ld ($A200),a
        ld bc,$243B
        ld a,$03
        out (c),a
        inc b
        in a,(c)
        ld ($A201),a
        dec b
        ld a,$05
        out (c),a
        inc b
        in a,(c)
        ld ($A202),a
        nextreg $56,14
        call copyin
        nextreg $56,40
        call copyin
        nextreg $56,0
        nextreg $50,14
        jp $0100
back:   ; the inner program jumps here when a run is over (slot 0 still holds its page)
        ld hl,RESULTS
        ld de,$A000
        ld a,(variant)
        add a,d
        ld d,a
        ld bc,160
        ldir
        ld a,(variant)
        inc a
        ld (variant),a
        cp 2
        jr z,alldone
        nextreg $50,40
        jp $0100
alldone: nextreg $50,$FF
        nextreg $07,0
        ld a,1
        ld ($A200),a
finish: jr finish
copyin: ld hl,blob
        ld de,$C000
        ld bc,blobend-blob
        ldir
        ret
variant: db 0

blob:
        DISP 0
        jp istart
        ds $38-$
handler: ds 16
        ds $100-$
istart: di
        ld sp,$1FF0
        im 1
        ld ix,RESULTS
        xor a
ispeed: ld (speed),a
        nextreg $07,a
        xor a
ipad:   ld (pad),a
        ; the three pad bytes: 0: 00 00 00 (12 T), 1: 23 3E 00 (13 T), 2: 23 00 00 (14 T), 3: 3E 00 00 (15 T)
        ld hl,padtab
        ld e,a
        add a,a
        add a,e
        ld e,a
        ld d,0
        add hl,de
        ld de,padloc
        ld bc,3
        ldir
        xor a
ilen:   ld (len),a
        ; build the handler
        ld hl,handler
        ld b,a
        and 1
        ld a,$0C                ; INC C
        jr z,first
        ld a,$03                ; INC BC
first:  ld (hl),a
        inc hl
        ld a,b
        srl a
        jr z,nonops
        ld b,a
nops:   ld (hl),0
        inc hl
        djnz nops
nonops: ld (hl),$FB             ; EI
        inc hl
        ld (hl),$C9             ; RET
        ; settle one frame, then count
        ld bc,0
        ei
        halt
        di
        ld bc,0
        ld e,FRAMES
iloop:  ei
        halt
padloc: nop
        nop
        nop
        dec e
        jr nz,iloop
        di
        ld (ix+0),c
        inc ix
        ld a,(len)
        inc a
        cp 10
        jr nz,ilen
        ld a,(pad)
        inc a
        cp 4
        jp nz,ipad
        ld a,(speed)
        inc a
        cp 4
        jp nz,ispeed
        jp back
padtab: db $00,$00,$00, $23,$3E,$00, $23,$00,$00, $3E,$00,$00
speed:  db 0
pad:    db 0
len:    db 0
        ENT
blobend:
        SAVEBIN "intlen.bin", $8000, blobend-$8000
