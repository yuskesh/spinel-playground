/* abi_race — E006 の後半の追補: object の close と別の thread の呼び出しの競合の契約 (予測は E006 の「後半の追補」— 走らせる前に commit)。
 *
 *   abi_race r1|r2|r3 <flow.bpf.o> <sha>     (root、unshare -n の中 — ASan + UBSan か TSan の build)
 * r1: 4 つの thread が回る間に close を 200 回 (STATE が 1 回以上) → thread を止めて close (OK) → 呼び出しは STATE
 * r2: thread を止めずに close を OK まで → その後の thread の呼び出しは全て STATE (前は OK か NOT_FOUND)
 *     (r1・r2 の worker は iterator の next も — 追補の 2 の R5)
 * r3 (追補の 2 の R4): thread が ring buffer の read (5000 ms) の中の bml_close と bml_ringbuf_close は待たずに STATE */
#define _GNU_SOURCE
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>

#include "bml/bml.h"
#include "abi_fixture.h"

#define S(x) (x), (int64_t)strlen(x)

static int64_t obj, iters[4];
static atomic_int stop, closed_seen;
static atomic_long bad_before, bad_after, calls;

static int kind_of(int64_t r)
{
	int k = (int)bml_result_kind(r);
	bml_result_free(r);
	return k;
}

static void *worker(void *arg)
{
	int t = (int)(intptr_t)arg;
	uint8_t key[16] = {(uint8_t)t}, val[24], ik[16], iv[24];
	static const uint8_t frame[64];
	while (!atomic_load(&stop)) {
		int after = atomic_load(&closed_seen);
		int k[6] = {
			kind_of(bml_map_get_int(obj, S(DECL_STATS), t % 4)),
			kind_of(bml_hash_get(obj, S(DECL_FLOWS), S(REC_KEY), S(REC_VAL), key, 16, val, 24)),
			kind_of(bml_test_run_xdp_data(obj, S("prog"), frame, 64)),
			kind_of(bml_map_describe(obj, S("flows"))),
			kind_of(bml_object_unmet(obj)),
			kind_of(bml_hash_iter_next(iters[t], ik, 16, iv, 24)), /* 終わりは value 0 の OK */
		};
		for (int i = 0; i < 6; i++) {
			atomic_fetch_add(&calls, 1);
			if (after && k[i] != BML_STATE)
				atomic_fetch_add(&bad_after, 1); /* close の OK を見た後に STATE でない */
			else if (!after && k[i] != BML_OK && k[i] != BML_NOT_FOUND && k[i] != BML_STATE)
				atomic_fetch_add(&bad_before, 1);
		}
	}
	return NULL;
}

static uint8_t *slurp(const char *path, int64_t *n)
{
	FILE *f = fopen(path, "rb");
	if (!f)
		return NULL;
	fseek(f, 0, SEEK_END);
	long l = ftell(f);
	fseek(f, 0, SEEK_SET);
	uint8_t *p = malloc((size_t)l + 1);
	if (p && fread(p, 1, (size_t)l, f) != (size_t)l) {
		free(p);
		p = NULL;
	}
	fclose(f);
	*n = l;
	return p;
}

static int64_t now_ms(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

struct rd {
	int64_t reader, kind, value, t_end;
};
static void *reader_thread(void *p)
{
	struct rd *x = p;
	uint8_t ev[32];
	int64_t r = bml_ringbuf_read(x->reader, 5000, ev, sizeof ev);
	x->kind = bml_result_kind(r);
	x->value = bml_result_value(r);
	bml_result_free(r);
	x->t_end = now_ms();
	return NULL;
}

/* R4: read の中の close は待たない */
static int r3(void)
{
	int64_t rh = bml_ringbuf_open(obj, S(DECL_EVENTS), S(REC_EVENT), 32);
	struct rd x = {.reader = bml_result_value(rh)};
	if (bml_result_kind(rh) != BML_OK) {
		printf("R4: ringbuf_open kind %lld — FAIL\n", (long long)bml_result_kind(rh));
		return 1;
	}
	bml_result_free(rh);
	pthread_t th;
	int64_t ts = now_ms();
	pthread_create(&th, NULL, reader_thread, &x);
	usleep(100000);
	int64_t t0 = now_ms();
	int kc = kind_of(bml_close(obj));
	int64_t t1 = now_ms();
	int krc = kind_of(bml_ringbuf_close(x.reader));
	int64_t t2 = now_ms();
	pthread_join(th, NULL);
	int krc2 = kind_of(bml_ringbuf_close(x.reader));
	int kc2 = kind_of(bml_close(obj));
	uint8_t ev[32];
	int kr = kind_of(bml_ringbuf_read(x.reader, 0, ev, 32));
	int good = kc == BML_STATE && t1 - t0 < 100 && krc == BML_STATE && t2 - t1 < 100 && x.kind == BML_OK && x.value == 0 &&
		   x.t_end - ts >= 4000 && krc2 == BML_OK && kc2 == BML_OK && kr == BML_STATE;
	printf("R4: bml_close during read %d (%lld ms), ringbuf_close %d (%lld ms), read %lld/%lld (%lld ms), later ringbuf_close %d, bml_close %d, read %d — %s\n",
	       kc, (long long)(t1 - t0), krc, (long long)(t2 - t1), (long long)x.kind, (long long)x.value, (long long)(x.t_end - ts), krc2, kc2, kr,
	       good ? "ok" : "FAIL");
	return !good;
}

int main(int argc, char **argv)
{
	if (argc != 4 || (strcmp(argv[1], "r1") && strcmp(argv[1], "r2") && strcmp(argv[1], "r3"))) {
		fprintf(stderr, "abi_race r1|r2|r3 <flow.bpf.o> <sha>\n");
		return 2;
	}
	int64_t n = 0;
	uint8_t *elf = slurp(argv[2], &n);
	int64_t r = bml_load_checked(elf, n, S(argv[3]), S(MAPS_OK), 0);
	free(elf);
	if (bml_result_kind(r) != BML_OK) {
		printf("load: kind %lld\n", (long long)bml_result_kind(r));
		return 1;
	}
	obj = bml_result_value(r);
	bml_result_free(r);
	if (!strcmp(argv[1], "r3"))
		return r3();
	for (int i = 0; i < 4; i++) {
		r = bml_hash_iter_open(obj, S(DECL_FLOWS), S(REC_KEY), S(REC_VAL), 16, 24);
		iters[i] = bml_result_value(r);
		bml_result_free(r);
	}
	pthread_t th[4];
	for (int i = 0; i < 4; i++)
		pthread_create(&th[i], NULL, worker, (void *)(intptr_t)i);
	usleep(20000);
	int fails = 0;
	if (!strcmp(argv[1], "r1")) {
		int st = 0, ok = 0;
		for (int i = 0; i < 200; i++) {
			int k = kind_of(bml_close(obj));
			st += k == BML_STATE;
			ok += k == BML_OK;
			if (k == BML_OK)
				break;
		}
		atomic_store(&stop, 1);
		for (int i = 0; i < 4; i++)
			pthread_join(th[i], NULL);
		int kc = kind_of(bml_close(obj));
		int ka = kind_of(bml_map_get_int(obj, S(DECL_STATS), 0));
		/* 予測は STATE が 1 回以上 — 200 回の中で数が 0 の瞬間に OK になりうる (その後は STATE の契約) */
		int good = st >= 1 && kc == BML_OK && ka == BML_STATE && atomic_load(&bad_before) == 0;
		printf("R1: close STATE %d times, OK %d times (while threads run), close after stopping %d, get after that %d, unexpected %ld, calls %ld — %s\n", st, ok, kc, ka,
		       atomic_load(&bad_before), atomic_load(&calls), good ? "ok" : "FAIL");
		fails += !good;
	} else {
		int tries = 0, k;
		do {
			k = kind_of(bml_close(obj));
			tries++;
		} while (k != BML_OK && tries < 1000000);
		atomic_store(&closed_seen, 1);
		usleep(50000); /* close の後も thread は回る — 全て STATE のはず */
		atomic_store(&stop, 1);
		for (int i = 0; i < 4; i++)
			pthread_join(th[i], NULL);
		int good = k == BML_OK && atomic_load(&bad_after) == 0 && atomic_load(&bad_before) == 0;
		printf("R2: close at attempt %d returned %d, non-STATE calls after close %ld, unexpected before %ld, calls %ld — %s\n", tries, k, atomic_load(&bad_after),
		       atomic_load(&bad_before), atomic_load(&calls), good ? "ok" : "FAIL");
		fails += !good;
	}
	return fails ? 1 : 0;
}
