/* bm040-frdm: E040's kernel on the bare Cortex-M33 (CPU0) of the NXP MCX N947
 * on the FRDM-MCXN947 board.
 *
 * The driver is bm040's (../../bm040/src/main.c): from "the trap hook and the
 * driver" on, this file is that one with only the BEGIN line's platform name
 * changed, and build_all.sh refuses to build if the two differ in anything
 * else. What is this board's is the console above it.
 */
#include <stdint.h>

#include "bm.h"
#include "spinel_freestanding.h"

/* ---- console: LP_FLEXCOMM4 as an LPUART, 115200 8N1, polled, TX only ------
 *
 * The board's MCU-Link carries this UART to the host as its VCOM: UM12018
 * (FRDM-MCXN947 Board User Manual) section 3.8 wires the target's P1_8 and
 * P1_9 to MCU-Link, and Table 24 names them FC4_P0_UART_RXD_MCULINK and
 * FC4_P1_UART_TXD_MCULINK. Zephyr's board files agree: `zephyr,console =
 * &flexcomm4_lpuart4` (frdm_mcxn947_mcxn947_cpu0.dtsi), `current-speed =
 * <115200>` (frdm_mcxn947.dtsi), pins FC4_P0_PIO1_8 and FC4_P1_PIO1_9
 * (frdm_mcxn947-pinctrl.dtsi).
 *
 * The register facts are from NXP's device headers as Zephyr's hal_nxp
 * module ships them (mcux-sdk-ng/devices/MCX/MCXN/MCXN947 and .../MCXN/periph;
 * nothing from them is compiled here). Secure addresses: bit 28 set over the
 * non-secure ones (MCXN947_cm33_core0_COMMON.h).
 *
 * The functional clock is FRO_12M, the SCG's SIRC, which runs from reset;
 * its output to peripherals is gated by SCG SIRCCSR.SIRC_CLK_PERIPH_EN, set
 * here if the boot ROM left it clear. SYSCON FCCLKSEL4 = 2 selects it
 * (PERI_SYSCON.h: FCCLKSEL SEL, 2 = FRO 12 MHz) and FLEXCOMMCLKDIV4 divides
 * by DIV+1 = 1, written the way fsl_clock.c's CLOCK_SetClkDiv does: halt and
 * reset the divider, then write the value. 12 MHz / 115200 with OSR = 26 and
 * SBR = 4 is 115384 baud (+0.16%), the pair fsl_lpuart.c's LPUART_Init picks
 * for that clock. */
#define BM_REG(a) (*(volatile uint32_t *)(a))

#define BM_SCG_SIRCCSR BM_REG(0x50044200u) /* SCG0 0x50044000 + 0x200 */
#define BM_SIRC_CLK_PERIPH_EN (1u << 5)
#define BM_SIRC_LK (1u << 23)

#define BM_SYSCON 0x50000000u
#define BM_PRESETCTRL0 BM_REG(BM_SYSCON + 0x100u)
#define BM_PRESETCTRL1 BM_REG(BM_SYSCON + 0x104u)
#define BM_PRESETCTRLCLR0 BM_REG(BM_SYSCON + 0x140u)
#define BM_PRESETCTRLCLR1 BM_REG(BM_SYSCON + 0x144u)
#define BM_AHBCLKCTRLSET0 BM_REG(BM_SYSCON + 0x220u)
#define BM_AHBCLKCTRLSET1 BM_REG(BM_SYSCON + 0x224u)
#define BM_FCCLKSEL4 BM_REG(BM_SYSCON + 0x2c0u)
#define BM_FLEXCOMMCLKDIV4 BM_REG(BM_SYSCON + 0x860u)
#define BM_PORT1_BIT (1u << 14) /* AHBCLKCTRL0 and PRESETCTRL0 */
#define BM_FC4_BIT (1u << 15)   /* AHBCLKCTRL1 and PRESETCTRL1 */

/* PORT1 0x50117000; PCR[n] at 0x80 + 4n. MUX [11:8] = 2 (FC4_P0/P1 are ALT2
 * in hal_nxp's MCXN947VDF-pinctrl.h), IBE bit 12, PE bit 1, PS bit 0: the
 * value Zephyr's pinctrl writes for the board's group (input-enable,
 * bias-pull-up, fast slew, low drive). */
#define BM_PORT1_PCR8 BM_REG(0x501170a0u)
#define BM_PORT1_PCR9 BM_REG(0x501170a4u)
#define BM_PCR_FC4 0x00001203u

/* LP_FLEXCOMM4 0x500B4000: the LPUART registers from 0, PSELID at 0xFF8
 * (PERSEL [2:0], 1 = UART). */
#define BM_FC4 0x500b4000u
#define BM_FC4_PSELID BM_REG(BM_FC4 + 0xff8u)
#define BM_UART_GLOBAL BM_REG(BM_FC4 + 0x08u) /* RST bit 1 */
#define BM_UART_BAUD BM_REG(BM_FC4 + 0x10u)   /* OSR [28:24] = osr-1, SBR [12:0] */
#define BM_UART_STAT BM_REG(BM_FC4 + 0x14u)   /* TDRE bit 23 */
#define BM_UART_CTRL BM_REG(BM_FC4 + 0x18u)   /* TE bit 19 */
#define BM_UART_DATA BM_REG(BM_FC4 + 0x1cu)
#define BM_UART_FIFO BM_REG(BM_FC4 + 0x28u)   /* TXFE bit 7, TXFLUSH bit 15 */
#define BM_UART_WATER BM_REG(BM_FC4 + 0x2cu)

static void bm_uart_init(void)
{
	uint32_t sirc = BM_SCG_SIRCCSR;
	if (!(sirc & BM_SIRC_CLK_PERIPH_EN)) {
		if (sirc & BM_SIRC_LK)
			BM_SCG_SIRCCSR = sirc & ~BM_SIRC_LK;
		BM_SCG_SIRCCSR = (BM_SCG_SIRCCSR & ~BM_SIRC_LK) | BM_SIRC_CLK_PERIPH_EN;
	}
	BM_FCCLKSEL4 = 2u;
	BM_FLEXCOMMCLKDIV4 = 3u << 29;
	BM_FLEXCOMMCLKDIV4 = 0u;

	BM_AHBCLKCTRLSET0 = BM_PORT1_BIT;
	BM_AHBCLKCTRLSET1 = BM_FC4_BIT;
	BM_PRESETCTRLCLR0 = BM_PORT1_BIT;
	while (BM_PRESETCTRL0 & BM_PORT1_BIT) {
	}
	BM_PRESETCTRLCLR1 = BM_FC4_BIT;
	while (BM_PRESETCTRL1 & BM_FC4_BIT) {
	}

	BM_PORT1_PCR8 = BM_PCR_FC4;
	BM_PORT1_PCR9 = BM_PCR_FC4;
	BM_FC4_PSELID = 1u;

	BM_UART_GLOBAL = 2u;
	BM_UART_GLOBAL = 0u;
	BM_UART_BAUD = (25u << 24) | 4u;
	BM_UART_CTRL = 0u;
	BM_UART_WATER = 0u;
	BM_UART_FIFO |= (1u << 7) | (1u << 15);
	BM_UART_CTRL = 1u << 19;
}

static void bm_putc(char c)
{
	while (!(BM_UART_STAT & (1u << 23))) {
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
	bm_puts("E040\tBEGIN\tbaremetal/frdm-mcxn947/cortex-m33\n");
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
