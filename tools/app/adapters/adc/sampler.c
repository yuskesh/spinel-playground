/* tools/app/adapters/adc/sampler.c -- the Adc adapter's background sampler
 * (0014 §3, §4): the "ADC driver's completion context" of §4's actor table.
 * A thread reads each channel in turn with the blocking driver call and
 * publishes the millivolt value with atomic_set; CORE never waits for a
 * conversion (adapter.c). The sampler owns the ADC device; entries own
 * nothing of it (§4: each device has one owning context, and the sampler is
 * that context). This is glue: compiled with the kernel's clang, measured,
 * linked, screened but for the block set (it sleeps, in its own thread).
 * Its stack is a generated thread's (0014 §9): the build sets SPC_ADC_STACK
 * to the requirement R it derives from this unit's measured frames and the
 * attested reserves (drv_adc_read, the driver's blocking read path;
 * thread_kernel_calls, the sleep), records the requested size as a word it
 * reads back from the image at step 10, and refuses an allocation of R - 1. */
#include "adapter.h"

#ifndef SPC_ADC_STACK
#define SPC_ADC_STACK 1024 /* the measuring compile; the build's R replaces it */
#endif
#define SPC_ADC_PERIOD_MS 5

static const struct adc_dt_spec *spc_adc_table;
static atomic_t *spc_adc_latest;
static uint32_t spc_adc_count;
static K_THREAD_STACK_DEFINE(spc_adc_stack, SPC_ADC_STACK);
/* the requested size, read back from the image at step 10 (see main.c) */
const volatile uint32_t spc_adc_stack_size = SPC_ADC_STACK;
static struct k_thread spc_adc_thread;

#if defined(SPC_VERIFY)
/* the painted stack's high-water mark, for the verification run's end line */
uint32_t spc_adapter_adc_stack_mark(uint32_t *size)
{
	size_t unused = 0;

	*size = spc_adc_stack_size;
	if (k_thread_stack_space_get(&spc_adc_thread, &unused) != 0) {
		return 0xffffffffu;
	}
	return spc_adc_stack_size - (uint32_t)unused;
}
#endif

static void spc_adc_sampler(void *a, void *b, void *c)
{
	int16_t buf;
	struct adc_sequence seq = {
		.buffer = &buf,
		.buffer_size = sizeof(buf),
	};

	(void)a; (void)b; (void)c;
	for (;;) {
		for (uint32_t i = 0; i < spc_adc_count; i++) {
			int32_t mv;

			if (adc_sequence_init_dt(&spc_adc_table[i], &seq) != 0) {
				continue;
			}
			if (adc_read_dt(&spc_adc_table[i], &seq) != 0) {
				continue;
			}
			mv = buf;
			if (adc_raw_to_millivolts_dt(&spc_adc_table[i], &mv) != 0) {
				continue;
			}
			atomic_set(&spc_adc_latest[i], mv);
		}
		k_msleep(SPC_ADC_PERIOD_MS);
	}
}

int32_t spc_adapter_adc_init(const struct adc_dt_spec *table, atomic_t *latest, uint32_t count)
{
	for (uint32_t i = 0; i < count; i++) {
		if (!adc_is_ready_dt(&table[i])) {
			return -1;
		}
		if (adc_channel_setup_dt(&table[i]) != 0) {
			return -1;
		}
		atomic_set(&latest[i], 0);
	}
	spc_adc_table = table;
	spc_adc_latest = latest;
	spc_adc_count = count;
	if (count > 0) {
		k_thread_create(&spc_adc_thread, spc_adc_stack, spc_adc_stack_size, spc_adc_sampler,
				NULL, NULL, NULL, K_LOWEST_APPLICATION_THREAD_PRIO, 0, K_NO_WAIT);
	}
	return 0;
}
