/* gcmon_probe.c — the section probe.
 *
 * It removes a contradiction: a tool that watches for zero allocation must not
 * allocate. GC.stat allocates a Hash and walks the string heap under the heap
 * lock, so it cannot measure an allocation-free section. This probe reads the
 * extern counters directly and writes into fixed static storage: observing
 * allocates NOTHING.
 *
 * Ruby calls it through vendor Patch 1 (SPINEL_EXTERN_METHODS):
 *
 *   SPINEL_EXTERN_METHODS=gcmon_begin,gcmon_end \
 *     vendor/spinel/bin/spinel app.rb --link gcmon_probe.o -o app
 *
 * app.rb carries stubs whose bodies are never compiled. They must return an
 * int: the canonical value ABI returns sp_int only for a concrete int result.
 *
 *   def gcmon_begin(id) = id
 *   def gcmon_end(id) = id
 *
 * At exit it writes TSV to GCMON_OUT (stderr when unset):
 *   gcmon_section  <id>  <metric>  <delta>
 *
 * Build:  $CC -c -O2 -o gcmon_probe.o gcmon_probe.c
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include "gcmon_contract.h"

#ifndef GCMON_MAX_SECTIONS
#define GCMON_MAX_SECTIONS 64
#endif

/* One section's counters. Quantities that rise and fall (the bytes) and
   monotonic ones (the cycles) share one shape. */
typedef struct {
  long long bytes, old_bytes, threshold, cycle, full_runs, remembered, rem_peak;
} gcmon_snap;

typedef struct {
  int      used;        /* this id was used at least once */
  int      depth;       /* begin/end pairing (nesting is not allowed) */
  long long entries;    /* number of begins */
  long long unmatched;  /* a begin never ended, or an end never begun */
  gcmon_snap at_begin;
  gcmon_snap accum;     /* sum of the section deltas */
} gcmon_sect;

static gcmon_sect g_sect[GCMON_MAX_SECTIONS];
static int g_installed = 0;
static long long g_out_of_range = 0;   /* an out-of-range id is counted, not dropped */

static void gcmon_take(gcmon_snap *s) {
  /* Plain reads (single-threaded; see gcmon_contract.h). No call and no
     allocation happen here: that is this probe's requirement. */
  s->bytes      = (long long)sp_gc_bytes;
  s->old_bytes  = (long long)sp_gc_old_bytes;
  s->threshold  = (long long)sp_gc_threshold;
  s->cycle      = (long long)sp_gc_cycle;
  s->full_runs  = (long long)sp_gc_full_runs;
  s->remembered = (long long)sp_gc_nremembered;
  s->rem_peak   = (long long)sp_gc_rem_peak;
}

static void gcmon_dump(void);

static void gcmon_install(void) {
  if (g_installed) return;
  g_installed = 1;
  atexit(gcmon_dump);
}

gcmon_int sp_gcmon_begin(gcmon_int id) {
  if (id < 0 || id >= GCMON_MAX_SECTIONS) { g_out_of_range++; return id; }
  gcmon_install();
  {
    gcmon_sect *t = &g_sect[id];
    t->used = 1;
    if (t->depth != 0) { t->unmatched++; return id; }  /* nested begin */
    t->depth = 1;
    t->entries++;
    gcmon_take(&t->at_begin);
  }
  return id;
}

gcmon_int sp_gcmon_end(gcmon_int id) {
  if (id < 0 || id >= GCMON_MAX_SECTIONS) { g_out_of_range++; return id; }
  {
    gcmon_sect *t = &g_sect[id];
    gcmon_snap now;
    if (t->depth != 1) { t->used = 1; t->unmatched++; return id; }  /* end without begin */
    t->depth = 0;
    gcmon_take(&now);
    t->accum.bytes      += now.bytes      - t->at_begin.bytes;
    t->accum.old_bytes  += now.old_bytes  - t->at_begin.old_bytes;
    t->accum.threshold  += now.threshold  - t->at_begin.threshold;
    t->accum.cycle      += now.cycle      - t->at_begin.cycle;
    t->accum.full_runs  += now.full_runs  - t->at_begin.full_runs;
    t->accum.remembered += now.remembered - t->at_begin.remembered;
    /* rem_peak is a monotonic high-water mark: keep the last value, not a delta */
    t->accum.rem_peak    = now.rem_peak;
  }
  return id;
}

/* The dump allocates nothing either.
 *
 * It was first written with fopen + fprintf, and THAT broke the non-invasive
 * check: with the probe on and off, the GC counters agreed exactly, but the
 * malloc counter moved by +1 malloc, +1 free and +4064 bytes. The atexit fopen
 * allocated FILE's buffer. The contradiction lives at the exit as well as on
 * the hot path, so the dump uses open(2)/write(2) and snprintf into a stack
 * buffer. */
static void gcmon_puts(int fd, const char *s) {
  size_t n = strlen(s), off = 0;
  while (off < n) {
    ssize_t w = write(fd, s + off, n - off);
    if (w <= 0) return;
    off += (size_t)w;
  }
}

static void gcmon_row(int fd, const char *inst, int id, const char *metric, long long v) {
  char line[128];
  int n = snprintf(line, sizeof line, "%s\t%d\t%s\t%lld\n", inst, id, metric, v);
  if (n > 0) gcmon_puts(fd, line);
}

static void gcmon_dump(void) {
  const char *path = getenv("GCMON_OUT");
  int fd = 2, opened = 0;
  int i;
  if (path && *path) {
    int g = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (g >= 0) { fd = g; opened = 1; }
  }

  gcmon_puts(fd, "# gcmon_probe. instrument\tid\tmetric\tvalue\n");
  for (i = 0; i < GCMON_MAX_SECTIONS; i++) {
    gcmon_sect *t = &g_sect[i];
    if (!t->used) continue;
    gcmon_row(fd, "gcmon_section", i, "entries",    t->entries);
    gcmon_row(fd, "gcmon_section", i, "cycle",      t->accum.cycle);
    gcmon_row(fd, "gcmon_section", i, "full_runs",  t->accum.full_runs);
    gcmon_row(fd, "gcmon_section", i, "bytes",      t->accum.bytes);
    gcmon_row(fd, "gcmon_section", i, "old_bytes",  t->accum.old_bytes);
    gcmon_row(fd, "gcmon_section", i, "threshold",  t->accum.threshold);
    gcmon_row(fd, "gcmon_section", i, "remembered", t->accum.remembered);
    gcmon_row(fd, "gcmon_section", i, "rem_peak",   t->accum.rem_peak);
    /* Say it loudly: any begin/end that did not pair is always reported. */
    if (t->depth != 0 || t->unmatched)
      gcmon_row(fd, "gcmon_section", i, "unmatched",
                t->unmatched + (t->depth != 0 ? 1 : 0));
  }
  if (g_out_of_range)
    gcmon_row(fd, "gcmon_section", -1, "out_of_range", g_out_of_range);
  if (opened) close(fd);
}
