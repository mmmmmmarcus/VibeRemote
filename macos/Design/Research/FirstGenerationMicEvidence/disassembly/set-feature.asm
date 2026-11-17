AppleBluetoothRemote.analysis-view:
(__TEXT_EXEC,__text) section
__ZN36AppleEmbeddedBluetoothHIDEventDriver18setFeatureReportWLEhPhj:
fffffe00091f5538:	5f 24 03 d5	hint	#0x22
fffffe00091f553c:	7f 23 03 d5	pacibsp
fffffe00091f5540:	fc 6f ba a9	stp	x28, x27, [sp, #-0x60]!
fffffe00091f5544:	fa 67 01 a9	stp	x26, x25, [sp, #0x10]
fffffe00091f5548:	f8 5f 02 a9	stp	x24, x23, [sp, #0x20]
fffffe00091f554c:	f6 57 03 a9	stp	x22, x21, [sp, #0x30]
fffffe00091f5550:	f4 4f 04 a9	stp	x20, x19, [sp, #0x40]
fffffe00091f5554:	fd 7b 05 a9	stp	x29, x30, [sp, #0x50]
fffffe00091f5558:	fd 43 01 91	add	x29, sp, #0x50
fffffe00091f555c:	ff c3 08 d1	sub	sp, sp, #0x230
fffffe00091f5560:	f3 03 03 aa	mov	x19, x3
fffffe00091f5564:	f4 03 02 aa	mov	x20, x2
fffffe00091f5568:	f6 03 01 aa	mov	x22, x1
fffffe00091f556c:	f5 03 00 aa	mov	x21, x0
fffffe00091f5570:	a8 71 ff f0	adrp	x8, -4553 ; 0xfffffe000802c000
fffffe00091f5574:	08 45 47 f9	ldr	x8, [x8, #0xe88]
fffffe00091f5578:	08 01 40 f9	ldr	x8, [x8]
fffffe00091f557c:	a8 83 1a f8	stur	x8, [x29, #-0x58]
fffffe00091f5580:	b7 57 80 52	mov	w23, #0x2bd
fffffe00091f5584:	17 00 bc 72	movk	w23, #0xe000, lsl #16
fffffe00091f5588:	3f 05 00 94	bl	0xfffffe00091f6a84 ; symbol stub for: __ZNK9IOService10isInactiveEv
fffffe00091f558c:	60 00 00 36	tbz	w0, #0x0, 0xfffffe00091f5598
fffffe00091f5590:	f7 6a 00 11	add	w23, w23, #0x1a
fffffe00091f5594:	81 00 00 14	b	0xfffffe00091f5798
fffffe00091f5598:	e8 9f 00 91	add	x8, sp, #0x27
fffffe00091f559c:	18 05 00 91	add	x24, x8, #0x1
fffffe00091f55a0:	00 e4 00 6f	movi.2d	v0, #0000000000000000
fffffe00091f55a4:	00 03 0f ad	stp	q0, q0, [x24, #0x1e0]
fffffe00091f55a8:	00 03 0e ad	stp	q0, q0, [x24, #0x1c0]
fffffe00091f55ac:	00 03 0d ad	stp	q0, q0, [x24, #0x1a0]
fffffe00091f55b0:	00 03 0c ad	stp	q0, q0, [x24, #0x180]
fffffe00091f55b4:	00 03 0b ad	stp	q0, q0, [x24, #0x160]
fffffe00091f55b8:	00 03 0a ad	stp	q0, q0, [x24, #0x140]
fffffe00091f55bc:	00 03 09 ad	stp	q0, q0, [x24, #0x120]
fffffe00091f55c0:	00 03 08 ad	stp	q0, q0, [x24, #0x100]
fffffe00091f55c4:	00 11 8f 3c	stur	q0, [x8, #0xf1]
fffffe00091f55c8:	00 11 8e 3c	stur	q0, [x8, #0xe1]
fffffe00091f55cc:	00 11 8d 3c	stur	q0, [x8, #0xd1]
fffffe00091f55d0:	00 11 8c 3c	stur	q0, [x8, #0xc1]
fffffe00091f55d4:	00 11 8b 3c	stur	q0, [x8, #0xb1]
fffffe00091f55d8:	00 11 8a 3c	stur	q0, [x8, #0xa1]
fffffe00091f55dc:	00 11 89 3c	stur	q0, [x8, #0x91]
fffffe00091f55e0:	00 11 88 3c	stur	q0, [x8, #0x81]
fffffe00091f55e4:	e0 83 89 3c	stur	q0, [sp, #0x98]
fffffe00091f55e8:	e0 83 88 3c	stur	q0, [sp, #0x88]
fffffe00091f55ec:	e0 83 87 3c	stur	q0, [sp, #0x78]
fffffe00091f55f0:	e0 83 86 3c	stur	q0, [sp, #0x68]
fffffe00091f55f4:	e0 83 85 3c	stur	q0, [sp, #0x58]
fffffe00091f55f8:	e0 83 84 3c	stur	q0, [sp, #0x48]
fffffe00091f55fc:	e0 83 83 3c	stur	q0, [sp, #0x38]
fffffe00091f5600:	e0 83 82 3c	stur	q0, [sp, #0x28]
fffffe00091f5604:	f6 cf 00 a9	stp	x22, x19, [sp, #0x8]
fffffe00091f5608:	5a 11 ff b0	adrp	x26, -7639 ; 0xfffffe000741e000
fffffe00091f560c:	5a f3 28 91	add	x26, x26, #0xa3c
fffffe00091f5610:	fa 03 00 f9	str	x26, [sp]
fffffe00091f5614:	40 11 ff 90	adrp	x0, -7640 ; 0xfffffe000741d000
fffffe00091f5618:	00 80 03 91	add	x0, x0, #0xe0
fffffe00091f561c:	a1 71 ff f0	adrp	x1, -4553 ; 0xfffffe000802c000
fffffe00091f5620:	21 48 47 f9	ldr	x1, [x1, #0xe90]
fffffe00091f5624:	43 11 ff d0	adrp	x3, -7638 ; 0xfffffe000741f000
fffffe00091f5628:	63 c8 04 91	add	x3, x3, #0x132
fffffe00091f562c:	42 00 80 52	mov	w2, #0x2
fffffe00091f5630:	1d 05 00 94	bl	0xfffffe00091f6aa4 ; symbol stub for: __os_log_internal
fffffe00091f5634:	7f 02 08 71	cmp	w19, #0x200
fffffe00091f5638:	e8 06 00 54	b.hi	0xfffffe00091f5714
fffffe00091f563c:	f6 9f 00 39	strb	w22, [sp, #0x27]
fffffe00091f5640:	d4 00 00 b4	cbz	x20, 0xfffffe00091f5658
fffffe00091f5644:	b3 00 00 34	cbz	w19, 0xfffffe00091f5658
fffffe00091f5648:	e2 03 13 2a	mov	w2, w19
fffffe00091f564c:	e0 03 18 aa	mov	x0, x24
fffffe00091f5650:	e1 03 14 aa	mov	x1, x20
fffffe00091f5654:	1c 05 00 94	bl	0xfffffe00091f6ac4 ; symbol stub for: _memcpy
fffffe00091f5658:	61 06 00 11	add	w1, w19, #0x1
fffffe00091f565c:	e0 9f 00 91	add	x0, sp, #0x27
fffffe00091f5660:	62 00 80 52	mov	w2, #0x3
fffffe00091f5664:	e0 04 00 94	bl	0xfffffe00091f69e4 ; symbol stub for: __ZN18IOMemoryDescriptor11withAddressEPvyj
fffffe00091f5668:	80 09 00 b4	cbz	x0, 0xfffffe00091f5798
fffffe00091f566c:	f8 03 00 aa	mov	x24, x0
fffffe00091f5670:	10 00 40 f9	ldr	x16, [x0]
fffffe00091f5674:	f9 03 00 aa	mov	x25, x0
fffffe00091f5678:	39 b4 f9 f2	movk	x25, #0xcda1, lsl #48
fffffe00091f567c:	f1 03 00 aa	mov	x17, x0
fffffe00091f5680:	31 b4 f9 f2	movk	x17, #0xcda1, lsl #48
fffffe00091f5684:	30 1a c1 da	autda	x16, x17
fffffe00091f5688:	11 43 80 d2	mov	x17, #0x218
fffffe00091f568c:	10 02 11 8b	add	x16, x16, x17
fffffe00091f5690:	08 02 40 f9	ldr	x8, [x16]
fffffe00091f5694:	61 00 80 52	mov	w1, #0x3
fffffe00091f5698:	70 b6 fe f2	movk	x16, #0xf5b3, lsl #48
fffffe00091f569c:	10 09 3f d7	blraa	x8, x16
fffffe00091f56a0:	f7 03 00 aa	mov	x23, x0
fffffe00091f56a4:	e0 06 00 35	cbnz	w0, 0xfffffe00091f5780
fffffe00091f56a8:	a0 4a 40 f9	ldr	x0, [x21, #0x90]
fffffe00091f56ac:	10 00 40 f9	ldr	x16, [x0]
fffffe00091f56b0:	f1 03 00 aa	mov	x17, x0
fffffe00091f56b4:	31 b4 f9 f2	movk	x17, #0xcda1, lsl #48
fffffe00091f56b8:	30 1a c1 da	autda	x16, x17
fffffe00091f56bc:	11 1e 81 d2	mov	x17, #0x8f0
fffffe00091f56c0:	10 02 11 8b	add	x16, x16, x17
fffffe00091f56c4:	08 02 40 f9	ldr	x8, [x16]
fffffe00091f56c8:	e1 03 18 aa	mov	x1, x24
fffffe00091f56cc:	42 00 80 52	mov	w2, #0x2
fffffe00091f56d0:	e3 03 16 aa	mov	x3, x22
fffffe00091f56d4:	04 00 80 52	mov	w4, #0x0
fffffe00091f56d8:	10 27 e3 f2	movk	x16, #0x1938, lsl #48
fffffe00091f56dc:	10 09 3f d7	blraa	x8, x16
fffffe00091f56e0:	f7 03 00 aa	mov	x23, x0
fffffe00091f56e4:	c0 01 00 34	cbz	w0, 0xfffffe00091f571c
fffffe00091f56e8:	f7 db 00 a9	stp	x23, x22, [sp, #0x8]
fffffe00091f56ec:	fa 03 00 f9	str	x26, [sp]
fffffe00091f56f0:	40 11 ff 90	adrp	x0, -7640 ; 0xfffffe000741d000
fffffe00091f56f4:	00 80 03 91	add	x0, x0, #0xe0
fffffe00091f56f8:	a1 71 ff f0	adrp	x1, -4553 ; 0xfffffe000802c000
fffffe00091f56fc:	21 48 47 f9	ldr	x1, [x1, #0xe90]
fffffe00091f5700:	43 11 ff d0	adrp	x3, -7638 ; 0xfffffe000741f000
fffffe00091f5704:	63 3c 05 91	add	x3, x3, #0x14f
fffffe00091f5708:	42 00 80 52	mov	w2, #0x2
fffffe00091f570c:	e6 04 00 94	bl	0xfffffe00091f6aa4 ; symbol stub for: __os_log_internal
fffffe00091f5710:	11 00 00 14	b	0xfffffe00091f5754
fffffe00091f5714:	17 00 80 52	mov	w23, #0x0
fffffe00091f5718:	20 00 00 14	b	0xfffffe00091f5798
fffffe00091f571c:	b0 02 40 f9	ldr	x16, [x21]
fffffe00091f5720:	f1 03 15 aa	mov	x17, x21
fffffe00091f5724:	31 b4 f9 f2	movk	x17, #0xcda1, lsl #48
fffffe00091f5728:	30 1a c1 da	autda	x16, x17
fffffe00091f572c:	11 10 81 d2	mov	x17, #0x880
fffffe00091f5730:	10 02 11 8b	add	x16, x16, x17
fffffe00091f5734:	08 02 40 f9	ldr	x8, [x16]
fffffe00091f5738:	e0 03 15 aa	mov	x0, x21
fffffe00091f573c:	e1 03 14 aa	mov	x1, x20
fffffe00091f5740:	e2 03 13 aa	mov	x2, x19
fffffe00091f5744:	03 00 80 d2	mov	x3, #0x0
fffffe00091f5748:	04 00 80 52	mov	w4, #0x0
fffffe00091f574c:	50 e8 f7 f2	movk	x16, #0xbf42, lsl #48
fffffe00091f5750:	10 09 3f d7	blraa	x8, x16
fffffe00091f5754:	10 03 40 f9	ldr	x16, [x24]
fffffe00091f5758:	30 1b c1 da	autda	x16, x25
fffffe00091f575c:	11 44 80 d2	mov	x17, #0x220
fffffe00091f5760:	10 02 11 8b	add	x16, x16, x17
fffffe00091f5764:	08 02 40 f9	ldr	x8, [x16]
fffffe00091f5768:	e0 03 18 aa	mov	x0, x24
fffffe00091f576c:	01 00 80 52	mov	w1, #0x0
fffffe00091f5770:	b0 50 f2 f2	movk	x16, #0x9285, lsl #48
fffffe00091f5774:	10 09 3f d7	blraa	x8, x16
fffffe00091f5778:	ff 02 00 71	cmp	w23, #0x0
fffffe00091f577c:	17 00 97 1a	csel	w23, w0, w23, eq
fffffe00091f5780:	10 03 40 f9	ldr	x16, [x24]
fffffe00091f5784:	30 1b c1 da	autda	x16, x25
fffffe00091f5788:	08 8e 42 f8	ldr	x8, [x16, #0x28]!
fffffe00091f578c:	e0 03 18 aa	mov	x0, x24
fffffe00091f5790:	f0 50 e7 f2	movk	x16, #0x3a87, lsl #48
fffffe00091f5794:	10 09 3f d7	blraa	x8, x16
fffffe00091f5798:	a8 83 5a f8	ldur	x8, [x29, #-0x58]
fffffe00091f579c:	a9 71 ff f0	adrp	x9, -4553 ; 0xfffffe000802c000
fffffe00091f57a0:	29 45 47 f9	ldr	x9, [x9, #0xe88]
fffffe00091f57a4:	29 01 40 f9	ldr	x9, [x9]
fffffe00091f57a8:	3f 01 08 eb	cmp	x9, x8
fffffe00091f57ac:	41 01 00 54	b.ne	0xfffffe00091f57d4
fffffe00091f57b0:	e0 03 17 aa	mov	x0, x23
fffffe00091f57b4:	ff c3 08 91	add	sp, sp, #0x230
fffffe00091f57b8:	fd 7b 45 a9	ldp	x29, x30, [sp, #0x50]
fffffe00091f57bc:	f4 4f 44 a9	ldp	x20, x19, [sp, #0x40]
fffffe00091f57c0:	f6 57 43 a9	ldp	x22, x21, [sp, #0x30]
fffffe00091f57c4:	f8 5f 42 a9	ldp	x24, x23, [sp, #0x20]
fffffe00091f57c8:	fa 67 41 a9	ldp	x26, x25, [sp, #0x10]
fffffe00091f57cc:	fc 6f c6 a8	ldp	x28, x27, [sp], #0x60
fffffe00091f57d0:	ff 0f 5f d6	retab
fffffe00091f57d4:	b0 04 00 94	bl	0xfffffe00091f6a94 ; symbol stub for: ___stack_chk_fail
