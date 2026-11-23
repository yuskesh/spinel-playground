/* abi/iter.h — map の iterator (hash.c・percpu.c — E006) */
#ifndef BML_ABI_ITER_H
#define BML_ABI_ITER_H

#include <pthread.h>
#include <stddef.h>
#include <stdint.h>

#include "abi/map_internal.h"

struct abi_iter {
	pthread_mutex_t mu;
	int64_t obj; /* 持ち主の object (next は object の走っている呼び出しとして数える — E006 の後半の追補の 2) */
	int fd; /* map の fd の dup (閉じるまで) */
	char *name;
	size_t klen, vlen; /* vlen は per-CPU では possible × 値の大きさ */
	int percpu;        /* possible CPU の数 (0 は per-CPU でない) */
	size_t elem;       /* per-CPU の 1 つの値の大きさ */
	uint32_t max_entries, count;
	uint8_t *cursor;
	int started, done, closed;
};

/* iterator を開き handle を返す結果 (m の map を dup する) */
int64_t abi_iter_open(struct abi_map *m, int64_t obj, int64_t klen, int64_t vlen, int percpu);

#endif
