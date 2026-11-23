/* The C driver for decision 0007 task 5, bullet 3.
 *
 * It MODELS NOTHING. Every cell it compares against was produced by the
 * original Full slot and link state under CRuby, which trace.rb ran beside an
 * independent reference model and the extracted Ruby, all three agreeing on
 * every cell before this file sees anything. Here the CORE kernels run the
 * same trace and are compared the same way.
 *
 *   usage: harness <trace-file> <mode>
 *
 *     run       run the trace in order. After EVERY operation the status, the
 *               result and every cell of every array must match.
 *     refuse    run the trace's ABI checks, each against a world of its own,
 *               with the cells it names preloaded and, where the check says
 *               so, one array's declared count one element short. Each must
 *               return the status the trace says AND change the number of
 *               cells it says. An index outside an array, an index below it,
 *               a value an i32 cell cannot hold, an exhausted capacity and a
 *               chain that closes on itself are where CRuby cannot answer for
 *               the ABI -- and in the second of those the original is not
 *               merely different but wrong.
 *     exhaust   allocate until the kernels refuse, at the ORIGINAL's own
 *               capacity, and the refusal must come at the step the trace says
 *               and be SPINEL_CORE_CAPACITY.
 *     shuffle   run the trace with the two collect-bearing halves swapped;
 *               the state must DIFFER. Reuse order is the answer here, so a
 *               trace whose order did not matter would make `run` a check of
 *               very little.
 *
 * Exit 0 when the mode's expectation held, 1 otherwise.
 *
 * TWO BACK ENDS, ONE COMPARISON. Built plainly it calls the CORE entries
 * directly. Built with -DSPINEL_VIA_ADAPTER the arrays become registry
 * storage, an operation is an `invoke` over their ids, and every cell is read
 * back through `load` before the comparison. Decision 0007 task 5 asks for
 * both, and they are one file so that the comparison is the same source either
 * way -- a difference is then a difference in the BOUNDARY and not in two
 * harnesses that drifted.
 *
 * The two paths part company in one place, by design: a refused `invoke`
 * POISONS the mutable participants, so through the adapter a caller cannot
 * read a half-written array at all, where the direct caller's own arrays keep
 * whatever the kernel wrote before the access that failed. `refuse` checks
 * that rather than working around it.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef SPINEL_VIA_ADAPTER
#include "spinel_adapter_mobj_alloc.h"
#include "spinel_adapter_mobj_free.h"
#include "spinel_adapter_thinker_add.h"
#include "spinel_adapter_thinker_collect.h"
#include "spinel_adapter_thinker_remove.h"
#include "spinel_adapter_registry.h"
#else
#include "spinel_core_mobj_alloc.h"
#include "spinel_core_mobj_free.h"
#include "spinel_core_thinker_add.h"
#include "spinel_core_thinker_collect.h"
#include "spinel_core_thinker_remove.h"
#endif

#define MAX_OPS 256
#define MAX_CHECKS 64
#define TH_NULL 10

enum { OP_TADD, OP_TREMOVE, OP_TCOLLECT, OP_MALLOC, OP_MFREE };

struct op {
  int kind;
  int64_t a, b;
  int32_t status;
  int64_t result;
  int thinker;            /* which world the `after` state describes */
  int32_t *after;         /* state[2] then the arrays, in world order */
};

struct check {
  char id[32];
  int thinker;
  int kind;               /* which kernel */
  int64_t args[2];
  int shorten;            /* an array whose COUNT is one less than cap, or -1 */
  int32_t want;
  long moved;             /* cells the call is declared to change, refusal included */
  /* preloaded cells: which array, which index, what value */
  int n_pre;
  struct { int which; long idx; long val; } pre[8];
};

/* A world: the four thinker arrays, or the one mobj array, plus its state. */
struct world {
  int32_t *func, *data, *next, *prev, *thing_next, state[2];
#ifdef SPINEL_VIA_ADAPTER
  int32_t id_func, id_data, id_next, id_prev, id_thing, id_state;
  int thinker;
#endif
  /* Each buffer is declared with ITS OWN count, and the kernels compare
   * against the one they were given. Holding them separately is what lets a
   * check shorten one and leave the others alone; passing `cap` five times
   * would make the five declarations indistinguishable. */
  size_t n_func, n_data, n_next, n_prev, n_thing, n_state;
};

static size_t cap, exhaust_cap;
static long exhaust_t, exhaust_m;
static struct op ops[MAX_OPS];
static size_t n_ops;
static struct check checks[MAX_CHECKS];
static size_t n_checks;

static void fail(const char *what) {
  fprintf(stderr, "harness: %s\n", what);
  exit(1);
}

static int32_t *alloc_cells(size_t n, int32_t fill) {
  int32_t *p = malloc(n * sizeof(int32_t));
  if (!p) fail("out of memory");
  for (size_t i = 0; i < n; i++) p[i] = fill;
  return p;
}

/* init_thinkers / init_mobjs, as the original writes them. */
static void world_init(struct world *w, size_t n, int thinker) {
  memset(w, 0, sizeof(*w));
  w->n_func = w->n_data = w->n_next = w->n_prev = w->n_thing = n;
  w->n_state = 2;
  if (thinker) {
    w->func = alloc_cells(n, TH_NULL);
    w->data = alloc_cells(n, -1);
    w->next = alloc_cells(n, 0);
    w->prev = alloc_cells(n, 0);
    w->state[0] = -1;                 /* the free list is empty */
    w->state[1] = 1;                  /* slot 0 is the sentinel */
  } else {
    w->thing_next = alloc_cells(n, -1);
    w->state[0] = -1;
    w->state[1] = 0;
  }
}

static int op_kind(const char *s) {
  if (strcmp(s, "tadd") == 0) return OP_TADD;
  if (strcmp(s, "tremove") == 0) return OP_TREMOVE;
  if (strcmp(s, "tcollect") == 0) return OP_TCOLLECT;
  if (strcmp(s, "malloc") == 0) return OP_MALLOC;
  if (strcmp(s, "mfree") == 0) return OP_MFREE;
  return -1;
}

static int kernel_kind(const char *s) {
  if (strcmp(s, "thinker_add") == 0) return OP_TADD;
  if (strcmp(s, "thinker_remove") == 0) return OP_TREMOVE;
  if (strcmp(s, "thinker_collect") == 0) return OP_TCOLLECT;
  if (strcmp(s, "mobj_alloc") == 0) return OP_MALLOC;
  if (strcmp(s, "mobj_free") == 0) return OP_MFREE;
  return -1;
}

/* Which array a preload names. The spelling is the contract's parameter name
 * with the `th_` dropped, which is how trace.tsv writes it. */
enum { PRE_FUNC, PRE_DATA, PRE_NEXT, PRE_PREV, PRE_STATE, PRE_THING };
static int pre_which(const char *s) {
  if (strcmp(s, "func") == 0) return PRE_FUNC;
  if (strcmp(s, "data") == 0) return PRE_DATA;
  if (strcmp(s, "next") == 0) return PRE_NEXT;
  if (strcmp(s, "prev") == 0) return PRE_PREV;
  if (strcmp(s, "state") == 0) return PRE_STATE;
  if (strcmp(s, "thing_next") == 0) return PRE_THING;
  return -1;
}

#ifdef SPINEL_VIA_ADAPTER
enum { ELEM_I32 = 2, ELEM_U32 = 3, ELEM_I64 = 4 };
static int32_t id_result, id_words;

static int32_t put(const int32_t *cells, size_t n) {
  int32_t id = spinel_adapter_registry_allocate(ELEM_I32, (int64_t)n);
  if (id <= 0) fail("the adapter would not allocate storage");
  for (size_t i = 0; i < n; i++)
    if (spinel_adapter_registry_store(id, (int64_t)i, (int64_t)cells[i]) != 0)
      fail("the adapter would not store into storage it had just made");
  return id;
}

/* Hand the world's arrays to the registry, exactly as they stand -- after any
 * preloads a check applied, so what the adapter holds is what the direct build
 * would have been given. */
static void world_open(struct world *w, int thinker) {
  static int started;
  if (!started) {
    if (spinel_adapter_registry_startup() != 0) fail("the adapter would not start");
    id_result = spinel_adapter_registry_allocate(ELEM_I64, 1);
    id_words = spinel_adapter_registry_allocate(ELEM_U32, 2);
    if (id_result <= 0 || id_words <= 0) fail("the adapter would not allocate a result");
    started = 1;
  }
  w->thinker = thinker;
  if (thinker) {
    w->id_func = put(w->func, w->n_func);
    w->id_data = put(w->data, w->n_data);
    w->id_next = put(w->next, w->n_next);
    w->id_prev = put(w->prev, w->n_prev);
  } else {
    w->id_thing = put(w->thing_next, w->n_thing);
  }
  w->id_state = put(w->state, w->n_state);
}

static void world_close(struct world *w) {
  int32_t ids[5];
  int n = 0;
  if (w->thinker) {
    ids[n++] = w->id_func; ids[n++] = w->id_data;
    ids[n++] = w->id_next; ids[n++] = w->id_prev;
  } else {
    ids[n++] = w->id_thing;
  }
  ids[n++] = w->id_state;
  for (int i = 0; i < n; i++)
    if (spinel_adapter_registry_release(ids[i]) != 0) fail("the adapter would not release");
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

/* The entries answer i64, and the ordinary `load` refuses i64 storage on
 * purpose, so a result comes back as two unsigned words. */
static int64_t adapter_result(void) {
  if (spinel_adapter_registry_load_i64_words(id_result, 0, id_words, 0, 1) != 0)
    fail("the adapter would not read back a result it had just written");
  int64_t lo = spinel_adapter_registry_load(id_words, 0);
  int64_t hi = spinel_adapter_registry_load(id_words, 1);
  if (lo < 0 || hi < 0) fail("the adapter would not read back a result word");
  return (int64_t)(((uint64_t)hi << 32) | (uint64_t)lo);
}

static int32_t call_kernel(int kind, const int64_t *args, struct world *w,
                           int64_t *result) {
  int32_t st;
  adapter_poison_result();
  switch (kind) {
    case OP_TADD:
      st = spinel_adapter_thinker_add_invoke(args[0], args[1], w->id_func, w->id_data,
                                             w->id_next, w->id_prev, w->id_state, id_result);
      break;
    case OP_TREMOVE:
      st = spinel_adapter_thinker_remove_invoke(args[0], w->id_func, id_result);
      break;
    case OP_TCOLLECT:
      st = spinel_adapter_thinker_collect_invoke(w->id_func, w->id_data, w->id_next,
                                                 w->id_prev, w->id_state, id_result);
      break;
    case OP_MALLOC:
      st = spinel_adapter_mobj_alloc_invoke(w->id_thing, w->id_state, id_result);
      break;
    default:
      st = spinel_adapter_mobj_free_invoke(args[0], w->id_thing, w->id_state, id_result);
      break;
  }
  int64_t got = adapter_result();
  const int64_t poison = (int64_t)(((uint64_t)SPINEL_RESULT_POISON_HI << 32) |
                                   (uint64_t)SPINEL_RESULT_POISON_LO);
  if (st == SPINEL_CORE_OK) {
    if (got == poison) fail("an accepted invoke wrote no result");
    *result = got;
  } else if (got != poison) {
    fail("a refused invoke wrote a result");
  }
  return st;
}
#else
#define world_open(w, thinker) ((void)(w), (void)(thinker))
#define world_close(w) ((void)(w))
/* The direct build works on its own arrays; there is nothing to bring back. */
#define world_sync(w, thinker) ((void)(w), (void)(thinker))

static int32_t call_kernel(int kind, const int64_t *args, struct world *w,
                           int64_t *result) {
  switch (kind) {
    case OP_TADD:
      return spinel_core_thinker_add(args[0], args[1], w->func, w->n_func,
                                     w->data, w->n_data, w->next, w->n_next,
                                     w->prev, w->n_prev, w->state, w->n_state, result);
    case OP_TREMOVE:
      return spinel_core_thinker_remove(args[0], w->func, w->n_func, result);
    case OP_TCOLLECT:
      return spinel_core_thinker_collect(w->func, w->n_func, w->data, w->n_data,
                                         w->next, w->n_next, w->prev, w->n_prev,
                                         w->state, w->n_state, result);
    case OP_MALLOC:
      return spinel_core_mobj_alloc(w->thing_next, w->n_thing, w->state, w->n_state, result);
    default:
      return spinel_core_mobj_free(args[0], w->thing_next, w->n_thing, w->state,
                                   w->n_state, result);
  }
}
#endif

/* One `after` line: state[0], state[1], then the world's arrays end to end. */
static size_t after_len(int thinker) { return 2 + (thinker ? 4 : 1) * cap; }

static void parse(const char *path) {
  FILE *f = fopen(path, "rb");
  if (!f) fail("the trace file will not open");
  if (fseek(f, 0, SEEK_END) != 0) fail("the trace file will not seek");
  long len = ftell(f);
  if (len < 0) fail("the trace file has no length");
  rewind(f);
  char *text = malloc((size_t)len + 1);
  if (!text) fail("out of memory");
  if (fread(text, 1, (size_t)len, f) != (size_t)len) fail("the trace file will not read");
  text[len] = '\0';
  fclose(f);

  int have_cap = 0, have_exhaust = 0;
  for (char *line = strtok(text, "\n"); line; line = strtok(NULL, "\n")) {
    char w1[64], w2[64], w3[64], w4[64], w5[64], w6[64], cid[32];
    unsigned long u1;
    long long v[4], vres;
    int off = 0;

    if (line[0] == '#' || line[0] == '\0') continue;

    if (sscanf(line, "cap %lu %n", &u1, &off) == 1) {
      if (line[off] != '\0') fail("the cap line is longer than its fields");
      if (have_cap) fail("the trace declares the capacity twice");
      cap = u1; have_cap = 1;
      if (cap < 4) fail("the capacity leaves no room for a list");
    } else if (sscanf(line, "exhaust %lu %lld %lld %n", &u1, &v[0], &v[1], &off) == 3) {
      if (line[off] != '\0') fail("the exhaust line is longer than its fields");
      if (have_exhaust) fail("the trace declares exhaustion twice");
      exhaust_cap = u1; exhaust_t = (long)v[0]; exhaust_m = (long)v[1];
      have_exhaust = 1;
    } else if (sscanf(line, "op %lld %63s %lld %lld %lld %lld %n",
                      &v[0], w1, &v[1], &v[2], &v[3], &vres, &off) == 6) {
      if (line[off] != '\0') fail("an op line is longer than its fields");
      if (n_ops == MAX_OPS) fail("the trace holds more operations than this harness carries");
      if ((size_t)v[0] != n_ops) fail("the operations are not numbered in order");
      int k = op_kind(w1);
      if (k < 0) fail("the trace holds an operation this harness does not know");
      ops[n_ops].kind = k;
      ops[n_ops].a = (int64_t)v[1];
      ops[n_ops].b = (int64_t)v[2];
      ops[n_ops].status = (int32_t)v[3];
      ops[n_ops].result = (int64_t)vres;
      ops[n_ops].thinker = (k == OP_TADD || k == OP_TREMOVE || k == OP_TCOLLECT);
      ops[n_ops].after = NULL;
      n_ops++;
    } else if (sscanf(line, "after %lld %63s %n", &v[0], w1, &off) == 2) {
      if (!have_cap) fail("an after line arrived before the capacity");
      size_t i = (size_t)v[0];
      if (i >= n_ops) fail("an after line names an operation that is not there");
      int thinker = strcmp(w1, "T") == 0;
      if (!thinker && strcmp(w1, "M") != 0) fail("an after line names an unknown world");
      if (thinker != ops[i].thinker) fail("an after line describes the other world");
      if (ops[i].after) fail("an operation carries two after lines");
      size_t want = after_len(thinker);
      int32_t *cells = malloc(want * sizeof(int32_t));
      if (!cells) fail("out of memory");
      char *p = line + off;
      for (size_t j = 0; j < want; j++) {
        char *end;
        long x = strtol(p, &end, 10);
        if (end == p) fail("an after line is short");
        cells[j] = (int32_t)x;
        p = end;
      }
      while (*p == ' ') p++;
      if (*p != '\0') fail("an after line is longer than its world");
      ops[i].after = cells;
    } else if (sscanf(line, "check %31s %63s %63s %63s %63s %63s %lld %lld %n",
                      cid, w2, w3, w4, w5, w6, &v[0], &v[1], &off) == 8) {
      if (line[off] != '\0') fail("a check line is longer than its fields");
      if (n_checks == MAX_CHECKS) fail("the trace holds more checks than this harness carries");
      struct check *c = &checks[n_checks];
      snprintf(c->id, sizeof(c->id), "%s", cid);
      c->thinker = strcmp(w2, "T") == 0;
      if (!c->thinker && strcmp(w2, "M") != 0) fail("a check names an unknown world");
      c->kind = kernel_kind(w4);
      if (c->kind < 0) fail("a check names a kernel this harness does not know");
      /* The world, the kernel and every cell the check touches have to be the
       * same world's. A row that named the thinker world and a mobj kernel
       * would quietly check the other one, and a preload naming an array the
       * world never allocated would write through a pointer nothing set. */
      if (c->thinker != (c->kind == OP_TADD || c->kind == OP_TREMOVE || c->kind == OP_TCOLLECT))
        fail("a check names one world and the other world's kernel");
      c->want = (int32_t)v[0];
      c->moved = (long)v[1];
      if (c->moved < 0) fail("a check declares a negative number of changed cells");
      c->shorten = -1;
      if (strcmp(w6, "-") != 0) {
        c->shorten = pre_which(w6);
        if (c->shorten < 0) fail("a check shortens an array this harness does not know");
        if (c->shorten != PRE_STATE && (c->shorten == PRE_THING) == c->thinker)
          fail("a check shortens an array of the other world");
      }
      c->n_pre = 0;
      if (strcmp(w3, "-") != 0) {
        char *q = w3;
        while (*q) {
          char name[32];
          long idx, val;
          int n = 0;
          if (sscanf(q, "%31[^:]:%ld=%ld%n", name, &idx, &val, &n) != 3)
            fail("a check's preload is malformed");
          if (c->n_pre == 8) fail("a check preloads more cells than this harness carries");
          int which = pre_which(name);
          if (which < 0) fail("a check preloads an array this harness does not know");
          if (which != PRE_STATE && (which == PRE_THING) == c->thinker)
            fail("a check preloads an array of the other world");
          c->pre[c->n_pre].which = which;
          c->pre[c->n_pre].idx = idx;
          c->pre[c->n_pre].val = val;
          c->n_pre++;
          q += n;
          if (*q == ',') q++;
          else if (*q != '\0') fail("a check's preload is malformed");
        }
      }
      c->args[0] = c->args[1] = 0;
      if (strcmp(w5, "-") != 0) {
        char *end;
        c->args[0] = strtoll(w5, &end, 10);
        if (end == w5) fail("a check's arguments are malformed");
        if (*end == ',') {
          char *e2;
          c->args[1] = strtoll(end + 1, &e2, 10);
          if (e2 == end + 1) fail("a check's arguments are malformed");
          end = e2;
        }
        if (*end != '\0') fail("a check's arguments are malformed");
      }
      n_checks++;
    } else {
      fail("the trace holds a record this harness does not know");
    }
  }
  if (!have_cap) fail("the trace declares no capacity");
  if (!have_exhaust) fail("the trace declares no exhaustion");
  if (n_ops == 0) fail("the trace declares no operations");
  if (n_checks == 0) fail("the trace declares no ABI checks");
  for (size_t i = 0; i < n_ops; i++)
    if (!ops[i].after) fail("an operation has no state to be compared with");
}

/* Lay the world's cells out the way an `after` line does, so the comparison is
 * one loop over everything rather than four that could each be forgotten. */
#ifdef SPINEL_VIA_ADAPTER
/* Every cell, one `load` at a time -- there is no bulk read at this boundary
 * on purpose, because every access is validated. Answers 1 when the storage is
 * POISONED, which is what a refused invoke leaves behind. */
static int world_cells_or_poison(const struct world *w, int thinker, int32_t *out) {
  const int32_t ids[5] = {w->id_func, w->id_data, w->id_next, w->id_prev, w->id_thing};
  const size_t counts[5] = {w->n_func, w->n_data, w->n_next, w->n_prev, w->n_thing};
  const int32_t *mirror[5] = {w->func, w->data, w->next, w->prev, w->thing_next};
  size_t k = 2;
  int64_t s0 = spinel_adapter_registry_load(w->id_state, 0);
  if (s0 == -(int64_t)SPINEL_CORE_ARGUMENT) return 1;
  int64_t s1 = w->n_state > 1 ? spinel_adapter_registry_load(w->id_state, 1)
                              : (int64_t)w->state[1];
  if (s1 == -(int64_t)SPINEL_CORE_ARGUMENT) return 1;
  if (s0 < 0 || s1 < 0) fail("the adapter would not read the state back");
  out[0] = (int32_t)(s0 >= 2147483648LL ? s0 - 4294967296LL : s0);
  out[1] = (int32_t)(s1 >= 2147483648LL ? s1 - 4294967296LL : s1);
  for (int a = thinker ? 0 : 4; a < (thinker ? 4 : 5); a++) {
    for (size_t i = 0; i < cap; i++) {
      /* Past the DECLARED count there is no storage to read and no way the
       * kernel could have written one, so the comparison takes the cell the
       * direct build would have had. That is what makes a shortened array
       * comparable between the two paths rather than a different question. */
      if (i >= counts[a]) { out[k++] = mirror[a][i]; continue; }
      int64_t v = spinel_adapter_registry_load(ids[a], (int64_t)i);
      if (v == -(int64_t)SPINEL_CORE_ARGUMENT) return 1;
      if (v < 0) fail("the adapter would not read an array back");
      out[k++] = (int32_t)(v >= 2147483648LL ? v - 4294967296LL : v);
    }
  }
  return 0;
}

/* Put the registry's contents back into the world's own arrays, for the few
 * places that read them directly rather than through world_cells. */
static void world_sync(struct world *w, int thinker) {
  size_t len = after_len(thinker);
  int32_t *cells = malloc(len * sizeof(int32_t));
  if (!cells) fail("out of memory");
  if (world_cells_or_poison(w, thinker, cells)) fail("the storage is poisoned");
  w->state[0] = cells[0];
  w->state[1] = cells[1];
  if (thinker) {
    memcpy(w->func, cells + 2, cap * sizeof(int32_t));
    memcpy(w->data, cells + 2 + cap, cap * sizeof(int32_t));
    memcpy(w->next, cells + 2 + 2 * cap, cap * sizeof(int32_t));
    memcpy(w->prev, cells + 2 + 3 * cap, cap * sizeof(int32_t));
  } else {
    memcpy(w->thing_next, cells + 2, cap * sizeof(int32_t));
  }
  free(cells);
}
static int world_cells(const struct world *w, int thinker, int32_t *out) {
  return world_cells_or_poison(w, thinker, out);
}
#else
static int world_cells(const struct world *w, int thinker, int32_t *out) {
  out[0] = w->state[0];
  out[1] = w->state[1];
  if (thinker) {
    memcpy(out + 2, w->func, cap * sizeof(int32_t));
    memcpy(out + 2 + cap, w->data, cap * sizeof(int32_t));
    memcpy(out + 2 + 2 * cap, w->next, cap * sizeof(int32_t));
    memcpy(out + 2 + 3 * cap, w->prev, cap * sizeof(int32_t));
  } else {
    memcpy(out + 2, w->thing_next, cap * sizeof(int32_t));
  }
  return 0;
}
#endif

static const char *cell_name(int thinker, size_t j, size_t *idx) {
  if (j < 2) { *idx = j; return "state"; }
  size_t k = (j - 2) % cap;
  size_t which = (j - 2) / cap;
  *idx = k;
  if (!thinker) return "thing_next";
  static const char *names[4] = {"th_func", "th_data", "th_next", "th_prev"};
  return names[which];
}

/* `order` gives the operation indices, in the order this mode runs them. */
static int run_trace(const size_t *order, int compare, size_t *differ_at) {
  struct world t, m;
  world_init(&t, cap, 1);
  world_init(&m, cap, 0);
  world_open(&t, 1);
  world_open(&m, 0);
  size_t widest = after_len(1);
  int32_t *got = malloc(widest * sizeof(int32_t));
  if (!got) fail("out of memory");

  for (size_t k = 0; k < n_ops; k++) {
    const struct op *o = &ops[order[k]];
    struct world *w = o->thinker ? &t : &m;
    int64_t args[2] = {o->a, o->b};
    int64_t result = -1;
    int32_t st = call_kernel(o->kind, args, w, &result);
    if (!compare) continue;

    if (st != o->status) {
      fprintf(stderr, "harness: operation %zu wanted status %d, got %d\n",
              order[k], (int)o->status, (int)st);
      return 1;
    }
    if (st == SPINEL_CORE_OK && result != o->result) {
      fprintf(stderr, "harness: operation %zu wanted result %lld, got %lld\n",
              order[k], (long long)o->result, (long long)result);
      return 1;
    }
    size_t len = after_len(o->thinker);
    if (world_cells(w, o->thinker, got)) fail("an accepted operation poisoned its storage");
    for (size_t j = 0; j < len; j++) {
      if (got[j] == o->after[j]) continue;
      size_t idx;
      const char *name = cell_name(o->thinker, j, &idx);
      fprintf(stderr, "harness: after operation %zu, %s[%zu]: the original says %d, "
                      "the kernel says %d\n",
              order[k], name, idx, (int)o->after[j], (int)got[j]);
      return 1;
    }
  }

  if (!compare) {
    /* A control, and it has to look at BOTH worlds: the mobj side has a reuse
     * order of its own, and counting only the thinkers would leave that part
     * of the claim unmeasured. */
    size_t d = 0;
    for (int thinker = 0; thinker < 2; thinker++) {
      const struct op *last = NULL;
      for (size_t i = n_ops; i-- > 0;) if (ops[i].thinker == thinker) { last = &ops[i]; break; }
      if (!last) fail("the trace leaves one of the two worlds untouched");
      size_t len = after_len(thinker);
      if (world_cells(thinker ? &t : &m, thinker, got)) fail("the control poisoned its storage");
      for (size_t j = 0; j < len; j++) if (got[j] != last->after[j]) d++;
    }
    *differ_at = d;
  }
  world_close(&t);
  world_close(&m);
  return 0;
}

int main(int argc, char **argv) {
  if (argc != 3) { fprintf(stderr, "usage: %s <trace-file> <mode>\n", argv[0]); return 2; }
  parse(argv[1]);

  /* Guards against a trace that would make the comparisons true for nothing. */
  {
    int seen[5] = {0, 0, 0, 0, 0};
    for (size_t i = 0; i < n_ops; i++) seen[ops[i].kind] = 1;
    for (int i = 0; i < 5; i++)
      if (!seen[i]) fail("the trace does not exercise all five kernels");
    /* Per KERNEL, not just overall. Five kernels sharing one accepted and one
     * refused case between them would leave four of them saying nothing. */
    for (int k = 0; k < 5; k++) {
      int any_ok = 0, any_refused = 0;
      for (size_t i = 0; i < n_checks; i++) {
        if (checks[i].kind != k) continue;
        if (checks[i].want == SPINEL_CORE_OK) any_ok = 1; else any_refused = 1;
      }
      if (!any_ok || !any_refused)
        fail("some kernel has no ABI check, or only checks of one kind; one "
             "that answered the same to everything would pass them");
    }
    int reused = 0;
    for (size_t i = 0; i < n_ops; i++)
      for (size_t j = 0; j < i; j++)
        if (ops[i].status == SPINEL_CORE_OK && ops[j].status == SPINEL_CORE_OK &&
            (ops[i].kind == OP_TADD || ops[i].kind == OP_MALLOC) &&
            ops[i].kind == ops[j].kind && ops[i].result == ops[j].result)
          reused = 1;
    if (!reused) fail("no slot is ever handed out twice, so the trace never reuses one");
  }

  size_t *order = malloc(n_ops * sizeof(size_t));
  if (!order) fail("out of memory");
  for (size_t i = 0; i < n_ops; i++) order[i] = i;

  if (strcmp(argv[2], "run") == 0) {
    if (run_trace(order, 1, NULL)) return 1;
    size_t nt = 0;
    for (size_t i = 0; i < n_ops; i++) if (ops[i].thinker) nt++;
    printf("run %zu operations: %zu over %zu thinker cells, %zu over %zu mobj cells\n",
           n_ops, nt, after_len(1), n_ops - nt, after_len(0));
    return 0;
  }

  if (strcmp(argv[2], "shuffle") == 0) {
    /* Swap the trace's two halves. Every operation still runs exactly once;
     * only when each runs changes, and reuse order is the answer here. */
    size_t half = n_ops / 2, k = 0;
    for (size_t i = half; i < n_ops; i++) order[k++] = i;
    for (size_t i = 0; i < half; i++) order[k++] = i;
    if (k != n_ops) fail("the control did not schedule every operation");
    size_t d = 0;
    run_trace(order, 0, &d);
    if (d == 0) {
      fprintf(stderr, "harness: the trace ends in the same state whichever order "
                      "it runs in; it does not depend on the order it claims to\n");
      return 1;
    }
    printf("shuffle %zu of %zu cells differ, as they must\n",
           d, after_len(1) + after_len(0));
    return 0;
  }

  if (strcmp(argv[2], "refuse") == 0) {
    size_t bad = 0;
    long poisoned = 0, refusals = 0;
    (void)poisoned; (void)refusals;
    for (size_t i = 0; i < n_checks; i++) {
      const struct check *c = &checks[i];
      struct world w;
      world_init(&w, cap, c->thinker);
      switch (c->shorten) {
        case PRE_FUNC:  w.n_func = cap - 1; break;
        case PRE_DATA:  w.n_data = cap - 1; break;
        case PRE_NEXT:  w.n_next = cap - 1; break;
        case PRE_PREV:  w.n_prev = cap - 1; break;
        case PRE_THING: w.n_thing = cap - 1; break;
        /* The state has two elements and no spare one, so shortening it means
         * a count of one: the bump is then outside its own buffer. */
        case PRE_STATE: w.n_state = 1; break;
        default: break;
      }
      for (int j = 0; j < c->n_pre; j++) {
        int32_t *a = NULL;
        switch (c->pre[j].which) {
          case PRE_FUNC:  a = w.func; break;
          case PRE_DATA:  a = w.data; break;
          case PRE_NEXT:  a = w.next; break;
          case PRE_PREV:  a = w.prev; break;
          case PRE_THING: a = w.thing_next; break;
          default:        a = w.state; break;
        }
        size_t room = c->pre[j].which == PRE_STATE ? 2 : cap;
        if (c->pre[j].idx < 0 || (size_t)c->pre[j].idx >= room)
          fail("a check preloads a cell outside its own array");
        a[c->pre[j].idx] = (int32_t)c->pre[j].val;
      }
      /* What the world held once the preloads were in, so what the CALL
       * changed can be told from what the check set up. */
      size_t len = after_len(c->thinker);
      int32_t *before = malloc(len * sizeof(int32_t));
      int32_t *after = malloc(len * sizeof(int32_t));
      if (!before || !after) fail("out of memory");
      world_open(&w, c->thinker);
      if (world_cells(&w, c->thinker, before)) fail("fresh storage was already poisoned");

      int64_t result = -1;
      int32_t st = call_kernel(c->kind, c->args, &w, &result);
      long moved = 0;
      int poison = world_cells(&w, c->thinker, after);
      if (poison) {
        /* THE TWO PATHS PART COMPANY HERE, by design. A refused invoke
         * poisons the mutable participants, so through the adapter a caller
         * cannot read a half-written array at all, where the direct caller's
         * own arrays keep whatever the kernel wrote before the access that
         * failed. The declared count is the direct path's; here what is
         * checked is that the refusal poisoned, and that only a refusal did. */
        if (st == SPINEL_CORE_OK) fail("an accepted invoke poisoned its storage");
        poisoned++;
        moved = c->moved;
      } else {
        for (size_t j = 0; j < len; j++) if (before[j] != after[j]) moved++;
      }
      world_close(&w);

      if (st != SPINEL_CORE_OK) refusals++;
      if (st != c->want) {
        fprintf(stderr, "harness: check %s wanted status %d, got %d\n",
                c->id, (int)c->want, (int)st);
        bad++;
      } else if (st == SPINEL_CORE_OK && result == -1) {
        fprintf(stderr, "harness: check %s returned OK without writing a result\n", c->id);
        bad++;
      } else if (st != SPINEL_CORE_OK && result != -1) {
        fprintf(stderr, "harness: check %s wrote a result while refusing\n", c->id);
        bad++;
      } else if (moved != c->moved) {
        /* The ABI does not promise that a refusal leaves the buffers alone;
         * a kernel may have written some of them before the access that
         * failed. So what each check moves is DECLARED, and a change to it is
         * a change to be noticed rather than a detail nobody looks at. */
        fprintf(stderr, "harness: check %s changed %ld cell(s), and declares %ld\n",
                c->id, moved, c->moved);
        bad++;
      }
      free(before); free(after);
    }
    if (bad) return 1;
#ifdef SPINEL_VIA_ADAPTER
    /* EVERY refusal, not merely one of them. A rule that held for all but one
     * case would read exactly the same from a count that only asked whether it
     * ever happened. */
    if (refusals == 0) fail("no check refused, so the poison rule was never asked");
    if (poisoned != refusals) {
      fprintf(stderr, "harness: %ld of %ld refusals poisoned their storage\n",
              poisoned, refusals);
      return 1;
    }
#endif
    printf("refuse %zu ABI check(s) answered as declared\n", n_checks);
    return 0;
  }

  if (strcmp(argv[2], "exhaust") == 0) {
    /* At the ORIGINAL's own capacity, which is the one place the two
     * capacities have to be the same number. */
    size_t keep = cap;
    cap = exhaust_cap;
    struct world t, m;
    world_init(&t, cap, 1);
    world_init(&m, cap, 0);
    world_open(&t, 1);
    world_open(&m, 0);
    /* Allocate exactly as many as the ORIGINAL took, each of which must be
     * accepted; then sweep the full list; then check the cells; and only THEN
     * ask for one more, which must be refused. The refusal comes last because
     * through the adapter it poisons the mutable participants, and nothing
     * that can be checked on both paths should sit behind it. */
    long n = 0;
    for (; n < exhaust_t; n++) {
      int64_t args[2] = {TH_NULL + 1, n}, result = -1;
      int32_t st = call_kernel(OP_TADD, args, &t, &result);
      if (st != SPINEL_CORE_OK) {
        fprintf(stderr, "harness: thinker %ld of %ld was refused with %d\n",
                n, exhaust_t, (int)st);
        return 1;
      }
      if (result != n + 1) {
        fprintf(stderr, "harness: thinker %ld came back as slot %lld\n",
                n, (long long)result);
        return 1;
      }
    }
    long mn = 0;
    for (; mn < exhaust_m; mn++) {
      int64_t args[2] = {0, 0}, result = -1;
      int32_t st = call_kernel(OP_MALLOC, args, &m, &result);
      if (st != SPINEL_CORE_OK) {
        fprintf(stderr, "harness: mobj %ld of %ld was refused with %d\n",
                mn, exhaust_m, (int)st);
        return 1;
      }
      if (result != mn) {
        fprintf(stderr, "harness: mobj %ld came back as slot %lld\n",
                mn, (long long)result);
        return 1;
      }
    }

    /* The anti-runaway bound, from below and at the real scale. Sweeping a
     * FULL list is the longest well-formed walk there is -- every slot but the
     * sentinel, none of them marked -- and it must come back SPINEL_CORE_OK
     * having freed nothing. A bound tightened to anything under the capacity
     * fails here, which is what makes "it cannot end a good walk early" a
     * measurement rather than a remark. */
    {
      int64_t args[2] = {0, 0}, result = -1;
      int32_t st = call_kernel(OP_TCOLLECT, args, &t, &result);
      if (st != SPINEL_CORE_OK) {
        fprintf(stderr, "harness: sweeping a full list of %ld answered %d\n", n, (int)st);
        return 1;
      }
      if (result != 0) {
        fprintf(stderr, "harness: sweeping a full list freed %lld, and nothing was marked\n",
                (long long)result);
        return 1;
      }
    }

    world_sync(&t, 1);
    world_sync(&m, 0);
    if (t.state[1] != (int32_t)cap || m.state[1] != (int32_t)cap) {
      fprintf(stderr, "harness: the bumps ended at %d and %d, not %zu\n",
              (int)t.state[1], (int)m.state[1], cap);
      return 1;
    }
    if (t.state[0] != -1 || m.state[0] != -1) {
      fprintf(stderr, "harness: a free list is not empty after exhausting the bump\n");
      return 1;
    }
    /* Exhausted, the list is every slot but the sentinel, in order. That is
     * the whole of the state at this capacity and it is checked rather than
     * summarised. Ruby compared these cells across all three worlds already;
     * this is the kernels' turn. */
    for (size_t i = 1; i < cap; i++) {
      int32_t want_next = (i + 1 == cap) ? 0 : (int32_t)(i + 1);
      int32_t want_prev = (int32_t)(i - 1);
      if (t.next[i] != want_next || t.prev[i] != want_prev ||
          t.func[i] != TH_NULL + 1 || t.data[i] != (int32_t)(i - 1)) {
        fprintf(stderr, "harness: after exhaustion slot %zu holds "
                        "func %d data %d next %d prev %d\n",
                i, (int)t.func[i], (int)t.data[i], (int)t.next[i], (int)t.prev[i]);
        return 1;
      }
      if (m.thing_next[i] != -1) {
        fprintf(stderr, "harness: after exhaustion mobj %zu was linked\n", i);
        return 1;
      }
    }
    if (t.next[0] != 1 || t.prev[0] != (int32_t)(cap - 1)) {
      fprintf(stderr, "harness: the sentinel ends at next %d prev %d\n",
              (int)t.next[0], (int)t.prev[0]);
      return 1;
    }

    /* And now the refusal, which is the last thing either world is asked. */
    {
      int64_t args[2] = {TH_NULL + 1, 0}, result = -1;
      int32_t st = call_kernel(OP_TADD, args, &t, &result);
      if (st != SPINEL_CORE_CAPACITY) {
        fprintf(stderr, "harness: one thinker past the capacity answered %d\n", (int)st);
        return 1;
      }
      st = call_kernel(OP_MALLOC, args, &m, &result);
      if (st != SPINEL_CORE_CAPACITY) {
        fprintf(stderr, "harness: one mobj past the capacity answered %d\n", (int)st);
        return 1;
      }
    }
#ifdef SPINEL_VIA_ADAPTER
    /* THE TWO PATHS PART COMPANY HERE. The direct caller still owns its arrays
     * and can read them after a refusal; through the adapter that refusal
     * POISONED them, so a Full caller that exhausts a capacity cannot inspect
     * the state afterwards at all. The hosted game does not behave that way --
     * add_thinker raises and the list is still there -- so this is a real gap
     * between the two ways of using the boundary, and it is checked here
     * rather than left to be discovered. */
    {
      int32_t scratch[2];
      (void)scratch;
      if (spinel_adapter_registry_load(t.id_func, 0) != -(int64_t)SPINEL_CORE_ARGUMENT ||
          spinel_adapter_registry_load(m.id_thing, 0) != -(int64_t)SPINEL_CORE_ARGUMENT) {
        fprintf(stderr, "harness: exhausting a capacity did not poison its storage\n");
        return 1;
      }
    }
#endif
    world_close(&t);
    world_close(&m);
    cap = keep;
    printf("exhaust %ld thinkers and %ld mobjs, then SPINEL_CORE_CAPACITY, "
           "and a full list still sweeps\n", n, mn);
    return 0;
  }

  fail("unknown mode; expected run, refuse, exhaust or shuffle");
  return 2;
}
