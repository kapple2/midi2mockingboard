; mb_basic.s - the Applesoft command  & MPLAY "..."  (ca65, plain 6502)
;
; Load at $8C00 (BLOAD MPLAY) and install with CALL 35840. Set HIMEM: 24576 first: the
; song is built or loaded at $6000-$80FF, and the code and variables sit above that.
;
;     & MPLAY "NAME"          BLOAD the .MBF file NAME into $6000 and play it
;     & MPLAY "!T120 CDEFG"   compile the tune text after the "!" and play it
; The argument can be any string expression (& MPLAY A$). A DOS file name needs the
; command inside a program, not typed as a direct command (DOS reuses the input buffer).
;
; Playing blocks the program until the song ends or a key is pressed (the key is
; consumed). The tune format is described in src/tune/tune2mbf.py.

        .setcpu "6502"

        .import MB_INIT, MB_PLAY, MB_POLL, MB_STOP
        .import TUNE_COMPILE

CHRGET          = $00B1         ; Applesoft: next program character (skips spaces)
CHRGOT          = $00B7         ; the current one
FRMEVL          = $DD7B         ; evaluate the expression at TXTPTR
GETSTR          = $E5FD         ; string result: A = length, X/Y = address
SYNERR          = $DEC9
COUT            = $FDED
AMPER           = $03F5         ; & jumps here: JMP routine
KEYBD           = $C000
STROBE          = $C010
OUT             = $6000
MAX_NAME        = 30            ; DOS 3.3 file names are at most 30 characters

TP              = $06           ; message pointer (the tune compiler is idle then)
SP              = $ED           ; the string argument

        .segment "CODE"

; CALL 35840: point the & vector at us
install:
        lda     #$4C
        sta     AMPER
        lda     #<amper
        sta     AMPER+1
        lda     #>amper
        sta     AMPER+2
        rts

amper:
        ldx     #0
        jsr     CHRGOT          ; the character after &
@name:  cmp     name,x          ; must read MPLAY
        bne     @syntax
        inx
        jsr     CHRGET
        cpx     #5
        bcc     @name
        jsr     FRMEVL          ; TXTPTR sits on the first character of the string expression
        jsr     GETSTR          ; (a literal, or a variable such as A$)
        stx     SP
        sty     SP+1
        sta     slen
        beq     @done           ; an empty string plays nothing
        ldy     #0
        lda     (SP),y
        and     #$7F
        cmp     #'!'
        beq     @tune
        jsr     load_file
        jmp     @play
@tune:  lda     SP              ; the text after the "!"
        clc
        adc     #1
        pha
        lda     SP+1
        adc     #0
        tax
        pla
        ldy     slen
        dey
        jsr     TUNE_COMPILE
@play:  jsr     play
@done:  rts
@syntax:
        jmp     SYNERR

; BLOAD <name>,A$6000 through DOS, as if the program had printed CHR$(4);"BLOAD ..."
load_file:
        ldy     #0              ; keep the name: in immediate mode it lives in the input
@k:     cpy     slen            ; buffer, which DOS is about to use for its command
        bcs     @kd
        cpy     #MAX_NAME
        bcs     @kd
        lda     (SP),y
        ora     #$80
        sta     fname,y
        iny
        bne     @k
@kd:    sty     nlen
        lda     #$8D            ; a return first, so the Ctrl-D starts a line
        jsr     COUT
        lda     #$84
        jsr     COUT
        ldx     #0
        stx     ci
@a:     ldx     ci
        lda     bload_txt,x
        beq     @name
        jsr     COUT
        inc     ci
        bne     @a
@name:  lda     #0
        sta     ci
@n:     ldx     ci
        cpx     nlen
        bcs     @addr
        lda     fname,x
        jsr     COUT
        inc     ci
        bne     @n
@addr:  lda     #0
        sta     ci
@b:     ldx     ci
        lda     addr_txt,x
        beq     @end
        jsr     COUT
        inc     ci
        bne     @b
@end:   lda     #$8D
        jmp     COUT

; Play the song at $6000 until it ends or a key is pressed.
play:
        lda     #0
        jsr     MB_INIT
        bcs     @nocard
        lda     #<OUT
        ldx     #>OUT
        jsr     MB_PLAY
        bcs     @bad
        bit     STROBE
@poll:  jsr     MB_POLL
        bcs     @done
        lda     KEYBD
        bpl     @poll
        bit     STROBE
        jsr     MB_STOP
@done:  rts
@nocard:
        lda     #<msg_none
        ldx     #>msg_none
        jmp     print
@bad:   lda     #<msg_bad
        ldx     #>msg_bad
        ; fall through

; Print the zero-terminated ASCII string at A/X
print:
        sta     TP
        stx     TP+1
        ldy     #0
        sty     ci
@c:     ldy     ci
        lda     (TP),y
        beq     @d
        ora     #$80
        jsr     COUT
        inc     ci
        bne     @c
@d:     rts

        .segment "BSS"
slen:           .res 1
ci:             .res 1
nlen:           .res 1
fname:          .res MAX_NAME

        .segment "RODATA"
name:           .byte "MPLAY"
bload_txt:      .byte $C2, $CC, $CF, $C1, $C4, $A0, 0                           ; "BLOAD "
addr_txt:       .byte $AC, $C1, $A4, $B6, $B0, $B0, $B0, 0                      ; ",A$6000"
msg_none:       .byte "NO MOCKINGBOARD FOUND", 13, 0
msg_bad:        .byte "NOT AN MBF1 FILE", 13, 0
