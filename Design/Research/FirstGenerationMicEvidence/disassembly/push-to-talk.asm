AppleBluetoothRemote.analysis-view:
(__TEXT_EXEC,__text) section
__ZN38AppleEmbeddedBluetoothDeviceManagement23setPushToTalkPropertyWLEP12OSDictionary:
fffffe00091ef5a0:	5f 24 03 d5	hint	#0x22
fffffe00091ef5a4:	7f 23 03 d5	pacibsp
fffffe00091ef5a8:	ff 83 01 d1	sub	sp, sp, #0x60
fffffe00091ef5ac:	f8 5f 02 a9	stp	x24, x23, [sp, #0x20]
fffffe00091ef5b0:	f6 57 03 a9	stp	x22, x21, [sp, #0x30]
fffffe00091ef5b4:	f4 4f 04 a9	stp	x20, x19, [sp, #0x40]
fffffe00091ef5b8:	fd 7b 05 a9	stp	x29, x30, [sp, #0x50]
fffffe00091ef5bc:	fd 43 01 91	add	x29, sp, #0x50
fffffe00091ef5c0:	f3 03 01 aa	mov	x19, x1
fffffe00091ef5c4:	f4 03 00 aa	mov	x20, x0
fffffe00091ef5c8:	30 00 40 f9	ldr	x16, [x1]
fffffe00091ef5cc:	f1 03 01 aa	mov	x17, x1
fffffe00091ef5d0:	31 b4 f9 f2	movk	x17, #0xcda1, lsl #48
fffffe00091ef5d4:	30 1a c1 da	autda	x16, x17
fffffe00091ef5d8:	11 47 80 d2	mov	x17, #0x238
fffffe00091ef5dc:	10 02 11 8b	add	x16, x16, x17
fffffe00091ef5e0:	08 02 40 f9	ldr	x8, [x16]
fffffe00091ef5e4:	61 11 ff d0	adrp	x1, -7634 ; 0xfffffe000741d000
fffffe00091ef5e8:	21 c4 30 91	add	x1, x1, #0xc31
fffffe00091ef5ec:	e0 03 13 aa	mov	x0, x19
fffffe00091ef5f0:	70 c7 e5 f2	movk	x16, #0x2e3b, lsl #48
fffffe00091ef5f4:	10 09 3f d7	blraa	x8, x16
fffffe00091ef5f8:	e8 71 ff b0	adrp	x8, -4547 ; 0xfffffe000802c000
fffffe00091ef5fc:	08 3d 47 f9	ldr	x8, [x8, #0xe78]
fffffe00091ef600:	01 01 40 f9	ldr	x1, [x8]
fffffe00091ef604:	f0 1c 00 94	bl	0xfffffe00091f69c4 ; symbol stub for: __ZN15OSMetaClassBase12safeMetaCastEPKS_PK11OSMetaClass
fffffe00091ef608:	f5 03 00 aa	mov	x21, x0
fffffe00091ef60c:	f1 03 14 aa	mov	x17, x20
fffffe00091ef610:	90 02 40 f9	ldr	x16, [x20]
fffffe00091ef614:	31 b4 f9 f2	movk	x17, #0xcda1, lsl #48
fffffe00091ef618:	30 1a c1 da	autda	x16, x17
fffffe00091ef61c:	f1 03 10 aa	mov	x17, x16
fffffe00091ef620:	f1 47 c1 da	xpacd	x17
fffffe00091ef624:	1f 02 11 eb	cmp	x16, x17
fffffe00091ef628:	40 00 00 54	b.eq	0xfffffe00091ef630
fffffe00091ef62c:	40 8e 38 d4	brk	#0xc472
fffffe00091ef630:	08 62 0b 91	add	x8, x16, #0x2d8
fffffe00091ef634:	09 6e 41 f9	ldr	x9, [x16, #0x2d8]
fffffe00091ef638:	61 11 ff d0	adrp	x1, -7634 ; 0xfffffe000741d000
fffffe00091ef63c:	21 7c 24 91	add	x1, x1, #0x91f
fffffe00091ef640:	e0 03 14 aa	mov	x0, x20
fffffe00091ef644:	f1 03 08 aa	mov	x17, x8
fffffe00091ef648:	b1 f4 e6 f2	movk	x17, #0x37a5, lsl #48
fffffe00091ef64c:	31 09 3f d7	blraa	x9, x17
fffffe00091ef650:	e8 71 ff b0	adrp	x8, -4547 ; 0xfffffe000802c000
fffffe00091ef654:	08 31 47 f9	ldr	x8, [x8, #0xe60]
fffffe00091ef658:	01 01 40 f9	ldr	x1, [x8]
fffffe00091ef65c:	da 1c 00 94	bl	0xfffffe00091f69c4 ; symbol stub for: __ZN15OSMetaClassBase12safeMetaCastEPKS_PK11OSMetaClass
fffffe00091ef660:	16 00 80 52	mov	w22, #0x0
fffffe00091ef664:	bf 02 00 f1	cmp	x21, #0x0
fffffe00091ef668:	04 18 40 fa	ccmp	x0, #0x0, #0x4, ne
fffffe00091ef66c:	ff 7f 00 39	strb	wzr, [sp, #0x1f]
fffffe00091ef670:	20 0c 00 54	b.eq	0xfffffe00091ef7f4
fffffe00091ef674:	f7 03 00 aa	mov	x23, x0
fffffe00091ef678:	f8 03 13 aa	mov	x24, x19
fffffe00091ef67c:	38 b4 f9 f2	movk	x24, #0xcda1, lsl #48
fffffe00091ef680:	10 00 40 f9	ldr	x16, [x0]
fffffe00091ef684:	f1 03 00 aa	mov	x17, x0
fffffe00091ef688:	31 b4 f9 f2	movk	x17, #0xcda1, lsl #48
fffffe00091ef68c:	30 1a c1 da	autda	x16, x17
fffffe00091ef690:	11 2d 80 d2	mov	x17, #0x168
fffffe00091ef694:	10 02 11 8b	add	x16, x16, x17
fffffe00091ef698:	08 02 40 f9	ldr	x8, [x16]
fffffe00091ef69c:	90 0c f4 f2	movk	x16, #0xa064, lsl #48
fffffe00091ef6a0:	10 09 3f d7	blraa	x8, x16
fffffe00091ef6a4:	08 78 1f 12	and	w8, w0, #0xfffffffe
fffffe00091ef6a8:	1f 51 0c 71	cmp	w8, #0x314
fffffe00091ef6ac:	41 04 00 54	b.ne	0xfffffe00091ef734
fffffe00091ef6b0:	b0 02 40 f9	ldr	x16, [x21]
fffffe00091ef6b4:	f1 03 15 aa	mov	x17, x21
fffffe00091ef6b8:	31 b4 f9 f2	movk	x17, #0xcda1, lsl #48
fffffe00091ef6bc:	30 1a c1 da	autda	x16, x17
fffffe00091ef6c0:	11 29 80 d2	mov	x17, #0x148
fffffe00091ef6c4:	10 02 11 8b	add	x16, x16, x17
fffffe00091ef6c8:	08 02 40 f9	ldr	x8, [x16]
fffffe00091ef6cc:	e0 03 15 aa	mov	x0, x21
fffffe00091ef6d0:	50 4c e9 f2	movk	x16, #0x4a62, lsl #48
fffffe00091ef6d4:	10 09 3f d7	blraa	x8, x16
fffffe00091ef6d8:	e0 7f 00 39	strb	w0, [sp, #0x1f]
fffffe00091ef6dc:	e2 7f 00 91	add	x2, sp, #0x1f
fffffe00091ef6e0:	e0 03 14 aa	mov	x0, x20
fffffe00091ef6e4:	21 13 80 52	mov	w1, #0x99
fffffe00091ef6e8:	23 00 80 52	mov	w3, #0x1
fffffe00091ef6ec:	93 17 00 94	bl	__ZN36AppleEmbeddedBluetoothHIDEventDriver18setFeatureReportWLEhPhj
fffffe00091ef6f0:	f6 03 00 aa	mov	x22, x0
fffffe00091ef6f4:	60 07 00 34	cbz	w0, 0xfffffe00091ef7e0
fffffe00091ef6f8:	e8 71 ff b0	adrp	x8, -4547 ; 0xfffffe000802c000
fffffe00091ef6fc:	08 51 47 f9	ldr	x8, [x8, #0xea0]
fffffe00091ef700:	08 01 40 f9	ldr	x8, [x8]
fffffe00091ef704:	02 01 40 f9	ldr	x2, [x8]
fffffe00091ef708:	70 02 40 f9	ldr	x16, [x19]
fffffe00091ef70c:	10 1b c1 da	autda	x16, x24
fffffe00091ef710:	11 40 80 d2	mov	x17, #0x200
fffffe00091ef714:	10 02 11 8b	add	x16, x16, x17
fffffe00091ef718:	08 02 40 f9	ldr	x8, [x16]
fffffe00091ef71c:	61 11 ff d0	adrp	x1, -7634 ; 0xfffffe000741d000
fffffe00091ef720:	21 c4 30 91	add	x1, x1, #0xc31
fffffe00091ef724:	e0 03 13 aa	mov	x0, x19
fffffe00091ef728:	70 64 f8 f2	movk	x16, #0xc323, lsl #48
fffffe00091ef72c:	10 09 3f d7	blraa	x8, x16
fffffe00091ef730:	2c 00 00 14	b	0xfffffe00091ef7e0
fffffe00091ef734:	e8 03 17 aa	mov	x8, x23
fffffe00091ef738:	28 b4 f9 f2	movk	x8, #0xcda1, lsl #48
fffffe00091ef73c:	f0 02 40 f9	ldr	x16, [x23]
fffffe00091ef740:	10 19 c1 da	autda	x16, x8
fffffe00091ef744:	11 2d 80 d2	mov	x17, #0x168
fffffe00091ef748:	10 02 11 8b	add	x16, x16, x17
fffffe00091ef74c:	08 02 40 f9	ldr	x8, [x16]
fffffe00091ef750:	e0 03 17 aa	mov	x0, x23
fffffe00091ef754:	90 0c f4 f2	movk	x16, #0xa064, lsl #48
fffffe00091ef758:	10 09 3f d7	blraa	x8, x16
fffffe00091ef75c:	68 11 ff d0	adrp	x8, -7634 ; 0xfffffe000741d000
fffffe00091ef760:	08 f1 30 91	add	x8, x8, #0xc3c
fffffe00091ef764:	e8 03 00 a9	stp	x8, x0, [sp]
fffffe00091ef768:	60 11 ff d0	adrp	x0, -7634 ; 0xfffffe000741d000
fffffe00091ef76c:	00 80 03 91	add	x0, x0, #0xe0
fffffe00091ef770:	e1 71 ff b0	adrp	x1, -4547 ; 0xfffffe000802c000
fffffe00091ef774:	21 48 47 f9	ldr	x1, [x1, #0xe90]
fffffe00091ef778:	63 11 ff f0	adrp	x3, -7633 ; 0xfffffe000741e000
fffffe00091ef77c:	63 34 32 91	add	x3, x3, #0xc8d
fffffe00091ef780:	02 00 80 52	mov	w2, #0x0
fffffe00091ef784:	c8 1c 00 94	bl	0xfffffe00091f6aa4 ; symbol stub for: __os_log_internal
fffffe00091ef788:	f1 03 18 aa	mov	x17, x24
fffffe00091ef78c:	e8 71 ff b0	adrp	x8, -4547 ; 0xfffffe000802c000
fffffe00091ef790:	08 51 47 f9	ldr	x8, [x8, #0xea0]
fffffe00091ef794:	08 01 40 f9	ldr	x8, [x8]
fffffe00091ef798:	02 01 40 f9	ldr	x2, [x8]
fffffe00091ef79c:	70 02 40 f9	ldr	x16, [x19]
fffffe00091ef7a0:	30 1a c1 da	autda	x16, x17
fffffe00091ef7a4:	f1 03 10 aa	mov	x17, x16
fffffe00091ef7a8:	f1 47 c1 da	xpacd	x17
fffffe00091ef7ac:	1f 02 11 eb	cmp	x16, x17
fffffe00091ef7b0:	40 00 00 54	b.eq	0xfffffe00091ef7b8
fffffe00091ef7b4:	40 8e 38 d4	brk	#0xc472
fffffe00091ef7b8:	08 02 08 91	add	x8, x16, #0x200
fffffe00091ef7bc:	09 02 41 f9	ldr	x9, [x16, #0x200]
fffffe00091ef7c0:	61 11 ff d0	adrp	x1, -7634 ; 0xfffffe000741d000
fffffe00091ef7c4:	21 c4 30 91	add	x1, x1, #0xc31
fffffe00091ef7c8:	e0 03 13 aa	mov	x0, x19
fffffe00091ef7cc:	f1 03 08 aa	mov	x17, x8
fffffe00091ef7d0:	71 64 f8 f2	movk	x17, #0xc323, lsl #48
fffffe00091ef7d4:	31 09 3f d7	blraa	x9, x17
fffffe00091ef7d8:	f6 58 80 52	mov	w22, #0x2c7
fffffe00091ef7dc:	16 00 bc 72	movk	w22, #0xe000, lsl #16
fffffe00091ef7e0:	62 11 ff d0	adrp	x2, -7634 ; 0xfffffe000741d000
fffffe00091ef7e4:	42 c4 30 91	add	x2, x2, #0xc31
fffffe00091ef7e8:	e0 03 14 aa	mov	x0, x20
fffffe00091ef7ec:	e1 03 13 aa	mov	x1, x19
fffffe00091ef7f0:	45 fc ff 97	bl	__ZN38AppleEmbeddedBluetoothDeviceManagement23storeFeaturesPropertyWLEP12OSDictionaryPKc
fffffe00091ef7f4:	e0 03 16 aa	mov	x0, x22
fffffe00091ef7f8:	fd 7b 45 a9	ldp	x29, x30, [sp, #0x50]
fffffe00091ef7fc:	f4 4f 44 a9	ldp	x20, x19, [sp, #0x40]
fffffe00091ef800:	f6 57 43 a9	ldp	x22, x21, [sp, #0x30]
fffffe00091ef804:	f8 5f 42 a9	ldp	x24, x23, [sp, #0x20]
fffffe00091ef808:	ff 83 01 91	add	sp, sp, #0x60
fffffe00091ef80c:	ff 0f 5f d6	retab
