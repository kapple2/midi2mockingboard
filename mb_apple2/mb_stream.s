; mb_stream.s - read a song from a DOS 3.3 file with the RWTS (ca65, 6502)
;
; The song is an ordinary DOS file in the catalog (CATALOG lists it). FILE_OPEN finds it by
; name, then the sectors are read one by one from the file's track/sector list, straight
; through DOS's own RWTS routine, so the whole file never has to be in RAM and a song may be
; as big as the disk. A binary (type B) file has a 4-byte header (address, length) in front
; of the data; FILE_OPEN tells the caller how many bytes to skip (0 or 4).
; The builder (build_disk.py) stores the sectors in the order 0,14,13,...,8,7,6,...,1,15 on
; each track, which asks the drive for the physical sectors 0,2,4,...,14,1,3,...,15, so each
; read starts about two sector times after the last one ended and a track of 16 sectors
; takes about two disk revolutions instead of sixteen.
;
; The song is always streamed: STREAM_OPEN fills a ring of RING_SLOTS slots (mb_layout.inc: 4 slots of
; 4 sectors) and STREAM_SERVICE keeps it filled from the main loop. A song that fits the ring is
; read once and never touched again. A disk read stops the CPU, so each refill pauses the music
; (MB_PAUSE / MB_RESUME) for as long as the sectors take.
; The ring needs a 64-byte copy of the first slot's start right behind it (TAIL_HI), so that a
; frame running over the end of the last slot reads on into the start of the first one.
; Needs DOS 3.3 in memory (RWTS at $03D9; slot, drive and device table are copied from
; DOS's own IOB, found with LOCRPL at $03E3).

        .setcpu "6502"

        .import MB_POS, MB_PAUSE, MB_RESUME, MB_TICK, MB_PLAY, MB_RING
        .export FILE_OPEN, STREAM_OPEN, STREAM_SERVICE, STREAM_STOP, STREAM_RESTART
        .export f_skip

RWTS            = $03D9
LOCRPL          = $03E3         ; DOS 3.3: returns the address of its own IOB in Y (low) / A (high)
MOTOR_OFF       = $C088         ; + slot * 16
MOTOR_ON        = $C089
SPINUP_TICKS    = 64            ; keep playing this long after switching the drive on (1.3 s at 50 Hz)

; IOB layout
IOB_SIZE        = 17
IOB_SLOT        = 1             ; slot * 16
IOB_DRIVE       = 2
IOB_VOLUME      = 3
IOB_TRACK       = 4
IOB_SECTOR      = 5
IOB_BUF         = 8             ; buffer address, low then high byte
IOB_COUNT       = 10            ; byte count, low then high byte ($0100 = a full sector)
IOB_CMD         = 12            ; 1 = read
IOB_ERROR       = 13
IOB_PREV_SLOT   = 15
IOB_PREV_DRIVE  = 16

; DOS 3.3 disk layout
VTOC_TRACK      = 17            ; the VTOC is sector 0 of track 17; its bytes 1, 2 start the catalog chain
ENTRY_FIRST     = 11            ; offset of the first file entry in a catalog sector
ENTRY_SIZE      = 35
ENTRY_NAME      = 3             ; 30 characters, high bit set, padded with $A0
NAME_BYTES      = 30
TYPE_BINARY     = $04
BIN_HEADER      = 4
LIST_FIRST      = 12            ; offset of the first track/sector pair in a track/sector list
LIST_PAIRS      = 122

        .include "mb_layout.inc"

NAMEPTR         = $EB           ; $EB/$EC: the name being looked up (free in Applesoft)
IOBPTR          = $ED           ; $ED/$EE: DOS's IOB, only inside FILE_OPEN

        .segment "BSS"
iob:            .res IOB_SIZE
dosiob:         .res IOB_SIZE   ; copy of DOS's IOB: the slot, drive and device table to use
nlen:           .res 1          ; length of the file name
ebase:          .res 1          ; catalog entry being compared
kk:             .res 1
tmp:            .res 1
f_tl:           .res 1          ; the file's first track/sector list
f_ts:           .res 1
f_skip:         .res 1          ; bytes of header in front of the song data (0 or 4)
ts_j:           .res 1          ; next pair to use in the list now in secbuf
eof:            .res 1          ; 1 when the file has no more sectors
nsec:           .res 1          ; sectors read into the slot being filled
dest_hi:        .res 1
fill_slot:      .res 1
st_wait:        .res 1          ; 1 while the drive is spinning up for a refill
st_tick:        .res 1          ; MB_TICK when the drive was switched on

; one sector for the catalog and the track/sector lists; page aligned so RWTS gets a whole page
        .segment "SECBUF"
secbuf:         .res 256

        .segment "CODE"

; A/X = address of the file name (ASCII), Y = its length (1-30). Looks it up in the catalog.
; C set = not found or disk error. C clear: A = bytes to skip at the start of the data.
FILE_OPEN:
        sta     NAMEPTR
        stx     NAMEPTR+1
        sty     nlen
        jsr     LOCRPL          ; the disk DOS used last: remember its IOB
        sty     IOBPTR
        sta     IOBPTR+1
        ldy     #IOB_SIZE - 1
@iob:   lda     (IOBPTR),y
        sta     dosiob,y
        dey
        bpl     @iob
        lda     #VTOC_TRACK
        ldx     #0
        jsr     read_secbuf
        bcc     @vtoc
        rts
@vtoc: ldx     secbuf+2        ; first catalog sector
        lda     secbuf+1
@sector:
        bne     @more
        jmp     @nf             ; track 0: end of the chain
@more:
        jsr     read_secbuf
        bcc     @cat
        rts
@cat:
        ldy     #ENTRY_FIRST
@entry: sty     ebase
        lda     secbuf,y
        beq     @skip           ; never used
        cmp     #$FF
        beq     @skip           ; deleted
        lda     #0
        sta     kk
@cmp:   lda     ebase
        clc
        adc     #ENTRY_NAME
        adc     kk
        tay
        lda     secbuf,y
        sta     tmp             ; the catalog's character
        ldy     kk
        cpy     nlen
        bcs     @pad
        lda     (NAMEPTR),y
        ora     #$80
        bne     @have
@pad:   lda     #$A0
@have:  cmp     tmp
        bne     @skip
        inc     kk
        lda     kk
        cmp     #NAME_BYTES
        bcc     @cmp
        ldy     ebase           ; found
        lda     secbuf,y
        sta     f_tl
        lda     secbuf+1,y
        sta     f_ts
        lda     secbuf+2,y
        and     #$7F
        ldx     #0
        cmp     #TYPE_BINARY
        bne     @store
        ldx     #BIN_HEADER
@store: stx     f_skip
        txa
        clc
        rts
@skip:  lda     ebase
        clc
        adc     #ENTRY_SIZE
        bcs     @next           ; ran off the end of the sector: 7 entries done
        tay
        jmp     @entry
@next:  ldx     secbuf+2        ; next catalog sector
        lda     secbuf+1
        jmp     @sector
@nf:    sec
@ret:   rts

; Fill the ring (RING_SLOTS slots) from the open file. C set = disk error.
; The drive keeps spinning afterwards; call STREAM_STOP when the song is over.
STREAM_OPEN:
        jsr     rewind
        bcs     @err
        lda     #0
        sta     fill_slot
        sta     st_wait
@fill:  lda     eof
        bne     @done
        jsr     fill_one
        bcs     @err
        lda     fill_slot
        bne     @fill           ; fill_slot wraps to 0 after the last slot
@done:  clc
@err:   rts                     ; the motor keeps running: spinning it up again costs about a second

; Play the streamed song again from the start, e.g. when MB_POLL reports that it has ended:
; refill the ring from the file's start (the music is silent meanwhile), then start the song with MB_PLAY and MB_RING. Needs a FILE_OPEN first.
; C set = disk error or not an MBF file. Keep calling STREAM_SERVICE as before.
STREAM_RESTART:
        jsr     STREAM_OPEN
        bcs     @ret
        lda     f_skip
        ldx     #RING_HI
        jsr     MB_PLAY
        bcs     @ret
        lda     #TAIL_HI
        ldx     #RING_PAGES
        jsr     MB_RING
        clc
@ret:   rts

; Call from the main loop. When the music has moved on from a slot, refill it with the
; next SLOT_PAGES sectors. A refill is not urgent (the ring holds several slots ahead), so first the
; drive is switched on and the music plays on for SPINUP_TICKS while it spins up; the
; read itself then pauses the music while the sectors come in. C set = disk error.
STREAM_SERVICE:
        lda     eof
        bne     @none
        lda     st_wait
        bne     @waiting
        jsr     MB_POS
        cmp     #TAIL_HI
        bcc     @inring
        lda     #RING_HI        ; reading the tail copy: the slot is slot 0
@inring:
        sec
        sbc     #RING_HI
        .repeat SLOT_SHIFT
        lsr
        .endrepeat              ; A = slot the music is in
        cmp     fill_slot
        beq     @none           ; that slot is still being played
        ldx     dosiob+IOB_SLOT
        lda     MOTOR_ON,x      ; start the drive; RWTS would otherwise wait a second for it
        jsr     MB_TICK
        sta     st_tick
        lda     #1
        sta     st_wait
        clc
        rts
@waiting:
        jsr     MB_TICK
        sec
        sbc     st_tick
        cmp     #SPINUP_TICKS
        bcc     @none           ; still spinning up; the music keeps playing
        lda     #0
        sta     st_wait
        jsr     MB_PAUSE
        jsr     fill_one
        php
        jsr     MB_RESUME
        plp
        rts
@none:  clc
        rts

; Read the next sectors into ring slot `fill_slot`, then advance. C set = disk error.
fill_one:
        lda     fill_slot
        .repeat SLOT_SHIFT
        asl
        .endrepeat              ; slot * SLOT_PAGES
        clc
        adc     #RING_HI
        sta     dest_hi
        jsr     read_slot
        bcs     @ret
        lda     fill_slot
        bne     @notfirst
        ldy     #TAIL_BYTES - 1 ; keep the tail copy of slot 0's start current
@t:     lda     RING_HI * 256,y
        sta     TAIL_HI * 256,y
        dey
        bpl     @t
@notfirst:
        inc     fill_slot
        lda     fill_slot
        cmp     #RING_SLOTS
        bcc     @ok
        lda     #0
        sta     fill_slot
@ok:    clc
@ret:   rts

; Go back to the start of the open file: read its first track/sector list.
rewind:
        lda     #0
        sta     eof
        sta     ts_j
        lda     f_tl
        ldx     f_ts
        jmp     read_secbuf

; The next data sector of the file: C clear, A = track, X = sector. C set: A = 0 at the end of
; the file, A = 1 for a disk error. Reads the next track/sector list when this one is used up.
next_sector:
        lda     eof
        bne     @end
        ldy     ts_j
        cpy     #LIST_PAIRS
        bcc     @have
        lda     secbuf+1        ; link to the next list
        beq     @seteof
        ldx     secbuf+2
        jsr     read_secbuf
        bcs     @fail
        ldy     #0
        sty     ts_j
@have:  tya
        asl
        tay
        lda     secbuf+LIST_FIRST,y
        beq     @seteof         ; track 0: no more sectors
        ldx     secbuf+LIST_FIRST+1,y
        inc     ts_j
        clc
        rts
@seteof:
        lda     #1
        sta     eof
@end:   lda     #0
        sec
        rts
@fail:  lda     #1
        sec
        rts

; Read the next SLOT_PAGES sectors of the file (fewer at the end) into pages dest_hi and up.
read_slot:
        lda     #0
        sta     nsec
@loop:  jsr     next_sector
        bcs     @stop
        sta     tmp
        lda     dest_hi
        clc
        adc     nsec
        tay
        lda     tmp
        jsr     rw_sector
        bcs     @ret
        inc     nsec
        lda     nsec
        cmp     #SLOT_PAGES
        bcc     @loop
        clc
        rts
@stop:  cmp     #1              ; A = 0 end of the file, 1 disk error
        beq     @fail
        clc
        rts
@fail:  sec
@ret:   rts

; Read track A, sector X of the disk into secbuf.
read_secbuf:
        ldy     #>secbuf

; Read track A, sector X into page Y. C set = disk error.
rw_sector:
        sta     tmp
        stx     nsec_x
        sty     buf_y
        jsr     init_iob
        lda     tmp
        sta     iob+IOB_TRACK
        lda     nsec_x
        sta     iob+IOB_SECTOR
        lda     buf_y
        sta     iob+IOB_BUF+1
        ldy     #<iob           ; RWTS wants the low byte in Y and the high byte in A
        lda     #>iob
        jmp     RWTS

; Start from a copy of DOS's own IOB (slot, drive, device table), set up for a read.
init_iob:
        ldy     #IOB_SIZE - 1
@c:     lda     dosiob,y
        sta     iob,y
        dey
        bpl     @c
        lda     #0
        sta     iob+IOB_VOLUME  ; any volume
        sta     iob+IOB_BUF     ; buffer low byte: whole pages
        sta     iob+IOB_COUNT   ; byte count $0100: a full sector
        sta     iob+IOB_ERROR
        lda     iob+IOB_SLOT            ; DOS leaves "previous slot" at 0 after a command, and RWTS
        sta     iob+IOB_PREV_SLOT       ; would then wait for slot 0's "drive" to stop spinning
        lda     iob+IOB_DRIVE           ; (forever: that is the language card). Same drive as last time.
        sta     iob+IOB_PREV_DRIVE
        lda     #1
        sta     iob+IOB_COUNT+1
        sta     iob+IOB_CMD     ; command: read
        rts

; Turn the drive motor off. Call when a streamed song ends .
STREAM_STOP:
motor_off:
        ldx     dosiob+IOB_SLOT
        lda     MOTOR_OFF,x
        rts

        .segment "BSS"
nsec_x:         .res 1
buf_y:          .res 1
