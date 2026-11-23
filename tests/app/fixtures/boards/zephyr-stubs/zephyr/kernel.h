/* stand-in: see README.md */
#ifndef STUB_ZEPHYR_KERNEL_H
#define STUB_ZEPHYR_KERNEL_H
#include <stdint.h>
#include <stddef.h>
typedef long atomic_t;
typedef long atomic_val_t;
static inline atomic_val_t atomic_get(const atomic_t *t) { return *t; }
static inline atomic_val_t atomic_set(atomic_t *t, atomic_val_t v) { atomic_val_t o = *t; *t = v; return o; }
typedef struct { char c; } k_thread_stack_t;
struct k_thread { int dummy; };
typedef void (*k_thread_entry_t)(void *, void *, void *);
typedef struct { long ticks; } k_timeout_t;
typedef struct k_thread *k_tid_t;
#define K_THREAD_STACK_DEFINE(name, size) k_thread_stack_t name[1]
#define K_LOWEST_APPLICATION_THREAD_PRIO 14
#define K_NO_WAIT ((k_timeout_t){0})
k_tid_t k_thread_create(struct k_thread *t, k_thread_stack_t *s, size_t n, k_thread_entry_t e, void *a, void *b, void *c, int prio, uint32_t opts, k_timeout_t delay);
int32_t k_msleep(int32_t ms);
int64_t k_uptime_ticks(void);
uint64_t k_ticks_to_us_floor64(uint64_t t);
uint64_t k_cycle_get_64(void);
uint32_t k_cycle_get_32(void);
#endif
