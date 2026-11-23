/* The C driver for decision 0007 task 5, bullet 2.
 *
 * It DRAWS NOTHING. Every pixel it compares against was produced by the
 * original Full job executor under CRuby (see scene.rb); this file parses that
 * output, calls the CORE kernels over the schedule, and compares every byte of
 * the screen. There is no C reference implementation, so there is no C
 * allowance that could stand between Full and CORE and hide a discrepancy.
 *
 *   usage: harness <scene-file> <mode>
 *
 *     run        execute the schedule in order; every byte must match.
 *     refuse     run the scene's ABI checks, each against a fresh screen;
 *                each must return the status the scene says. Off the end of a
 *                buffer, and past what i64 arithmetic can hold, is where CRuby
 *                cannot answer for the ABI, so those are checked against the
 *                ABI's own numbers instead of against the original.
 *     reverse    execute it backwards; the screen must DIFFER. Without this,
 *                "the order is preserved" would be a claim about a schedule
 *                whose order might not matter.
 *     fuzzfirst  execute the fuzz jobs before the rest; the screen must
 *                DIFFER. Fuzz reads the pixels earlier jobs wrote, so moving
 *                it ahead of them has to change the answer -- that is the
 *                neighbouring access showing itself from the driver side.
 *
 * Exit 0 when the mode's expectation held, 1 otherwise.
 *
 * TWO BACK ENDS, ONE COMPARISON. Built plainly it calls the CORE entries
 * directly, which is how a C consumer uses them. Built with
 * -DSPINEL_VIA_ADAPTER the same modes run through the Full adapter instead:
 * the screen and the resources become registry storage, a job is an `invoke`
 * over their ids, and the screen is read back a cell at a time before the
 * comparison. Decision 0007 task 5 asks for both, and they are one file so
 * that the parsing and the byte comparison are the same source either way --
 * a difference in the answer is then a difference in the BOUNDARY rather than
 * in two harnesses that drifted apart.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef SPINEL_VIA_ADAPTER
#include "spinel_adapter_draw_fuzz.h"
#include "spinel_adapter_draw_span.h"
#include "spinel_adapter_draw_wall.h"
#include "spinel_adapter_registry.h"
#else
#include "spinel_core_draw_fuzz.h"
#include "spinel_core_draw_span.h"
#include "spinel_core_draw_wall.h"
#endif

#define MAX_JOBS 256

struct job {
  char kind;                  /* 'w', 's' or 'f' */
  int64_t f[7];
  int32_t want;               /* checks only: the status the ABI must return */
};

static uint8_t *screen0, *atlas, *flatbuf, *cmap, *expect;
static size_t n_screen, n_atlas, n_flat, n_cmap, n_expect;
static int32_t *fuzzoffset;
static size_t n_fuzz;
static struct job jobs[MAX_JOBS];
static size_t n_jobs;
static struct job checks[MAX_JOBS];
static size_t n_checks;
static int64_t width, height, viewwindowx, viewwindowy, centery;

static int32_t run_job_inner(const struct job *j, uint8_t *scr, int64_t *out);

#ifdef SPINEL_VIA_ADAPTER
#define SPINEL_OPEN(scr)  adapter_open(scr)
#define SPINEL_CLOSE(scr) adapter_close(scr)
#else
/* The direct build works on the caller's own array, so there is nothing to
 * hand over and nothing to read back. */
#define SPINEL_OPEN(scr)  ((void)(scr))
#define SPINEL_CLOSE(scr) ((void)(scr))
#endif

static void fail(const char *what) {
  fprintf(stderr, "harness: %s\n", what);
  exit(1);
}

#ifdef SPINEL_VIA_ADAPTER
enum { ELEM_U8 = 1, ELEM_I32 = 2, ELEM_U32 = 3 };
static int32_t id_scr, id_atlas, id_flat, id_cmap, id_fuzz, id_result, id_words;

/* Storage the caller owns, filled a cell at a time. The adapter has no bulk
 * copy on purpose: every store is validated, which is the whole point of the
 * boundary, so this is what a Full caller's cost looks like. */
static int32_t adapter_put(int32_t element, const void *cells, size_t n, int wide) {
  int32_t id = spinel_adapter_registry_allocate(element, (int64_t)n);
  if (id <= 0) fail("the adapter would not allocate storage");
  for (size_t i = 0; i < n; i++) {
    int64_t v = wide ? (int64_t)((const int32_t *)cells)[i]
                     : (int64_t)((const uint8_t *)cells)[i];
    if (spinel_adapter_registry_store(id, (int64_t)i, v) != 0)
      fail("the adapter would not store into storage it had just made");
  }
  return id;
}

/* The result cell is poisoned before every invoke, so "answered OK and wrote
 * nothing" and "refused and wrote anyway" are both visible here as they are on
 * the direct path. Without it the cell keeps the previous call's value and
 * either mistake reads as success. */
#define SPINEL_RESULT_POISON_LO 3735928559u   /* 0xdeadbeef */
#define SPINEL_RESULT_POISON_HI 3405691582u   /* 0xcafebabe */
static void adapter_poison_result(void) {
  if (spinel_adapter_registry_store_i64_words(id_result, 0, SPINEL_RESULT_POISON_LO,
                                              SPINEL_RESULT_POISON_HI) != 0)
    fail("the adapter would not poison the result cell");
}

/* The entries all answer i64, and the ordinary `load` refuses i64 storage on
 * purpose, so the result comes back as two unsigned words. */
static int64_t adapter_result(void) {
  if (spinel_adapter_registry_load_i64_words(id_result, 0, id_words, 0, 1) != 0)
    fail("the adapter would not read back a result it had just written");
  int64_t lo = spinel_adapter_registry_load(id_words, 0);
  int64_t hi = spinel_adapter_registry_load(id_words, 1);
  if (lo < 0 || hi < 0) fail("the adapter would not read back a result word");
  return (int64_t)(((uint64_t)hi << 32) | (uint64_t)lo);
}

static void adapter_open(const uint8_t *scr) {
  if (spinel_adapter_registry_startup() != 0) fail("the adapter would not start");
  id_scr = adapter_put(ELEM_U8, scr, n_screen, 0);
  id_atlas = adapter_put(ELEM_U8, atlas, n_atlas, 0);
  id_flat = adapter_put(ELEM_U8, flatbuf, n_flat, 0);
  id_cmap = adapter_put(ELEM_U8, cmap, n_cmap, 0);
  id_fuzz = adapter_put(ELEM_I32, fuzzoffset, n_fuzz, 1);
  id_result = spinel_adapter_registry_allocate(4 /* ELEM_I64 */, 1);
  id_words = spinel_adapter_registry_allocate(ELEM_U32, 2);
  if (id_result <= 0 || id_words <= 0) fail("the adapter would not allocate a result");
}

static void adapter_release(void) {
  int32_t ids[7] = {id_scr, id_atlas, id_flat, id_cmap, id_fuzz, id_result, id_words};
  for (int i = 0; i < 7; i++)
    if (spinel_adapter_registry_release(ids[i]) != 0) fail("the adapter would not release");
}

/* Read the screen back out of the registry, so everything below compares the
 * same bytes the direct build compares. */
static void adapter_close(uint8_t *scr) {
  for (size_t i = 0; i < n_screen; i++) {
    int64_t v = spinel_adapter_registry_load(id_scr, (int64_t)i);
    if (v < 0) fail("the adapter would not read the screen back");
    scr[i] = (uint8_t)v;
  }
  adapter_release();
}

/* THE TWO PATHS PART COMPANY HERE, and by design rather than by accident. A
 * refused call leaves the direct caller's own array as the kernel left it --
 * partly written, because the ABI promises no atomicity. Through the adapter
 * the same refusal POISONS the mutable participants: every operation on them
 * but `release` is ARGUMENT afterwards, so a Full caller cannot read a
 * half-written buffer at all. That is decision 0007's rule for the adapter and
 * it is checked here rather than worked around. */
static long adapter_close_refused(void) {
  long poisoned = 0;
  for (size_t i = 0; i < n_screen; i++) {
    int64_t v = spinel_adapter_registry_load(id_scr, (int64_t)i);
    if (v != -(int64_t)SPINEL_CORE_ARGUMENT)
      fail("a refused invoke did not poison its mutable buffer with ARGUMENT");
    poisoned++;
  }
  /* The read-only participants are not poisoned: nothing wrote them. */
  if (spinel_adapter_registry_load(id_cmap, 0) < 0)
    fail("a refused invoke poisoned a buffer it only read");
  adapter_release();
  return poisoned;
}
#endif

static int hexval(int c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

/* "buf <name> <count> <2*count hex digits>" -- the count and the digits must
 * agree, so a truncated line is a parse failure and not a short buffer. */
static uint8_t *parse_bytes(char *digits, size_t count) {
  uint8_t *out = malloc(count ? count : 1);
  if (!out) fail("out of memory");
  if (strlen(digits) != count * 2) fail("a byte run does not match its count");
  for (size_t i = 0; i < count; i++) {
    int hi = hexval((unsigned char)digits[2 * i]);
    int lo = hexval((unsigned char)digits[2 * i + 1]);
    if (hi < 0 || lo < 0) fail("a byte run holds a non-hex digit");
    out[i] = (uint8_t)(hi * 16 + lo);
  }
  return out;
}

static void parse(const char *path) {
  FILE *f = fopen(path, "rb");
  if (!f) fail("the scene file will not open");
  if (fseek(f, 0, SEEK_END) != 0) fail("the scene file will not seek");
  long len = ftell(f);
  if (len < 0) fail("the scene file has no length");
  rewind(f);
  char *text = malloc((size_t)len + 1);
  if (!text) fail("out of memory");
  if (fread(text, 1, (size_t)len, f) != (size_t)len) fail("the scene file will not read");
  text[len] = '\0';
  fclose(f);

  int have_frame = 0, have_expect = 0;
  for (char *line = strtok(text, "\n"); line; line = strtok(NULL, "\n")) {
    char name[32];
    unsigned long count;
    long long v[5];
    int off = 0, is_job = 0;

    if (line[0] == '#' || line[0] == '\0') continue;

    if (sscanf(line, "frame %lld %lld %lld %lld %lld %n",
               &v[0], &v[1], &v[2], &v[3], &v[4], &off) == 5) {
      if (line[off] != '\0') fail("the frame line is longer than its fields");
      if (have_frame) fail("the scene declares the frame twice");
      width = v[0]; height = v[1];
      viewwindowx = v[2]; viewwindowy = v[3]; centery = v[4];
      have_frame = 1;
    } else if (sscanf(line, "buf %31s %lu %n", name, &count, &off) == 2) {
      uint8_t *bytes = parse_bytes(line + off, count);
      /* A buffer named twice would leave the harness reading one of them and
       * the scene's author believing it read the other. */
      if (strcmp(name, "screen") == 0)     { if (screen0) fail("a buffer is declared twice"); screen0 = bytes; n_screen = count; }
      else if (strcmp(name, "atlas") == 0) { if (atlas) fail("a buffer is declared twice"); atlas = bytes; n_atlas = count; }
      else if (strcmp(name, "flat") == 0)  { if (flatbuf) fail("a buffer is declared twice"); flatbuf = bytes; n_flat = count; }
      else if (strcmp(name, "cmap") == 0)  { if (cmap) fail("a buffer is declared twice"); cmap = bytes; n_cmap = count; }
      else fail("the scene names a buffer this harness does not know");
    } else if (sscanf(line, "expect %lu %n", &count, &off) == 1) {
      if (have_expect) fail("the scene declares the expected screen twice");
      expect = parse_bytes(line + off, count);
      n_expect = count;
      have_expect = 1;
    } else if (sscanf(line, "i32 %31s %lu %n", name, &count, &off) == 2) {
      if (strcmp(name, "fuzzoffset") != 0) fail("the scene names an i32 table this harness does not know");
      if (fuzzoffset) fail("an i32 table is declared twice");
      if (count == 0) fail("the fuzzoffset table is empty");
      fuzzoffset = malloc(count * sizeof(int32_t));
      if (!fuzzoffset) fail("out of memory");
      n_fuzz = count;
      char *p = line + off;
      for (size_t i = 0; i < count; i++) {
        char *end;
        long x = strtol(p, &end, 10);
        if (end == p) fail("the fuzzoffset table is short");
        fuzzoffset[i] = (int32_t)x;
        p = end;
      }
      while (*p == ' ') p++;
      if (*p != '\0') fail("the fuzzoffset table is longer than its count");
    } else if ((is_job = (sscanf(line, "job %31s %n", name, &off) == 1)) ||
               sscanf(line, "check %31s %n", name, &off) == 1) {
      int is_check = !is_job;
      struct job *slot;
      if (is_check) {
        if (n_checks == MAX_JOBS) fail("the scene holds more checks than this harness carries");
        slot = &checks[n_checks];
      } else {
        if (n_jobs == MAX_JOBS) fail("the scene holds more jobs than this harness carries");
        slot = &jobs[n_jobs];
      }
      if (strcmp(name, "wall") == 0) slot->kind = 'w';
      else if (strcmp(name, "span") == 0) slot->kind = 's';
      else if (strcmp(name, "fuzz") == 0) slot->kind = 'f';
      else fail("the scene holds a job kind this harness does not know");
      char *p = line + off;
      for (int i = 0; i < 7; i++) {
        char *end;
        long long x = strtoll(p, &end, 10);
        if (end == p) fail("a job line is short");
        slot->f[i] = (int64_t)x;
        p = end;
      }
      if (is_check) {
        char *end;
        long long x = strtoll(p, &end, 10);
        if (end == p) fail("a check line carries no expected status");
        slot->want = (int32_t)x;
        p = end;
      } else {
        slot->want = SPINEL_CORE_OK;
      }
      /* A fuzz job has four fields; the scene pads the rest with zeroes, and
       * the kernel is not given them. Anything else in those columns would be
       * a value the scene emits and nothing reads. */
      if (slot->kind == 'f' && (slot->f[4] || slot->f[5] || slot->f[6]))
        fail("a fuzz record carries fields the fuzz kernel does not take");
      while (*p == ' ') p++;
      if (*p != '\0') fail("a job or check line is longer than its fields");
      if (is_check) n_checks++; else n_jobs++;
    } else {
      fail("the scene holds a record this harness does not know");
    }
  }
  if (!have_frame) fail("the scene declares no frame");
  if (!have_expect) fail("the scene declares no expected screen");
  if (!screen0 || !atlas || !flatbuf || !cmap || !fuzzoffset) fail("the scene is missing a resource");
  if (n_jobs == 0) fail("the scene declares no jobs");
  if (n_checks == 0) fail("the scene declares no ABI checks");
  if (n_expect != n_screen) fail("the expected screen is not the size of the screen");
  if (width <= 0 || height <= 0) fail("the frame has no picture in it");
  if ((size_t)(width * height) != n_screen) fail("the frame geometry does not match the screen");

  /* Three guards against a scene that would make every comparison below
   * true for the wrong reason. */
  if (memcmp(screen0, expect, n_screen) == 0)
    fail("the schedule changes no byte of the screen");
  int seen_w = 0, seen_s = 0, seen_f = 0;
  for (size_t i = 0; i < n_jobs; i++) {
    if (jobs[i].kind == 'w') seen_w = 1;
    else if (jobs[i].kind == 's') seen_s = 1;
    else seen_f = 1;
  }
  if (!seen_w || !seen_s || !seen_f)
    fail("the schedule does not exercise all three kernels");
  /* Per KERNEL, not just overall: three kernels sharing one accepted and one
   * refused case between them would leave two of them answering nothing in
   * particular. */
  static const char kinds[3] = {'w', 's', 'f'};
  for (int k = 0; k < 3; k++) {
    int any_ok = 0, any_refused = 0;
    for (size_t i = 0; i < n_checks; i++) {
      if (checks[i].kind != kinds[k]) continue;
      if (checks[i].want == SPINEL_CORE_OK) any_ok = 1; else any_refused = 1;
    }
    if (!any_ok || !any_refused)
      fail("the ABI checks are all of one kind for some kernel; one that "
           "answered the same to everything would pass them");
  }
}

/* Run one job. Returns the kernel's status; the caller decides what to do.
 *
 * The result slot is poisoned first. The ABI says the result is written only
 * on SPINEL_CORE_OK, so a refusal that wrote one, or an acceptance that did
 * not, is a boundary defect even when every pixel is right. */
static int32_t run_job(const struct job *j, uint8_t *scr) {
  static const int64_t POISON = -1;
  int64_t result = POISON;
  int32_t st = run_job_inner(j, scr, &result);
  if (st == SPINEL_CORE_OK) {
    if (result != 0) fail("a kernel returned OK with a result it does not define");
  } else if (result != POISON) {
    fail("a kernel wrote its result while refusing");
  }
  return st;
}

#ifdef SPINEL_VIA_ADAPTER
static int32_t run_job_inner(const struct job *j, uint8_t *scr, int64_t *out) {
  (void)scr;
  int32_t st;
  adapter_poison_result();
  switch (j->kind) {
    case 'w':
      st = spinel_adapter_draw_wall_invoke(id_scr, id_atlas, id_cmap,
                                           j->f[1], j->f[2], j->f[5], j->f[6],
                                           j->f[3], j->f[4], j->f[0], width,
                                           viewwindowx, viewwindowy, centery,
                                           id_result);
      break;
    case 's':
      st = spinel_adapter_draw_span_invoke(id_scr, id_flat, id_cmap,
                                           j->f[1], j->f[2], j->f[0], j->f[5],
                                           j->f[6], j->f[3], j->f[4], width,
                                           viewwindowx, viewwindowy, id_result);
      break;
    default:
      st = spinel_adapter_draw_fuzz_invoke(id_scr, id_cmap, id_fuzz,
                                           j->f[1], j->f[2], j->f[0], j->f[3],
                                           width, viewwindowx, viewwindowy,
                                           id_result);
      break;
  }
  int64_t got = adapter_result();
  const int64_t poison = (int64_t)(((uint64_t)SPINEL_RESULT_POISON_HI << 32) |
                                   (uint64_t)SPINEL_RESULT_POISON_LO);
  if (st == SPINEL_CORE_OK) {
    if (got == poison) fail("an accepted invoke wrote no result");
    *out = got;
  } else if (got != poison) {
    fail("a refused invoke wrote a result");
  }
  return st;
}
#else
static int32_t run_job_inner(const struct job *j, uint8_t *scr, int64_t *out) {
  int64_t *presult = out;
  switch (j->kind) {
    case 'w':
      /* x yl yh iscale texmid srcofs cmap */
      return spinel_core_draw_wall(scr, n_screen, atlas, n_atlas, cmap, n_cmap,
                                   j->f[1], j->f[2], j->f[5], j->f[6], j->f[3],
                                   j->f[4], j->f[0], width, viewwindowx,
                                   viewwindowy, centery, presult);
    case 's':
      /* y x1 x2 position step srcofs cmap */
      return spinel_core_draw_span(scr, n_screen, flatbuf, n_flat, cmap, n_cmap,
                                   j->f[1], j->f[2], j->f[0], j->f[5], j->f[6],
                                   j->f[3], j->f[4], width, viewwindowx,
                                   viewwindowy, presult);
    default:
      /* x yl yh fz */
      return spinel_core_draw_fuzz(scr, n_screen, cmap, n_cmap, fuzzoffset,
                                   n_fuzz, j->f[1], j->f[2], j->f[0], j->f[3],
                                   width, viewwindowx, viewwindowy, presult);
  }
}
#endif

/* Fill `order` with the job indices this mode runs, in the order it runs
 * them. Every mode runs every job exactly once; the modes differ only in the
 * order, which is the whole point of the controls. */
static void schedule_for(const char *mode, size_t *order) {
  size_t k = 0;
  if (strcmp(mode, "run") == 0) {
    for (size_t i = 0; i < n_jobs; i++) order[k++] = i;
  } else if (strcmp(mode, "reverse") == 0) {
    for (size_t i = n_jobs; i-- > 0;) order[k++] = i;
  } else if (strcmp(mode, "fuzzfirst") == 0) {
    for (size_t i = 0; i < n_jobs; i++) if (jobs[i].kind == 'f') order[k++] = i;
    for (size_t i = 0; i < n_jobs; i++) if (jobs[i].kind != 'f') order[k++] = i;
  } else {
    fail("unknown mode; expected run, refuse, reverse or fuzzfirst");
  }
  if (k != n_jobs) fail("a mode did not schedule every job");
}

int main(int argc, char **argv) {
  if (argc != 3) { fprintf(stderr, "usage: %s <scene-file> <mode>\n", argv[0]); return 2; }
  parse(argv[1]);

  uint8_t *scr = malloc(n_screen);
  if (!scr) fail("out of memory");

  if (strcmp(argv[2], "refuse") == 0) {
    size_t bad = 0;
    long poisoned = 0;
    (void)poisoned;
    for (size_t i = 0; i < n_checks; i++) {
      memcpy(scr, screen0, n_screen);
      SPINEL_OPEN(scr);
      int32_t st = run_job(&checks[i], scr);
#ifdef SPINEL_VIA_ADAPTER
      if (st == SPINEL_CORE_OK) adapter_close(scr); else poisoned += adapter_close_refused();
#else
      SPINEL_CLOSE(scr);
#endif
      if (st != checks[i].want) {
        fprintf(stderr, "harness: check %zu wanted status %d, got %d\n",
                i, (int)checks[i].want, (int)st);
        bad++;
      }
    }
    if (bad) return 1;
#ifdef SPINEL_VIA_ADAPTER
    if (poisoned == 0) fail("no refusal poisoned its buffer, so nothing showed that it does");
#endif
    printf("refuse %zu ABI check(s) answered as declared\n", n_checks);
    return 0;
  }

  size_t *order = malloc(n_jobs * sizeof(size_t));
  if (!order) fail("out of memory");
  schedule_for(argv[2], order);
  memcpy(scr, screen0, n_screen);

  SPINEL_OPEN(scr);
  for (size_t k = 0; k < n_jobs; k++) {
    int32_t st = run_job(&jobs[order[k]], scr);
    if (st != SPINEL_CORE_OK) {
      fprintf(stderr, "harness: job %zu returned status %d\n", order[k], (int)st);
      return 1;
    }
  }
  SPINEL_CLOSE(scr);

  /* Every byte, including the ones no job should have touched. */
  size_t differ = 0, first = n_screen;
  for (size_t i = 0; i < n_screen; i++) {
    if (scr[i] != expect[i]) { if (differ == 0) first = i; differ++; }
  }

  if (strcmp(argv[2], "run") == 0) {
    if (differ != 0) {
      fprintf(stderr, "harness: %zu of %zu byte(s) differ; first at %zu "
                      "(x=%zu y=%zu) the original says %d, the kernel says %d\n",
              differ, n_screen, first, first % (size_t)width, first / (size_t)width,
              (int)expect[first], (int)scr[first]);
      return 1;
    }
    printf("run %zu jobs, %zu bytes identical\n", n_jobs, n_screen);
    return 0;
  }

  /* A control. Differing is the expected outcome, and NOT differing means the
   * scene cannot tell the orders apart -- which would make the `run` lane a
   * check of nothing in particular. */
  if (differ == 0) {
    fprintf(stderr, "harness: mode %s drew the same screen as the schedule order; "
                    "the scene does not depend on the order it claims to\n", argv[2]);
    return 1;
  }
  printf("%s %zu of %zu bytes differ, as it must\n", argv[2], differ, n_screen);
  return 0;
}
