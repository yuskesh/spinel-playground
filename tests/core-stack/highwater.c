/* tests/core-stack/highwater.c -- decision 0010 step 2, the runtime check.
 *
 *   highwater <static kernel_stack bytes>
 *
 * 0010's proof-of-concept acceptance: "a runtime high-water measurement on a
 * painted stack stays within the static kernel_stack. The measurement is a
 * lower bound, and exceeding the static value is a defect in the method."
 *
 * WHY IT IS A LOWER BOUND, and not a second opinion. Painting detects bytes
 * that were WRITTEN. A frame code generation allocated and the run did not
 * write through is invisible here, and a path the run did not take costs
 * nothing. The static figure is a maximum over all paths; this is one run of
 * one path. Under is expected; over means the static method missed something.
 *
 * WHAT THE FIRST TWO ATTEMPTS MEASURED, because the shape of this program is a
 * consequence of them.
 *
 *   1. Painting the thread's stack once and reading it after pthread_join
 *      measured 1799 bytes for the entry and 1799 for a no-op: teardown reuses
 *      the region below the call site and goes deeper than either callee.
 *   2. Reading it inside the thread instead gave the same two numbers, and
 *      scanning before the call as well as after showed why -- the deepest
 *      byte was already dirty BEFORE the call. Thread startup writes 1799
 *      bytes below the call site, and a scan finds the DEEPEST dirty byte, so
 *      startup's floor hid everything shallower.
 *
 * Both passed. Neither measured anything. So the region below the call site is
 * REPAINTED from inside the thread, immediately before the call, by an inline
 * loop through a volatile pointer -- not memset, whose own frame would land in
 * the region it was clearing.
 *
 * The repaint cannot reach the call site itself without overwriting the live
 * locals of the frame doing the repainting, so it stops GAP bytes short. GAP
 * is this harness's resolution: a callee writing less than GAP below the call
 * site is invisible. The figure reported is the DIFFERENCE between a mark and
 * the no-op's, which removes the floor and the call's own return address alike.
 *
 * GAP IS THE WORST CASE FOR THE FLOOR, NOT ITS VALUE. This file first required
 * the no-op to measure exactly GAP, which encoded a glibc fact as a property of
 * stacks: on glibc the thread start-up writes into that region before the call
 * -- 1799 bytes in the measurement this file replaces -- so the floor is always
 * dirty up to the boundary. On Darwin arm64 it is simply clean and the no-op
 * measures 0, which is BETTER than the condition the check was written for, and
 * the harness refused a sound run for it. So the no-op is required to be at or
 * below GAP, and the figure does not depend on where in that range it falls,
 * because it is subtracted either way.
 *
 * AND THE HARNESS PROVES IT CAN SEE. Before the entry is measured, a control
 * with a known CONTROL_BYTES buffer, written through so nothing may narrow it,
 * must measure at least that much. A harness that cannot see the control is
 * refused rather than believed.
 */
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include "st_deep.h"

#define PATTERN 0xA5
#define STACK_BYTES (1u << 20)
/* Bytes left unpainted below the call site, to keep the repainting frame's own
 * locals. Larger than that frame and much smaller than the entry under test. */
#define GAP 128
#define CONTROL_BYTES 4096

typedef int32_t (*entry_fn)(int64_t *, uint64_t, int64_t, int64_t, int64_t *);

static int32_t noop_entry(int64_t *cnt, uint64_t n_cnt, int64_t a, int64_t b,
                          int64_t *result) {
  (void)cnt;
  (void)n_cnt;
  (void)a;
  (void)b;
  *result = 0;
  return 0;
}

/* The positive control: a frame that cannot be smaller than CONTROL_BYTES,
 * written through volatile storage so nothing may narrow or drop it. */
__attribute__((noinline)) static int32_t control_entry(int64_t *cnt,
                                                       uint64_t n_cnt,
                                                       int64_t a, int64_t b,
                                                       int64_t *result) {
  volatile unsigned char buf[CONTROL_BYTES];
  size_t i;
  (void)cnt;
  (void)n_cnt;
  (void)b;
  for (i = 0; i < CONTROL_BYTES; i++) buf[i] = (unsigned char)(a + (int64_t)i);
  *result = (int64_t)buf[0] + (int64_t)buf[CONTROL_BYTES - 1];
  return 0;
}

struct run {
  entry_fn fn;
  char *base; /* the painted region, low address first */
  size_t size;
  int64_t *cnt; /* the entry's buffer, owned by the frame ABOVE the call site */
  long used;    /* out: bytes written below the call site */
  int32_t status;
  int64_t result;
};

/* The call site, and nothing else: its frame must stay small enough to fit in
 * GAP. noinline so it cannot be folded into its caller's larger frame. */
__attribute__((noinline)) static void measure_call(struct run *r) {
  volatile char mark = 0;
  char *probe = (char *)&mark;
  volatile unsigned char *q = (volatile unsigned char *)r->base;
  const size_t limit = (size_t)((probe - GAP) - r->base);
  size_t i;

  for (i = 0; i < limit; i++) q[i] = PATTERN;

  r->status = r->fn(r->cnt, 8, 3, 5, &r->result);

  i = 0;
  while (i < r->size && q[i] == PATTERN) i++;
  r->used = (i >= r->size) ? -1 : (long)(probe - (r->base + i));
  (void)mark;
}

static void *body(void *p) {
  struct run *r = (struct run *)p;
  int64_t cnt[8] = {0};
  r->cnt = cnt;
  measure_call(r);
  return NULL;
}

/* Bytes written below the call site, on a freshly painted stack. */
static long high_water(entry_fn fn, int32_t *status, int64_t *result) {
  const size_t size = STACK_BYTES;
  char *stack = (char *)mmap(NULL, size, PROT_READ | PROT_WRITE,
                             MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (stack == MAP_FAILED) {
    perror("highwater: mmap");
    return -1;
  }
  memset(stack, PATTERN, size);

  pthread_attr_t attr;
  if (pthread_attr_init(&attr) != 0) return -1;
  if (pthread_attr_setstack(&attr, stack, size) != 0) {
    fprintf(stderr, "highwater: pthread_attr_setstack refused the region\n");
    return -1;
  }
  struct run r;
  r.fn = fn;
  r.base = stack;
  r.size = size;
  r.cnt = NULL;
  r.used = -1;
  r.status = -1;
  r.result = 0;
  pthread_t t;
  if (pthread_create(&t, &attr, body, &r) != 0) {
    fprintf(stderr, "highwater: pthread_create failed\n");
    return -1;
  }
  pthread_join(t, NULL);
  pthread_attr_destroy(&attr);

  if (r.used < 0) {
    fprintf(stderr, "highwater: the pattern is untouched; nothing ran here\n");
    return -1;
  }
  *status = r.status;
  *result = r.result;
  munmap(stack, size);
  return r.used;
}

int main(int argc, char **argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: %s <static kernel_stack bytes>\n", argv[0]);
    return 2;
  }
  char *end = NULL;
  const long stat_bytes = strtol(argv[1], &end, 10);
  if (end == argv[1] || *end != '\0' || stat_bytes < 0) {
    fprintf(stderr, "highwater: '%s' is not a byte count\n", argv[1]);
    return 2;
  }

  int32_t status = -1;
  int64_t result = 0;
  const long base_mark = high_water(noop_entry, &status, &result);
  const long ctrl_mark = high_water(control_entry, &status, &result);
  if (base_mark < 0 || ctrl_mark < 0) return 3;

  /* THE CONTROL FIRST, and it does two jobs.
   *
   * It proves the harness can see a frame at all: a run that cannot find a
   * known CONTROL_BYTES buffer is not evidence about a smaller one.
   *
   * And it CALIBRATES. A mark is measured from the call site, so it counts a
   * fixed overhead that is not the callee's -- the part of measure_call's own
   * frame below the mark, and the return address the call pushes. The control
   * has a known size, so that overhead is what its mark exceeds it by, and the
   * same constant is then taken off the entry's mark.
   *
   * The control's own frame may itself be a little larger than its buffer, so
   * the overhead derived here is an upper bound on the true one, and the
   * corrected figure is correspondingly an under-estimate. That is the right
   * direction: 0010 asks for a lower bound.
   *
   * The no-op's mark is not that constant. It is GAP -- the repaint boundary
   * -- because nothing the no-op wrote reached below it. It is checked, not
   * subtracted. */
  const long overhead = ctrl_mark - CONTROL_BYTES;
  printf("harness_gap %ld\n", base_mark);
  printf("control_frame %d\n", CONTROL_BYTES);
  printf("control_mark %ld\n", ctrl_mark);
  printf("call_site_overhead %ld\n", overhead);
  /* AT OR BELOW, NOT EQUAL. A no-op above the boundary means something wrote
   * below the repaint and the floor is not where this program thinks it is;
   * at or below it, the floor is merely cleaner than the worst case and the
   * subtraction is unaffected. A CLEAN FLOOR IS ACCEPTABLE ONLY BECAUSE THE
   * CONTROL IS CHECKED IMMEDIATELY BELOW, IN THE SAME RUN: without that, a
   * no-op of 0 and a scan that sees nothing at all are the same reading. The
   * control is what distinguishes them, so it is refused, not relaxed. */
  if (base_mark > GAP) {
    fprintf(stderr,
            "highwater: the no-op measured %ld, above the repaint boundary %d; "
            "something wrote below the repaint, so the harness floor is not "
            "where this program thinks it is\n",
            base_mark, GAP);
    return 1;
  }
  if (ctrl_mark < CONTROL_BYTES || overhead > 512) {
    fprintf(stderr,
            "highwater: the control has a %d-byte buffer and its mark is %ld; "
            "this harness is not seeing what it claims to measure\n",
            CONTROL_BYTES, ctrl_mark);
    return 1;
  }

  status = -1;
  result = 0;
  const long entry_mark = high_water(spinel_core_st_deep, &status, &result);
  if (entry_mark < 0) return 3;
  if (status != SPINEL_CORE_OK) {
    fprintf(stderr, "highwater: the entry returned status %d\n", (int)status);
    return 3;
  }
  const long used = entry_mark - overhead;
  printf("entry_mark %ld\n", entry_mark);
  printf("runtime_high_water %ld\n", used);
  printf("static_kernel_stack %ld\n", stat_bytes);
  if (entry_mark <= GAP) {
    fprintf(stderr,
            "highwater: the entry's mark is %ld and the repaint boundary is "
            "%d, so nothing it wrote was visible to this harness\n",
            entry_mark, (int)GAP);
    return 1;
  }
  if (used <= 0) {
    fprintf(stderr, "highwater: the entry measured %ld once the call site's "
                    "own overhead was taken off; nothing is attributed to it\n",
            used);
    return 1;
  }
  if (used > stat_bytes) {
    fprintf(stderr,
            "highwater: the run wrote %ld bytes below the call site, more than "
            "the static kernel_stack of %ld; the static method missed "
            "something\n",
            used, stat_bytes);
    return 1;
  }
  printf("verdict within\n");
  return 0;
}
