/* bm040: E040's kernel on the bare Cortex-M33 of QEMU's mps2-an521.
 *
 * The same driver as tests/freestanding/e040/zephyr/src/main.c, without
 * Zephyr: it calls every entry the kernel object exports and prints one
 * `E040<TAB><case><TAB><result>` line per case, between BEGIN and END, from
 * the cases.inc that e040/mkcases.rb generates. The prototypes come from the
 * header spinel-fs-emit wrote, not from here.
 *
 * spinel_trap is the platform's (P003 D-2). The default build records the
 * code and jumps back into the driver with bm_longjmp, so the six cases
 * that trap are rows of the same run. With BM040_PANIC_TRAP it prints the
 * trap and stops the core in a loop, which is what a product would do; the
 * panic build runs only the case that traps.
 */
#include <stdint.h>

#include "bm.h"
#include "spinel_freestanding.h"

/* ---- console: UART0, a CMSDK APB UART -------------------------------------
 *
 * 0x50200000 is UART0 as the secure CPU0 sees it. QEMU's hw/arm/mps2-tz.c
 * places "uart0" at 0x40200000 for the AN505/AN521 (an505_ppcs), and the
 * SSE-200's secure alias of that address sets bit 28. Zephyr's
 * mps2_an521-common.dtsi has `uart0: uart@200000` under
 * `peripheral@50000000` (ranges <0x0 0x50000000 0x10000000>) in
 * mps2_an521_cpu0.dts. The registers are QEMU's hw/char/cmsdk-apb-uart.c:
 * DATA at 0x0, STATE at 0x4 (bit 0 TX buffer full), CTRL at 0x8 (bit 0 TX
 * enable) and BAUDDIV at 0x10, whose minimum valid setting is 16. */
#define BM_UART0 0x50200000u
#define BM_UART_DATA (*(volatile uint32_t *)(BM_UART0 + 0x00))
#define BM_UART_STATE (*(volatile uint32_t *)(BM_UART0 + 0x04))
#define BM_UART_CTRL (*(volatile uint32_t *)(BM_UART0 + 0x08))
#define BM_UART_BAUDDIV (*(volatile uint32_t *)(BM_UART0 + 0x10))

static void bm_uart_init(void)
{
	BM_UART_BAUDDIV = 16;
	BM_UART_CTRL = 1;
}

static void bm_putc(char c)
{
	while (BM_UART_STATE & 1u) {
	}
	BM_UART_DATA = (uint32_t)(unsigned char)c;
}

void bm_puts(const char *s)
{
	while (*s)
		bm_putc(*s++);
}

/* %lld: the magnitude as an unsigned value, so INT64_MIN prints too. */
void bm_put_i64(int64_t v)
{
	char buf[21];
	int n = 0;
	uint64_t m = v < 0 ? (uint64_t)0 - (uint64_t)v : (uint64_t)v;
	do {
		buf[n++] = (char)('0' + (int)(m % 10u));
		m /= 10u;
	} while (m != 0);
	if (v < 0)
		bm_putc('-');
	while (n > 0)
		bm_putc(buf[--n]);
}

/* ---- the trap hook and the driver ----------------------------------------- */

#ifndef BM040_PANIC_TRAP
static bm_jmp_buf e040_jmp;
static volatile int e040_armed;
static volatile int e040_code;
static const char *volatile e040_detail;
#endif

void spinel_trap(int32_t code, int64_t a, int64_t b, const char *detail)
{
#ifdef BM040_PANIC_TRAP
	bm_puts("E040\tTRAP\tcode=");
	bm_put_i64(code);
	bm_puts(" a=");
	bm_put_i64(a);
	bm_puts(" b=");
	bm_put_i64(b);
	bm_puts(" detail=");
	bm_puts(detail);
	bm_puts("\n");
	for (;;) {
	}
#else
	(void)a;
	(void)b;
	e040_code = code;
	e040_detail = detail;
	if (e040_armed)
		bm_longjmp(e040_jmp, 1);
	/* A trap outside a driver arm is a bug in the harness, not in the kernel
	 * object; say so rather than return into code that assumes it cannot. */
	bm_puts("E040\tFATAL\tunarmed trap code=");
	bm_put_i64(code);
	bm_puts(" detail=");
	bm_puts(detail);
	bm_puts("\n");
	for (;;) {
	}
#endif
}

#define E040_CASE(name, expr)                                                  \
	do {                                                                   \
		e040_code = 0;                                                 \
		e040_armed = 1;                                                \
		if (bm_setjmp(e040_jmp) == 0) {                                \
			long long _v = (long long)(expr);                      \
			e040_armed = 0;                                        \
			bm_puts("E040\t" name "\t");                           \
			bm_put_i64(_v);                                        \
			bm_puts("\n");                                         \
		} else {                                                       \
			e040_armed = 0;                                        \
			bm_puts("E040\t" name "\ttrap:");                      \
			bm_put_i64(e040_code);                                 \
			bm_puts("\n");                                         \
		}                                                              \
	} while (0);

void bm_main(void)
{
	bm_uart_init();
	bm_puts("E040\tBEGIN\tbaremetal/mps2-an521/cortex-m33\n");
#ifdef BM040_PANIC_TRAP
	/* The call first, as printk evaluates its arguments first: the trap's
	 * line then starts a line of its own. */
	long long v = (long long)spinel_mulnarrow(46341, 46341);
	bm_puts("E040\tpanic-probe\t");
	bm_put_i64(v);
	bm_puts("\n");
	bm_puts("E040\tUNREACHABLE\t0\n");
#else
#include "cases.inc"
	bm_puts("E040\tEND\t0\n");
#endif
}
