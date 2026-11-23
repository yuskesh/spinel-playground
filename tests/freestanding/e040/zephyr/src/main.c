/* E040 -- P003 Phase 1 (M1): the MCU side of the differential oracle.
 *
 * Boots Zephyr, calls every entry the freestanding kernel object exports, and
 * prints one `E040<TAB><case><TAB><result>` line per case.  The host side
 * (e040_host.rb, compiled by bin/spinel through its ordinary C back end) prints
 * exactly the same first two columns, and run_gates.sh joins them.
 *
 * THE PROTOTYPES ARE NOT WRITTEN HERE.  `spinel-mlirgen --emit-header` wrote
 * them into spinel_freestanding.h from the same declarations it compiled, so a
 * transcription error is not possible -- which is the point of having the
 * boundary be a declaration at all.
 *
 * ---------------------------------------------------------------------------
 * WHAT `spinel_trap` DOES HERE, and why it is allowed to be different
 *
 * P003 decision record D-2 makes the trap hook the PLATFORM's responsibility:
 * the generator emits a call to a noreturn symbol and `llvm.unreachable` after
 * it, and what happens next is not the compiler's business.  Two platforms are
 * built from this one file:
 *
 *   default            spinel_trap records (code, a, b, detail) and longjmps
 *                      back into the driver, so all 31 cases -- including the
 *                      seven that trap -- run in ONE image.  It never returns to
 *                      its caller, which is the only thing the generated code
 *                      assumes.  This is exactly what the HOSTED runtime does
 *                      (sp_raise_cls longjmps to the innermost handler,
 *                      spinel_rt.h:6685), so it is not a special-case invention.
 *   E040_PANIC_TRAP    spinel_trap prints and calls k_panic(), which is what a
 *                      real product would do.  R006 P6 demonstrated this shape;
 *                      the panic build re-demonstrates it so that the claim
 *                      "a trap really is fatal" does not rest on the harness's
 *                      convenience implementation.
 */
#include <zephyr/kernel.h>
#include <zephyr/sys/printk.h>
#include <setjmp.h>
#include <stdint.h>

#include "spinel_freestanding.h"

static jmp_buf e040_jmp;
static volatile int e040_armed;
static volatile int e040_code;
static const char *volatile e040_detail;

void spinel_trap(int32_t code, int64_t a, int64_t b, const char *detail)
{
#ifdef E040_PANIC_TRAP
	printk("E040\tTRAP\tcode=%d a=%lld b=%lld detail=%s\n",
	       (int)code, (long long)a, (long long)b, detail);
	k_panic();
	for (;;) {
	}
#else
	(void)a;
	(void)b;
	e040_code = code;
	e040_detail = detail;
	if (e040_armed) {
		longjmp(e040_jmp, 1);
	}
	/* A trap outside a driver arm is a bug in the harness, not in the
	 * kernel object; say so loudly rather than falling off the end. */
	printk("E040\tFATAL\tunarmed trap code=%d detail=%s\n", (int)code, detail);
	k_panic();
	for (;;) {
	}
#endif
}

/* Every case is invoked under setjmp, so a trap becomes a row rather than the
 * end of the run.  `volatile` on nothing here: the only object live across
 * setjmp is the loop index, which lives in the generated code below as a
 * straight-line sequence. */
#define E040_CASE(name, expr)                                                  \
	do {                                                                   \
		e040_code = 0;                                                 \
		e040_armed = 1;                                                \
		if (setjmp(e040_jmp) == 0) {                                   \
			long long _v = (long long)(expr);                      \
			e040_armed = 0;                                        \
			printk("E040\t%s\t%lld\n", name, _v);                  \
		} else {                                                       \
			e040_armed = 0;                                        \
			printk("E040\t%s\ttrap:%d\n", name, (int)e040_code);   \
		}                                                              \
	} while (0);

int main(void)
{
	printk("E040\tBEGIN\t%s\n", CONFIG_BOARD_TARGET);
#ifdef E040_PANIC_TRAP
	/* The panic build runs exactly one case: the one that traps. */
	printk("E040\tpanic-probe\t%lld\n",
	       (long long)spinel_mulnarrow(46341, 46341));
	printk("E040\tUNREACHABLE\t0\n");
#else
#include "cases.inc"
	printk("E040\tEND\t0\n");
#endif
	return 0;
}
