/* The concurrency harness for tests/core-boundary/adapter.sh.
 *
 * Decision 0007: one C-side mutex serialises every registry and helper
 * operation, including the whole CORE invocation and release. What that does
 * and does not promise are different claims, and this program separates them.
 *
 * It establishes:
 *   * ids are unique across threads. A repeat would mean two callers owning
 *     one allocation, which is what "never reused" exists to prevent;
 *   * concurrent allocate/store/load/invoke/release leave every thread's own
 *     storage holding what that thread put there;
 *   * releases and invocations interleave without the registry losing track:
 *     every id allocated is released exactly once and no release fails.
 *
 * It deliberately does NOT establish that two Ruby reads are atomic, and the
 * last scenario shows why: each operation is serialised, a SEQUENCE of them is
 * not a transaction, and a caller that lets another thread mutate storage
 * between two word reads gets two halves of different values. That is the
 * caller's documented obligation, demonstrated rather than asserted.
 */
#include <pthread.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "spinel_adapter_sum_u8.h"

#define THREADS 8
#define ROUNDS  64


static int32_t ids[THREADS][ROUNDS];
static int failures;

static void fail(const char *what) {
  __atomic_fetch_add(&failures, 1, __ATOMIC_SEQ_CST);
  printf("FAIL %s\n", what);
}

static void *worker(void *arg) {
  const long t = (long)arg;
  for (int i = 0; i < ROUNDS; ++i) {
    int32_t b = spinel_adapter_sum_u8_allocate(SPINEL_CORE_ELEM_U8, 4);
    if (b <= 0) { fail("allocate returned no id"); return 0; }
    ids[t][i] = b;
    for (int k = 0; k < 4; ++k)
      if (spinel_adapter_sum_u8_store(b, k, (int64_t)((t + k) & 0xff)) != SPINEL_CORE_OK)
        fail("store refused");
    int32_t r = spinel_adapter_sum_u8_allocate(SPINEL_CORE_ELEM_I64, 1);
    if (r <= 0) { fail("result allocate returned no id"); return 0; }
    if (spinel_adapter_sum_u8_invoke(b, r) != SPINEL_CORE_OK) fail("invoke refused");
    /* This thread's own storage still holds this thread's values: the lock
     * kept another thread's work out of it. */
    for (int k = 0; k < 4; ++k)
      if (spinel_adapter_sum_u8_load(b, k) != (int64_t)((t + k) & 0xff))
        fail("a thread's own storage changed under it");
    if (spinel_adapter_sum_u8_release(r) != SPINEL_CORE_OK) fail("release of the result refused");
    if (spinel_adapter_sum_u8_release(b) != SPINEL_CORE_OK) fail("release refused");
  }
  return 0;
}

/* The obligation scenario.
 *
 * `load_i64_words` writes BOTH words under one lock, so the pair it produces is
 * consistent -- measured: a writer racing the SOURCE never tore it. The hazard
 * the decision names is the other one: the caller owns the destination, and
 * must not let another thread mutate or release it between the two ordinary
 * reads that follow. So the writer here mutates the DESTINATION.
 */
static int32_t shared_i64, shared_out;
static volatile int stop_writer;

static void *writer(void *arg) {
  (void)arg;
  while (!__atomic_load_n(&stop_writer, __ATOMIC_SEQ_CST)) {
    spinel_adapter_sum_u8_store(shared_out, 0, 0);
    spinel_adapter_sum_u8_store(shared_out, 1, 0);
    spinel_adapter_sum_u8_store(shared_out, 0, 7);
    spinel_adapter_sum_u8_store(shared_out, 1, 7);
  }
  return 0;
}

int main(void) {
  if (spinel_adapter_sum_u8_startup() != 0) { printf("FAIL startup\n"); return 1; }

  pthread_t th[THREADS];
  for (long t = 0; t < THREADS; ++t)
    if (pthread_create(&th[t], 0, worker, (void *)t) != 0) {
      printf("FAIL pthread_create\n");
      return 1;
    }
  for (int t = 0; t < THREADS; ++t) pthread_join(th[t], 0);

  /* Every id issued, exactly once. Sorted rather than compared pairwise so
   * that a repeat anywhere is caught, not only an adjacent one. */
  const int total = THREADS * ROUNDS;
  int32_t *flat = malloc((size_t)total * sizeof *flat);
  if (!flat) return 1;
  int n = 0;
  for (int t = 0; t < THREADS; ++t)
    for (int i = 0; i < ROUNDS; ++i) flat[n++] = ids[t][i];
  for (int i = 0; i < n; ++i)
    for (int j = i + 1; j < n; ++j)
      if (flat[i] == flat[j]) { fail("two threads were given the same id"); i = n; break; }
  free(flat);

  /* The obligation. A pair read either side of another thread's store may be
   * two halves of different values -- and that is the contract, not a defect:
   * individual operations are serialised, a sequence of them is not. */
  shared_i64 = spinel_adapter_sum_u8_allocate(SPINEL_CORE_ELEM_I64, 1);
  shared_out = spinel_adapter_sum_u8_allocate(SPINEL_CORE_ELEM_U32, 2);
  spinel_adapter_sum_u8_store_i64_words(shared_i64, 0, 0, 0);
  spinel_adapter_sum_u8_store(shared_out, 0, 0);
  spinel_adapter_sum_u8_store(shared_out, 1, 0);
  pthread_t w;
  if (pthread_create(&w, 0, writer, 0) != 0) { printf("FAIL writer\n"); return 1; }
  int torn = 0;
  for (int i = 0; i < 2000000 && !torn; ++i) {
    /* Two SEPARATE loads, which is what a Ruby caller doing two reads does.
     * Each is serialised; the pair is not. */
    const int64_t low = spinel_adapter_sum_u8_load(shared_out, 0);
    const int64_t high = spinel_adapter_sum_u8_load(shared_out, 1);
    if (low >= 0 && high >= 0 && low != high) torn = 1;
  }
  __atomic_store_n(&stop_writer, 1, __ATOMIC_SEQ_CST);
  pthread_join(w, 0);

  printf("ids-unique %d\n", failures == 0);
  printf("threads-kept-their-own %d\n", failures == 0);
  /* Printed either way. A run that did not happen to observe a mismatch has
   * not shown the pair IS atomic -- it has shown nothing, and saying so is
   * the point. */
  printf("sequence-is-not-a-transaction %s\n", torn ? "demonstrated" : "not-observed");
  return failures == 0 ? 0 : 1;
}
