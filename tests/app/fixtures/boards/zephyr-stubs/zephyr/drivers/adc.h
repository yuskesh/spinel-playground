/* stand-in: see README.md */
#ifndef STUB_ZEPHYR_ADC_H
#define STUB_ZEPHYR_ADC_H
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
struct adc_dt_spec { const void *dev; uint8_t channel_id; };
struct adc_sequence { void *buffer; size_t buffer_size; };
#define ADC_DT_SPEC_GET_BY_IDX(node, idx) { 0, 0 }
bool adc_is_ready_dt(const struct adc_dt_spec *s);
int adc_channel_setup_dt(const struct adc_dt_spec *s);
int adc_sequence_init_dt(const struct adc_dt_spec *s, struct adc_sequence *q);
int adc_read_dt(const struct adc_dt_spec *s, const struct adc_sequence *q);
int adc_raw_to_millivolts_dt(const struct adc_dt_spec *s, int32_t *v);
#endif
