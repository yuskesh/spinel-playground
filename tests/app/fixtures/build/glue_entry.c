/* The glue-screen control of Task 10 (a call back into CORE): a glue unit
 * (--mutate-glue) that calls the sample's interrupt entry directly. Only
 * the generated dispatch may run an entry; the screen refuses the call at
 * step 5, naming the entry symbol. */
#include <stdint.h>
int32_t spinel_core_sample(int32_t *reading);
void spc_glue_calls_entry(int32_t *reading)
{
	(void)spinel_core_sample(reading);
}
