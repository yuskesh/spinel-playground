/*
 * Timer probe for tests/app/platform-facts.sh (decision 0014, Task 1).
 *
 * It establishes, on the pinned Zephyr under QEMU, that k_cycle_get_64()
 * advances inside a k_timer expiry function that busy-waits, that the expiry
 * runs in interrupt context, and that the ADC and GPIO emulators added by
 * emul.overlay come up. Every line it prints starts with PROBE, and the last
 * one is "PROBE end"; the script keys on those.
 */
#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/devicetree.h>
#include <zephyr/drivers/adc.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/sys/printk.h>

#define BUSY_US 2000

static struct k_timer probe_timer;
static volatile uint64_t cycles_before;
static volatile uint64_t cycles_after;
static volatile int expiry_in_isr;
static volatile int fired;

static void expiry(struct k_timer *timer)
{
	ARG_UNUSED(timer);
	expiry_in_isr = k_is_in_isr();
	cycles_before = k_cycle_get_64();
	k_busy_wait(BUSY_US);
	cycles_after = k_cycle_get_64();
	fired = 1;
}

int main(void)
{
	const struct device *adc = DEVICE_DT_GET(DT_NODELABEL(spinel_adc_emul));
	const struct device *gpio = DEVICE_DT_GET(DT_NODELABEL(spinel_gpio_emul));

	printk("PROBE start cycles_per_sec=%u has_64bit_counter=%d\n",
	       sys_clock_hw_cycles_per_sec(),
	       IS_ENABLED(CONFIG_TIMER_HAS_64BIT_CYCLE_COUNTER));

	k_timer_init(&probe_timer, expiry, NULL);
	k_timer_start(&probe_timer, K_MSEC(10), K_NO_WAIT);
	while (!fired) {
		k_msleep(1);
	}
	printk("PROBE timer busy_us=%d before=%llu after=%llu delta=%llu in_isr=%d\n",
	       BUSY_US, (unsigned long long)cycles_before,
	       (unsigned long long)cycles_after,
	       (unsigned long long)(cycles_after - cycles_before), expiry_in_isr);

	printk("PROBE emul adc_ready=%d gpio_ready=%d\n",
	       device_is_ready(adc) ? 1 : 0, device_is_ready(gpio) ? 1 : 0);
	printk("PROBE end\n");
	return 0;
}
