
B439-main-thumb.elf:	file format elf32-littlearm

Disassembly of section .text:

08008000 <.text>:
 8033482: b5f0         	push	{r4, r5, r6, r7, lr}
 8033484: af03         	add	r7, sp, #0xc
 8033486: e92d 0bc0    	push.w	{r6, r7, r8, r9, r11}
 803348a: 461d         	mov	r5, r3
 803348c: 4690         	mov	r8, r2
 803348e: 4606         	mov	r6, r0
 8033490: f000 f83a    	bl	0x8033508 <.text+0x2b508> @ imm = #0x74
 8033494: b340         	cbz	r0, 0x80334e8 <.text+0x2b4e8> @ imm = #0x50
 8033496: f8d7 9008    	ldr.w	r9, [r7, #0x8]
 803349a: b345         	cbz	r5, 0x80334ee <.text+0x2b4ee> @ imm = #0x50
 803349c: 7b01         	ldrb	r1, [r0, #0xc]
 803349e: 6804         	ldr	r4, [r0]
 80334a0: 4668         	mov	r0, sp
 80334a2: 220a         	movs	r2, #0xa
 80334a4: eb06 0181    	add.w	r1, r6, r1, lsl #2
 80334a8: 6ace         	ldr	r6, [r1, #0x2c]
 80334aa: f106 0128    	add.w	r1, r6, #0x28
 80334ae: f029 fc8d    	bl	0x805cdcc <.text+0x54dcc> @ imm = #0x2991a
 80334b2: 6936         	ldr	r6, [r6, #0x10]
 80334b4: 4621         	mov	r1, r4
 80334b6: 4630         	mov	r0, r6
 80334b8: f012 fe08    	bl	0x80460cc <.text+0x3e0cc> @ imm = #0x12c10
 80334bc: b1d8         	cbz	r0, 0x80334f6 <.text+0x2b4f6> @ imm = #0x36
 80334be: 7902         	ldrb	r2, [r0, #0x4]
 80334c0: 7943         	ldrb	r3, [r0, #0x5]
 80334c2: 7981         	ldrb	r1, [r0, #0x6]
 80334c4: 79c0         	ldrb	r0, [r0, #0x7]
 80334c6: ea42 2403    	orr.w	r4, r2, r3, lsl #8
 80334ca: ea41 2000    	orr.w	r0, r1, r0, lsl #8
 80334ce: 42ac         	cmp	r4, r5
 80334d0: eb06 0100    	add.w	r1, r6, r0
 80334d4: 4640         	mov	r0, r8
 80334d6: bf88         	it	hi
 80334d8: 462c         	movhi	r4, r5
 80334da: 4622         	mov	r2, r4
 80334dc: f7d7 fabc    	bl	0x800aa58 <.text+0x2a58> @ imm = #-0x28a88
 80334e0: f8c9 4000    	str.w	r4, [r9]
 80334e4: 2400         	movs	r4, #0x0
 80334e6: e008         	b	0x80334fa <.text+0x2b4fa> @ imm = #0x10
 80334e8: f04f 34ff    	mov.w	r4, #0xffffffff
 80334ec: e008         	b	0x8033500 <.text+0x2b500> @ imm = #0x10
 80334ee: 2400         	movs	r4, #0x0
 80334f0: f8c9 4000    	str.w	r4, [r9]
 80334f4: e004         	b	0x8033500 <.text+0x2b500> @ imm = #0x8
 80334f6: f04f 34ff    	mov.w	r4, #0xffffffff
 80334fa: 4668         	mov	r0, sp
 80334fc: f029 fc98    	bl	0x805ce30 <.text+0x54e30> @ imm = #0x29930
 8033500: 4620         	mov	r0, r4
 8033502: e8bd 0b0c    	pop.w	{r2, r3, r8, r9, r11}
 8033506: bdf0         	pop	{r4, r5, r6, r7, pc}
 8033508: b5d0         	push	{r4, r6, r7, lr}
 803350a: af02         	add	r7, sp, #0x8
 803350c: f8d0 c038    	ldr.w	r12, [r0, #0x38]
 8033510: 2200         	movs	r2, #0x0
 8033512: f04f 33ff    	mov.w	r3, #0xffffffff
 8033516: 3301         	adds	r3, #0x1
 8033518: 4563         	cmp	r3, r12
 803351a: bf24         	itt	hs
 803351c: 2000         	movhs	r0, #0x0
 803351e: bdd0         	pophs	{r4, r6, r7, pc}
 8033520: 6b44         	ldr	r4, [r0, #0x34]
 8033522: f102 0e10    	add.w	lr, r2, #0x10
 8033526: 58a2         	ldr	r2, [r4, r2]
 8033528: 428a         	cmp	r2, r1
 803352a: 4672         	mov	r2, lr
 803352c: d1f3         	bne	0x8033516 <.text+0x2b516> @ imm = #-0x1a
 803352e: eb04 000e    	add.w	r0, r4, lr
 8033532: 3810         	subs	r0, #0x10
 8033534: bdd0         	pop	{r4, r6, r7, pc}
 8033536: bf00         	nop
 8033538: 4804         	ldr	r0, [pc, #0x10]         @ 0x803354c <.text+0x2b54c>
 803353a: 6a00         	ldr	r0, [r0, #0x20]
 803353c: b100         	cbz	r0, 0x8033540 <.text+0x2b540> @ imm = #0x0
 803353e: 4770         	bx	lr
 8033540: b580         	push	{r7, lr}
 8033542: 466f         	mov	r7, sp
 8033544: 4802         	ldr	r0, [pc, #0x8]          @ 0x8033550 <.text+0x2b550>
 8033546: f7f5 fc99    	bl	0x8028e7c <.text+0x20e7c> @ imm = #-0xa6ce
