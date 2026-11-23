/* tests/app/fixtures/udp/ring_host.h -- included first (-include) when
 * tests/app/udp.sh compiles a generated OCRAM-ring unit on the host: the
 * region is the harness's own array, and the barrier a host fence
 * (tools/app/ring/ring_abi.h). */
#include <stdint.h>
#define SPC_RING_HOST 1
extern uintptr_t spc_test_base;
#define SPC_RING_M7_BASE spc_test_base
