; SPDX-License-Identifier: GPL-3.0-or-later
; Copyright (C) 2026 NextTang contributors
;
; memstress: main-memory reads and writes at every CPU speed, run on the board through the debugger
; (load at $8000, PC $8000, SP $8F00, run to the label finish).
; Tests per speed: LDIR copy, zxnDMA copy, PUSH copy, write-then-read at once (CPL, INC, DEC in place),
; zxnDMA fill (copy to the next address). Results: $8F80 errors (word), $8F82 = 1 when done,
; $8F87 errors in the DMA fill (word).
        DEVICE ZXSPECTRUMNEXT
SRC     equ $9000
DST     equ $C000
LEN     equ $1000
        ORG $8000
start:  di
        ld sp,$8F00
        nextreg $56,0
        nextreg $57,1
        ld hl,0
        ld (errs),hl
        ld (errs2),hl
        xor a
        ld (done),a
        ld a,PASSES
        ld (passes),a
pass:   xor a
speedl: ld (speed),a
        nextreg $07,a
        ld hl,SRC
        ld bc,LEN
fill:   ld a,l
        add a,a
        add a,a
        add a,l
        xor h
        ld e,a
        ld a,(speed)
        add a,e
        ld e,a
        ld a,(passes)
        add a,e
        ld (hl),a
        inc hl
        dec bc
        ld a,b
        or c
        jr nz,fill
        ; 1: LDIR
        ld hl,SRC
        ld de,DST
        ld bc,LEN
        ldir
        call cmp
        ; 2: zxnDMA
        call clr
        ld hl,dmaprog
        ld b,dmaend-dmaprog
        ld c,$6B
        otir
        call cmp
        ; 3: PUSH
        call clr
        ld (savesp),sp
        ld sp,DST+LEN
        ld hl,SRC+LEN-1
        ld bc,LEN/2
pushl:  ld d,(hl)
        dec hl
        ld e,(hl)
        dec hl
        push de
        dec bc
        ld a,b
        or c
        jr nz,pushl
        ld sp,(savesp)
        call cmp
        ; 4: write then read at once, twice over
        ld hl,DST
        ld bc,LEN
rmw:    ld a,(hl)
        cpl
        ld (hl),a
        cp (hl)
        call nz,err1
        inc (hl)
        inc a
        cp (hl)
        call nz,err1
        dec (hl)
        ld a,(hl)
        cpl
        ld (hl),a
        inc hl
        dec bc
        ld a,b
        or c
        jp nz,rmw
        call cmp
        ; 5: zxnDMA fill (copy to the next address), then check every byte
        ld a,(speed)
        xor $5A
        ld (DST),a
        ld hl,dmafill
        ld b,dmafillend-dmafill
        ld c,$6B
        otir
        ld hl,DST
        ld bc,LEN
        ld a,(speed)
        xor $5A
        ld e,a
fchk:   ld a,(hl)
        cp e
        call nz,err2
        inc hl
        dec bc
        ld a,b
        or c
        jr nz,fchk
        ld a,(speed)
        inc a
        cp 4
        jp nz,speedl
        ld hl,passes
        dec (hl)
        jp nz,pass
        nextreg $07,0
        ld a,1
        ld (done),a
finish: jr finish

cmp:    ld hl,SRC
        ld de,DST
        ld bc,LEN
cmpl:   ld a,(de)
        cp (hl)
        call nz,err1
        inc hl
        inc de
        dec bc
        ld a,b
        or c
        jr nz,cmpl
        ret
clr:    ld hl,DST
        ld de,DST+1
        ld bc,LEN-1
        ld (hl),0
        ldir
        ret
err1:   push hl
        ld hl,(errs)
        inc hl
        ld (errs),hl
        pop hl
        ret
err2:   push hl
        ld hl,(errs2)
        inc hl
        ld (errs2),hl
        pop hl
        ret
dmafill: db $83, $7D
        dw DST, LEN-1
        db $14, $10, $AD
        dw DST+1
        db $82, $CF, $87
dmafillend:
dmaprog: db $83, $7D
        dw SRC, LEN
        db $14, $10, $AD
        dw DST
        db $82, $CF, $87
dmaend:
PASSES  equ 8
        ORG $8F80
errs:   dw 0
done:   db 0
speed:  db 0
passes: db 0
savesp: dw 0
errs2:  dw 0
        SAVEBIN "memstress.bin", $8000, $1000
