/* tools/app/adapters/adc/adapter.c -- the Adc adapter's CORE-facing member
 * (0014 §3, §4): `latest` is one atomic read of the word the sampler in
 * sampler.c publishes. This object is what CORE calls and what the screen of
 * §6 reads; it names no kernel primitive. The sampler thread, which does the
 * blocking driver reads, is glue (sampler.c): compiled and measured, linked,
 * and never called from a CORE context. */
#include "adapter.h"

int32_t spc_adapter_adc_latest(const atomic_t *latest, uint32_t index)
{
	return (int32_t)atomic_get(&latest[index]);
}
