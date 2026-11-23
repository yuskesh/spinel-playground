/* E077 -- P003 Phase 2: the MCU side of the four-way differential.
 *
 * The same shape E040's driver had, with one thing added: a case's answer is
 * now the returned value AND, where the declaration says a buffer is written,
 * the buffer's contents afterwards.  Printing both is what makes "the four
 * targets agree" a statement about MEMORY and not only about r0.
 *
 * THE PROTOTYPES ARE NOT WRITTEN HERE.  `spinel-mlirgen --emit-header` wrote
 * them from the same declarations it compiled, so a transcription error is not
 * possible -- and with buffers there is now something worth transcribing
 * wrongly (which int32_t is a length?  is that pointer const?).  The header
 * answers both, in C, where the C compiler enforces it.
 *
 * ---------------------------------------------------------------------------
 * WHAT `spinel_trap` DOES HERE
 *
 * Exactly what E040 made it do, for exactly the same reason: it records
 * (code, a, b, detail) and longjmps back into the driver, so all cases --
 * including the ones that trap -- run in one image.  It never returns to its
 * caller, which is the only thing the generated code assumes.  A second build
 * (-DE077_PANIC_TRAP=1) calls k_panic() instead, so that "a bounds trap really
 * is fatal" does not rest on the harness's convenience implementation.
 *
 * E077 adds three codes to the four E040 knew (1 overflow, 2 divzero,
 * 3 narrow): 4 bounds, 5 NULL buffer, 6 negative length.  The driver prints
 * the code, so the differential distinguishes them.
 */
#include <zephyr/kernel.h>
#include <zephyr/sys/printk.h>
#include <setjmp.h>
#include <stdint.h>
#include <stdio.h>

#include "spinel_freestanding.h"

static jmp_buf e077_jmp;
static volatile int e077_armed;
static volatile int e077_code;
static const char *volatile e077_detail;

void spinel_trap(int32_t code, int64_t a, int64_t b, const char *detail)
{
#ifdef E077_PANIC_TRAP
	printk("E077\tTRAP\tcode=%d a=%lld b=%lld detail=%s\n",
	       (int)code, (long long)a, (long long)b, detail);
	k_panic();
	for (;;) {
	}
#else
	(void)a;
	(void)b;
	e077_code = code;
	e077_detail = detail;
	if (e077_armed) {
		longjmp(e077_jmp, 1);
	}
	printk("E077\tFATAL\tunarmed trap code=%d detail=%s\n", (int)code, detail);
	k_panic();
	for (;;) {
	}
#endif
}

/* One line per case.  The value first, then (for a case that names an output
 * fixture) the buffer, as `v,v,v,` -- the same trailing-comma rendering the
 * Ruby driver produces, so the two texts are comparable without a parser. */
static char e077_line[512];
static int e077_len;

static void e077_put(const char *s)
{
	while (*s && e077_len < (int)sizeof(e077_line) - 1) {
		e077_line[e077_len++] = *s++;
	}
	e077_line[e077_len] = 0;
}

static void e077_puti(long long v)
{
	char b[32];
	snprintf(b, sizeof b, "%lld", v);
	e077_put(b);
}

static void e077_putf(double v)
{
	char b[64];
	/* %.17g round-trips every double.  Ruby prints the SHORTEST decimal that
	 * round-trips, which is different text for the same value -- the harness
	 * parses both sides and compares the doubles, and says so.  Choosing a
	 * format that made the strings match would hide the fact that this is a
	 * value comparison, not a byte comparison. */
	snprintf(b, sizeof b, "%.17g", v);
	e077_put(b);
}

static int e077_trapped;

#define E077_BEGIN(name)                                                       \
	e077_len = 0;                                                          \
	e077_line[0] = 0;                                                      \
	e077_code = 0;                                                         \
	e077_trapped = 0;                                                      \
	e077_armed = 1;                                                        \
	e077_put(name);                                                        \
	e077_put("\t");

/* A trapped case prints `trap:<code>` and NO buffer columns.  Not an
 * omission: the trap hook never returns, so the buffer's contents at that
 * point are whatever the kernel had written before the fault, which is a
 * property of the schedule and not of the contract.  The Ruby side is in the
 * same position (the process died), so both sides print one column. */
#define E077_CASE_I(name, expr)                                                \
	do {                                                                   \
		E077_BEGIN(name)                                               \
		if (setjmp(e077_jmp) == 0) {                                   \
			long long _v = (long long)(expr);                      \
			e077_armed = 0;                                        \
			e077_puti(_v);                                         \
		} else {                                                       \
			e077_armed = 0;                                        \
			e077_trapped = 1;                                      \
			e077_put("trap:");                                     \
			e077_puti((long long)e077_code);                       \
		}                                                              \
	} while (0);

#define E077_CASE_F(name, expr)                                                \
	do {                                                                   \
		E077_BEGIN(name)                                               \
		if (setjmp(e077_jmp) == 0) {                                   \
			double _v = (double)(expr);                            \
			e077_armed = 0;                                        \
			e077_putf(_v);                                         \
		} else {                                                       \
			e077_armed = 0;                                        \
			e077_trapped = 1;                                      \
			e077_put("trap:");                                     \
			e077_puti((long long)e077_code);                       \
		}                                                              \
	} while (0);

#define E077_BUF_U8(nm)                                                        \
	do {                                                                   \
		if (!e077_trapped) {                                           \
			e077_put("\t");                                        \
			for (unsigned _j = 0;                                  \
			     _j < sizeof(nm) / sizeof(nm[0]); _j++) {          \
				e077_puti((long long)nm[_j]);                  \
				e077_put(",");                                 \
			}                                                      \
		}                                                              \
	} while (0);
#define E077_BUF_I32 E077_BUF_U8
#define E077_BUF_F32(nm)                                                       \
	do {                                                                   \
		if (!e077_trapped) {                                           \
			e077_put("\t");                                        \
			for (unsigned _j = 0;                                  \
			     _j < sizeof(nm) / sizeof(nm[0]); _j++) {          \
				e077_putf((double)nm[_j]);                     \
				e077_put(",");                                 \
			}                                                      \
		}                                                              \
	} while (0);
#define E077_BUF_F64 E077_BUF_F32

#define E077_EOL()                                                             \
	do {                                                                   \
		printk("E077\t%s\n", e077_line);                               \
	} while (0);

#include "cases.inc"

int main(void)
{
	printk("E077\tBEGIN\t%s\n", CONFIG_BOARD_TARGET);
#ifdef E077_PANIC_TRAP
	/* The panic build runs exactly one case: a KERNEL that indexes one past
	 * the length it was given (trap 4).  Note which case it is NOT:
	 * `spinel_adler32(bf_hello, 9)` is a CALLER that lied about the length,
	 * and the bounds check cannot see that -- it reads nine bytes because it
	 * was told there were nine.  Picking the wrong one of those two here
	 * would have made the panic build print a number and look healthy. */
	printk("E077\tpanic-probe\t%lld\n",
	       (long long)spinel_sum_offby1(bf_sig, 8));
	printk("E077\tUNREACHABLE\t0\n");
#else
	e077_run();
	printk("E077\tEND\t0\n");
#endif
	return 0;
}
