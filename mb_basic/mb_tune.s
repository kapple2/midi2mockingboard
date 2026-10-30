; mb_tune.s - compile a text tune into an .MBF stream in memory (ca65, plain 6502)
;
; The same compiler as src/tune/tune2mbf.py, step for step: both must produce the same bytes
; (the tests in test/ check that). The tune format is described there. Up to 6 voices
; separated by "/"; the song is built at OUT = $6000 and is at most $1F00 bytes long.
;
;   TUNE_COMPILE   in:  A/X = low/high address of the tune text, Y = its length (0-255)
;                  out: the .MBF file at $6000, ready for MB_PLAY
; Text bytes may have the high bit set or clear, upper or lower case.
; Zero page: $06-$09 and $EB-$EE (Applesoft leaves them alone).

        .setcpu "6502"

        .export TUNE_COMPILE

TP              = $06           ; read pointer into the tune text
OP              = $08           ; write pointer into the output
CP              = $EB           ; where the current frame's count byte is
SP              = $ED           ; source text while it is copied

OUT_HI          = $60           ; output starts at $6000
LIMIT_HI        = $7F           ; stop starting new frames at $7F00
MAX_VOICES      = 6
WHOLE_120       = 100           ; ticks per whole note at 120 quarter notes a minute (50 Hz)
WHOLE_TICKS     = 12000         ; the same at 1 quarter note a minute
MIXER_TONES     = $38

        .segment "BSS"
tbuf:           .res 260        ; the text, voices separated by 0
nvoices:        .res 1
v_ptr_lo:       .res MAX_VOICES
v_ptr_hi:       .res MAX_VOICES
v_left_lo:      .res MAX_VOICES ; ticks left in the current note
v_left_hi:      .res MAX_VOICES
v_whole_lo:     .res MAX_VOICES ; ticks in a whole note (tempo)
v_whole_hi:     .res MAX_VOICES
v_gap:          .res MAX_VOICES ; 1 = the last tick of this note is silent
v_oct:          .res MAX_VOICES
v_len:          .res MAX_VOICES ; default note length
v_vol:          .res MAX_VOICES
v_done:         .res MAX_VOICES
vx:             .res 1          ; voice being processed
cb:             .res 1          ; chip << 4 of that voice
ch:             .res 1          ; its channel 0-2
cnt:            .res 1          ; register pairs in the frame so far
first:          .res 1
pval:           .res 1          ; value of the next pair
tlen:           .res 1
kc:             .res 1
kr:             .res 1
num:            .res 1
numfound:       .res 1
tmp:            .res 1
dvl:            .res 1          ; 16-bit dividend / quotient
dvh:            .res 1
drem:           .res 1
dsr:            .res 1          ; divisor
ev_lo:          .res 1          ; ticks of the event just parsed
ev_hi:          .res 1
xl:             .res 1
xh:             .res 1
per_lo:         .res 1          ; tone period of the note just parsed
per_hi:         .res 1
semi:           .res 1
accid:          .res 1          ; 0 natural, 1 sharp, 2 flat

        .segment "RODATA"
header:         .byte "MBF1", 50, 0, 0, 0
; Tone period of C0..B0 (the other octaves halve it)
base_lo:        .byte <3909, <3690, <3483, <3287, <3103, <2929, <2764, <2609, <2463, <2324, <2194, <2071
base_hi:        .byte >3909, >3690, >3483, >3287, >3103, >2929, >2764, >2609, >2463, >2324, >2194, >2071
semis:          .byte 9, 11, 0, 2, 4, 5, 7      ; A B C D E F G
limit_regs:     .byte $08, $09, $0A, $18, $19, $1A

        .segment "CODE"

TUNE_COMPILE:
        sta     SP
        stx     SP+1
        sty     tlen
        ; copy the text to tbuf: upper case, voices separated by 0
        ldx     #0
        stx     nvoices
        ldy     #0
@copy:  cpy     tlen
        beq     @cdone
        lda     (SP),y
        iny
        and     #$7F
        cmp     #'/'
        bne     @notsep
        lda     nvoices
        cmp     #MAX_VOICES-1   ; a seventh voice is ignored
        bcs     @cdone
        inc     nvoices
        lda     #0
        sta     tbuf,x
        inx
        jmp     @copy
@notsep:
        cmp     #'a'
        bcc     @store
        cmp     #'z'+1
        bcs     @store
        and     #$DF
@store: sta     tbuf,x
        inx
        jmp     @copy
@cdone: lda     #0
        sta     tbuf,x
        inc     nvoices         ; separators + 1

        ; each voice's start in tbuf
        ldx     #0
        ldy     #0
@vp:    tya
        clc
        adc     #<tbuf
        sta     v_ptr_lo,x
        lda     #>tbuf
        adc     #0
        sta     v_ptr_hi,x
@find:  lda     tbuf,y
        beq     @found
        iny
        bne     @find
@found: iny
        inx
        cpx     nvoices
        bcc     @vp

        ; voice state: T120 L4 O4 V12
        ldx     #0
@iv:    lda     #4
        sta     v_oct,x
        sta     v_len,x
        lda     #12
        sta     v_vol,x
        lda     #<WHOLE_120
        sta     v_whole_lo,x
        lda     #>WHOLE_120
        sta     v_whole_hi,x
        lda     #0
        sta     v_left_lo,x
        sta     v_left_hi,x
        sta     v_gap,x
        sta     v_done,x
        inx
        cpx     nvoices
        bcc     @iv

        lda     #0
        sta     OP
        lda     #OUT_HI
        sta     OP+1
        ldx     #0
@hd:    lda     header,x
        jsr     put
        inx
        cpx     #8
        bcc     @hd

        lda     #1
        sta     first
@tick:  lda     OP+1
        cmp     #LIMIT_HI
        bcs     @limit
        lda     OP              ; remember where this frame's count byte goes
        sta     CP
        lda     OP+1
        sta     CP+1
        lda     #0
        jsr     put
        sta     cnt
        lda     first
        beq     @voices
        lda     #0
        sta     first
        jsr     keyframe
@voices:
        ldx     #0
@vt:    cpx     nvoices
        bcs     @tdone
        lda     v_done,x
        bne     @vnext
        stx     vx
        jsr     voice_tick
        ldx     vx
@vnext: inx
        jmp     @vt
@tdone: ldy     #0
        lda     cnt
        sta     (CP),y
        ldx     #0
@ad:    cpx     nvoices         ; stop when every voice is done
        bcs     @finish
        lda     v_done,x
        beq     @again
        inx
        jmp     @ad
@again: jmp     @tick
@limit: lda     #6              ; too long: silence everything and stop
        jsr     put
        ldx     #0
@lm:    lda     limit_regs,x
        jsr     put
        lda     #0
        jsr     put
        inx
        cpx     #6
        bcc     @lm
@finish:
        lda     #$FF
        ; fall through

; Write A at OP and step it. Uses Y.
put:
        ldy     #0
        sta     (OP),y
        inc     OP
        bne     @r
        inc     OP+1
@r:     rts

; Add the pair (A = chip << 4 | register, pval = value) to the frame.
pair:
        jsr     put
        lda     pval
        jsr     put
        inc     cnt
        rts

; Volume register of the current voice = A.
emit_vol:
        sta     pval
        lda     ch
        clc
        adc     #8
        ora     cb
        jmp     pair

; The first frame sets every register of both chips: tones off, mixer = tones only.
keyframe:
        lda     #0
        sta     kc
@chip:  lda     #0
        sta     kr
@reg:   lda     kr
        cmp     #7
        bne     @zero
        lda     #MIXER_TONES
        jmp     @st
@zero:  lda     #0
@st:    sta     pval
        lda     kc
        ora     kr
        jsr     pair
        inc     kr
        lda     kr
        cmp     #11
        bcc     @reg
        lda     kc
        clc
        adc     #$10
        sta     kc
        cmp     #$20
        bcc     @chip
        rts

; One tick of voice vx: start the next note or rest when the last one has run out.
voice_tick:
        ldx     vx
        lda     #0
        sta     cb
        txa
        cmp     #3
        bcc     @chip0
        lda     #$10
        sta     cb
        txa
        sec
        sbc     #3
@chip0: sta     ch
        lda     v_left_lo,x
        ora     v_left_hi,x
        bne     @running
        jsr     next_event
        ldx     vx
        cmp     #0
        bne     @ev
        lda     #1              ; the voice has ended
        sta     v_done,x
        lda     #0
        jmp     emit_vol
@ev:    cmp     #1
        bne     @rest
        lda     per_lo          ; a note: period low, period high, volume
        sta     pval
        lda     ch
        asl
        ora     cb
        jsr     pair
        lda     per_hi
        sta     pval
        lda     ch
        asl
        ora     cb
        ora     #1
        jsr     pair
        ldx     vx
        lda     v_vol,x
        jsr     emit_vol
        ldx     vx
        lda     ev_hi           ; the last tick of notes of 3 ticks or more is silent
        bne     @g1
        lda     ev_lo
        cmp     #3
        bcc     @g0
@g1:    lda     #1
        bne     @gs
@g0:    lda     #0
@gs:    sta     v_gap,x
        jmp     @setleft
@rest:  lda     #0
        jsr     emit_vol
        ldx     vx
        lda     #0
        sta     v_gap,x
@setleft:
        ldx     vx
        lda     ev_lo
        sta     v_left_lo,x
        lda     ev_hi
        sta     v_left_hi,x
        jmp     @dec
@running:
        lda     v_left_hi,x
        bne     @dec
        lda     v_left_lo,x
        cmp     #1
        bne     @dec
        lda     v_gap,x
        beq     @dec
        lda     #0
        jsr     emit_vol
@dec:   ldx     vx
        lda     v_left_lo,x
        bne     @d1
        dec     v_left_hi,x
@d1:    dec     v_left_lo,x
        rts

; Parse the voice's text up to its next note or rest.
; out: A = 0 end of voice, 1 note (per_lo/hi, ev_lo/hi), 2 rest (ev_lo/hi)
next_event:
        ldx     vx
        lda     v_ptr_lo,x
        sta     TP
        lda     v_ptr_hi,x
        sta     TP+1
@loop:  ldy     #0
        lda     (TP),y
        bne     @have
        jsr     save_ptr        ; end of the voice: the pointer stays on the terminator
        lda     #0
        rts
@have:  jsr     adv
        cmp     #'A'
        bcc     @cmd
        cmp     #'H'
        bcs     @cmd
        sec                     ; a note A-G
        sbc     #'A'
        tax
        lda     semis,x
        sta     semi
        lda     #0
        sta     accid
        ldy     #0
        lda     (TP),y
        cmp     #'#'
        beq     @sharp
        cmp     #'+'
        beq     @sharp
        cmp     #'-'
        bne     @accdone
        lda     #2
        sta     accid
        jsr     adv
        jmp     @accdone
@sharp: lda     #1
        sta     accid
        jsr     adv
@accdone:
        jsr     get_ticks
        jsr     calc_period
        jsr     save_ptr
        lda     #1
        rts
@cmd:   cmp     #'R'
        bne     @cl
        jsr     get_ticks
        jsr     save_ptr
        lda     #2
        rts
@cl:    cmp     #'L'
        bne     @co
        jsr     parse_num
        bcc     @loop
        jsr     clamp_len
        ldx     vx
        sta     v_len,x
        jmp     @loop
@co:    cmp     #'O'
        bne     @ct
        jsr     parse_num
        bcc     @loop
        cmp     #8
        bcc     @oset
        lda     #7
@oset:  ldx     vx
        sta     v_oct,x
@j1:    jmp     @loop
@ct:    cmp     #'T'
        bne     @cv
        jsr     parse_num
        bcc     @j1
        cmp     #32
        bcs     @tset
        lda     #32
@tset:  sta     dsr
        lda     #<WHOLE_TICKS
        sta     dvl
        lda     #>WHOLE_TICKS
        sta     dvh
        jsr     div16by8
        ldx     vx
        lda     dvl
        sta     v_whole_lo,x
        lda     dvh
        sta     v_whole_hi,x
@j2:    jmp     @loop
@cv:    cmp     #'V'
        bne     @cdn
        jsr     parse_num
        bcc     @j2
        cmp     #16
        bcc     @vset
        lda     #15
@vset:  ldx     vx
        sta     v_vol,x
@j3:    jmp     @loop
@cdn:   cmp     #'<'
        bne     @cup
        ldx     vx
        lda     v_oct,x
        beq     @j3
        dec     v_oct,x
@j4:    jmp     @loop
@cup:   cmp     #'>'
        bne     @j4             ; anything else is ignored
        ldx     vx
        lda     v_oct,x
        cmp     #7
        bcs     @j4
        inc     v_oct,x
        jmp     @loop

; Store the read pointer back into the voice.
save_ptr:
        ldx     vx
        lda     TP
        sta     v_ptr_lo,x
        lda     TP+1
        sta     v_ptr_hi,x
        rts

; Step the read pointer (keeps A and Y).
adv:    inc     TP
        bne     @r
        inc     TP+1
@r:     rts

; Read a decimal number at TP. C set = found, A = the value (8 bits, wrapping).
parse_num:
        lda     #0
        sta     num
        sta     numfound
@d:     ldy     #0
        lda     (TP),y
        sec
        sbc     #'0'
        cmp     #10
        bcs     @done
        pha
        lda     num             ; num = num * 10 + digit
        asl
        sta     tmp
        asl
        asl
        clc
        adc     tmp
        sta     num
        pla
        clc
        adc     num
        sta     num
        inc     numfound
        jsr     adv
        jmp     @d
@done:  lda     numfound
        cmp     #1              ; C set if any digit was read
        lda     num
        rts

; A -> 1..64
clamp_len:
        cmp     #0
        bne     @nz
        lda     #1
@nz:    cmp     #65
        bcc     @ok
        lda     #64
@ok:    rts

; Note or rest length in ticks (number or the default, then dots) -> ev_lo/ev_hi
get_ticks:
        jsr     parse_num
        bcs     @have
        ldx     vx
        lda     v_len,x
@have:  jsr     clamp_len
        sta     dsr
        ldx     vx
        lda     v_whole_lo,x
        sta     dvl
        lda     v_whole_hi,x
        sta     dvh
        jsr     div16by8
        lda     dvl
        ora     dvh
        bne     @t
        lda     #1
        sta     dvl
@t:     lda     dvl
        sta     ev_lo
        sta     xl
        lda     dvh
        sta     ev_hi
        sta     xh
@dots:  ldy     #0
        lda     (TP),y
        cmp     #'.'
        bne     @done
        jsr     adv
        lsr     xh              ; a dot adds half of the last addition
        ror     xl
        lda     ev_lo
        clc
        adc     xl
        sta     ev_lo
        lda     ev_hi
        adc     xh
        sta     ev_hi
        jmp     @dots
@done:  rts

; dvl/dvh = dvl/dvh / dsr (1-255)
div16by8:
        lda     #0
        sta     drem
        ldx     #16
@l:     asl     dvl
        rol     dvh
        rol     drem
        bcs     @sub            ; the remainder overflowed 8 bits, so it is >= dsr
        lda     drem
        cmp     dsr
        bcc     @n
@sub:   lda     drem
        sec
        sbc     dsr
        sta     drem
        inc     dvl
@n:     dex
        bne     @l
        rts

; Tone period of the note: octave v_oct, semitone semi, accidental accid -> per_lo/per_hi
calc_period:
        ldx     vx
        lda     v_oct,x
        tax
        lda     #0
@m:     cpx     #0
        beq     @md
        clc
        adc     #12
        dex
        jmp     @m
@md:    clc
        adc     semi
        ldx     accid
        cpx     #1
        bne     @nf
        clc
        adc     #1
        jmp     @split
@nf:    cpx     #2
        bne     @split
        cmp     #0
        beq     @split          ; a flat C0 stays C0
        sec
        sbc     #1
@split: ldx     #0              ; X = n div 12 (octave), A = n mod 12
@dv:    cmp     #12
        bcc     @dd
        sbc     #12
        inx
        jmp     @dv
@dd:    tay
        lda     base_lo,y
        sta     per_lo
        lda     base_hi,y
        sta     per_hi
        cpx     #0
        beq     @done
@sh:    lsr     per_hi          ; halve once per octave; the last bit shifted out rounds up
        ror     per_lo
        dex
        bne     @sh
        lda     per_lo
        adc     #0
        sta     per_lo
        lda     per_hi
        adc     #0
        sta     per_hi
@done:  rts
