MP2_ADDRESS	=	28
MP2_LENGTH	=	32
MP2_FREQUENCY	=	36
MP2_EXTERNAL	=	40
MP2_REPEAT	=	44
MP2_START	=	48
MP2_STOP	=	52
MP2_ADD_AVAILABLE =	56
MP2_STREAM_AVAILABLE =	60
MP2_FEED	=	64
MP2_INPUT	=	72

; 0: load the whole file. Otherwise the size of a buffer (a multiple of
; 8) through which longer files are streamed.
MP2_DFD_BUFFER_SIZE =	0
MP2_LOOP	=	1
; 1: mp2_feed sends the stream through the host port, 0: the sound DMA
; reads it from ST-RAM.
MP2_HOST_PORT	=	1

	text

	move.l	4(sp),a0		; basepage
	lea	stack,sp
	move.l	#$100,d0
	add.l	$0c(a0),d0
	add.l	$14(a0),d0
	add.l	$1c(a0),d0
	move.l	d0,-(sp)
	move.l	a0,-(sp)
	clr.w	-(sp)
	move.w	#$4a,-(sp)		; Mshrink()
	trap	#1
	lea	12(sp),sp

	clr.l	-(sp)
	move.w	#$20,-(sp)		; Super()
	trap	#1
	addq.l	#6,sp

	clr.w	-(sp)
	pea	mp2file
	move.w	#$3d,-(sp)		; Fopen()
	trap	#1
	addq.l	#8,sp
	tst.l	d0
	bmi	exit
	move.w	d0,handle

	move.w	#2,-(sp)
	move.w	handle,-(sp)
	clr.l	-(sp)
	move.w	#$42,-(sp)		; Fseek() to the end: the file size
	trap	#1
	lea	10(sp),sp
	move.l	d0,d7
	bsr	rewind

	move.l	d7,d6			; whole file, rounded for the DMA
	addq.l	#3,d6
	andi.w	#-4,d6
	ifne	MP2_DFD_BUFFER_SIZE
	cmp.l	#MP2_DFD_BUFFER_SIZE,d6
	bls.s	.alloc
	move.l	#MP2_DFD_BUFFER_SIZE,d6
	st	streaming
	st	refilling
	endc
.alloc	move.l	d6,d0
	lsr.l	#1,d0
	move.l	d0,half
	move.w	#MP2_HOST_PORT*3,-(sp)	; ST-RAM, or TT-RAM if there is any
	move.l	d6,-(sp)
	move.w	#$44,-(sp)		; Mxalloc()
	trap	#1
	addq.l	#8,sp
	tst.l	d0
	beq	close
	move.l	d0,buffer
	movea.l	d0,a3
	clr.l	-4(a3,d6.l)		; padding after the file

	move.l	d6,d3
	tst.b	streaming
	bne.s	.load
	move.l	d7,d3
.load	bsr	fill

	lea	mp2player,a0
	move.l	buffer,MP2_ADDRESS(a0)
	move.l	d6,MP2_LENGTH(a0)
	move.l	#44100,MP2_FREQUENCY(a0)
	move.l	#44100,MP2_EXTERNAL(a0)
	move.l	#MP2_HOST_PORT,MP2_INPUT(a0)
	move.l	#MP2_LOOP,MP2_REPEAT(a0)
	tst.b	streaming
	beq.s	.start
	move.l	#1,MP2_REPEAT(a0)	; the buffer wraps
.start	jsr	mp2player+MP2_START

.loop	move.w	#37,-(sp)		; Vsync()
	trap	#14
	addq.l	#2,sp
	jsr	mp2player+MP2_FEED	; once per VBL

	tst.b	refilling
	beq.s	.key
	bsr	refill
.key	cmp.b	#$3b,$fffffc02.w
	bne.s	.loop

	jsr	mp2player+MP2_STOP

	move.l	buffer,-(sp)
	move.w	#$49,-(sp)		; Mfree()
	trap	#1
	addq.l	#6,sp

close	move.w	handle,-(sp)
	move.w	#$3e,-(sp)		; Fclose()
	trap	#1
	addq.l	#4,sp

exit	clr.w	-(sp)
	trap	#1

;
; Once less than half of the buffer is left, let the decoder have
; another half. When streaming, refill the half it has finished with
; first; a whole file is still all there as the DMA repeats the buffer
; or mp2_feed wraps around.
;
refill	jsr	mp2player+MP2_STREAM_AVAILABLE
	move.l	half,d3
	cmp.l	d3,d0
	bge.s	.out
	move.l	d3,d0
	tst.b	streaming
	beq.s	.add
	movea.l	buffer,a3
	tst.b	second
	beq.s	.first
	adda.l	d3,a3
.first	not.b	second
	bsr	fill
.add	jsr	mp2player+MP2_ADD_AVAILABLE
.out	rts

;
; Read d3.l bytes of the file to a3; with MP2_LOOP from its start again
; at its end, otherwise refilling stops there. d0.l = bytes read.
;
fill	moveq	#0,d4
	moveq	#0,d5			; rewound
.read	move.l	a3,-(sp)
	move.l	d3,-(sp)
	move.w	handle,-(sp)
	move.w	#$3f,-(sp)		; Fread()
	trap	#1
	lea	12(sp),sp
	tst.l	d0
	ble.s	.end
	moveq	#0,d5
	add.l	d0,d4
	adda.l	d0,a3
	sub.l	d0,d3
	bne.s	.read
	bra.s	.out
.end	ifne	MP2_LOOP
	tst.b	d5			; nothing even after rewinding
	bne.s	.stop
	st	d5
	bsr	rewind
	bra.s	.read
	endc
.stop	sf	refilling
.out	move.l	d4,d0
	rts

rewind	clr.w	-(sp)
	move.w	handle,-(sp)
	clr.l	-(sp)
	move.w	#$42,-(sp)		; Fseek() to the start
	trap	#1
	lea	10(sp),sp
	rts

	data

mp2file	dc.b	'f:\mp2\sound_of.mp2',0
streaming	dc.b	0
refilling	dc.b	MP2_LOOP
second	dc.b	0
	even

mp2player	incbin	mp2inc.bin

	bss

buffer	ds.l	1
half	ds.l	1
handle	ds.w	1
	ds.l	4096
stack

	end
