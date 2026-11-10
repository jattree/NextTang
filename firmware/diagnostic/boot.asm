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
SPI_SELECT      equ $e7                 ; write $fe selects SD 0, $ff deselects
SPI_DATA        equ $eb
SD_BUFFER       equ RAM_UNDER_TEST      ; reused once the RAM test has passed
STATUS_BORDER   equ $5b00               ; first byte above the attributes

; Border colours reporting the SD card test.
BORDER_SD_PASS          equ 4           ; green: sector 0 ends 55 aa
BORDER_SD_NO_INIT       equ 1           ; blue: no card, or it never became ready
BORDER_SD_NO_READ       equ 3           ; magenta: read command or data token failed
BORDER_SD_BAD_SIGNATURE equ 5           ; cyan: sector read, signature wrong
BORDER_KEY_HELD         equ 6           ; yellow: while any key is held

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
; Read sector 0 of the SD card through the Next's own SPI ports.
;
; The result is left as the border colour, so it can be read off the screen or
; from the captured video. Main memory has just passed its test, so the sector
; lands in the same window.
; ---------------------------------------------------------------------------
        call    sd_read_sector_zero
        ld      (STATUS_BORDER),a
        out     ($fe),a

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

        ; While any key on any half-row is held, the border turns yellow. The
        ; keyboard port reads every row when the high address byte is zero.
        xor     a
        in      a,($fe)
        and     $1f
        cp      $1f
        ld      a,BORDER_KEY_HELD
        jr      nz,show_border
        ld      a,(STATUS_BORDER)
show_border:
        out     ($fe),a

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

; ---------------------------------------------------------------------------
; SD card access.
;
; Port SPI_DATA starts an 8-bit transfer: a write sends the byte, and a read
; sends $ff and returns the byte received by the previous transfer. A transfer
; takes 16 CPU clocks and an access made during one is ignored, so every
; access goes through a call, which keeps successive ones at least 38 T-states
; apart.
;
; Returns the border colour for the result in A.
; ---------------------------------------------------------------------------
sd_read_sector_zero:
        ld      a,$ff
        out     (SPI_SELECT),a          ; deselected for the wake-up clocks
        ld      b,10
wake_clocks:
        ld      a,$ff
        call    spi_send                ; 80 clocks with chip select high
        djnz    wake_clocks

        ld      a,$fe
        out     (SPI_SELECT),a          ; select SD 0
        ld      hl,sd_cmd0
        call    sd_command
        cp      $01                     ; idle
        jr      nz,sd_not_ready

        ld      hl,sd_cmd8
        call    sd_command              ; $01 on version 2 cards, $05 on older
        ld      b,4
skip_cmd8_reply:
        call    spi_receive             ; voltage and check pattern
        djnz    skip_cmd8_reply

        ld      de,$ffff
wait_ready:
        ld      hl,sd_cmd55
        call    sd_command
        ld      hl,sd_acmd41
        call    sd_command
        or      a                       ; $00 once initialised
        jr      z,sd_ready
        dec     de
        ld      a,d
        or      e
        jr      nz,wait_ready
        jr      sd_not_ready

sd_ready:
        ld      hl,sd_cmd17             ; sector 0 is address 0 on any card
        call    sd_command
        or      a
        jr      nz,sd_no_read
        ld      de,$ffff
wait_token:
        call    spi_receive
        cp      $fe                     ; start of data
        jr      z,read_sector
        dec     de
        ld      a,d
        or      e
        jr      nz,wait_token
        jr      sd_no_read

read_sector:
        ld      hl,SD_BUFFER
        ld      bc,512
read_byte:
        call    spi_receive
        ld      (hl),a
        inc     hl
        dec     bc
        ld      a,b
        or      c
        jr      nz,read_byte
        call    spi_receive             ; CRC
        call    spi_receive
        call    sd_release

        ld      a,(SD_BUFFER+510)
        cp      $55
        jr      nz,sd_bad_signature
        ld      a,(SD_BUFFER+511)
        cp      $aa
        jr      nz,sd_bad_signature
        ld      a,BORDER_SD_PASS
        ret

sd_not_ready:
        call    sd_release
        ld      a,BORDER_SD_NO_INIT
        ret
sd_no_read:
        call    sd_release
        ld      a,BORDER_SD_NO_READ
        ret
sd_bad_signature:
        ld      a,BORDER_SD_BAD_SIGNATURE
        ret

sd_release:
        ld      a,$ff
        out     (SPI_SELECT),a
        call    spi_receive             ; one more byte so the card lets go
        ret

; Send the six-byte command at HL and return its R1 response in A, or $ff if
; none arrives within 16 bytes.
sd_command:
        call    spi_receive             ; a spacer byte between commands
        ld      b,6
command_byte:
        ld      a,(hl)
        call    spi_send
        inc     hl
        djnz    command_byte
        ld      b,16
command_reply:
        call    spi_receive
        cp      $ff
        ret     nz
        djnz    command_reply
        ret

spi_send:
        out     (SPI_DATA),a
        ret

spi_receive:
        in      a,(SPI_DATA)
        ret

sd_cmd0:        db      $40,$00,$00,$00,$00,$95
sd_cmd8:        db      $48,$00,$00,$01,$aa,$87
sd_cmd55:       db      $77,$00,$00,$00,$00,$01
sd_acmd41:      db      $69,$40,$00,$00,$00,$01
sd_cmd17:       db      $51,$00,$00,$00,$00,$01

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
        db      "NEXTTANG DIAG 4",0
        defs    $2000-$,$ff

        assert  $ = $2000
