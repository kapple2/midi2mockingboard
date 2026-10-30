; mb_basic.s - the Applesoft command  & MPLAY ...  (ca65, plain 6502)
;
; BRUN MPLAY installs it (once, as early as you can: before the program makes any string).
; The file is loaded at $7D00; the ring and the variables sit below it (mb_layout.inc), so
; the whole player takes $6900-$89FF and nothing else: it works on a plain DOS 3.3 disk and
; on the K-HANGEUL / KBASIC disk (see ADDON_MEMORY.md).
;
;     & MPLAY "NAME"         play the .MBF file NAME from the disk catalog (streamed)
;     & MPLAY "NAME",1       the same, and start it again when it ends (a key stops it)
;     & MPLAY "NAME",2       a key other than ESC or Q plays a short blip over the music instead of
;                            stopping it (a demo of MB_SFX; the tests use it). 3 = both.
;     & MPLAY "!T120 CDEFG"  compile the tune text after the "!" and play it
; The argument can be any string expression (& MPLAY A$). It works typed at the prompt
; too: the file is read through RWTS, not with a DOS command.
;
; Playing blocks the program until the song ends or a key is pressed (the key is
; consumed). Errors are DOS's own: FILE NOT FOUND (6), I/O ERROR (8: a disk error, or
; no Mockingboard), FILE TYPE MISMATCH (13, not an MBF1 file). Any other &
; word is handed on to the routine that was on the & vector before us.
;
; Zero page: $06-$09 and $EB-$EF (free in Applesoft), $FA-$FE (the driver, only while
; playing), $5E/$5F (Applesoft's string result). Page 3: only the & vector at $03F5.

        .setcpu "6502"

        .import MB_INIT, MB_PLAY, MB_POLL, MB_STOP, MB_RING, MB_SFX
        .import FILE_OPEN, STREAM_OPEN, STREAM_SERVICE, STREAM_STOP, STREAM_RESTART, f_skip
        .import TUNE_COMPILE
        .import __RING_RUN__, __SECBUF_RUN__, __BSS_RUN__

        .include "mb_layout.inc"

; Applesoft
CHRGET          = $00B1         ; next program character (skips spaces)
CHRGOT          = $00B7         ; the current one
TXTPTR          = $00B8
INDEX           = $005E         ; FRESTR leaves the string address here
FRETOP          = $006F
HIMEMLO         = $0073
STREND          = $006D
FRMEVL          = $DD7B         ; evaluate the expression at TXTPTR
FRESTR          = $E5FD         ; string result: A = length, address in INDEX
GETBYT          = $E6F8         ; evaluate a byte expression into X
SYNCHR          = $DEC0
ERROR           = $D412
OUTOFMEM        = $4D           ; error offset of ?OUT OF MEMORY
AMPER           = $03F5         ; & jumps here: JMP routine
KEYBD           = $C000
STROBE          = $C010
KEY_ESC         = $9B
KEY_Q           = $D1
F_LOOP          = 1
F_BLIP          = 2

; DOS 3.3
DOSERR          = $A6D2         ; DOS's error routine, A = code
E_FNF           = 6             ; FILE NOT FOUND
E_IO            = 8             ; I/O ERROR
E_TYPE          = 13            ; FILE TYPE MISMATCH
MAX_NAME        = 30            ; DOS 3.3 file names are at most 30 characters

SP              = $ED           ; the string argument ($ED/$EE)

        .assert __RING_RUN__ = RING_HI * 256, error, "ring is not where mb_layout.inc says"
        .assert __SECBUF_RUN__ = TAIL_HI * 256 + $100, error, "sector buffer is not where mb_layout.inc says"
        .assert __BSS_RUN__ = TAIL_HI * 256 + $200, error, "variables are not where mb_layout.inc says"

        .segment "CODE"

; BRUN starts here (this is the first byte of the file)
install:
        ldx     #6              ; DOS 3.3 as expected? else leave & alone
@dos:   lda     dosbytes,x
        cmp     DOSERR,x
        bne     @ret
        dex
        bpl     @dos
        lda     AMPER+1         ; already ours?
        cmp     #<amper
        bne     @new
        lda     AMPER+2
        cmp     #>amper
        beq     @ret
@new:   lda     FRETOP          ; no strings yet (string top = HIMEM), program and variables
        cmp     HIMEMLO         ; end below the ring: else the block would land on them
        bne     @nomem
        lda     FRETOP+1
        cmp     HIMEMLO+1
        bne     @nomem
        cmp     #>BLOCK_END     ; HIMEM must not be below the block (KBASIC's $8A00 or higher)
        bcc     @nomem
        lda     STREND+1
        cmp     #RING_HI
        bcs     @nomem
        lda     #<BLOCK_START   ; protect the block: HIMEM and the string top move down
        sta     HIMEMLO
        sta     FRETOP
        lda     #>BLOCK_START
        sta     HIMEMLO+1
        sta     FRETOP+1
        ldx     #2
@old:   lda     AMPER,x         ; keep the previous & routine to chain to
        sta     old,x
        dex
        bpl     @old
        lda     #$4C
        sta     AMPER
        lda     #<amper
        sta     AMPER+1
        lda     #>amper
        sta     AMPER+2
@ret:   rts
@nomem: ldx     #OUTOFMEM
        jmp     ERROR

; Stop the music and the drive, then raise DOS error A. DOS's error routine expects to run
; inside DOS's own I/O hook, where the real input and output routines are in $36-$39 (DOS keeps
; them in $AA53-$AA56): put them there, or its message goes through our hook again.
fail:   pha
        jsr     MB_STOP
        lda     disk            ; the drive was only touched once FILE_OPEN had run
        beq     @s
        jsr     STREAM_STOP
@s:     pla
raise:  pha                     ; (no card: nothing was started, and MB_STOP would write to a wrong slot)
        ldx     #3
@h:     ldy     $AA53,x
        sty     $36,x
        dex
        bpl     @h
        pla
        jmp     DOSERR

; The & handler. TXTPTR is just after the &.
amper:
        lda     TXTPTR
        sta     savetp
        lda     TXTPTR+1
        sta     savetp+1
        ldx     #0
        jsr     CHRGOT          ; the character after &
@word:  cmp     word,x          ; must read MPLAY
        bne     @notmine
        inx
        jsr     CHRGET
        cpx     #5
        bcc     @word
        jsr     FRMEVL          ; TXTPTR sits on the first character of the string expression
        jsr     FRESTR          ; (a literal, or a variable such as A$)
        sta     slen
        lda     INDEX
        sta     SP
        lda     INDEX+1
        sta     SP+1
        lda     #0
        sta     loopf
        sta     disk
        jsr     CHRGOT
        cmp     #','            ; & MPLAY "NAME",1 : play it again and again
        bne     @arg
        jsr     CHRGET
        jsr     GETBYT
        stx     loopf
@arg:   lda     slen
        beq     @done           ; an empty string plays nothing
        lda     #0
        jsr     MB_INIT         ; find the card first: no point in reading the disk without one
        bcs     @nocard
        ldy     #0
        lda     (SP),y
        and     #$7F
        cmp     #'!'
        beq     @tune
        jmp     file
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
        lda     #0
        ldx     #RING_HI
        jsr     MB_PLAY
        bcs     @bad
        lda     #0              ; a compiled tune is not read from the disk
        sta     disk
        beq     run
@done:  rts
@nocard:
        lda     #E_IO           ; DOS 3.3 has no "no device" message
        jmp     raise
@bad:   lda     #E_TYPE
        jmp     fail
@notmine:
        lda     savetp          ; not ours: give the line back untouched and pass it on
        sta     TXTPTR
        lda     savetp+1
        sta     TXTPTR+1
        jmp     old

; Play the DOS file whose name is at (SP), length slen
file:   ldy     #0
@k:     cpy     slen
        bcs     @kd
        cpy     #MAX_NAME
        bcs     @kd
        lda     (SP),y
        and     #$7F
        cmp     #'a'            ; DOS names are upper case
        bcc     @up
        cmp     #'z'+1
        bcs     @up
        and     #$DF
@up:    sta     fname,y
        iny
        bne     @k
@kd:    lda     #<fname
        ldx     #>fname
        jsr     FILE_OPEN       ; Y = length of the name
        ldx     #1
        stx     disk            ; the drive and the IOB copy are in use from here on
        bcs     @nf
        jsr     STREAM_OPEN
        bcs     @io
        lda     f_skip          ; a binary file has a 4-byte header in front of the song
        ldx     #RING_HI
        jsr     MB_PLAY
        bcs     @bad
        lda     #TAIL_HI
        ldx     #RING_PAGES
        jsr     MB_RING
        lda     #1
        sta     disk
        bne     run
@nf:    lda     #E_FNF
        jmp     fail
@io:    lda     #E_IO
        jmp     fail
@bad:   lda     #E_TYPE
        jmp     fail

; Play until the song ends or a key is pressed
run:    bit     STROBE          ; forget any key pressed before
@poll:  jsr     MB_POLL
        bcs     @ended
        lda     disk
        beq     @keys
        jsr     STREAM_SERVICE
        bcs     @ioerr
@keys:  lda     KEYBD
        bpl     @poll
        bit     STROBE
        ldx     loopf
        cpx     #F_BLIP
        bcc     @stop           ; not in blip mode: any key stops
        cmp     #KEY_ESC
        beq     @stop
        cmp     #KEY_Q
        beq     @stop
        lda     #<sfx_blip
        ldx     #>sfx_blip
        jsr     MB_SFX
        jmp     @poll
@stop:  jsr     MB_STOP
        lda     disk
        beq     @out
        jsr     STREAM_STOP     ; drive motor off
@out:   rts
@ended: lda     disk            ; the song ran out; a streamed one can be started again
        beq     @stop
        lda     loopf
        and     #F_LOOP
        beq     @stop
        jsr     STREAM_RESTART
        bcs     @ioerr
        jmp     @poll
@ioerr: lda     #E_IO


        .segment "RODATA"
word:           .byte "MPLAY"
; A short falling blip on chip 1 channel B: period, then volume 15 down to 0
sfx_blip:
        .byte 3, $12, $A0, $13, $00, $19, $0F
        .byte 1, $19, $0C
        .byte 1, $19, $09
        .byte 1, $19, $06
        .byte 1, $19, $03
        .byte 1, $19, $00
        .byte $FF
dosbytes:       .byte $8D,$5C,$AA,$20,$E6,$BF,$AD     ; STA $AA5C / JSR $BFE6 / LDA $AAB6

; The ring and its tail copy: just room, filled in at run time by mb_stream.s
        .segment "RING"
ring:           .res RING_PAGES * 256
        .segment "TAIL"
tail:           .res TAIL_BYTES

        .segment "BSS"
slen:           .res 1
loopf:          .res 1          ; nonzero: start a streamed song again when it ends
disk:           .res 1          ; 1 = the song is streamed from a file, 0 = a compiled tune
savetp:         .res 2
old:            .res 3          ; the & routine we replaced (JMP address)
fname:          .res MAX_NAME
