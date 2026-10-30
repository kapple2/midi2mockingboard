; mb_layout.inc - where the resident player (MPLAY) lives in RAM (ca65 constants)
;
; The block sits just under $8A00, the lowest address any add-on of the K-HANGEUL / KBASIC
; disk uses (KBASIC is $8A00-$93FF, the Hangul driver's stubs are $9400-$95FF, DOS is $9600).
; Nothing below $4000 is touched: the Hangul font, text buffer and hi-res screen live there.
; mb_basic.cfg repeats these numbers; the .assert lines in mb_basic.s stop the link if they disagree.
; See ADDON_MEMORY.md before changing anything.
;
;   $6900-$78FF  RING     the song ring: 4 slots of 4 sectors (1 KB), refilled from the disk
;   $7900-$793F  TAIL     copy of the ring's first 64 bytes, so a frame can run over the ring end
;   $7A00-$7AFF  SECBUF   one sector for the catalog and the track/sector lists (page aligned)
;   $7B00-$7CFF  BSS      driver, streamer and tune compiler variables
;   $7D00-$89FF  CODE     BRUN MPLAY loads this much and starts at $7D00
; HIMEM and the string top are lowered to the start of the ring when MPLAY is installed.

BLOCK_START     = $6900         ; = HIMEM after BRUN MPLAY
BLOCK_END       = $8A00         ; the first byte of KBASIC (KBBASE)

RING_HI         = $69
SLOT_PAGES      = 4             ; 4 sectors = 1 KB per slot
SLOT_SHIFT      = 2             ; log2(SLOT_PAGES)
RING_SLOTS      = 4
RING_PAGES      = RING_SLOTS * SLOT_PAGES
TAIL_HI         = RING_HI + RING_PAGES
TAIL_BYTES      = 64
