
B439-main-thumb.elf:	file format elf32-littlearm

Disassembly of section .text:

08008000 <.text>:
 802493c: b5f0         	push	{r4, r5, r6, r7, lr}
 802493e: af03         	add	r7, sp, #0xc
 8024940: e92d 0700    	push.w	{r8, r9, r10}
 8024944: b098         	sub	sp, #0x60
 8024946: 4605         	mov	r5, r0
 8024948: 460c         	mov	r4, r1
 802494a: 6868         	ldr	r0, [r5, #0x4]
 802494c: 28d2         	cmp	r0, #0xd2
 802494e: db09         	blt	0x8024964 <.text+0x1c964> @ imm = #0x12
 8024950: 78e0         	ldrb	r0, [r4, #0x3]
 8024952: 68a1         	ldr	r1, [r4, #0x8]
 8024954: 22d1         	movs	r2, #0xd1
 8024956: e9cd 0100    	strd	r0, r1, [sp]
 802495a: 48c7         	ldr	r0, [pc, #0x31c]        @ 0x8024c78 <.text+0x1cc78>
 802495c: 49c7         	ldr	r1, [pc, #0x31c]        @ 0x8024c7c <.text+0x1cc7c>
 802495e: 4bc8         	ldr	r3, [pc, #0x320]        @ 0x8024c80 <.text+0x1cc80>
 8024960: f029 fe6c    	bl	0x804e63c <.text+0x4663c> @ imm = #0x29cd8
 8024964: 78e0         	ldrb	r0, [r4, #0x3]
 8024966: f04f 36ff    	mov.w	r6, #0xffffffff
 802496a: f1a0 01b0    	sub.w	r1, r0, #0xb0
 802496e: 290c         	cmp	r1, #0xc
 8024970: d91a         	bls	0x80249a8 <.text+0x1c9a8> @ imm = #0x34
 8024972: f1a0 0154    	sub.w	r1, r0, #0x54
 8024976: 2904         	cmp	r1, #0x4
 8024978: d92c         	bls	0x80249d4 <.text+0x1c9d4> @ imm = #0x58
 802497a: 2813         	cmp	r0, #0x13
 802497c: f000 8142    	beq.w	0x8024c04 <.text+0x1cc04> @ imm = #0x284
 8024980: 288e         	cmp	r0, #0x8e
 8024982: f000 80b4    	beq.w	0x8024aee <.text+0x1caee> @ imm = #0x168
 8024986: 288f         	cmp	r0, #0x8f
 8024988: f000 80ba    	beq.w	0x8024b00 <.text+0x1cb00> @ imm = #0x174
 802498c: 28e0         	cmp	r0, #0xe0
 802498e: f000 80c5    	beq.w	0x8024b1c <.text+0x1cb1c> @ imm = #0x18a
 8024992: 28e1         	cmp	r0, #0xe1
 8024994: f000 80d4    	beq.w	0x8024b40 <.text+0x1cb40> @ imm = #0x1a8
 8024998: 28ff         	cmp	r0, #0xff
 802499a: f000 80de    	beq.w	0x8024b5a <.text+0x1cb5a> @ imm = #0x1bc
