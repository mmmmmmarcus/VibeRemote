
B439-main-thumb.elf:	file format elf32-littlearm

Disassembly of section .text:

08008000 <.text>:
 802cac4: 1e70         	subs	r0, r6, #0x1
 802cac6: 2801         	cmp	r0, #0x1
 802cac8: f200 8159    	bhi.w	0x802cd7e <.text+0x24d7e> @ imm = #0x2b2
 802cacc: 486f         	ldr	r0, [pc, #0x1bc]        @ 0x802cc8c <.text+0x24c8c>
 802cace: f8d8 43d8    	ldr.w	r4, [r8, #0x3d8]
 802cad2: 6900         	ldr	r0, [r0, #0x10]
 802cad4: f9b4 1242    	ldrsh.w	r1, [r4, #0x242]
 802cad8: 4a6d         	ldr	r2, [pc, #0x1b4]        @ 0x802cc90 <.text+0x24c90>
 802cada: f7f9 fde1    	bl	0x80266a0 <.text+0x1e6a0> @ imm = #-0x643e
 802cade: f8d4 0238    	ldr.w	r0, [r4, #0x238]
 802cae2: 2201         	movs	r2, #0x1
 802cae4: 2501         	movs	r5, #0x1
 802cae6: 6901         	ldr	r1, [r0, #0x10]
 802cae8: 6141         	str	r1, [r0, #0x14]
 802caea: 4620         	mov	r0, r4
 802caec: 2102         	movs	r1, #0x2
 802caee: f7fd ffc1    	bl	0x802aa74 <.text+0x22a74> @ imm = #-0x207e
 802caf2: f504 708a    	add.w	r0, r4, #0x114
 802caf6: f8c4 0128    	str.w	r0, [r4, #0x128]
 802cafa: f06f 0007    	mvn	r0, #0x7
 802cafe: f8c4 0110    	str.w	r0, [r4, #0x110]
 802cb02: f44f 7040    	mov.w	r0, #0x300
 802cb06: f884 5115    	strb.w	r5, [r4, #0x115]
 802cb0a: 4d62         	ldr	r5, [pc, #0x188]        @ 0x802cc94 <.text+0x24c94>
 802cb0c: f8a4 0118    	strh.w	r0, [r4, #0x118]
 802cb10: f204 102d    	addw	r0, r4, #0x12d
 802cb14: f8c4 0124    	str.w	r0, [r4, #0x124]
 802cb18: 209b         	movs	r0, #0x9b
 802cb1a: f8c4 011c    	str.w	r0, [r4, #0x11c]
 802cb1e: 2005         	movs	r0, #0x5
 802cb20: f884 011a    	strb.w	r0, [r4, #0x11a]
 802cb24: 2000         	movs	r0, #0x0
 802cb26: f8c4 0120    	str.w	r0, [r4, #0x120]
 802cb2a: 485b         	ldr	r0, [pc, #0x16c]        @ 0x802cc98 <.text+0x24c98>
 802cb2c: 5d80         	ldrb	r0, [r0, r6]
 802cb2e: f884 0116    	strb.w	r0, [r4, #0x116]
 802cb32: f894 1246    	ldrb.w	r1, [r4, #0x246]
 802cb36: f884 112c    	strb.w	r1, [r4, #0x12c]
 802cb3a: f884 1117    	strb.w	r1, [r4, #0x117]
 802cb3e: 6a63         	ldr	r3, [r4, #0x24]
 802cb40: 6862         	ldr	r2, [r4, #0x4]
 802cb42: 1c5e         	adds	r6, r3, #0x1
 802cb44: f363 2517    	bfi	r5, r3, #8, #16
 802cb48: 2a3c         	cmp	r2, #0x3c
 802cb4a: 6266         	str	r6, [r4, #0x24]
 802cb4c: f8c4 5108    	str.w	r5, [r4, #0x108]
 802cb50: f504 7582    	add.w	r5, r4, #0x104
 802cb54: f8d4 3264    	ldr.w	r3, [r4, #0x264]
 802cb58: f103 0301    	add.w	r3, r3, #0x1
 802cb5c: f8c4 3264    	str.w	r3, [r4, #0x264]
