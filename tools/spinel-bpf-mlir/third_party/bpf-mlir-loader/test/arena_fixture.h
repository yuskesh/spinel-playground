/* E061 stop A: one address for all declaration/transaction unit modes. */
#ifndef E061_ARENA_FIXTURE_H
#define E061_ARENA_FIXTURE_H
#include <stdint.h>
#define E061_ARENA_ADDRESS_DEC 35184372092928
#define E061_ARENA_ADDRESS UINT64_C(35184372092928)
#define E061_STRING_(x) #x
#define E061_STRING(x) E061_STRING_(x)
#define E061_ARENA_ADDRESS_JSON E061_STRING(E061_ARENA_ADDRESS_DEC)
#endif
