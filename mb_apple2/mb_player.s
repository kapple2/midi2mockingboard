; mb_player.s - standalone .MBF player for DOS 3.3 (ca65, plain 6502)
;
; Load at $8E00 (BLOAD MBPLAY). The song is an ordinary DOS file in the catalog, found by
; name (see mb_stream.s). The caller puts the file name (ASCII, at most 30 characters) at
; $0300, sets the rest and does CALL 36352:
;     POKE 6,mode : POKE 7,length of the name
;     mode 0 = load the whole song into RAM first (at most 28 KB), then play
;     mode 1 = stream it through a 7-slot ring buffer, refilling from the disk
;     POKE 9,1 (optional, streaming only) starts the song again when it ends
; Plays until the song ends or ESC / Q is pressed. Any other key plays a short
; sound effect on top of the music (MB_SFX demo).

        .setcpu "6502"

        .import MB_INIT, MB_PLAY, MB_POLL, MB_STOP, MB_SFX, MB_RING
        .import FILE_OPEN, STREAM_LOAD, STREAM_OPEN, STREAM_SERVICE, STREAM_STOP, STREAM_RESTART, f_skip

MODE            = $06           ; Applesoft leaves $06-$09 free
NAMELEN         = $07
NAME            = $0300         ; the file name, typed by the caller
LOOPF           = $09           ; nonzero: restart a streamed song when it ends
STR             = $EB           ; $EB-$EF are free as well
COUT            = $FDED
KEYBD           = $C000
STROBE          = $C010
KEY_ESC         = $9B
KEY_Q           = $D1
SONG            = $1000
RING_END        = $80           ; the ring is $1000-$7FFF; a frame may run on into $8000
RING_WRAP       = $70

        .segment "CODE"

start:
        lda     #0              ; auto-detect the slot
        jsr     MB_INIT
        bcc     @found
        lda     #<msg_none
        ldx     #>msg_none
        jmp     print
@found: pha
        lda     #<msg_slot
        ldx     #>msg_slot
        jsr     print
        pla
        clc
        adc     #$B0            ; slot number as a high-bit digit
        jsr     COUT
        lda     #<NAME
        ldx     #>NAME
        ldy     NAMELEN
        jsr     FILE_OPEN
        bcc     @opened
        jmp     no_file
@opened:
        lda     MODE
        bne     @stream

        lda     #<msg_load      ; load the whole song first
        ldx     #>msg_load
        jsr     print
        jsr     STREAM_LOAD
        bcs     disk_error
        jsr     play
        bcs     bad_file
        jmp     loop

@stream:
        lda     #<msg_stream
        ldx     #>msg_stream
        jsr     print
        jsr     STREAM_OPEN
        bcs     disk_error
        jsr     play
        bcs     bad_file
        lda     #RING_END
        ldx     #RING_WRAP
        jsr     MB_RING
        ; fall through

loop:   lda     #<msg_keys
        ldx     #>msg_keys
        jsr     print
        bit     STROBE
@poll:  jsr     MB_POLL
        bcs     @ended
        lda     MODE
        beq     @keys
        jsr     STREAM_SERVICE
        bcs     @stop_diskerr
@keys:  lda     KEYBD
        bpl     @poll
        bit     STROBE
        cmp     #KEY_ESC
        beq     @done
        cmp     #KEY_Q
        beq     @done
        lda     #<sfx_blip
        ldx     #>sfx_blip
        jsr     MB_SFX
        jmp     @poll
@ended: lda     MODE            ; the song ran out; a streamed one can be started again
        beq     @done
        lda     LOOPF
        beq     @done
        jsr     STREAM_RESTART
        bcs     @stop_diskerr
        jmp     @poll
@done:  jsr     MB_STOP
        jsr     STREAM_STOP     ; drive motor off
        lda     #<msg_end
        ldx     #>msg_end
        jmp     print
@stop_diskerr:
        jsr     MB_STOP
        jsr     STREAM_STOP
no_file:
        lda     #<msg_nofile
        ldx     #>msg_nofile
        jmp     print
disk_error:
        lda     #<msg_disk
        ldx     #>msg_disk
        jmp     print
bad_file:
        lda     #<msg_bad
        ldx     #>msg_bad
        jmp     print

play:   lda     f_skip          ; a binary file has a 4-byte header in front of the song
        ldx     #>SONG
        jmp     MB_PLAY

; Print the zero-terminated ASCII string at A/X
print:
        sta     STR
        stx     STR+1
        ldy     #0
@c:     lda     (STR),y
        beq     @d
        ora     #$80
        jsr     COUT
        iny
        bne     @c
@d:     rts

        .segment "RODATA"

msg_none:       .byte 13, "NO MOCKINGBOARD FOUND", 13, 0
msg_slot:       .byte 13, "MOCKINGBOARD IN SLOT ", 0
msg_load:       .byte 13, "LOADING...", 13, 0
msg_stream:     .byte 13, "STREAMING...", 13, 0
msg_keys:       .byte "ESC OR Q STOPS, ANY OTHER KEY = SFX", 13, 0
msg_bad:        .byte "NOT AN MBF1 FILE", 13, 0
msg_disk:       .byte "DISK ERROR OR SONG TOO BIG TO LOAD", 13, 0
msg_nofile:     .byte "FILE NOT FOUND", 13, 0
msg_end:        .byte "DONE", 13, 0

; A short falling blip on chip 1 channel B: period, then volume 15 down to 0
sfx_blip:
        .byte 3, $12, $A0, $13, $00, $19, $0F
        .byte 1, $19, $0C
        .byte 1, $19, $09
        .byte 1, $19, $06
        .byte 1, $19, $03
        .byte 1, $19, $00
        .byte $FF
