/* The C harness for tests/core-boundary/adapter.sh.
 *
 * One argument, the case id. Each case builds its own situation and performs
 * one operation, because the situations are what the table's `setup` column
 * names and they are not expressible as a flag.
 *
 * Every case starts from a fresh process, so ids never carry between them: the
 * registry never reuses an id, and a case that assumed a particular number
 * would be asserting the order the suite happens to run in.
 *
 * Printed: the answer, then whatever the case's `expect` column is about.
 */
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include "spinel_adapter_sum_u8.h"
#include "spinel_adapter_sum_i64.h"
#include "spinel_adapter_store_at.h"
#include "spinel_adapter_store_at_i64.h"
#include "spinel_adapter_collision.h"
#include "spinel_adapter_merge_into.h"
#include "spinel_adapter_sum_i16.h"
#include "spinel_adapter_store_i8.h"
#include "spinel_core_sum_u8.h"

/* The adapter's id budget is its own; the harness only needs to know what it
 * was built with. Left at the real value here, so a build that forgot to lower
 * it refuses the exhaustion case rather than looping two billion times. */
#ifndef SPINEL_CORE_ADAPTER_ID_LIMIT
#define SPINEL_CORE_ADAPTER_ID_LIMIT 2147483647
#endif

#define A_startup        spinel_adapter_sum_u8_startup
#define A_allocate       spinel_adapter_sum_u8_allocate
#define A_bind           spinel_adapter_sum_u8_bind
#define A_store          spinel_adapter_sum_u8_store
#define A_load           spinel_adapter_sum_u8_load
#define A_store_words    spinel_adapter_sum_u8_store_i64_words
#define A_load_words     spinel_adapter_sum_u8_load_i64_words
#define A_invoke         spinel_adapter_sum_u8_invoke
#define A_release        spinel_adapter_sum_u8_release

static int32_t filled_u8(int64_t n) {
  int32_t id = A_allocate(SPINEL_CORE_ELEM_U8, n);
  for (int64_t i = 0; i < n; ++i) A_store(id, i, 1 + i);
  return id;
}

int main(int argc, char **argv) {
  if (argc != 2) return 99;
  const char *id = argv[1];
  if (A_startup() != 0) { printf("startup-failed\n"); return 98; }

#define CASE(name) if (strcmp(id, name) == 0)

  CASE("alloc-u8") {
    int32_t a = A_allocate(SPINEL_CORE_ELEM_U8, 4);
    printf("%s %lld\n", a > 0 ? "id" : "zero", (long long)A_load(a, 3));
    return 0;
  }
  CASE("alloc-i32") {
    int32_t a = A_allocate(SPINEL_CORE_ELEM_I32, 2);
    printf("%s %lld\n", a > 0 ? "id" : "zero", (long long)A_load(a, 1));
    return 0;
  }
  CASE("alloc-u32") {
    int32_t a = A_allocate(SPINEL_CORE_ELEM_U32, 2);
    printf("%s %lld\n", a > 0 ? "id" : "zero", (long long)A_load(a, 1));
    return 0;
  }
  CASE("alloc-i64") {
    int32_t a = A_allocate(SPINEL_CORE_ELEM_I64, 2);
    int32_t w = A_allocate(SPINEL_CORE_ELEM_U32, 2);
    A_load_words(a, 1, w, 0, 1);
    printf("%s %lld\n", a > 0 ? "id" : "zero", (long long)(A_load(w, 0) + A_load(w, 1)));
    return 0;
  }
  CASE("alloc-zero-count") {
    int32_t a = A_allocate(SPINEL_CORE_ELEM_U8, 0);
    printf("%s %d\n", a > 0 ? "id" : "zero", (int)A_release(a));
    return 0;
  }
  CASE("alloc-ids-ascend") {
    int32_t a = A_allocate(SPINEL_CORE_ELEM_U8, 1);
    int32_t b = A_allocate(SPINEL_CORE_ELEM_U8, 1);
    int32_t c = A_allocate(SPINEL_CORE_ELEM_U8, 1);
    A_release(b);
    int32_t d = A_allocate(SPINEL_CORE_ELEM_U8, 1);
    printf("%s %d\n", a > 0 ? "id" : "zero", (b > a && c > b && d > c) ? 1 : 0);
    return 0;
  }
  CASE("alloc-exhausted") {
    /* Built with a lowered id limit, so this reaches the same refusal the real
     * budget would without issuing two billion ids. */
    if (SPINEL_CORE_ADAPTER_ID_LIMIT > 1000) {
      printf("needs-a-lowered-id-limit\n");
      return 96;
    }
    int32_t last = 0, a;
    for (int64_t i = 0; i < (int64_t)SPINEL_CORE_ADAPTER_ID_LIMIT + 2; ++i) {
      a = A_allocate(SPINEL_CORE_ELEM_U8, 1);
      if (a == 0) break;
      last = a;
    }
    printf("%s %d\n", a == 0 ? "zero" : "id", last == SPINEL_CORE_ADAPTER_ID_LIMIT);
    return 0;
  }
  CASE("store-ok") {
    int32_t a = A_allocate(SPINEL_CORE_ELEM_U8, 4);
    int32_t st = A_store(a, 0, 200);
    printf("%d %lld\n", (int)st, (long long)A_load(a, 0));
    return 0;
  }
  CASE("store-index-past-end") {
    int32_t a = filled_u8(4);
    int32_t st = A_store(a, 4, 1);
    printf("%d %lld\n", (int)st, (long long)A_load(a, 3));
    return 0;
  }
  CASE("store-index-negative") {
    int32_t a = filled_u8(4);
    int32_t st = A_store(a, -1, 1);
    printf("%d %lld\n", (int)st, (long long)A_load(a, 0));
    return 0;
  }
  CASE("store-value-too-wide") {
    int32_t a = filled_u8(4);
    int32_t st = A_store(a, 0, 256);
    printf("%d %lld\n", (int)st, (long long)A_load(a, 0));
    return 0;
  }
  CASE("store-stale-id") {
    int32_t a = A_allocate(SPINEL_CORE_ELEM_U8, 4);
    A_release(a);
    printf("%d -\n", (int)A_store(a, 0, 1));
    return 0;
  }
  CASE("store-on-i64") {
    int32_t a = A_allocate(SPINEL_CORE_ELEM_I64, 2);
    printf("%d -\n", (int)A_store(a, 0, 1));
    return 0;
  }
  CASE("store-zero-count") {
    int32_t a = A_allocate(SPINEL_CORE_ELEM_U8, 0);
    printf("%d -\n", (int)A_store(a, 0, 1));
    return 0;
  }
  CASE("load-ok") {
    printf("value %lld\n", (long long)A_load(filled_u8(4), 1));
    return 0;
  }
  CASE("load-i32-negative") {
    int32_t a = A_allocate(SPINEL_CORE_ELEM_I32, 2);
    A_store(a, 0, -1);
    printf("value %lld\n", (long long)A_load(a, 0));
    return 0;
  }
  CASE("load-index-past-end") {
    printf("%d -\n", (int)-A_load(filled_u8(4), 4));
    return 0;
  }
  CASE("load-stale-id") {
    int32_t a = A_allocate(SPINEL_CORE_ELEM_U8, 4);
    A_release(a);
    printf("%d -\n", (int)-A_load(a, 0));
    return 0;
  }
  /* An id the registry never issued, at either end of the range below the
   * first: 0 here, and START - 1 in the ceiling build below. Both are refused
   * as an argument. */
  CASE("load-id-zero") {
    printf("%d -\n", (int)-A_load(0, 0));
    return 0;
  }
  /* Built with the id start near INT32_MAX: after one allocation (which takes
   * the start), the id just below it is refused exactly as id 0 is. The second
   * field says the allocation took the start, so the table exists. */
  CASE("load-below-start-ceiling") {
#ifdef SPINEL_CORE_ADAPTER_ID_START
    int32_t a = A_allocate(SPINEL_CORE_ELEM_U8, 1);
    printf("%d %d\n", (int)-A_load(SPINEL_CORE_ADAPTER_ID_START - 1, 0),
           a == SPINEL_CORE_ADAPTER_ID_START);
#else
    printf("n/a -\n");
#endif
    return 0;
  }
  CASE("load-on-i64") {
    printf("%d -\n", (int)-A_load(A_allocate(SPINEL_CORE_ELEM_I64, 2), 0));
    return 0;
  }
  CASE("words-roundtrip-min") {
    int32_t a = A_allocate(SPINEL_CORE_ELEM_I64, 2);
    int32_t w = A_allocate(SPINEL_CORE_ELEM_U32, 2);
    int32_t st = A_store_words(a, 0, 0, 2147483648LL);
    A_load_words(a, 0, w, 0, 1);
    printf("%d %lld:%lld\n", (int)st, (long long)A_load(w, 0), (long long)A_load(w, 1));
    return 0;
  }
  CASE("words-roundtrip-max") {
    int32_t a = A_allocate(SPINEL_CORE_ELEM_I64, 2);
    int32_t w = A_allocate(SPINEL_CORE_ELEM_U32, 2);
    int32_t st = A_store_words(a, 0, 4294967295LL, 2147483647LL);
    A_load_words(a, 0, w, 0, 1);
    printf("%d %lld:%lld\n", (int)st, (long long)A_load(w, 0), (long long)A_load(w, 1));
    return 0;
  }
  CASE("words-on-u8") {
    int32_t a = filled_u8(4);
    int32_t st = A_store_words(a, 0, 1, 0);
    printf("%d %lld\n", (int)st, (long long)A_load(a, 0));
    return 0;
  }
  CASE("words-out-equal-indices") {
    int32_t a = A_allocate(SPINEL_CORE_ELEM_I64, 2);
    int32_t w = A_allocate(SPINEL_CORE_ELEM_U32, 2);
    A_store_words(a, 0, 0, 2147483648LL);
    A_store(w, 0, 11); A_store(w, 1, 22);
    int32_t st = A_load_words(a, 0, w, 0, 0);
    printf("%d %lld:%lld\n", (int)st, (long long)A_load(w, 0), (long long)A_load(w, 1));
    return 0;
  }
  CASE("words-out-past-end") {
    int32_t a = A_allocate(SPINEL_CORE_ELEM_I64, 2);
    int32_t w = A_allocate(SPINEL_CORE_ELEM_U32, 2);
    A_store_words(a, 0, 0, 2147483648LL);
    A_store(w, 0, 11); A_store(w, 1, 22);
    int32_t st = A_load_words(a, 0, w, 0, 2);
    printf("%d %lld:%lld\n", (int)st, (long long)A_load(w, 0), (long long)A_load(w, 1));
    return 0;
  }
  CASE("words-out-wrong-type") {
    int32_t a = A_allocate(SPINEL_CORE_ELEM_I64, 2);
    int32_t u = filled_u8(4);
    A_store_words(a, 0, 0, 2147483648LL);
    int32_t st = A_load_words(a, 0, u, 0, 1);
    printf("%d %lld:%lld\n", (int)st, (long long)A_load(u, 0), (long long)A_load(u, 1));
    return 0;
  }
  CASE("words-out-aliases-source") {
    int32_t a = A_allocate(SPINEL_CORE_ELEM_I64, 2);
    A_store_words(a, 0, 0, 2147483648LL);
    printf("%d -\n", (int)A_load_words(a, 0, a, 0, 1));
    return 0;
  }
  CASE("words-out-ok") {
    int32_t a = A_allocate(SPINEL_CORE_ELEM_I64, 2);
    int32_t w = A_allocate(SPINEL_CORE_ELEM_U32, 2);
    A_store_words(a, 0, 0, 2147483648LL);
    int32_t st = A_load_words(a, 0, w, 0, 1);
    printf("%d %lld:%lld\n", (int)st, (long long)A_load(w, 0), (long long)A_load(w, 1));
    return 0;
  }
  CASE("invoke-ok") {
    int32_t b = filled_u8(7);              /* 1+2+3+4+5+6+7 */
    int32_t r = A_allocate(SPINEL_CORE_ELEM_I64, 1);
    int32_t w = A_allocate(SPINEL_CORE_ELEM_U32, 2);
    int32_t st = A_invoke(b, r);
    A_load_words(r, 0, w, 0, 1);
    printf("%d %lld\n", (int)st, (long long)A_load(w, 0));
    return 0;
  }
  CASE("invoke-result-aliases-input") {
    int32_t b = filled_u8(4);
    printf("%d %lld\n", (int)A_invoke(b, b), (long long)A_load(b, 0));
    return 0;
  }
  CASE("invoke-result-wrong-type") {
    int32_t b = filled_u8(4);
    int32_t r = A_allocate(SPINEL_CORE_ELEM_U8, 1);
    A_store(r, 0, 99);
    printf("%d %lld\n", (int)A_invoke(b, r), (long long)A_load(r, 0));
    return 0;
  }
  CASE("invoke-result-zero-length") {
    int32_t b = filled_u8(4);
    int32_t r = A_allocate(SPINEL_CORE_ELEM_I64, 0);
    printf("%d -\n", (int)A_invoke(b, r));
    return 0;
  }
  /* The store_at contract: one `inout` buffer and a caller-supplied index, so
   * the kernel CAN fail, and there is a mutable participant to poison. sum_u8
   * has neither -- its loop is bounded by the registry's count. */
  CASE("invoke-kernel-bounds") {
    int32_t d = spinel_adapter_store_at_allocate(SPINEL_CORE_ELEM_U8, 2);
    int32_t r = spinel_adapter_store_at_allocate(SPINEL_CORE_ELEM_I64, 1);
    printf("%d %lld\n", (int)spinel_adapter_store_at_invoke(d, 5, 7, r),
           (long long)spinel_adapter_store_at_load(d, 0));
    return 0;
  }
  CASE("invoke-poisons-mutable") {
    int32_t d = spinel_adapter_store_at_allocate(SPINEL_CORE_ELEM_U8, 2);
    int32_t r = spinel_adapter_store_at_allocate(SPINEL_CORE_ELEM_I64, 1);
    spinel_adapter_store_at_invoke(d, 5, 7, r);       /* fails on bounds */
    /* Everything but release refuses from here: the call may have written a
     * prefix and no rollback is promised. */
    printf("%d %d\n", (int)spinel_adapter_store_at_store(d, 0, 1),
           (int)spinel_adapter_store_at_release(d));
    return 0;
  }
  CASE("invoke-result-not-poisoned") {
    int32_t d = spinel_adapter_store_at_allocate(SPINEL_CORE_ELEM_U8, 2);
    int32_t r = spinel_adapter_store_at_allocate(SPINEL_CORE_ELEM_I64, 1);
    int32_t w = spinel_adapter_store_at_allocate(SPINEL_CORE_ELEM_U32, 2);
    spinel_adapter_store_at_store_i64_words(r, 0, 99, 0);
    spinel_adapter_store_at_invoke(d, 5, 7, r);       /* fails on bounds */
    /* The result is not poisoned: a failed invocation left its previous value
     * alone, so there is nothing damaged to protect the caller from. */
    spinel_adapter_store_at_load_i64_words(r, 0, w, 0, 1);
    printf("value %lld\n", (long long)spinel_adapter_store_at_load(w, 0));
    return 0;
  }
  CASE("store-value-negative") {
    int32_t a = filled_u8(4);
    int32_t st = A_store(a, 0, -1);
    printf("%d %lld\n", (int)st, (long long)A_load(a, 0));
    return 0;
  }
  CASE("words-low-negative") {
    int32_t a = spinel_adapter_sum_i64_allocate(SPINEL_CORE_ELEM_I64, 2);
    int32_t w = spinel_adapter_sum_i64_allocate(SPINEL_CORE_ELEM_U32, 2);
    spinel_adapter_sum_i64_store_i64_words(a, 0, 7, 0);
    int32_t st = spinel_adapter_sum_i64_store_i64_words(a, 0, -1, 0);
    spinel_adapter_sum_i64_load_i64_words(a, 0, w, 0, 1);
    printf("%d %lld\n", (int)st, (long long)spinel_adapter_sum_i64_load(w, 0));
    return 0;
  }
  CASE("words-high-above-u32") {
    int32_t a = spinel_adapter_sum_i64_allocate(SPINEL_CORE_ELEM_I64, 2);
    int32_t w = spinel_adapter_sum_i64_allocate(SPINEL_CORE_ELEM_U32, 2);
    spinel_adapter_sum_i64_store_i64_words(a, 0, 7, 0);
    int32_t st = spinel_adapter_sum_i64_store_i64_words(a, 0, 0, 4294967296LL);
    spinel_adapter_sum_i64_load_i64_words(a, 0, w, 0, 1);
    printf("%d %lld\n", (int)st, (long long)spinel_adapter_sum_i64_load(w, 0));
    return 0;
  }
  /* The identity rule on its own. With a u8 input the element-type check
   * refuses this first and the rule is never reached; here the participant and
   * the result are both i64 and only the id is the same. */
  CASE("invoke-result-is-input-same-type") {
    int32_t b = spinel_adapter_sum_i64_allocate(SPINEL_CORE_ELEM_I64, 2);
    spinel_adapter_sum_i64_store_i64_words(b, 0, 5, 0);
    int32_t w = spinel_adapter_sum_i64_allocate(SPINEL_CORE_ELEM_U32, 2);
    int32_t st = spinel_adapter_sum_i64_invoke(b, b);
    spinel_adapter_sum_i64_load_i64_words(b, 0, w, 0, 1);
    printf("%d %lld\n", (int)st, (long long)spinel_adapter_sum_i64_load(w, 0));
    return 0;
  }
  /* TWO `inout` PARTICIPANTS GIVEN ONE ID. merge_into writes `dst` from
   * `other` and both are `inout`, so this is the only shape here where one id
   * names two written ranges. The contract answers ARGUMENT and writes
   * nothing; the participants are poisoned, so every later load on them
   * refuses with a negative status rather than returning a byte. */
  CASE("invoke-two-inout-same-id") {
    int32_t r = spinel_adapter_merge_into_allocate(SPINEL_CORE_ELEM_I64, 1);
    int32_t a = spinel_adapter_merge_into_allocate(SPINEL_CORE_ELEM_U8, 4);
    for (int i = 0; i < 4; ++i) spinel_adapter_merge_into_store(a, i, 7);
    int32_t st = spinel_adapter_merge_into_invoke(a, a, r);
    printf("%d %lld,%lld,%lld,%lld\n", (int)st,
           (long long)spinel_adapter_merge_into_load(a, 0),
           (long long)spinel_adapter_merge_into_load(a, 1),
           (long long)spinel_adapter_merge_into_load(a, 2),
           (long long)spinel_adapter_merge_into_load(a, 3));
    return 0;
  }
  /* THE SAME CALL WITH TWO IDS, which is the control: without it the case
   * above would pass for a contract that refuses every merge_into. */
  CASE("invoke-two-inout-separate-ids") {
    int32_t r = spinel_adapter_merge_into_allocate(SPINEL_CORE_ELEM_I64, 1);
    int32_t a = spinel_adapter_merge_into_allocate(SPINEL_CORE_ELEM_U8, 4);
    int32_t b = spinel_adapter_merge_into_allocate(SPINEL_CORE_ELEM_U8, 4);
    for (int i = 0; i < 4; ++i) {
      spinel_adapter_merge_into_store(a, i, 7);
      spinel_adapter_merge_into_store(b, i, 3);
    }
    int32_t st = spinel_adapter_merge_into_invoke(a, b, r);
    printf("%d %lld,%lld,%lld,%lld\n", (int)st,
           (long long)spinel_adapter_merge_into_load(a, 0),
           (long long)spinel_adapter_merge_into_load(a, 1),
           (long long)spinel_adapter_merge_into_load(a, 2),
           (long long)spinel_adapter_merge_into_load(a, 3));
    return 0;
  }
  CASE("invoke-result-is-input-zero-length") {
    int32_t b = spinel_adapter_sum_i64_allocate(SPINEL_CORE_ELEM_I64, 0);
    printf("%d -\n", (int)spinel_adapter_sum_i64_invoke(b, b));
    return 0;
  }
  CASE("release-ok") {
    int32_t a = filled_u8(4);
    int32_t st = A_release(a);
    printf("%d %d\n", (int)st, (int)A_store(a, 0, 1));
    return 0;
  }
  CASE("release-double") {
    int32_t a = A_allocate(SPINEL_CORE_ELEM_U8, 4);
    A_release(a);
    printf("%d -\n", (int)A_release(a));
    return 0;
  }
  CASE("release-zero-count") {
    int32_t a = A_allocate(SPINEL_CORE_ELEM_U8, 0);
    int32_t st = A_release(a);
    printf("%d %d\n", (int)st, (int)A_release(a));
    return 0;
  }
  /* The real ceiling, reached by STARTING near it. A lowered limit exercises
   * the refusal but not the arithmetic at INT32_MAX, where `id = next_id++` on
   * an int32_t was signed overflow rather than a refusal. */
  CASE("alloc-exhausted-real-ceiling") {
    int32_t a = A_allocate(SPINEL_CORE_ELEM_U8, 1);
    int32_t b = A_allocate(SPINEL_CORE_ELEM_U8, 1);
    int32_t c = A_allocate(SPINEL_CORE_ELEM_U8, 1);
    printf("%s %d\n", c == 0 ? "zero" : "id",
           (a == 2147483646 && b == 2147483647 && c == 0));
    return 0;
  }
  CASE("invoke-result-poisoned") {
    /* An i64 buffer poisoned as the mutable participant of a failed call, then
     * offered back as a RESULT. Being the result is not an exception to
     * "invalid for every operation but release". */
    int32_t d = spinel_adapter_store_at_i64_allocate(SPINEL_CORE_ELEM_I64, 2);
    int32_t r = spinel_adapter_store_at_i64_allocate(SPINEL_CORE_ELEM_I64, 1);
    spinel_adapter_store_at_i64_invoke(d, 5, 7, r);      /* fails on bounds */
    int32_t src = spinel_adapter_sum_i64_allocate(SPINEL_CORE_ELEM_I64, 1);
    printf("%d -\n", (int)spinel_adapter_sum_i64_invoke(src, d));
    return 0;
  }
  CASE("adapter-name-collision") {
    /* A buffer `src` beside a scalar `src_id`. That this case RUNS is the
     * check: the generated header and source have to compile, and they did not
     * while contract names went straight into C. */
    int32_t b = spinel_adapter_collision_allocate(SPINEL_CORE_ELEM_U8, 1);
    int32_t r = spinel_adapter_collision_allocate(SPINEL_CORE_ELEM_I64, 1);
    spinel_adapter_collision_store(b, 0, 5);
    printf("%d -\n", (int)spinel_adapter_collision_invoke(b, 3, r));
    return 0;
  }
  /* Decision 0018: the narrow elements. A load answers the 32-bit pattern of
   * the SIGN-EXTENDED value for i8 and i16, as it does for i32, so one decode
   * rule serves every signed element; u16 is zero-extended. The second field
   * is every element of the storage, in order. */
  CASE("alloc-i8") {
    int32_t a = A_allocate(SPINEL_CORE_ELEM_I8, 3);
    printf("%s %lld\n", a > 0 ? "id" : "zero", (long long)A_load(a, 2));
    return 0;
  }
  CASE("alloc-u16") {
    int32_t a = A_allocate(SPINEL_CORE_ELEM_U16, 3);
    printf("%s %lld\n", a > 0 ? "id" : "zero", (long long)A_load(a, 2));
    return 0;
  }
  CASE("alloc-i16") {
    int32_t a = A_allocate(SPINEL_CORE_ELEM_I16, 3);
    printf("%s %lld\n", a > 0 ? "id" : "zero", (long long)A_load(a, 2));
    return 0;
  }
  CASE("store-i8-range-ends") {
    int32_t a = A_allocate(SPINEL_CORE_ELEM_I8, 2);
    int32_t st = A_store(a, 0, -128) | A_store(a, 1, 127);
    printf("%d %lld,%lld\n", (int)st, (long long)A_load(a, 0), (long long)A_load(a, 1));
    return 0;
  }
  CASE("store-i8-outside") {
    int32_t a = A_allocate(SPINEL_CORE_ELEM_I8, 2);
    A_store(a, 0, 5); A_store(a, 1, 6);
    int32_t hi = A_store(a, 0, 128), lo = A_store(a, 1, -129);
    printf("%d %d,%lld,%lld\n", (int)hi, (int)lo, (long long)A_load(a, 0), (long long)A_load(a, 1));
    return 0;
  }
  CASE("store-u16-range-ends") {
    int32_t a = A_allocate(SPINEL_CORE_ELEM_U16, 2);
    int32_t st = A_store(a, 0, 0) | A_store(a, 1, 65535);
    printf("%d %lld,%lld\n", (int)st, (long long)A_load(a, 0), (long long)A_load(a, 1));
    return 0;
  }
  CASE("store-u16-outside") {
    int32_t a = A_allocate(SPINEL_CORE_ELEM_U16, 2);
    A_store(a, 0, 5); A_store(a, 1, 6);
    int32_t hi = A_store(a, 0, 65536), lo = A_store(a, 1, -1);
    printf("%d %d,%lld,%lld\n", (int)hi, (int)lo, (long long)A_load(a, 0), (long long)A_load(a, 1));
    return 0;
  }
  CASE("store-i16-range-ends") {
    int32_t a = A_allocate(SPINEL_CORE_ELEM_I16, 2);
    int32_t st = A_store(a, 0, -32768) | A_store(a, 1, 32767);
    printf("%d %lld,%lld\n", (int)st, (long long)A_load(a, 0), (long long)A_load(a, 1));
    return 0;
  }
  CASE("store-i16-outside") {
    int32_t a = A_allocate(SPINEL_CORE_ELEM_I16, 2);
    A_store(a, 0, 5); A_store(a, 1, 6);
    int32_t hi = A_store(a, 0, 32768), lo = A_store(a, 1, -32769);
    printf("%d %d,%lld,%lld\n", (int)hi, (int)lo, (long long)A_load(a, 0), (long long)A_load(a, 1));
    return 0;
  }
  /* sum_i16 through its adapter: the kernel sign-extends, and the i64 result
   * comes back as its two words. */
  CASE("invoke-i16-sign-extends") {
    int32_t b = spinel_adapter_sum_i16_allocate(SPINEL_CORE_ELEM_I16, 3);
    spinel_adapter_sum_i16_store(b, 0, -32768);
    spinel_adapter_sum_i16_store(b, 1, 32767);
    spinel_adapter_sum_i16_store(b, 2, -1);
    int32_t r = spinel_adapter_sum_i16_allocate(SPINEL_CORE_ELEM_I64, 1);
    int32_t w = spinel_adapter_sum_i16_allocate(SPINEL_CORE_ELEM_U32, 2);
    int32_t st = spinel_adapter_sum_i16_invoke(b, r);
    spinel_adapter_sum_i16_load_i64_words(r, 0, w, 0, 1);
    printf("%d %lld,%lld\n", (int)st, (long long)spinel_adapter_sum_i16_load(w, 0),
           (long long)spinel_adapter_sum_i16_load(w, 1));
    return 0;
  }
  /* The registry refuses storage of another element before the kernel runs.
   * u16 storage is the same width as i16 and differs only in its tag, so the
   * tag is the whole check; i8 storage differs in width too. The result keeps
   * the 99 it held. */
  CASE("invoke-i16-given-u16") {
    int32_t b = spinel_adapter_sum_i16_allocate(SPINEL_CORE_ELEM_U16, 3);
    int32_t r = spinel_adapter_sum_i16_allocate(SPINEL_CORE_ELEM_I64, 1);
    int32_t w = spinel_adapter_sum_i16_allocate(SPINEL_CORE_ELEM_U32, 2);
    spinel_adapter_sum_i16_store_i64_words(r, 0, 99, 0);
    int32_t st = spinel_adapter_sum_i16_invoke(b, r);
    spinel_adapter_sum_i16_load_i64_words(r, 0, w, 0, 1);
    printf("%d %lld\n", (int)st, (long long)spinel_adapter_sum_i16_load(w, 0));
    return 0;
  }
  CASE("invoke-i16-given-i8") {
    int32_t b = spinel_adapter_sum_i16_allocate(SPINEL_CORE_ELEM_I8, 6);
    int32_t r = spinel_adapter_sum_i16_allocate(SPINEL_CORE_ELEM_I64, 1);
    int32_t w = spinel_adapter_sum_i16_allocate(SPINEL_CORE_ELEM_U32, 2);
    spinel_adapter_sum_i16_store_i64_words(r, 0, 99, 0);
    int32_t st = spinel_adapter_sum_i16_invoke(b, r);
    spinel_adapter_sum_i16_load_i64_words(r, 0, w, 0, 1);
    printf("%d %lld\n", (int)st, (long long)spinel_adapter_sum_i16_load(w, 0));
    return 0;
  }
  /* store_i8 through its adapter. A value the KERNEL stores outside i8 is
   * ARITHMETIC, not ARGUMENT, and the participant is poisoned: the load after
   * it refuses. In range, the element holds the sign-extended pattern. */
  CASE("invoke-i8-store-ok") {
    int32_t d = spinel_adapter_store_i8_allocate(SPINEL_CORE_ELEM_I8, 2);
    int32_t r = spinel_adapter_store_i8_allocate(SPINEL_CORE_ELEM_I64, 1);
    int32_t st = spinel_adapter_store_i8_invoke(d, -128, r);
    printf("%d %lld\n", (int)st, (long long)spinel_adapter_store_i8_load(d, 0));
    return 0;
  }
  CASE("invoke-i8-store-outside") {
    int32_t d = spinel_adapter_store_i8_allocate(SPINEL_CORE_ELEM_I8, 2);
    int32_t r = spinel_adapter_store_i8_allocate(SPINEL_CORE_ELEM_I64, 1);
    int32_t st = spinel_adapter_store_i8_invoke(d, 128, r);
    printf("%d %lld\n", (int)st, (long long)spinel_adapter_store_i8_load(d, 0));
    return 0;
  }
  /* Decision 0021: storage the caller placed, bound read-only. The memory is
   * the harness's own and static, so a registry that wrote it, or freed it,
   * would show here: a write changes what the second field prints, and a
   * free of static memory aborts the case. Every refusal violates one rule;
   * the rest of its descriptor is the one bind-ok binds. */
  static const uint8_t mem_u8[4] __attribute__((aligned(8))) = {1, 2, 3, 4};
  static const uint16_t mem_u16[3] __attribute__((aligned(8))) = {0, 0, 0};
  static const uint32_t mem_u32[2] __attribute__((aligned(8))) = {7, 8};
  static const int64_t mem_i64[1] __attribute__((aligned(8))) = {5};
#define ADDR(p) ((uint64_t)(uintptr_t)(p))
#define READ_U8_4(b) (long long)A_load(b, 0), (long long)A_load(b, 1), \
                     (long long)A_load(b, 2), (long long)A_load(b, 3)
  CASE("bind-ok") {
    int32_t b = A_bind(SPINEL_CORE_ELEM_U8, 4, ADDR(mem_u8));
    printf("%s %lld,%lld,%lld,%lld\n", b > 0 ? "id" : "zero", READ_U8_4(b));
    return 0;
  }
  CASE("bind-zero-count-null") {
    int32_t b = A_bind(SPINEL_CORE_ELEM_U8, 0, 0);
    printf("%s %lld\n", b > 0 ? "id" : "zero", (long long)A_load(b, 0));
    return 0;
  }
  CASE("bind-null-with-count") {
    int32_t b = A_bind(SPINEL_CORE_ELEM_U8, 4, 0);
    printf("%s %d\n", b > 0 ? "id" : "zero", (int)b);
    return 0;
  }
  CASE("bind-negative-count") {
    int32_t b = A_bind(SPINEL_CORE_ELEM_U8, -1, ADDR(mem_u8));
    printf("%s %d\n", b > 0 ? "id" : "zero", (int)b);
    return 0;
  }
  CASE("bind-unknown-element") {
    int32_t b = A_bind(9, 4, ADDR(mem_u8));
    printf("%s %d\n", b > 0 ? "id" : "zero", (int)b);
    return 0;
  }
  CASE("bind-misaligned") {
    /* One byte into an aligned u16 array: in range, live, aligned for u8 and
     * not for u16. */
    int32_t b = A_bind(SPINEL_CORE_ELEM_U16, 2, ADDR(mem_u16) + 1);
    printf("%s %d\n", b > 0 ? "id" : "zero", (int)b);
    return 0;
  }
  CASE("bind-size-overflow") {
    /* 2^62 u32 elements: count x 4 is 2^64. */
    int32_t b = A_bind(SPINEL_CORE_ELEM_U32, (int64_t)1 << 62, ADDR(mem_u32));
    printf("%s %d\n", b > 0 ? "id" : "zero", (int)b);
    return 0;
  }
  CASE("bind-end-overflow") {
    /* Four bytes from the second-to-last address: the size fits, the end
     * does not. u8, so every address is aligned. */
    int32_t b = A_bind(SPINEL_CORE_ELEM_U8, 4, UINT64_MAX - 1);
    printf("%s %d\n", b > 0 ? "id" : "zero", (int)b);
    return 0;
  }
  CASE("bind-store-refused") {
    int32_t b = A_bind(SPINEL_CORE_ELEM_U8, 4, ADDR(mem_u8));
    int32_t st = A_store(b, 0, 9);
    printf("%d %lld,%lld,%lld,%lld\n", (int)st, READ_U8_4(b));
    return 0;
  }
  CASE("bind-words-store-refused") {
    int32_t b = A_bind(SPINEL_CORE_ELEM_I64, 1, ADDR(mem_i64));
    int32_t st = A_store_words(b, 0, 9, 0);
    printf("%d %lld\n", (int)st, (long long)mem_i64[0]);
    return 0;
  }
  CASE("bind-words-into-bound-refused") {
    int32_t a = A_allocate(SPINEL_CORE_ELEM_I64, 2);
    A_store_words(a, 0, 0, 2147483648LL);
    int32_t w = A_bind(SPINEL_CORE_ELEM_U32, 2, ADDR(mem_u32));
    int32_t st = A_load_words(a, 0, w, 0, 1);
    printf("%d %lld,%lld\n", (int)st, (long long)A_load(w, 0), (long long)A_load(w, 1));
    return 0;
  }
  CASE("bind-invoke-as-in") {
    /* The control that passes: bound storage in an `in` position. */
    int32_t b = A_bind(SPINEL_CORE_ELEM_U8, 4, ADDR(mem_u8));
    int32_t r = A_allocate(SPINEL_CORE_ELEM_I64, 1);
    int32_t w = A_allocate(SPINEL_CORE_ELEM_U32, 2);
    int32_t st = A_invoke(b, r);
    A_load_words(r, 0, w, 0, 1);
    printf("%d %lld\n", (int)st, (long long)A_load(w, 0));
    return 0;
  }
  CASE("bind-invoke-as-inout-refused") {
    int32_t b = spinel_adapter_store_at_bind(SPINEL_CORE_ELEM_U8, 4, ADDR(mem_u8));
    int32_t r = spinel_adapter_store_at_allocate(SPINEL_CORE_ELEM_I64, 1);
    int32_t st = spinel_adapter_store_at_invoke(b, 0, 9, r);
    printf("%d %lld,%lld,%lld,%lld\n", (int)st, READ_U8_4(b));
    return 0;
  }
  CASE("bind-invoke-as-result-refused") {
    int32_t s = spinel_adapter_sum_i64_allocate(SPINEL_CORE_ELEM_I64, 1);
    spinel_adapter_sum_i64_store_i64_words(s, 0, 3, 0);
    int32_t r = spinel_adapter_sum_i64_bind(SPINEL_CORE_ELEM_I64, 1, ADDR(mem_i64));
    int32_t st = spinel_adapter_sum_i64_invoke(s, r);
    printf("%d %lld\n", (int)st, (long long)mem_i64[0]);
    return 0;
  }
  CASE("bind-release-keeps-memory") {
    int32_t b = A_bind(SPINEL_CORE_ELEM_U8, 4, ADDR(mem_u8));
    int32_t st = A_release(b);
    printf("%d %lld,%d\n", (int)st, (long long)A_load(b, 0), (int)mem_u8[0]);
    return 0;
  }
  printf("unknown-case\n");
  return 97;
}
