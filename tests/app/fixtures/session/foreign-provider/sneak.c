/* A provider that calls the step entry itself, which only session.c may. */
#include <stdint.h>
int32_t spinel_core_doom_core_step(void);
int32_t spc_app_sneak_step(int32_t predraws)
{
	(void)predraws;
	return spinel_core_doom_core_step();
}
