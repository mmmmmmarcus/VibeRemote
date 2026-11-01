
B439-main-thumb.elf:	file format elf32-littlearm

Disassembly of section .text:

08008000 <.text>:
 8024b40: 68a3         	ldr	r3, [r4, #0x8]
 8024b42: 6922         	ldr	r2, [r4, #0x10]
 8024b44: f8d5 0140    	ldr.w	r0, [r5, #0x140]
 8024b48: f104 010c    	add.w	r1, r4, #0xc
 8024b4c: 2600         	movs	r6, #0x0
 8024b4e: 9100         	str	r1, [sp]
 8024b50: 2100         	movs	r1, #0x0
 8024b52: f00e fc96    	bl	0x8033482 <.text+0x2b482> @ imm = #0xe92c
 8024b56: bbf0         	cbnz	r0, 0x8024bd6 <.text+0x1cbd6> @ imm = #0x7c
 8024b58: e052         	b	0x8024c00 <.text+0x1cc00> @ imm = #0xa4
 8024b5a: 68a1         	ldr	r1, [r4, #0x8]
 8024b5c: f8d5 2128    	ldr.w	r2, [r5, #0x128]
 8024b60: 6920         	ldr	r0, [r4, #0x10]
 8024b62: 4291         	cmp	r1, r2
 8024b64: bf38         	it	lo
 8024b66: 460a         	movlo	r2, r1
 8024b68: f105 01e8    	add.w	r1, r5, #0xe8
 8024b6c: 60e2         	str	r2, [r4, #0xc]
 8024b6e: e044         	b	0x8024bfa <.text+0x1cbfa> @ imm = #0x88
