
B439-main-thumb.elf:	file format elf32-littlearm

Disassembly of section .text:

08008000 <.text>:
 8024c98: b5bc         	push	{r2, r3, r4, r5, r7, lr}
 8024c9a: af04         	add	r7, sp, #0x10
 8024c9c: 4604         	mov	r4, r0
 8024c9e: 4615         	mov	r5, r2
 8024ca0: f8d4 2088    	ldr.w	r2, [r4, #0x88]
 8024ca4: 6860         	ldr	r0, [r4, #0x4]
 8024ca6: 428a         	cmp	r2, r1
 8024ca8: d108         	bne	0x8024cbc <.text+0x1ccbc> @ imm = #0x10
 8024caa: 2832         	cmp	r0, #0x32
 8024cac: db18         	blt	0x8024ce0 <.text+0x1cce0> @ imm = #0x30
 8024cae: 28c8         	cmp	r0, #0xc8
 8024cb0: db0f         	blt	0x8024cd2 <.text+0x1ccd2> @ imm = #0x1e
 8024cb2: 9500         	str	r5, [sp]
 8024cb4: 2219         	movs	r2, #0x19
 8024cb6: 4827         	ldr	r0, [pc, #0x9c]         @ 0x8024d54 <.text+0x1cd54>
 8024cb8: 4927         	ldr	r1, [pc, #0x9c]         @ 0x8024d58 <.text+0x1cd58>
 8024cba: e00e         	b	0x8024cda <.text+0x1ccda> @ imm = #0x1c
 8024cbc: 280a         	cmp	r0, #0xa
 8024cbe: bfb8         	it	lt
 8024cc0: bdbc         	poplt	{r2, r3, r4, r5, r7, pc}
 8024cc2: 9500         	str	r5, [sp]
 8024cc4: 2241         	movs	r2, #0x41
 8024cc6: 4826         	ldr	r0, [pc, #0x98]         @ 0x8024d60 <.text+0x1cd60>
 8024cc8: 4926         	ldr	r1, [pc, #0x98]         @ 0x8024d64 <.text+0x1cd64>
 8024cca: 4b27         	ldr	r3, [pc, #0x9c]         @ 0x8024d68 <.text+0x1cd68>
 8024ccc: f029 fd8c    	bl	0x804e7e8 <.text+0x467e8> @ imm = #0x29b18
 8024cd0: bdbc         	pop	{r2, r3, r4, r5, r7, pc}
 8024cd2: 9500         	str	r5, [sp]
 8024cd4: 2100         	movs	r1, #0x0
 8024cd6: 2200         	movs	r2, #0x0
 8024cd8: 481e         	ldr	r0, [pc, #0x78]         @ 0x8024d54 <.text+0x1cd54>
 8024cda: 4b20         	ldr	r3, [pc, #0x80]         @ 0x8024d5c <.text+0x1cd5c>
 8024cdc: f029 fcae    	bl	0x804e63c <.text+0x4663c> @ imm = #0x2995c
 8024ce0: 1f68         	subs	r0, r5, #0x5
 8024ce2: 2805         	cmp	r0, #0x5
 8024ce4: d8f4         	bhi	0x8024cd0 <.text+0x1ccd0> @ imm = #-0x18
 8024ce6: e8df f000    	tbb	[pc, r0]
 8024cea: 2503         	movs	r5, #0x3
 8024cec: 1407         	asrs	r7, r0, #0x10
 8024cee: 3121         	adds	r1, #0x21
 8024cf0: e8bd 40bc    	pop.w	{r2, r3, r4, r5, r7, lr}
 8024cf4: f7fe ba34    	b.w	0x8023160 <.text+0x1b160> @ imm = #-0x1b98
 8024cf8: f8d4 0134    	ldr.w	r0, [r4, #0x134]
 8024cfc: f035 fe48    	bl	0x805a990 <.text+0x52990> @ imm = #0x35c90
 8024d00: 2803         	cmp	r0, #0x3
 8024d02: d0e5         	beq	0x8024cd0 <.text+0x1ccd0> @ imm = #-0x36
 8024d04: f8d4 0134    	ldr.w	r0, [r4, #0x134]
 8024d08: 2101         	movs	r1, #0x1
 8024d0a: e8bd 40bc    	pop.w	{r2, r3, r4, r5, r7, lr}
 8024d0e: f036 b86b    	b.w	0x805ade8 <.text+0x52de8> @ imm = #0x360d6
 8024d12: f8d4 0134    	ldr.w	r0, [r4, #0x134]
 8024d16: f035 fe3b    	bl	0x805a990 <.text+0x52990> @ imm = #0x35c76
 8024d1a: 2803         	cmp	r0, #0x3
 8024d1c: d1d8         	bne	0x8024cd0 <.text+0x1ccd0> @ imm = #-0x50
 8024d1e: f8d4 0134    	ldr.w	r0, [r4, #0x134]
 8024d22: 2100         	movs	r1, #0x0
 8024d24: e8bd 40bc    	pop.w	{r2, r3, r4, r5, r7, lr}
 8024d28: f036 b85e    	b.w	0x805ade8 <.text+0x52de8> @ imm = #0x360bc
 8024d2c: 2001         	movs	r0, #0x1
 8024d2e: f884 0169    	strb.w	r0, [r4, #0x169]
 8024d32: bdbc         	pop	{r2, r3, r4, r5, r7, pc}
 8024d34: f8d4 0134    	ldr.w	r0, [r4, #0x134]
 8024d38: 2101         	movs	r1, #0x1
 8024d3a: f036 f855    	bl	0x805ade8 <.text+0x52de8> @ imm = #0x360aa
 8024d3e: f8d4 0134    	ldr.w	r0, [r4, #0x134]
 8024d42: 2102         	movs	r1, #0x2
 8024d44: e8bd 40bc    	pop.w	{r2, r3, r4, r5, r7, lr}
 8024d48: f036 b84e    	b.w	0x805ade8 <.text+0x52de8> @ imm = #0x3609c
 8024d4c: 2000         	movs	r0, #0x0
 8024d4e: f884 0169    	strb.w	r0, [r4, #0x169]
 8024d52: bdbc         	pop	{r2, r3, r4, r5, r7, pc}
