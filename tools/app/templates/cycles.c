/* tools/app/templates/cycles.c -- the __aeabi_ldivmod wrapper of a
 * verification build (decision 0014 plan, Task 11, the deferred D3):
 * linked with --wrap=__aeabi_ldivmod, it counts the cycles spent inside
 * the helper for the entry whose invocation is current, so the run's
 * report can say how many of an invocation's cycles are 64-bit division.
 * The wrapper is assembly because the helper returns its quotient and
 * remainder in r0-r3 (AEABI), which a C wrapper cannot preserve; its own
 * cycles are inside the figure, and its 24 bytes of pushes are on the
 * calling entry's stack, which the verification build's requirement
 * carries (stack.rb, the `ldivmod wrapper` term). The unsigned helper
 * __aeabi_uldivmod is wrapped the same way, into the same figure. */
#include <stdint.h>
#include <zephyr/kernel.h>
#include "recorder.h"

extern uint32_t spc_cyc_ldivmod_calls[];
extern uint64_t spc_cyc_ldivmod[];

uint32_t spc_cyc_now32(void)
{
	return (uint32_t)k_cycle_get_64();
}

void spc_cyc_ldivmod_done(uint32_t start)
{
	if (spc_rec_entry != SPC_NO_ENTRY) {
		spc_cyc_ldivmod[spc_rec_entry] += (uint32_t)((uint32_t)k_cycle_get_64() - start);
		spc_cyc_ldivmod_calls[spc_rec_entry] += 1u;
	}
}

__asm__(
	".syntax unified\n"
	".thumb\n"
	".global __wrap___aeabi_ldivmod\n"
	".type __wrap___aeabi_ldivmod, %function\n"
	"__wrap___aeabi_ldivmod:\n"
	"	push {r4, lr}\n"
	"	push {r0-r3}\n"
	"	bl spc_cyc_now32\n"
	"	mov r4, r0\n"
	"	pop {r0-r3}\n"
	"	bl __real___aeabi_ldivmod\n"
	"	push {r0-r3}\n"
	"	mov r0, r4\n"
	"	bl spc_cyc_ldivmod_done\n"
	"	pop {r0-r3}\n"
	"	pop {r4, pc}\n"
	".size __wrap___aeabi_ldivmod, .-__wrap___aeabi_ldivmod\n"
	".global __wrap___aeabi_uldivmod\n"
	".type __wrap___aeabi_uldivmod, %function\n"
	"__wrap___aeabi_uldivmod:\n"
	"	push {r4, lr}\n"
	"	push {r0-r3}\n"
	"	bl spc_cyc_now32\n"
	"	mov r4, r0\n"
	"	pop {r0-r3}\n"
	"	bl __real___aeabi_uldivmod\n"
	"	push {r0-r3}\n"
	"	mov r0, r4\n"
	"	bl spc_cyc_ldivmod_done\n"
	"	pop {r0-r3}\n"
	"	pop {r4, pc}\n"
	".size __wrap___aeabi_uldivmod, .-__wrap___aeabi_uldivmod\n");
