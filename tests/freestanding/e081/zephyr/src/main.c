/* E081 -- P003 Phase 4: the MCU legs of the four-way differential, plus the
 * device-only property rows.
 *
 * The case list is #included from the generated cases.inc (one table,
 * mkcases.py) and the prototypes come from the generated header, so nothing
 * here is transcribed.  The trap hook is E040/E077's harness shape: record
 * (code, detail) and longjmp back into the driver so all cases run in one
 * image; a second build (-DE081_PANIC_TRAP=1) runs exactly one narrowing case
 * and k_panic()s, so "an extern-argument trap really is fatal" does not rest
 * on the harness's convenience implementation.
 *
 * After the cases, the PROPERTY rows: the things that are true on a real
 * platform but are not values a host oracle can share --
 *   uptime_monotonic  two k_uptime_get() reads around a k_msleep, t1 >= t0
 *   sleep_elapsed     the uptime delta covered the requested sleep
 *   print_witness     (checked by run_gates.sh: the E081P line printed by the
 *                     chirp case is in this same console log)
 *   gpio_backend      how many pins were driven through the real GPIO driver
 *                     (2 on mps2/an521, 0 on qemu_riscv32) -- E056's
 *                     field-of-view row, printed per run rather than assumed
 *   gpio_readback     set pin 0 through the wrapper, read it back through the
 *                     wrapper (on M33 that is a register readback from the
 *                     QEMU-emulated FPGAIO device)
 */
#include <zephyr/kernel.h>
#include <zephyr/sys/printk.h>
#include <setjmp.h>
#include <stdint.h>
#include <stdio.h>

#include "spinel_freestanding.h"

int e081_gpio_real_pins(void); /* spinel_zephyr.c */

static jmp_buf e081_jmp;
static volatile int e081_armed;
static volatile int e081_code;

void spinel_trap(int32_t code, int64_t a, int64_t b, const char *detail)
{
#ifdef E081_PANIC_TRAP
	printk("E081\tTRAP\tcode=%d a=%lld b=%lld detail=%s\n",
	       (int)code, (long long)a, (long long)b, detail);
	k_panic();
	for (;;) {
	}
#else
	(void)a;
	(void)b;
	e081_code = code;
	if (e081_armed) {
		longjmp(e081_jmp, 1);
	}
	printk("E081\tFATAL\tunarmed trap code=%d detail=%s\n", (int)code, detail);
	k_panic();
	for (;;) {
	}
#endif
}

static char e081_line[256];
static int e081_len;

static void e081_put(const char *s)
{
	while (*s && e081_len < (int)sizeof(e081_line) - 1) {
		e081_line[e081_len++] = *s++;
	}
	e081_line[e081_len] = 0;
}

static void e081_puti(long long v)
{
	char b[32];

	snprintf(b, sizeof b, "%lld", v);
	e081_put(b);
}

static void e081_putf(double v)
{
	char b[64];

	/* %.17g round-trips every double; Ruby and JS print shortest forms of
	 * the same value.  compare.py parses both sides (E077's honest form:
	 * float rows are a VALUE comparison, not a byte comparison). */
	snprintf(b, sizeof b, "%.17g", v);
	e081_put(b);
}

#define E081_BEGIN(name)                                                       \
	e081_len = 0;                                                          \
	e081_line[0] = 0;                                                      \
	e081_code = 0;                                                         \
	e081_armed = 1;                                                        \
	e081_put(name);                                                        \
	e081_put("\t");

#define E081_CASE_I(name, expr)                                                \
	do {                                                                   \
		E081_BEGIN(name)                                               \
		if (setjmp(e081_jmp) == 0) {                                   \
			long long _v = (long long)(expr);                      \
			e081_armed = 0;                                        \
			e081_puti(_v);                                         \
		} else {                                                       \
			e081_armed = 0;                                        \
			e081_put("trap:");                                     \
			e081_puti((long long)e081_code);                       \
		}                                                              \
		printk("E081\t%s\n", e081_line);                               \
	} while (0);

#define E081_CASE_F(name, expr)                                                \
	do {                                                                   \
		E081_BEGIN(name)                                               \
		if (setjmp(e081_jmp) == 0) {                                   \
			double _v = (double)(expr);                            \
			e081_armed = 0;                                        \
			e081_putf(_v);                                         \
		} else {                                                       \
			e081_armed = 0;                                        \
			e081_put("trap:");                                     \
			e081_puti((long long)e081_code);                       \
		}                                                              \
		printk("E081\t%s\n", e081_line);                               \
	} while (0);

#include "cases.inc"

static void e081_props(void)
{
	int64_t t0 = spinel_zephyr_uptime_ms();
	int32_t r = spinel_zephyr_sleep_ms(20);
	int64_t t1 = spinel_zephyr_uptime_ms();

	printk("E081\tPROP\tuptime_monotonic\t%d\n", t1 >= t0 ? 1 : 0);
	printk("E081\tPROP\tsleep_elapsed\t%d\n",
	       (t1 - t0 >= 20 && r == 0) ? 1 : 0);
	printk("E081\tPROP\tgpio_backend\treal_pins=%d\n", e081_gpio_real_pins());
	spinel_zephyr_gpio_set(0, 1);
	printk("E081\tPROP\tgpio_readback\t%d\n", (int)spinel_zephyr_gpio_get(0));
	spinel_zephyr_gpio_set(0, 0);
	printk("E081\tPROP\tgpio_readback0\t%d\n", (int)spinel_zephyr_gpio_get(0));
}

int main(void)
{
	printk("E081\tBEGIN\t%s\n", CONFIG_BOARD_TARGET);
#ifdef E081_PANIC_TRAP
	/* One case, and it is the ARGUMENT-narrowing one this experiment adds:
	 * pin 2**32+5 does not fit the extern's declared :i32.  If the panic
	 * build printed a number here, D-8's trap would be a harness fiction. */
	printk("E081\tpanic-probe\t%d\n",
	       (int)spinel_pin_probe(INT64_C(4294967301)));
	printk("E081\tUNREACHABLE\t0\n");
#else
	e081_run();
	e081_props();
	printk("E081\tEND\t0\n");
#endif
	return 0;
}
