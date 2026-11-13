# Build mp2inc.bin, the 68030 player, together with decoder.dsp, the
# DSP56001 MPEG audio layer 2 decoder it includes, using the host
# tools asm56000, cldlod, lod2p56 and vasmm68k_mot.

ASM56000 = asm56000
CLDLOD   = cldlod
LOD2P56  = lod2p56
VASM     = vasmm68k_mot

all: mp2inc.bin

mp2inc.bin: mp2inc.s decoder.dsp
	$(VASM) -Ftos -m68030 -m68882 -nosym -quiet -o $@ $<

decoder.cld: decoder.asm equates.asm
	$(ASM56000) -A -B$@ $<

decoder.lod: decoder.cld
	$(CLDLOD) $< > $@

decoder.dsp: decoder.lod
	$(LOD2P56) $< $@

clean:
	rm -f decoder.cld decoder.lod decoder.dsp mp2inc.bin

.PHONY: all clean
.INTERMEDIATE: decoder.cld decoder.lod
.DELETE_ON_ERROR:
