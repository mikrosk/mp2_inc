RPC_AVAILABLE	equ	-10		; decoder rpc 9, sent as -(9+1)
HC_FREE		equ	$80|($24/2)	; host command: free words in the ring
FEED_MAX	equ	384		; 384 kbit/s, 44.1 kHz replayed at 49170 Hz
ANSWER_POLLS	equ	256		; HC_FREE answer, in mp2_feed
START_POLLS	equ	65535		; HC_FREE answer, the DSP initialising
TXDE_POLLS	equ	64		; host port ready for the next word

mp2_address	ds.l	1
mp2_length	ds.l	1
mp2_frequency	ds.l	1
mp2_external	ds.l	1
mp2_repeat	ds.l	1
mp2_start	bra.w	start_all
mp2_stop	bra.w	stop_all
mp2_add_available	bra.w	add_available
mp2_stream_available	bra.w	stream_available
mp2_feed	bra.w	feed
mp2_feedmax	ds.l	1		; words per mp2_feed, 0 = FEED_MAX
mp2_input	ds.l	1		; 0 = sound DMA, 1 = host port

start_all
	movem.l	d0-a6,-(sp)
	bsr	saveaudio
	bsr	mute
	bsr	set_matrix
	tst.l	mp2_input(pc)
	beq.s	.dma
	andi.w	#$ff7f,$ffff8932.w	; DSP receive off the matrix
.dma
	bsr	dsp_load_program
	bsr	initialize_program
	bsr	unmute
	tst.l	mp2_input(pc)
	bne.s	.out
	bsr	play
.out	movem.l	(sp)+,d0-a6
	rts
	
stop_all
	movem.l	d0-a6,-(sp)
	lea	playing(pc),a0
	clr.w	(a0)
	bsr	restoreaudio
	bsr	dsp_reset
	movem.l	(sp)+,d0-a6
	rts

;
; Streaming: d0.l more bytes of the stream follow in the buffer.
;
add_available
	tst.l	mp2_input(pc)
	bne.s	.host
	move.l	d0,-(sp)
	lsr.l	#1,d0			; in 16-bit words
.wait	btst	#1,$ffffa202.w
	beq.s	.wait
	move.l	d0,$ffffa204.w
	move.l	(sp)+,d0
	rts
.host	move.l	a0,-(sp)
	lea	unsent(pc),a0
	add.l	d0,(a0)
	movea.l	(sp)+,a0
	rts

;
; Streaming: d0.l = bytes of the stream the decoder has not read yet,
; negative while it waits for more; from the host port, the bytes of
; the buffer that mp2_feed has not sent yet.
;
stream_available
	tst.l	mp2_input(pc)
	bne.s	.host
.send	btst	#1,$ffffa202.w
	beq.s	.send
	move.l	#RPC_AVAILABLE,$ffffa204.w
.receive	btst	#0,$ffffa202.w
	beq.s	.receive
	move.l	$ffffa204.w,d0
	lsl.l	#8,d0
	asr.l	#7,d0			; signed 24-bit words to bytes
	rts
.host	move.l	unsent(pc),d0
	rts

;
; Host port: call once per VBL. Keeps all registers and does not call
; the OS, so it may run in the VBL interrupt.
;
feed	movem.l	d0-d7/a0-a4,-(sp)
	tst.w	playing(pc)
	beq.s	.out
	move.l	mp2_feedmax(pc),d6
	bne.s	.max
	move.l	#FEED_MAX,d6
.max	move.w	#ANSWER_POLLS,d5
	bsr.s	send
.out	movem.l	(sp)+,d0-d7/a0-a4
	rts

;
; Ask the decoder how many words fit into its input ring and send that
; many, d6.l at most and no more than reported, three bytes of the
; buffer in each, from its start again at its end. d5.w = polls for the
; answer. Uses d0-d4/d7/a0-a4.
;
send	movea.l	stream_ptr(pc),a0
	movea.l	mp2_address(pc),a2
	movea.l	a2,a3
	adda.l	mp2_length(pc),a3	; end of the buffer
	move.l	unsent(pc),d4
	divu.l	#3,d4			; whole words reported
	beq	.out

	lea	$ffffa200.w,a1		; host port
	moveq	#16-1,d1		; drop old answers
.drain	btst	#0,2(a1)		; RXDF
	beq.s	.cmd
	tst.b	7(a1)
	dbra	d1,.drain
.cmd	btst	#7,1(a1)		; last host command still pending
	bne.s	.out
	move.b	#HC_FREE,1(a1)
.answer	btst	#0,2(a1)		; RXDF
	dbne	d5,.answer
	beq.s	.out
	move.l	4(a1),d0
	and.l	#$00ffffff,d0
	cmp.l	d6,d0
	bls.s	.max
	move.l	d6,d0
.max	cmp.l	d4,d0
	bls.s	.count
	move.l	d4,d0
.count	moveq	#0,d7			; bytes sent
	subq.l	#1,d0
	bmi.s	.out

	lea	-3(a3),a4		; last whole word before the end
.word	moveq	#TXDE_POLLS-1,d1
.txde	btst	#1,2(a1)		; TXDE
	dbne	d1,.txde
	beq.s	.stop
	cmpa.l	a4,a0
	bhi.s	.tail
	move.b	(a0)+,5(a1)
	move.b	(a0)+,6(a1)
	move.b	(a0)+,7(a1)
.next	addq.l	#3,d7
	dbra	d0,.word
.stop	lea	stream_ptr(pc),a4
	move.l	a0,(a4)
	lea	unsent(pc),a4
	sub.l	d7,(a4)
.out	rts

.tail	moveq	#0,d3			; a word across the end of the
	moveq	#3-1,d2			; buffer: the missing bytes come
.byte	lsl.l	#8,d3			; from its start
	cmpa.l	a3,a0
	blo.s	.get
	movea.l	a2,a0
.get	move.b	(a0)+,d3
	dbra	d2,.byte
	move.l	d3,4(a1)
	bra.s	.next



set_matrix
	;	sndstatus(SND_RESET);
	move.w	#1,-(sp)
	move.w	#$8c,-(sp)
	trap	#14
	addq.l	#4,sp
	
	tst.l	mp2_input(pc)
	bne	.host

	;	setmode(STEREO16);
	move.w	#1,-(sp)
	move.w	#$84,-(sp)
	trap	#14
	addq.l	#4,sp

	;	soundcmd(ADDERIN,MATIN);
	move.w	#2,-(sp)
	move.w	#4,-(sp)
	move.w	#$82,-(sp)
	trap	#14
	addq.l	#6,sp

	;	dsptristate(ENABLE,ENABLE);
	move.w	#1,-(sp)
	move.w	#1,-(sp)
	move.w	#$89,-(sp)
	trap	#14
	addq.l	#6,sp

	;	setbuffer(SR_PLAY, stream_get_buffer(), stream_get_buffer_end());
	move.l	mp2_address(pc),d0
	move.l	mp2_address(pc),d1
	add.l	mp2_length(pc),d1
	move.l	d1,-(sp)
	move.l	d0,-(sp)
	move.w	#0,-(sp)
	move.w	#$83,-(sp)
	trap	#14
	lea	12(sp),sp	
	bra.s	.freq

.host	;	soundcmd(ADDERIN,MATIN);
	move.w	#2,-(sp)
	move.w	#4,-(sp)
	move.w	#$82,-(sp)
	trap	#14
	addq.l	#6,sp

	;	dsptristate(ENABLE,TRISTATE); the DSP receives nothing
	;	from the matrix, its input comes through the host port.
	move.w	#0,-(sp)
	move.w	#1,-(sp)
	move.w	#$89,-(sp)
	trap	#14
	addq.l	#6,sp

.freq	move.l	mp2_frequency(pc),d0
	move.l	mp2_external(pc),d1

	cmp.l	#48000,d0
	bne.s	.freq48000
	cmp.l	#48000,d1
	bne.s	.freq48000_ext
	bra.s	set_matrix_ext_full
.freq48000_ext
	bra	set_matrix_int_49170
.freq48000
	cmp.l	#44100,d0
	bne.s	.freq44100
	cmp.l	#44100,d1
	bne.s	.freq44100_ext
	bra.s	set_matrix_ext_full
.freq44100_ext
	bra	set_matrix_int_49170
.freq44100
	cmp.l	#32000,d0
	bne.s	.freq32000
	cmp.l	#48000,d1
	bne.s	.freq32000_ext
	bra.s	set_matrix_ext_32000
.freq32000_ext
	bra	set_matrix_int_32780
.freq32000
	cmp.l	#24000,d0
	bne.s	.freq24000
	cmp.l	#48000,d1
	bne.s	.freq24000_ext
	bra.s	set_matrix_ext_half
.freq24000_ext
	bra	set_matrix_int_24585
.freq24000
	cmp.l	#22050,d0
	bne.s	.freq22050
	cmp.l	#44100,d1
	bne.s	.freq22050_ext
	bra.s	set_matrix_ext_half
.freq22050_ext
	bra.s	set_matrix_int_24585
.freq22050
	cmp.l	#16000,d0
	bne.s	.freq16000
	cmp.l	#48000,d1
	bne.s	.freq16000_ext
	bra.s	set_matrix_ext_16000
.freq16000_ext
	bra.s	set_matrix_int_16390
.freq16000

; If unknown, just set 49170, and hope it goes well.
	bra.s	set_matrix_int_49170	
	rts

set_matrix_ext_full:
	move.l	#$63b42080,$ffff8930.w
	move.w	#$0101,$ffff8934.w
	rts

; Only usable if external clock is 48KHz
set_matrix_ext_32000:
	move.l	#$63b42080,$ffff8930.w
	move.w	#$0201,$ffff8934.w
	rts

; Only usable if external clock is 48KHz
set_matrix_ext_16000:
	move.l	#$63b42080,$ffff8930.w
	move.w	#$0501,$ffff8934.w
	rts

set_matrix_ext_half:
	move.l	#$63b42080,$ffff8930.w
	move.w	#$0301,$ffff8934.w
	rts

set_matrix_int_49170:
	move.l	#$01942080,$ffff8930.w
	move.w	#$0001,$ffff8934.w
	rts

set_matrix_int_32780:
	move.l	#$01942080,$ffff8930.w
	move.w	#$0002,$ffff8934.w
	rts

set_matrix_int_24585:
	move.l	#$01942080,$ffff8930.w
	move.w	#$0003,$ffff8934.w
	rts

set_matrix_int_16390:
	move.l	#$01942080,$ffff8930.w
	move.w	#$0005,$ffff8934.w
	rts

saveaudio
	lea	audiosaved(pc),a1
	tst.w	(a1)
	bne.s	.skip
	lea	saveaudiobuf(pc),a0
	move.w	$ffff8930.w,(a0)+
	move.w	$ffff8932.w,(a0)+
	move.b	$ffff8934.w,(a0)+
	move.b	$ffff8935.w,(a0)+
	move.b	$ffff8936.w,(a0)+
	move.b	$ffff8937.w,(a0)+
	move.b	$ffff8938.w,(a0)+
	move.b	$ffff8939.w,(a0)+
;	move.b	$ffff893a.w,(a0)+
	move.b	$ffff893c.w,(a0)+
	move.b	$ffff8941.w,(a0)+
	move.b	$ffff8943.w,(a0)+
	move.b	$ffff8900.w,(a0)+
	move.b	$ffff8901.w,(a0)+
	move.b	$ffff8920.w,(a0)+
	move.b	$ffff8921.w,(a0)+
	move.w	#1,(a1)
.skip
	rts

restoreaudio
	lea	audiosaved(pc),a1
	tst.w	(a1)
	beq.s	.skip
	lea	saveaudiobuf(pc),a0
	move.w	(a0)+,$ffff8930.w
	move.w	(a0)+,$ffff8932.w
	move.b	(a0)+,$ffff8934.w
	move.b	(a0)+,$ffff8935.w
	move.b	(a0)+,$ffff8936.w
	move.b	(a0)+,$ffff8937.w
	move.b	(a0)+,$ffff8938.w
	move.b	(a0)+,$ffff8939.w
;	move.b	(a0)+,$ffff893a.w
	move.b	(a0)+,$ffff893c.w
	move.b	(a0)+,$ffff8941.w
	move.b	(a0)+,$ffff8943.w
	move.b	(a0)+,$ffff8900.w
	move.b	(a0)+,$ffff8901.w
	move.b	(a0)+,$ffff8920.w
	move.b	(a0)+,$ffff8921.w
	clr.w	(a1)
.skip
	rts	
	

mute
	lea	savevol(pc),a4
	move.w	#-1,-(sp)
	move.w	#0,-(sp)
	move.w	#$82,-(sp)
	trap	#14
	addq.l	#6,sp
	move.w	d0,(a4)+

	move.w	#-1,-(sp)
	move.w	#1,-(sp)
	move.w	#$82,-(sp)
	trap	#14
	addq.l	#6,sp
	move.w	d0,(a4)+

	move.w	#$f0,-(sp)
	move.w	#0,-(sp)
	move.w	#$82,-(sp)
	trap	#14
	addq.l	#6,sp

	move.w	#$f0,-(sp)
	move.w	#1,-(sp)
	move.w	#$82,-(sp)
	trap	#14
	addq.l	#6,sp
	rts

unmute
	lea	savevol(pc),a4
	move.w	(a4)+,-(sp)
	move.w	#0,-(sp)
	move.w	#$82,-(sp)
	trap	#14
	addq.l	#6,sp

	move.w	(a4)+,-(sp)
	move.w	#1,-(sp)
	move.w	#$82,-(sp)
	trap	#14
	addq.l	#6,sp
	rts


play
	move.w	#$1,d0
	tst.l	mp2_repeat(pc)
	beq.s	.norepeat
	move.w	#$3,d0
.norepeat
	move.w	d0,-(sp)
	move.w	#$88,-(sp)
	trap	#14
	addq.l	#4,sp
	rts

dsp_load_program
	lea	dsp_mp2_player(pc),a0
	move.l	#(end_mp2_player-dsp_mp2_player)/3,d0

	lea	dsp_program(pc),a1
	move.l	a0,(a1)
	lea	dsp_length(pc),a1
	move.l	d0,(a1)

	bsr.s	dsp_load

	; d0 == status

	rts

dsp_load	bsr.s	dsp_reset
	bsr.s	dsp_go
	rts

dsp_reset	; Power down.
	move.w	sr,d1
	ori.w	#$0700,sr		; no other PSG access in between
	move.b	#$e,$ffff8800.w
	move.b	$ffff8800.w,d0
	andi.b	#$ef,d0
	move.b	d0,$ffff8802.w
	ori.b	#$10,d0
	move.b	d0,$ffff8802.w
	move.w	d1,sr

	; Wait for DSP to power down.
	move.w	#10000-1,d0
.wait	tst.b	$ffff8800.w		; PSG reads take the same time on any CPU
	dbra	d0,.wait

	; Power up.
	ori.w	#$0700,sr
	move.b	#$e,$ffff8800.w
	move.b	$ffff8800.w,d0
	andi.b	#$ef,d0
	move.b	d0,$ffff8802.w
	move.w	d1,sr
	rts

dsp_go
	; Load system startup code.
	lea	dsp_bootstrap_code(pc),a0
	move.w	#512-1,d0
.next	btst.b	#1,$ffffa202.w
	beq.s	.next
	move.b	(a0)+,$ffffa205.w
	move.b	(a0)+,$ffffa206.w
	move.b	(a0)+,$ffffa207.w
	dbra	d0,.next

	; Load DSP binary
	move.l	dsp_program(pc),a0
	move.l	dsp_length(pc),d0
	subq.w	#1,d0
	bmi.s	.no_way
.copy	btst.b	#1,$ffffa202.w
	beq.s	.copy
	move.b	(a0)+,$ffffa205.w
	move.b	(a0)+,$ffffa206.w
	move.b	(a0)+,$ffffa207.w
	dbra	d0,.copy

	; Launch DSP binary
.go	btst.b	#1,$ffffa202.w
	beq.s	.go
	move.l	#3,$ffffa204.w
	
	moveq	#1,d0
	rts
.no_way	moveq	#0,d0
	rts


;
; Tell the decoder where its input comes from and, for the sound DMA, how
; many words the buffer holds. From the host port, fill its input ring
; from the start of the stream; the first HC_FREE answer comes once the
; decoder has set itself up.
;
initialize_program
	lea	dsp_buf(pc),a0
	move.l	mp2_input(pc),(a0)
	moveq	#1,d1
	tst.l	(a0)
	bne.s	.send
	move.l	mp2_length(pc),d0
	subq.l	#8,d0			; NoCrew's mp2audio (stream.c) holds back 8 bytes too
	lsr.l	#1,d0			; in 16-bit words
	move.l	d0,4(a0)
	moveq	#2,d1
.send	move.l	#0,-(sp)
	pea	0.w
	move.l	d1,-(sp)
	move.l	a0,-(sp)
	move.w	#$62,-(sp)
	trap	#14
	lea	18(sp),sp

	tst.l	mp2_input(pc)
	beq.s	.out
	lea	stream_ptr(pc),a0
	move.l	mp2_address(pc),(a0)
	lea	unsent(pc),a0
	move.l	mp2_length(pc),(a0)
	move.l	#$ffffff,d6
	move.w	#START_POLLS,d5
	bsr	send
	lea	playing(pc),a0
	move.w	#1,(a0)
.out	rts

	
	data
audiosaved	dc.w	0
dsp_buf	dc.l	0,0
playing	dc.w	0
stream_ptr	dc.l	0		; next byte to send
unsent	dc.l	0		; bytes reported, not sent yet

dsp_bootstrap_code
	dc.b	$0c,$00,$40,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$60,$f4,$00,$00,$00,$4f,$61,$f4
	dc.b	$00,$00,$7e,$a9,$06,$2e,$80,$00,$00,$47
	dc.b	$07,$d8,$84,$07,$59,$84,$08,$f4,$a8,$00
	dc.b	$00,$04,$08,$f4,$bf,$00,$0c,$00,$00,$fe
	dc.b	$b8,$0a,$f0,$80,$00,$7e,$a9,$08,$f4,$a0
	dc.b	$00,$00,$01,$08,$f4,$be,$00,$00,$00,$0a
	dc.b	$a9,$80,$00,$7e,$ad,$08,$4e,$2b,$44,$f4
	dc.b	$00,$00,$00,$03,$44,$f4,$45,$00,$00,$01
	dc.b	$0e,$a0,$00,$0a,$a9,$80,$00,$7e,$b5,$08
	dc.b	$50,$2b,$0a,$a9,$80,$00,$7e,$b8,$08,$46
	dc.b	$2b,$44,$f4,$45,$00,$00,$02,$0a,$f0,$aa
	dc.b	$00,$7e,$c9,$20,$00,$45,$0a,$f0,$aa,$00
	dc.b	$7e,$d0,$06,$c6,$00,$00,$7e,$c6,$0a,$a9
	dc.b	$80,$00,$7e,$c4,$08,$58,$6b,$0a,$f0,$80
	dc.b	$00,$7e,$ad,$06,$c6,$00,$00,$7e,$cd,$0a
	dc.b	$a9,$80,$00,$7e,$cb,$08,$58,$ab,$0a,$f0
	dc.b	$80,$00,$7e,$ad,$06,$c6,$00,$00,$7e,$d4
	dc.b	$0a,$a9,$80,$00,$7e,$d2,$08,$58,$eb,$0a
	dc.b	$f0,$80,$00,$7e,$ad,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00,$00,$00,$00,$00
	dc.b	$00,$00,$00,$00,$00,$00

dsp_mp2_player	incbin	decoder.dsp
end_mp2_player
	even

; ds, not bss: the player is included with incbin and its file has no bss.
dsp_program	ds.l	1
dsp_length	ds.l	1
dsp_value	ds.l	1
savevol	ds.w	2
saveaudiobuf	ds.w	10

	end
