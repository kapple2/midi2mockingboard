; mb_layout.inc - where the resident player (MPLAY) lives in RAM (ca65 constants)
;
; The block sits just under $8A00, the lowest address any add-on of the K-HANGEUL / KBASIC
; disk uses (KBASIC is $8A00-$93FF, the Hangul driver's stubs are $9400-$95FF, DOS is $9600).
; Nothing below $4000 is touched: the Hangul font, text buffer and hi-res screen live there.
; mb_basic.cfg repeats these numbers; the .assert lines in mb_basic.s stop the link if they disagree.
; See ADDON_MEMORY.md before changing anything.
;
;   (ring_hi)-$78FF  RING     the song ring, refilled from the disk: SLOT_PAGES pages per slot, as many slots as
;                             `& MPLAY n` asks for (DEFAULT_SLOTS at BRUN time). It ends at TAIL_HI and grows
;                             downwards, so nothing else moves when its size changes. It is not part of the file.
;   $7900-$793F  TAIL     copy of the ring's first 64 bytes, so a frame can run over the ring end
;   $7A00-$7AFF  SECBUF   one sector for the catalog and the track/sector lists (page aligned)
;   $7B00-$7CFF  BSS      driver, streamer and tune compiler variables
;   $7D00-$89FF  CODE     BRUN MPLAY loads this much and starts at $7D00
; HIMEM and the string top are lowered to the start of the ring when MPLAY is installed (and again
; when `& MPLAY n` changes the ring).

BLOCK_END       = $8A00         ; the first byte of KBASIC (KBBASE)

SLOT_PAGES      = 2             ; 2 sectors = 512 bytes per slot
SLOT_SHIFT      = 1             ; log2(SLOT_PAGES)
DEFAULT_SLOTS   = 4             ; the ring after BRUN MPLAY: 4 slots = 2 KB
MIN_SLOTS       = 2             ; the music plays one slot while the other is refilled
MAX_SLOTS       = 28            ; 14 KB: the ring then starts at $4100, the lowest page above BASIC's start ($4001);
                                ; the memory checks (variables must end below the ring) decide what fits
TAIL_HI         = $79           ; the ring ends here and the tail copy follows
TAIL_BYTES      = 64
DEFAULT_RING_HI = TAIL_HI - DEFAULT_SLOTS * SLOT_PAGES      ; $71
