; mb_driver.s - Mockingboard music driver for the Apple II (ca65, plain 6502)
;
; Plays .MBF streams made by src/converter. Include it in a game by linking
; this object and calling the routines below. The driver owns the zero-page
; bytes in segment ZEROPAGE (5 bytes) and the variables in segment BSS.
;
; API
;   MB_INIT    A = slot 1-7, or 0 to auto-detect (tries slots 4,5,6,7,2,1,3)
;              out: C clear and A = slot found; C set = no Mockingboard
;              Both 6522s ($Cn00 and $Cn80) must answer.
;   MB_PLAY    A/X = low/high address of the .MBF file already loaded in memory
;              out: C clear = playing; C set = not a valid MBF1 file
;              The header tick rate must be 16-255 Hz.
;   MB_POLL    Call as often as you like. When the 6522 timer has ticked it runs
;              MB_UPDATE. It misses ticks if you call it slower than the tick rate.
;   MB_UPDATE  Play one frame now. Call it once per tick from your own timer or IRQ.
;   MB_POLL and MB_UPDATE out: C clear = still playing; C set = stopped or finished
;   MB_STOP    Stop the song and silence both chips.
;   MB_RING    A = high byte of the ring end, X = high byte to subtract on wrap.
;              Call after MB_PLAY when the song is read from a ring buffer that a
;              streamer refills: the read pointer wraps at the start of a frame
;              once its high byte reaches A. A frame may run past the end into a
;              copy of the ring's first bytes. Turns looping off.
;   MB_POS     out: A = high byte of the music read pointer (streamer use)
;   MB_TICK    out: A = number of ticks played so far, modulo 256
;   MB_PAUSE   silence both chips while the CPU is busy (a disk read); the
;              music state is kept
;   MB_RESUME  put the volumes back and restart the tick timer
;   MB_SFX     A/X = address of a sound-effect stream. It takes over chip 1
;              channels B and C (registers 2-5, 9, 10) until it ends; the music
;              there is restored afterwards. Effects advance inside MB_UPDATE, so
;              they only run while a song is playing. Same frame format as MBF
;              (count byte, then [chip<<4|reg, value] pairs, $FF ends); the chip
;              bit is ignored and writes outside those registers are dropped.
;
; MBF stream: 8-byte header 'MBF1', rate (u16 LE), loop flag, reserved; then one
; frame per tick: count byte N, N pairs of [chip<<4 | register, value]; $FF ends.
; A count byte of $80 + n (n = 1-126) stands for n ticks with no register changes.

        .setcpu "6502"

        .export MB_INIT, MB_PLAY, MB_POLL, MB_UPDATE, MB_STOP, MB_SFX
        .export MB_RING, MB_POS, MB_PAUSE, MB_RESUME, MB_TICK

; 6522 VIA register offsets
VIA_ORB         = $00           ; PB0 = BC1, PB1 = BDIR, PB2 = /RESET of the AY
VIA_ORA         = $01           ; AY data / register bus
VIA_DDRB        = $02
VIA_DDRA        = $03
VIA_T1CL        = $04
VIA_T1CH        = $05
VIA_ACR         = $0B
VIA_IFR         = $0D
VIA_IER         = $0E

; Values written to ORB to drive the AY-3-8910 bus control lines
AY_RESET        = $00
AY_INACTIVE     = $04
AY_WRITE        = $06
AY_LATCH        = $07

END_MARK        = $FF
HEADER_SIZE     = 8
CPU_CLOCK_HZ    = 1022727       ; the AY runs from the Apple II clock

        .segment "ZEROPAGE"
zp_ptr:         .res 2          ; stream pointer (song, or sound effect while swapped)
zp_via:         .res 2          ; base address of the 6522 being written
zp_tmp:         .res 1

        .segment "BSS"
mb_slot_hi:     .res 1          ; $C0 + slot
mb_state:       .res 1          ; 0 = stopped, 1 = playing
mb_loop:        .res 1
mb_start:       .res 2          ; address of the first frame
mb_sfx_on:      .res 1
mb_sfx_ptr:     .res 2
mb_mode:        .res 1          ; 0 = running music, 1 = running a sound effect
mb_ring_end:    .res 1          ; high byte where the ring wraps; 0 = no ring
mb_ring_wrap:   .res 1          ; high byte subtracted on wrap
mb_paused:      .res 1          ; 1 between MB_PAUSE and MB_RESUME (lets tests tag writes)
mb_ticks:       .res 1          ; ticks played, modulo 256
mb_skip:        .res 1          ; empty ticks left in the run the music pointer is on
cnt:            .res 1          ; register pairs left in this frame
idx:            .res 1
rv:             .res 1          ; value for the next AY register write
div:            .res 1          ; tick rate
rem:            .res 1
q0:             .res 1          ; quotient, low to high
q1:             .res 1
q2:             .res 1
shadow:         .res 32         ; last value the music wrote: chip * 16 + register

        .segment "RODATA"
magic:          .byte "MBF1"
scan_order:     .byte 4, 5, 6, 7, 2, 1, 3, 0
sfx_regs:       .byte 2, 3, 4, 5, 9, 10, $FF
; Registers an effect may use, indexed by register number
sfx_ok:         .byte 0, 0, 1, 1, 1, 1, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0

        .segment "CODE"

;-----------------------------------------------------------------------------
; MB_INIT
;-----------------------------------------------------------------------------
MB_INIT:
        cmp     #0
        bne     @have
        ldx     #0
@scan:  lda     scan_order,x
        beq     @none
        jsr     probe_slot
        bcc     @found
        inx
        bne     @scan
@none:  sec
        rts
@found: lda     scan_order,x
@have:  ora     #$C0
        sta     mb_slot_hi
        lda     #0
        sta     mb_state
        sta     mb_sfx_on
        jsr     setup_via
        lda     #0
        sta     zp_via
        jsr     init_chip
        lda     #$80
        sta     zp_via
        jsr     init_chip
        jsr     silence
        lda     mb_slot_hi
        and     #$07
        clc
        rts

; Configure one 6522 for the AY bus and pulse the AY reset line. zp_via = VIA.
init_chip:
        ldy     #VIA_DDRA
        lda     #$FF
        sta     (zp_via),y
        ldy     #VIA_DDRB
        lda     #$07
        sta     (zp_via),y
        ldy     #VIA_ORB
        lda     #AY_RESET
        sta     (zp_via),y
        lda     #AY_INACTIVE
        sta     (zp_via),y
        rts

; A = slot. C clear if both 6522s of that slot answer.
probe_slot:
        ora     #$C0
        sta     zp_via+1
        lda     #$00
        sta     zp_via
        jsr     probe_via
        bcs     @no
        lda     #$80
        sta     zp_via
        jsr     probe_via
@no:    rts

; zp_via = VIA address. C clear if a 6522 is there: DDRA reads back what was
; written, and timer 1 counts down once started. Uses Y only.
probe_via:
        ldy     #VIA_DDRA
        lda     #$FF
        sta     (zp_via),y
        lda     (zp_via),y
        cmp     #$FF
        bne     @no
        lda     #$00
        sta     (zp_via),y
        lda     (zp_via),y
        bne     @no
        ldy     #VIA_T1CL
        lda     #$FF
        sta     (zp_via),y
        iny                     ; T1CH
        sta     (zp_via),y      ; starts the timer
        dey
        lda     (zp_via),y
        sta     zp_tmp
        nop
        nop
        nop
        nop
        lda     (zp_via),y
        cmp     zp_tmp
        beq     @no
        clc
        rts
@no:    sec
        rts

;-----------------------------------------------------------------------------
; MB_PLAY
;-----------------------------------------------------------------------------
MB_PLAY:
        sta     zp_ptr
        stx     zp_ptr+1
        jsr     setup_via
        ldy     #3
@mg:    lda     (zp_ptr),y
        cmp     magic,y
        bne     @bad
        dey
        bpl     @mg
        ldy     #5
        lda     (zp_ptr),y      ; rate high byte must be 0
        bne     @bad
        dey
        lda     (zp_ptr),y      ; rate low byte
        cmp     #16             ; below 16 Hz the tick period overflows the 16-bit timer
        bcc     @bad
        sta     div
        ldy     #6
        lda     (zp_ptr),y
        sta     mb_loop
        lda     zp_ptr          ; first frame = file + 8
        clc
        adc     #HEADER_SIZE
        sta     zp_ptr
        sta     mb_start
        lda     zp_ptr+1
        adc     #0
        sta     zp_ptr+1
        sta     mb_start+1
        ldy     #0              ; an empty song cannot loop
        lda     (zp_ptr),y
        cmp     #END_MARK
        bne     @go
        sty     mb_loop
@go:    lda     #0
        sta     mb_sfx_on
        sta     mb_mode
        sta     mb_ring_end
        sta     mb_paused
        sta     mb_ticks
        sta     mb_skip
        ldx     #31
@z:     sta     shadow,x
        dex
        bpl     @z
        jsr     silence
        jsr     start_timer
        lda     #1
        sta     mb_state
        clc
        rts
@bad:   sec
        rts

; Timer 1 free-running with a period of CPU_CLOCK_HZ / rate cycles, no IRQs.
start_timer:
        lda     #<CPU_CLOCK_HZ
        sta     q0
        lda     #>CPU_CLOCK_HZ
        sta     q1
        lda     #^CPU_CLOCK_HZ
        sta     q2
        lda     #0
        sta     rem
        ldx     #24
@d:     asl     q0              ; 24-bit by 8-bit shift-and-subtract division
        rol     q1
        rol     q2
        rol     rem
        bcs     @sub            ; the remainder overflowed 8 bits, so it is >= div
        lda     rem
        cmp     div
        bcc     @next
@sub:   lda     rem
        sec
        sbc     div
        sta     rem
        inc     q0
@next:  dex
        bne     @d
        lda     q0              ; the timer counts N + 2 cycles
        sec
        sbc     #2
        sta     q0
        lda     q1
        sbc     #0
        sta     q1
        lda     #0
        sta     zp_via
        ldy     #VIA_IER
        lda     #$7F            ; no interrupts from this 6522
        sta     (zp_via),y
        ldy     #VIA_ACR
        lda     #$40            ; timer 1 free-running
        sta     (zp_via),y
        ldy     #VIA_T1CL
        lda     q0
        sta     (zp_via),y
        ldy     #VIA_T1CH
        lda     q1
        sta     (zp_via),y      ; loads the counter and starts it
        rts

;-----------------------------------------------------------------------------
; MB_POLL
;-----------------------------------------------------------------------------
MB_POLL:
        lda     mb_state
        beq     @stopped
        jsr     setup_via
        lda     #0
        sta     zp_via
        ldy     #VIA_IFR
        lda     (zp_via),y
        and     #$40
        beq     @wait
        ldy     #VIA_T1CL       ; reading the low counter clears the timer flag
        lda     (zp_via),y
        jmp     MB_UPDATE
@wait:  clc
        rts
@stopped:
        sec
        rts

;-----------------------------------------------------------------------------
; MB_UPDATE
;-----------------------------------------------------------------------------
MB_UPDATE:
        lda     mb_state
        beq     @stopped
        inc     mb_ticks
        jsr     setup_via
        lda     #0
        sta     mb_mode
        jsr     run_frame
        bcc     @music_ok
        lda     mb_loop         ; end of song
        beq     @finish
        lda     mb_start
        sta     zp_ptr
        lda     mb_start+1
        sta     zp_ptr+1
        jsr     run_frame       ; the first frame is a keyframe, never the end mark
@music_ok:
        lda     mb_sfx_on
        beq     @playing
        jsr     sfx_frame
@playing:
        clc
        rts
@finish:
        jsr     MB_STOP
@stopped:
        sec
        rts

; Run the frame at zp_ptr. C set = end mark found (pointer not moved);
; C clear = frame played and the pointer advanced.
run_frame:
        lda     mb_mode
        bne     @fetch          ; sound effects: plain frames only
        lda     mb_ring_end
        beq     @runs
        lda     zp_ptr+1        ; wrap the music pointer at the end of the ring
        cmp     mb_ring_end
        bcc     @runs
        sbc     mb_ring_wrap
        sta     zp_ptr+1
@runs:  lda     mb_skip         ; inside a run of empty ticks?
        beq     @fetch
        dec     mb_skip
        bne     @empty
        ldy     #1              ; last tick of the run: step over its code byte
        jmp     @adv
@empty: clc
        rts
@fetch: ldy     #0
        lda     (zp_ptr),y
        cmp     #END_MARK
        beq     @end
        cmp     #$80
        bcc     @plain
        and     #$7F            ; $80 + n: this tick and n-1 more are empty
        sec
        sbc     #1
        bcc     @one            ; $80 itself counts as one tick
        sta     mb_skip
        bne     @empty          ; the pointer stays on the code byte until the run is over
@one:   ldy     #1
        jmp     @adv
@plain: sta     cnt
        ldy     #1
@pair:  lda     cnt
        beq     @adv
        dec     cnt
        sty     idx
        lda     (zp_ptr),y
        sta     zp_tmp
        iny
        lda     (zp_ptr),y
        sta     rv
        jsr     write_pair
        ldy     idx
        iny
        iny
        bne     @pair
@adv:   tya
        clc
        adc     zp_ptr
        sta     zp_ptr
        bcc     @ok
        inc     zp_ptr+1
@ok:    clc
        rts
@end:   sec
        rts

; zp_tmp = chip<<4 | register, rv = value
write_pair:
        lda     mb_mode
        bne     @sfx
        lda     zp_tmp
        and     #$10            ; 0 for chip 0, 16 for chip 1
        tay
        beq     @c0
        lda     #$80
@c0:    sta     zp_via
        lda     zp_tmp
        and     #$0F
        sta     zp_tmp
        tya
        clc
        adc     zp_tmp
        tax
        lda     rv
        sta     shadow,x        ; remember it so an effect can hand the channel back
        lda     mb_sfx_on
        beq     @out
        cpy     #16
        bne     @out
        ldx     zp_tmp
        lda     sfx_ok,x
        bne     @skip           ; channel is on loan to the effect
@out:   lda     zp_tmp
        jmp     ay_write
@skip:  rts
@sfx:   lda     zp_tmp
        and     #$0F
        sta     zp_tmp
        tax
        lda     sfx_ok,x
        beq     @skip
        lda     #$80            ; effects always go to chip 1
        sta     zp_via
        lda     zp_tmp
        jmp     ay_write

; Write rv to AY register A on the 6522 at zp_via. Uses A and Y.
ay_write:
        ldy     #VIA_ORA
        sta     (zp_via),y      ; register number on the bus
        ldy     #VIA_ORB
        lda     #AY_LATCH
        sta     (zp_via),y
        lda     #AY_INACTIVE
        sta     (zp_via),y
        lda     rv
        ldy     #VIA_ORA
        sta     (zp_via),y      ; value on the bus
        ldy     #VIA_ORB
        lda     #AY_WRITE
        sta     (zp_via),y
        lda     #AY_INACTIVE
        sta     (zp_via),y
        rts

;-----------------------------------------------------------------------------
; Sound effects
;-----------------------------------------------------------------------------
MB_SFX:
        sta     mb_sfx_ptr
        stx     mb_sfx_ptr+1
        lda     #1
        sta     mb_sfx_on
        rts

; Run one frame of the current effect. At its end hand the channels back.
sfx_frame:
        jsr     swap_ptr
        lda     #1
        sta     mb_mode
        jsr     run_frame
        php
        jsr     swap_ptr
        plp
        bcc     @ret
        lda     #0
        sta     mb_sfx_on
        sta     mb_mode
        lda     #$80
        sta     zp_via
        ldx     #0
@r:     lda     sfx_regs,x
        bmi     @ret
        sta     zp_tmp
        stx     idx
        clc
        adc     #16
        tax
        lda     shadow,x
        sta     rv
        lda     zp_tmp
        jsr     ay_write
        ldx     idx
        inx
        bne     @r
@ret:   rts

; Exchange zp_ptr with mb_sfx_ptr
swap_ptr:
        ldx     #1
@s:     lda     zp_ptr,x
        ldy     mb_sfx_ptr,x
        sta     mb_sfx_ptr,x
        sty     zp_ptr,x
        dex
        bpl     @s
        rts

;-----------------------------------------------------------------------------
; MB_STOP
;-----------------------------------------------------------------------------
MB_STOP:
        lda     #0
        sta     mb_state
        sta     mb_sfx_on
        jsr     setup_via
        lda     #0
        sta     zp_via
        ldy     #VIA_ACR
        sta     (zp_via),y      ; timer 1 back to one-shot
silence:
        lda     #0
        sta     rv
        sta     zp_via
        jsr     silence_chip
        lda     #$80
        sta     zp_via
silence_chip:
        lda     #8
        jsr     ay_write
        lda     #9
        jsr     ay_write
        lda     #10
        jmp     ay_write

setup_via:
        lda     mb_slot_hi
        sta     zp_via+1
        rts

;-----------------------------------------------------------------------------
; Streaming support
;-----------------------------------------------------------------------------
MB_RING:
        sta     mb_ring_end
        stx     mb_ring_wrap
        lda     #0
        sta     mb_loop
        rts

MB_POS:
        lda     zp_ptr+1
        rts

MB_TICK:
        lda     mb_ticks
        rts

MB_PAUSE:
        jsr     setup_via
        lda     #1
        sta     mb_paused
        jmp     silence         ; only the chips go quiet; the shadow keeps the music's volumes

MB_RESUME:
        jsr     setup_via
        lda     #0
        sta     zp_via
        ldx     #0
        jsr     restore_volumes
        lda     #$80
        sta     zp_via
        ldx     #16
        jsr     restore_volumes
        lda     #0
        sta     zp_via
        ldy     #VIA_T1CH
        lda     q1
        sta     (zp_via),y      ; reload the counter: ticks restart from now, none are replayed
        lda     #0
        sta     mb_paused
        rts

; X = 0 or 16 (shadow bank), zp_via = chip
restore_volumes:
        lda     shadow+8,x
        sta     rv
        lda     #8
        jsr     ay_write
        lda     shadow+9,x
        sta     rv
        lda     #9
        jsr     ay_write
        lda     shadow+10,x
        sta     rv
        lda     #10
        jmp     ay_write
