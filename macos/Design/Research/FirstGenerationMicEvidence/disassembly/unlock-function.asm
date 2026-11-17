
B439-main-thumb.elf:	file format elf32-littlearm

Disassembly of section .text:

08008000 <.text>:
 8023160: b5bc         	push	{r2, r3, r4, r5, r7, lr}
 8023162: af04         	add	r7, sp, #0x10
 8023164: 2000         	movs	r0, #0x0
 8023166: f807 0c09    	strb	r0, [r7, #-9]
 802316a: 4810         	ldr	r0, [pc, #0x40]         @ 0x80231ac <.text+0x1b1ac>
 802316c: 4910         	ldr	r1, [pc, #0x40]         @ 0x80231b0 <.text+0x1b1b0>
 802316e: f039 f969    	bl	0x805c444 <.text+0x54444> @ imm = #0x392d2
 8023172: 4810         	ldr	r0, [pc, #0x40]         @ 0x80231b4 <.text+0x1b1b4>
 8023174: f02b f856    	bl	0x804e224 <.text+0x46224> @ imm = #0x2b0ac
 8023178: 4c0f         	ldr	r4, [pc, #0x3c]         @ 0x80231b8 <.text+0x1b1b8>
 802317a: f06f 054f    	mvn	r5, #0x4f
 802317e: e003         	b	0x8023188 <.text+0x1b188> @ imm = #0x6
 8023180: 4620         	mov	r0, r4
 8023182: f02b f84f    	bl	0x804e224 <.text+0x46224> @ imm = #0x2b09e
 8023186: 3501         	adds	r5, #0x1
 8023188: 2d00         	cmp	r5, #0x0
 802318a: d1f9         	bne	0x8023180 <.text+0x1b180> @ imm = #-0xe
 802318c: 480b         	ldr	r0, [pc, #0x2c]         @ 0x80231bc <.text+0x1b1bc>
 802318e: f02b f849    	bl	0x804e224 <.text+0x46224> @ imm = #0x2b092
 8023192: f030 fe3b    	bl	0x8053e0c <.text+0x4be0c> @ imm = #0x30c76
 8023196: 6ac0         	ldr	r0, [r0, #0x2c]
 8023198: 2101         	movs	r1, #0x1
 802319a: f1a7 0209    	sub.w	r2, r7, #0x9
 802319e: 2301         	movs	r3, #0x1
 80231a0: 9100         	str	r1, [sp]
 80231a2: 2100         	movs	r1, #0x0
 80231a4: f023 f818    	bl	0x80461d8 <.text+0x3e1d8> @ imm = #0x23030
 80231a8: bdbc         	pop	{r2, r3, r4, r5, r7, pc}
 80231aa: bf00         	nop
 80231ac: e225         	b	0x80235fa <.text+0x1b5fa> @ imm = #0x44a
 80231ae: 0804         	lsrs	r4, r0, #0x20
 80231b0: c288         	stm	r2!, {r3, r7}
 80231b2: 0806         	lsrs	r6, r0, #0x20
 80231b4: c294         	stm	r2!, {r2, r4, r7}
 80231b6: 0806         	lsrs	r6, r0, #0x20
 80231b8: 4b59         	ldr	r3, [pc, #0x164]        @ 0x8023320 <.text+0x1b320>
 80231ba: 0807         	lsrs	r7, r0, #0x20
 80231bc: 4b5b         	ldr	r3, [pc, #0x16c]        @ 0x802332c <.text+0x1b32c>
 80231be: 0807         	lsrs	r7, r0, #0x20
