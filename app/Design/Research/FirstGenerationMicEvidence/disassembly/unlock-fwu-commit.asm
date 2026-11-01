
B439-main-thumb.elf:	file format elf32-littlearm

Disassembly of section .text:

08008000 <.text>:
 8024468: b5f0         	push	{r4, r5, r6, r7, lr}
 802446a: af03         	add	r7, sp, #0xc
 802446c: f84d 8d04    	str	r8, [sp, #-4]!
 8024470: b082         	sub	sp, #0x8
 8024472: 4604         	mov	r4, r0
 8024474: 6860         	ldr	r0, [r4, #0x4]
 8024476: 28d2         	cmp	r0, #0xd2
 8024478: db06         	blt	0x8024488 <.text+0x1c488> @ imm = #0xc
 802447a: 4853         	ldr	r0, [pc, #0x14c]        @ 0x80245c8 <.text+0x1c5c8>
 802447c: 4953         	ldr	r1, [pc, #0x14c]        @ 0x80245cc <.text+0x1c5cc>
 802447e: 4b54         	ldr	r3, [pc, #0x150]        @ 0x80245d0 <.text+0x1c5d0>
 8024480: f44f 72a4    	mov.w	r2, #0x148
 8024484: f02a f8da    	bl	0x804e63c <.text+0x4663c> @ imm = #0x2a1b4
 8024488: f8d4 513c    	ldr.w	r5, [r4, #0x13c]
 802448c: 6868         	ldr	r0, [r5, #0x4]
 802448e: 28d2         	cmp	r0, #0xd2
 8024490: db09         	blt	0x80244a6 <.text+0x1c4a6> @ imm = #0x12
 8024492: f8d5 00c0    	ldr.w	r0, [r5, #0xc0]
 8024496: f44f 72f5    	mov.w	r2, #0x1ea
 802449a: 9000         	str	r0, [sp]
 802449c: 484a         	ldr	r0, [pc, #0x128]        @ 0x80245c8 <.text+0x1c5c8>
 802449e: 494d         	ldr	r1, [pc, #0x134]        @ 0x80245d4 <.text+0x1c5d4>
 80244a0: 4b4d         	ldr	r3, [pc, #0x134]        @ 0x80245d8 <.text+0x1c5d8>
 80244a2: f02a f8cb    	bl	0x804e63c <.text+0x4663c> @ imm = #0x2a196
 80244a6: f8d5 00bc    	ldr.w	r0, [r5, #0xbc]
 80244aa: 6801         	ldr	r1, [r0]
 80244ac: 29d0         	cmp	r1, #0xd0
 80244ae: d11b         	bne	0x80244e8 <.text+0x1c4e8> @ imm = #0x36
 80244b0: 6840         	ldr	r0, [r0, #0x4]
 80244b2: 2101         	movs	r1, #0x1
 80244b4: fa01 f000    	lsl.w	r0, r1, r0
 80244b8: f8d5 10c0    	ldr.w	r1, [r5, #0xc0]
 80244bc: 4208         	tst	r0, r1
 80244be: d013         	beq	0x80244e8 <.text+0x1c4e8> @ imm = #0x26
 80244c0: f8b5 8036    	ldrh.w	r8, [r5, #0x36]
 80244c4: f02f fca2    	bl	0x8053e0c <.text+0x4be0c> @ imm = #0x2f944
 80244c8: 2101         	movs	r1, #0x1
 80244ca: 2601         	movs	r6, #0x1
 80244cc: f02f fce3    	bl	0x8053e96 <.text+0x4be96> @ imm = #0x2f9c6
 80244d0: 4580         	cmp	r8, r0
 80244d2: d00a         	beq	0x80244ea <.text+0x1c4ea> @ imm = #0x14
 80244d4: 6868         	ldr	r0, [r5, #0x4]
 80244d6: 280a         	cmp	r0, #0xa
 80244d8: db1b         	blt	0x8024512 <.text+0x1c512> @ imm = #0x36
 80244da: 4840         	ldr	r0, [pc, #0x100]        @ 0x80245dc <.text+0x1c5dc>
 80244dc: 4940         	ldr	r1, [pc, #0x100]        @ 0x80245e0 <.text+0x1c5e0>
 80244de: 4b41         	ldr	r3, [pc, #0x104]        @ 0x80245e4 <.text+0x1c5e4>
 80244e0: f44f 72f8    	mov.w	r2, #0x1f0
 80244e4: f02a f980    	bl	0x804e7e8 <.text+0x467e8> @ imm = #0x2a300
 80244e8: 2600         	movs	r6, #0x0
 80244ea: 6868         	ldr	r0, [r5, #0x4]
 80244ec: 28dc         	cmp	r0, #0xdc
 80244ee: db0c         	blt	0x802450a <.text+0x1c50a> @ imm = #0x18
 80244f0: 9600         	str	r6, [sp]
 80244f2: f44f 72fa    	mov.w	r2, #0x1f4
 80244f6: 483c         	ldr	r0, [pc, #0xf0]         @ 0x80245e8 <.text+0x1c5e8>
 80244f8: 4936         	ldr	r1, [pc, #0xd8]         @ 0x80245d4 <.text+0x1c5d4>
 80244fa: 4b3c         	ldr	r3, [pc, #0xf0]         @ 0x80245ec <.text+0x1c5ec>
 80244fc: f02a f89e    	bl	0x804e63c <.text+0x4663c> @ imm = #0x2a13c
 8024500: 2e00         	cmp	r6, #0x0
 8024502: bf18         	it	ne
 8024504: f7fe fe2c    	blne	0x8023160 <.text+0x1b160> @ imm = #-0x13a8
 8024508: e003         	b	0x8024512 <.text+0x1c512> @ imm = #0x6
 802450a: 2e01         	cmp	r6, #0x1
 802450c: d101         	bne	0x8024512 <.text+0x1c512> @ imm = #0x2
 802450e: f7fe fe27    	bl	0x8023160 <.text+0x1b160> @ imm = #-0x13b2
 8024512: f8d4 513c    	ldr.w	r5, [r4, #0x13c]
 8024516: 6868         	ldr	r0, [r5, #0x4]
 8024518: 28d2         	cmp	r0, #0xd2
 802451a: db09         	blt	0x8024530 <.text+0x1c530> @ imm = #0x12
 802451c: f8d5 00c0    	ldr.w	r0, [r5, #0xc0]
 8024520: f240 12fb    	movw	r2, #0x1fb
 8024524: 9000         	str	r0, [sp]
 8024526: 4828         	ldr	r0, [pc, #0xa0]         @ 0x80245c8 <.text+0x1c5c8>
 8024528: 4931         	ldr	r1, [pc, #0xc4]         @ 0x80245f0 <.text+0x1c5f0>
 802452a: 4b2b         	ldr	r3, [pc, #0xac]         @ 0x80245d8 <.text+0x1c5d8>
 802452c: f02a f886    	bl	0x804e63c <.text+0x4663c> @ imm = #0x2a10c
 8024530: f8d5 00bc    	ldr.w	r0, [r5, #0xbc]
 8024534: 6800         	ldr	r0, [r0]
 8024536: 28d0         	cmp	r0, #0xd0
 8024538: d01a         	beq	0x8024570 <.text+0x1c570> @ imm = #0x34
 802453a: 2100         	movs	r1, #0x0
 802453c: f8d5 00c0    	ldr.w	r0, [r5, #0xc0]
 8024540: 2301         	movs	r3, #0x1
 8024542: 9101         	str	r1, [sp, #0x4]
 8024544: 491d         	ldr	r1, [pc, #0x74]         @ 0x80245bc <.text+0x1c5bc>
 8024546: 680a         	ldr	r2, [r1]
 8024548: f042 5280    	orr	r2, r2, #0x10000000
 802454c: 600a         	str	r2, [r1]
 802454e: 4a1c         	ldr	r2, [pc, #0x70]         @ 0x80245c0 <.text+0x1c5c0>
 8024550: 6809         	ldr	r1, [r1]
 8024552: f001 5180    	and	r1, r1, #0x10000000
 8024556: 9101         	str	r1, [sp, #0x4]
 8024558: 9901         	ldr	r1, [sp, #0x4]
 802455a: f44f 7180    	mov.w	r1, #0x100
 802455e: fa91 f1a1    	rbit	r1, r1
 8024562: fab1 f181    	clz	r1, r1
 8024566: f842 3021    	str.w	r3, [r2, r1, lsl #2]
 802456a: 4916         	ldr	r1, [pc, #0x58]         @ 0x80245c4 <.text+0x1c5c4>
 802456c: 6008         	str	r0, [r1]
 802456e: 6808         	ldr	r0, [r1]
 8024570: 2000         	movs	r0, #0x0
 8024572: f8c5 00c0    	str.w	r0, [r5, #0xc0]
 8024576: 6868         	ldr	r0, [r5, #0x4]
 8024578: 28dc         	cmp	r0, #0xdc
 802457a: db08         	blt	0x802458e <.text+0x1c58e> @ imm = #0x10
 802457c: 20a1         	movs	r0, #0xa1
 802457e: f240 2205    	movw	r2, #0x205
 8024582: 9000         	str	r0, [sp]
 8024584: 4818         	ldr	r0, [pc, #0x60]         @ 0x80245e8 <.text+0x1c5e8>
 8024586: 491a         	ldr	r1, [pc, #0x68]         @ 0x80245f0 <.text+0x1c5f0>
 8024588: 4b18         	ldr	r3, [pc, #0x60]         @ 0x80245ec <.text+0x1c5ec>
 802458a: f02a f857    	bl	0x804e63c <.text+0x4663c> @ imm = #0x2a0ae
 802458e: 20a1         	movs	r0, #0xa1
 8024590: 2100         	movs	r1, #0x0
 8024592: f8c4 0158    	str.w	r0, [r4, #0x158]
 8024596: 4620         	mov	r0, r4
 8024598: f7fe fd8e    	bl	0x80230b8 <.text+0x1b0b8> @ imm = #-0x14e4
 802459c: 6860         	ldr	r0, [r4, #0x4]
 802459e: 28dc         	cmp	r0, #0xdc
 80245a0: db06         	blt	0x80245b0 <.text+0x1c5b0> @ imm = #0xc
 80245a2: 4811         	ldr	r0, [pc, #0x44]         @ 0x80245e8 <.text+0x1c5e8>
 80245a4: 4909         	ldr	r1, [pc, #0x24]         @ 0x80245cc <.text+0x1c5cc>
 80245a6: 4b0a         	ldr	r3, [pc, #0x28]         @ 0x80245d0 <.text+0x1c5d0>
 80245a8: f44f 72ab    	mov.w	r2, #0x156
 80245ac: f02a f846    	bl	0x804e63c <.text+0x4663c> @ imm = #0x2a08c
 80245b0: 2000         	movs	r0, #0x0
 80245b2: b002         	add	sp, #0x8
 80245b4: f85d 8b04    	ldr	r8, [sp], #4
 80245b8: bdf0         	pop	{r4, r5, r6, r7, pc}
