/* bm040: setjmp/longjmp for Thumb-2 with no floating-point state (the image is
 * soft-float, so there are no s16-s31 to keep). A jump buffer holds the AAPCS
 * callee-saved registers r4-r11, then sp and lr: ten words.
 *
 *   int  bm_setjmp(bm_jmp_buf env);            0 directly, nonzero from a jump
 *   void bm_longjmp(bm_jmp_buf env, int val);  returns val (1 if val is 0)
 */
	.syntax unified
	.thumb
	.text

	.global bm_setjmp
	.type bm_setjmp, %function
	.thumb_func
bm_setjmp:
	stmia	r0!, {r4-r11}
	mov	r2, sp
	str	r2, [r0], #4
	str	lr, [r0]
	movs	r0, #0
	bx	lr
	.size bm_setjmp, . - bm_setjmp

	.global bm_longjmp
	.type bm_longjmp, %function
	.thumb_func
bm_longjmp:
	ldmia	r0!, {r4-r11}
	ldr	r2, [r0], #4
	mov	sp, r2
	ldr	lr, [r0]
	movs	r0, r1
	it	eq
	moveq	r0, #1
	bx	lr
	.size bm_longjmp, . - bm_longjmp
