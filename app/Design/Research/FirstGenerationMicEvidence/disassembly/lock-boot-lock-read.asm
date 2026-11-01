
B439-main-thumb.elf:	file format elf32-littlearm

Disassembly of section .text:

08008000 <.text>:
 80502ea: 4658         	mov	r0, r11
 80502ec: 2100         	movs	r1, #0x0
 80502ee: 2400         	movs	r4, #0x0
 80502f0: f7e3 f8a3    	bl	0x803343a <.text+0x2b43a> @ imm = #-0x1ceba
 80502f4: b1e0         	cbz	r0, 0x8050330 <.text+0x48330> @ imm = #0x38
 80502f6: f8cd 8000    	str.w	r8, [sp]
 80502fa: 4658         	mov	r0, r11
 80502fc: 2100         	movs	r1, #0x0
 80502fe: 2301         	movs	r3, #0x1
 8050300: 2501         	movs	r5, #0x1
 8050302: 4c0a         	ldr	r4, [pc, #0x28]         @ 0x805032c <.text+0x4832c>
 8050304: 4622         	mov	r2, r4
 8050306: f7e3 f8bc    	bl	0x8033482 <.text+0x2b482> @ imm = #-0x1ce88
 805030a: b100         	cbz	r0, 0x805030e <.text+0x4830e> @ imm = #0x0
 805030c: 7025         	strb	r5, [r4]
 805030e: 9c1b         	ldr	r4, [sp, #0x6c]
 8050310: e01a         	b	0x8050348 <.text+0x48348> @ imm = #0x34
 8050312: bf00         	nop
 8050314: 47e2         	<unknown>
 8050316: 0807         	lsrs	r7, r0, #0x20
 8050318: 3282         	adds	r2, #0x82
 805031a: 0807         	lsrs	r7, r0, #0x20
 805031c: 2c79         	cmp	r4, #0x79
 805031e: 0807         	lsrs	r7, r0, #0x20
 8050320: 927c         	str	r2, [sp, #0x1f0]
 8050322: 0806         	lsrs	r6, r0, #0x20
 8050324: 704c         	strb	r4, [r1, #0x1]
 8050326: 0806         	lsrs	r6, r0, #0x20
 8050328: 2f82         	cmp	r7, #0x82
 805032a: 0807         	lsrs	r7, r0, #0x20
 805032c: 27f0         	movs	r7, #0xf0
 805032e: 2000         	movs	r0, #0x0
 8050330: 981b         	ldr	r0, [sp, #0x6c]
 8050332: 2101         	movs	r1, #0x1
 8050334: 2301         	movs	r3, #0x1
 8050336: 9100         	str	r1, [sp]
 8050338: 2100         	movs	r1, #0x0
 805033a: 7004         	strb	r4, [r0]
 805033c: 4604         	mov	r4, r0
 805033e: f8db 0024    	ldr.w	r0, [r11, #0x24]
 8050342: 4622         	mov	r2, r4
 8050344: f7f5 ff48    	bl	0x80461d8 <.text+0x3e1d8> @ imm = #-0xa170
