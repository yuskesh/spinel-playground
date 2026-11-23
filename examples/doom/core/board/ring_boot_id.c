/* examples/doom/core/board/ring_boot_id.c — the boot id the M33 publishes, for CORE.
 *
 * The provider of the board application's `Ring.boot_id(out)`: one load of
 * the ring's shared boot_id word (tools/app/ring/ring_abi.h, line 1, in the
 * M7's view of OCRAM2), after a barrier, written into out[0..3] little-endian.
 * It never waits: the word is 0 until the M33 has its address by DHCP and
 * writes it once (decision 0024's wire format v2), and the application puts
 * no message while it reads 0. No allocation, no blocking, one iteration. */
#include <stdint.h>
#include "ring/ring_abi.h"

void spc_app_ring_boot_id(uint8_t *out, uint32_t out_len)
{
	uint32_t id;

	if (out_len < 4u)
		return;
	id = spc_ring_load((volatile uint32_t *)SPC_RING_M7_BASE, SPC_RING_W_BOOT_ID);
	spc_ring_dmb(); /* the load before anything the id's arrival orders */
	out[0] = (uint8_t)id;
	out[1] = (uint8_t)(id >> 8);
	out[2] = (uint8_t)(id >> 16);
	out[3] = (uint8_t)(id >> 24);
}
