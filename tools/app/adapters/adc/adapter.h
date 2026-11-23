/* tools/app/adapters/adc/adapter.h -- the Adc adapter: a background sampler. */
#ifndef SPC_ADAPTER_ADC_H
#define SPC_ADAPTER_ADC_H
#include <stdint.h>
#include <zephyr/drivers/adc.h>
#include <zephyr/kernel.h>
/* Starts the sampler thread over the table's channels; `latest` holds the
 * last completed reading of each, in millivolts, updated word-atomically. */
int32_t spc_adapter_adc_init(const struct adc_dt_spec *table, atomic_t *latest, uint32_t count);
/* The last completed reading of channel `index`, in millivolts; 0 before the
 * first completes. One atomic read; never blocks. */
int32_t spc_adapter_adc_latest(const atomic_t *latest, uint32_t index);
#endif
