
B439-main-thumb.elf:	file format elf32-littlearm

Disassembly of section .text:

08008000 <.text>:
 802a3f4: 6823         	ldr	r3, [r4]
 802a3f6: 2100         	movs	r1, #0x0
 802a3f8: 7998         	ldrb	r0, [r3, #0x6]
 802a3fa: b110         	cbz	r0, 0x802a402 <.text+0x22402> @ imm = #0x4
 802a3fc: 60d9         	str	r1, [r3, #0xc]
 802a3fe: 6823         	ldr	r3, [r4]
 802a400: 7999         	ldrb	r1, [r3, #0x6]
 802a402: 789a         	ldrb	r2, [r3, #0x2]
 802a404: 7918         	ldrb	r0, [r3, #0x4]
 802a406: 68db         	ldr	r3, [r3, #0xc]
 802a408: f509 7896    	add.w	r8, r9, #0x12c
 802a40c: f8d9 925c    	ldr.w	r9, [r9, #0x25c]
 802a410: 2500         	movs	r5, #0x0
 802a412: f103 0a01    	add.w	r10, r3, #0x1
 802a416: 4b7b         	ldr	r3, [pc, #0x1ec]        @ 0x802a604 <.text+0x22604>
 802a418: e003         	b	0x802a422 <.text+0x22422> @ imm = #0x6
 802a41a: 5d5e         	ldrb	r6, [r3, r5]
 802a41c: 4296         	cmp	r6, r2
 802a41e: d002         	beq	0x802a426 <.text+0x22426> @ imm = #0x4
 802a420: 3501         	adds	r5, #0x1
 802a422: 2d06         	cmp	r5, #0x6
 802a424: d9f9         	bls	0x802a41a <.text+0x2241a> @ imm = #-0xe
 802a426: 290a         	cmp	r1, #0xa
 802a428: f200 80cc    	bhi.w	0x802a5c4 <.text+0x225c4> @ imm = #0x198
 802a42c: 2400         	movs	r4, #0x0
 802a42e: e8df f001    	tbb	[pc, r1]
 802a432: 0c3b         	lsrs	r3, r7, #0x10
 802a434: 3606         	adds	r6, #0x6
 802a436: 0906         	lsrs	r6, r0, #0x4
 802a438: 0909         	lsrs	r1, r1, #0x4
 802a43a: 0639         	lsls	r1, r7, #0x18
 802a43c: 000c         	movs	r4, r1
 802a43e: f640 2406    	movw	r4, #0xa06
 802a442: e031         	b	0x802a4a8 <.text+0x224a8> @ imm = #0x62
 802a444: f640 240a    	movw	r4, #0xa0a
 802a448: e02e         	b	0x802a4a8 <.text+0x224a8> @ imm = #0x5c
 802a44a: f640 2435    	movw	r4, #0xa35
 802a44e: e02b         	b	0x802a4a8 <.text+0x224a8> @ imm = #0x56
 802a450: 485f         	ldr	r0, [pc, #0x17c]        @ 0x802a5d0 <.text+0x225d0>
 802a452: 4b71         	ldr	r3, [pc, #0x1c4]        @ 0x802a618 <.text+0x22618>
 802a454: 2100         	movs	r1, #0x0
 802a456: 2200         	movs	r2, #0x0
 802a458: f024 f8f0    	bl	0x804e63c <.text+0x4663c> @ imm = #0x241e0
 802a45c: f899 0244    	ldrb.w	r0, [r9, #0x244]
 802a460: 2800         	cmp	r0, #0x0
 802a462: f43f af2f    	beq.w	0x802a2c4 <.text+0x222c4> @ imm = #-0x1a2
 802a466: 9d05         	ldr	r5, [sp, #0x14]
 802a468: 2400         	movs	r4, #0x0
 802a46a: 2100         	movs	r1, #0x0
 802a46c: f885 4244    	strb.w	r4, [r5, #0x244]
 802a470: f8d5 0230    	ldr.w	r0, [r5, #0x230]
 802a474: f7ff f8ea    	bl	0x802964c <.text+0x2164c> @ imm = #-0xe2c
 802a478: a910         	add	r1, sp, #0x40
 802a47a: 2001         	movs	r0, #0x1
 802a47c: 2202         	movs	r2, #0x2
 802a47e: f8ad 4040    	strh.w	r4, [sp, #0x40]
 802a482: f023 facb    	bl	0x804da1c <.text+0x45a1c> @ imm = #0x23596
 802a486: f44f 707a    	mov.w	r0, #0x3e8
 802a48a: 2100         	movs	r1, #0x0
 802a48c: f7e4 fe94    	bl	0x800f1b8 <.text+0x71b8> @ imm = #-0x1b2d8
 802a490: 4628         	mov	r0, r5
 802a492: 210c         	movs	r1, #0xc
 802a494: 2200         	movs	r2, #0x0
 802a496: 2300         	movs	r3, #0x0
 802a498: f02f fb76    	bl	0x8059b88 <.text+0x51b88> @ imm = #0x2f6ec
 802a49c: e712         	b	0x802a2c4 <.text+0x222c4> @ imm = #-0x1dc
 802a49e: f640 2411    	movw	r4, #0xa11
 802a4a2: e001         	b	0x802a4a8 <.text+0x224a8> @ imm = #0x2
 802a4a4: f640 240d    	movw	r4, #0xa0d
 802a4a8: 2801         	cmp	r0, #0x1
 802a4aa: d017         	beq	0x802a4dc <.text+0x224dc> @ imm = #0x2e
 802a4ac: 2800         	cmp	r0, #0x0
 802a4ae: d173         	bne	0x802a598 <.text+0x22598> @ imm = #0xe6
 802a4b0: f8d9 1004    	ldr.w	r1, [r9, #0x4]
 802a4b4: fa1f f68a    	uxth.w	r6, r10
 802a4b8: 2931         	cmp	r1, #0x31
 802a4ba: dd32         	ble	0x802a522 <.text+0x22522> @ imm = #0x64
 802a4bc: b2a0         	uxth	r0, r4
 802a4be: 29c8         	cmp	r1, #0xc8
 802a4c0: db26         	blt	0x802a510 <.text+0x22510> @ imm = #0x4c
 802a4c2: 9602         	str	r6, [sp, #0x8]
 802a4c4: e9cd 5000    	strd	r5, r0, [sp]
 802a4c8: 22e3         	movs	r2, #0xe3
 802a4ca: 4841         	ldr	r0, [pc, #0x104]        @ 0x802a5d0 <.text+0x225d0>
 802a4cc: 494e         	ldr	r1, [pc, #0x138]        @ 0x802a608 <.text+0x22608>
 802a4ce: e025         	b	0x802a51c <.text+0x2251c> @ imm = #0x4a
 802a4d0: 1c12         	adds	r2, r2, #0x0
 802a4d2: 0807         	lsrs	r7, r0, #0x20
 802a4d4: 1cbb         	adds	r3, r7, #0x2
 802a4d6: 0807         	lsrs	r7, r0, #0x20
 802a4d8: 47e2         	<unknown>
 802a4da: 0807         	lsrs	r7, r0, #0x20
 802a4dc: f8d9 1004    	ldr.w	r1, [r9, #0x4]
 802a4e0: 2932         	cmp	r1, #0x32
 802a4e2: db3e         	blt	0x802a562 <.text+0x22562> @ imm = #0x7c
 802a4e4: b2a0         	uxth	r0, r4
 802a4e6: 29c8         	cmp	r1, #0xc8
 802a4e8: db33         	blt	0x802a552 <.text+0x22552> @ imm = #0x66
 802a4ea: e9cd 5000    	strd	r5, r0, [sp]
 802a4ee: 22f1         	movs	r2, #0xf1
 802a4f0: 4837         	ldr	r0, [pc, #0xdc]         @ 0x802a5d0 <.text+0x225d0>
 802a4f2: 4947         	ldr	r1, [pc, #0x11c]        @ 0x802a610 <.text+0x22610>
 802a4f4: e032         	b	0x802a55c <.text+0x2255c> @ imm = #0x64
 802a4f6: bf00         	nop
 802a4f8: 47e2         	<unknown>
 802a4fa: 0807         	lsrs	r7, r0, #0x20
 802a4fc: 1cf1         	adds	r1, r6, #0x3
 802a4fe: 0807         	lsrs	r7, r0, #0x20
 802a500: 1c50         	adds	r0, r2, #0x1
 802a502: 0807         	lsrs	r7, r0, #0x20
 802a504: 1324         	asrs	r4, r4, #0xc
 802a506: 0807         	lsrs	r7, r0, #0x20
 802a508: d5f1         	bpl	0x802a4ee <.text+0x224ee> @ imm = #-0x1e
 802a50a: 0806         	lsrs	r6, r0, #0x20
 802a50c: d5cf         	bpl	0x802a4ae <.text+0x224ae> @ imm = #-0x62
 802a50e: 0806         	lsrs	r6, r0, #0x20
 802a510: 9602         	str	r6, [sp, #0x8]
 802a512: e9cd 5000    	strd	r5, r0, [sp]
 802a516: 2100         	movs	r1, #0x0
 802a518: 2200         	movs	r2, #0x0
 802a51a: 482d         	ldr	r0, [pc, #0xb4]         @ 0x802a5d0 <.text+0x225d0>
 802a51c: 4b3b         	ldr	r3, [pc, #0xec]         @ 0x802a60c <.text+0x2260c>
 802a51e: f024 f88d    	bl	0x804e63c <.text+0x4663c> @ imm = #0x2411a
 802a522: fa1f f08a    	uxth.w	r0, r10
 802a526: 289c         	cmp	r0, #0x9c
 802a528: d24c         	bhs	0x802a5c4 <.text+0x225c4> @ imm = #0x98
 802a52a: f8ad 4042    	strh.w	r4, [sp, #0x42]
 802a52e: f8ad 5040    	strh.w	r5, [sp, #0x40]
 802a532: ad10         	add	r5, sp, #0x40
 802a534: 4641         	mov	r1, r8
 802a536: 4632         	mov	r2, r6
 802a538: 1d28         	adds	r0, r5, #0x4
 802a53a: f7e0 fa8d    	bl	0x800aa58 <.text+0x2a58> @ imm = #-0x1fae6
 802a53e: 2001         	movs	r0, #0x1
 802a540: 1d32         	adds	r2, r6, #0x4
 802a542: 2152         	movs	r1, #0x52
 802a544: 462b         	mov	r3, r5
 802a546: 9000         	str	r0, [sp]
 802a548: 4648         	mov	r0, r9
 802a54a: f01a fea7    	bl	0x804529c <.text+0x3d29c> @ imm = #0x1ad4e
 802a54e: b9b0         	cbnz	r0, 0x802a57e <.text+0x2257e> @ imm = #0x2c
 802a550: e022         	b	0x802a598 <.text+0x22598> @ imm = #0x44
 802a552: e9cd 5000    	strd	r5, r0, [sp]
 802a556: 2100         	movs	r1, #0x0
 802a558: 2200         	movs	r2, #0x0
 802a55a: 481d         	ldr	r0, [pc, #0x74]         @ 0x802a5d0 <.text+0x225d0>
 802a55c: 4b2d         	ldr	r3, [pc, #0xb4]         @ 0x802a614 <.text+0x22614>
 802a55e: f024 f86d    	bl	0x804e63c <.text+0x4663c> @ imm = #0x240da
 802a562: 2001         	movs	r0, #0x1
 802a564: ab10         	add	r3, sp, #0x40
 802a566: 2157         	movs	r1, #0x57
 802a568: 2204         	movs	r2, #0x4
 802a56a: f8ad 4042    	strh.w	r4, [sp, #0x42]
 802a56e: f8ad 5040    	strh.w	r5, [sp, #0x40]
 802a572: 9000         	str	r0, [sp]
 802a574: 4648         	mov	r0, r9
 802a576: f01a fe91    	bl	0x804529c <.text+0x3d29c> @ imm = #0x1ad22
 802a57a: 2801         	cmp	r0, #0x1
 802a57c: d10c         	bne	0x802a598 <.text+0x22598> @ imm = #0x18
 802a57e: 9a05         	ldr	r2, [sp, #0x14]
 802a580: f8d2 0128    	ldr.w	r0, [r2, #0x128]
 802a584: f502 711b    	add.w	r1, r2, #0x26c
 802a588: 7900         	ldrb	r0, [r0, #0x4]
 802a58a: 2801         	cmp	r0, #0x1
 802a58c: bf08         	it	eq
 802a58e: f502 711a    	addeq.w	r1, r2, #0x268
 802a592: 6808         	ldr	r0, [r1]
 802a594: 3001         	adds	r0, #0x1
 802a596: 6008         	str	r0, [r1]
 802a598: 9c05         	ldr	r4, [sp, #0x14]
 802a59a: 2000         	movs	r0, #0x0
 802a59c: 2101         	movs	r1, #0x1
 802a59e: 2201         	movs	r2, #0x1
 802a5a0: f8c4 0254    	str.w	r0, [r4, #0x254]
 802a5a4: 4620         	mov	r0, r4
 802a5a6: f000 fa65    	bl	0x802aa74 <.text+0x22a74> @ imm = #0x4ca
 802a5aa: 4620         	mov	r0, r4
 802a5ac: 2102         	movs	r1, #0x2
 802a5ae: 2200         	movs	r2, #0x0
 802a5b0: f000 fa60    	bl	0x802aa74 <.text+0x22a74> @ imm = #0x4c0
 802a5b4: 9806         	ldr	r0, [sp, #0x18]
 802a5b6: f9b4 1242    	ldrsh.w	r1, [r4, #0x242]
 802a5ba: 6900         	ldr	r0, [r0, #0x10]
 802a5bc: 4a03         	ldr	r2, [pc, #0xc]          @ 0x802a5cc <.text+0x225cc>
 802a5be: f7fc f8b3    	bl	0x8026728 <.text+0x1e728> @ imm = #-0x3e9a
 802a5c2: e67f         	b	0x802a2c4 <.text+0x222c4> @ imm = #-0x302
