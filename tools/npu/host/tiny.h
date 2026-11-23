#ifndef __ASSEMBLER__
#include <stdint.h>
#include <stdbool.h>
#ifdef __cplusplus
extern "C" {
#endif
bool tiny_wait_until(int64_t deadline_ns);
#ifdef __cplusplus
}
#endif
#endif
