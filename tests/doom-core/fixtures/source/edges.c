/* tests/doom-core/fixtures/source/edges.c — calls the compiled source entries on
 * the cases tests/doom-core/source-edges.rb writes, and prints what happened.
 *
 * IT COMPUTES NOTHING. It allocates each buffer at the size the case gives --
 * exactly, so under AddressSanitizer a read or write one element past lands in
 * a redzone -- fills it, calls the entry, and prints the status, the result
 * word (or `untouched`) and every cell of every buffer that changed. The
 * expected lines come from the generator, which derives every one but the
 * ARITHMETIC cases by running the Ruby port on the same case.
 *
 * Input, one case at a time:
 *   case NAME ENTRY
 *   buf NAME u8|i64 COUNT ALLOC seq|zero|val:V|list:V,V,...
 *   scalars V...
 *   end
 */
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "col.h"
#include "span.h"
#include "mjob.h"
#include "none.h"
#include "tex.h"
#include "mask.h"
#include "flat.h"
#include "zone.h"
#include "zalloc.h"
#include "jreset.h"
#include "exec.h"
#include "pwall.h"
#include "pspan.h"
#include "pmask.h"
#include "ph1.h"
#include "ph3.h"
#include "cdis.h"
#include "cspan.h"
#include "cmask.h"
#include "call.h"
#include "dplanes.h"
#include "cplanes.h"

#define MAXB 40
#define MAXS 32
#define SENTINEL INT64_C(0x5a5a5a5a5a5a5a5a)

struct buf {
  char name[32];
  int width;
  uint64_t count, alloc;
  unsigned char *data, *before;
};

static void fill(struct buf *b, const char *how) {
  size_t bytes = b->alloc * b->width;
  b->data = bytes ? malloc(bytes) : NULL;
  if (bytes && !b->data) { fprintf(stderr, "edges: out of memory\n"); exit(2); }
  const char *list = strncmp(how, "list:", 5) == 0 ? how + 5 : NULL;
  for (uint64_t i = 0; i < b->alloc; i++) {
    int64_t v = 0;
    if (list) {
      char *end;
      v = strtoll(list, &end, 10);
      if (end == list) { fprintf(stderr, "edges: list too short for %s\n", b->name); exit(2); }
      list = *end == ',' ? end + 1 : end;
    } else if (strcmp(how, "seq") == 0) {
      v = (int64_t)(i & 255);
    } else if (strncmp(how, "val:", 4) == 0) {
      v = strtoll(how + 4, NULL, 10);
    }
    if (b->width == 1) b->data[i] = (unsigned char)v; else memcpy(b->data + i * 8, &v, 8);
  }
  b->before = bytes ? malloc(bytes) : NULL;
  if (bytes) memcpy(b->before, b->data, bytes);
}

static int call(const char *entry, struct buf *b, int64_t *s, int64_t *result) {
#define P(i) (b[i].data)
#define C(i) (b[i].count)
#define Q(i) ((int64_t *)(void *)b[i].data)
  if (strcmp(entry, "col") == 0)
    return spinel_core_dc_sp_col(P(0), C(0), P(1), C(1), P(2), C(2), P(3), C(3), P(4), C(4),
                                 Q(5), C(5), s[0], s[1], s[2], s[3], s[4], s[5],
                                 s[6], s[7], s[8], s[9], s[10], s[11], result);
  if (strcmp(entry, "span") == 0)
    return spinel_core_dc_sp_span(P(0), C(0), P(1), C(1), P(2), C(2), Q(3), C(3),
                                  s[0], s[1], s[2], s[3], s[4], s[5], s[6], s[7], s[8], s[9],
                                  s[10], s[11], s[12], result);
  if (strcmp(entry, "mjob") == 0)
    return spinel_core_dc_sp_mjob(P(0), C(0), P(1), C(1), P(2), C(2), P(3), C(3), s[0], s[1],
                                  s[2], s[3], s[4], s[5], s[6], s[7], s[8], s[9], s[10], s[11],
                                  result);
  if (strcmp(entry, "none") == 0)
    return spinel_core_dc_sp_none(Q(0), C(0), s[0], s[1], result);
  if (strcmp(entry, "tex") == 0)
    return spinel_core_dc_sp_tex(Q(0), C(0), s[0], s[1], s[2], s[3], s[4], result);
  if (strcmp(entry, "mask") == 0)
    return spinel_core_dc_sp_mask(Q(0), C(0), s[0], s[1], s[2], s[3], s[4], s[5], result);
  if (strcmp(entry, "flat") == 0)
    return spinel_core_dc_sp_flat(Q(0), C(0), s[0], s[1], s[2], result);
  if (strcmp(entry, "zone") == 0)
    return spinel_core_dc_sp_zone(P(0), C(0), Q(1), C(1), Q(2), C(2), Q(3), C(3), P(4), C(4), s[0], s[1], s[2], result);
  if (strcmp(entry, "zalloc") == 0)
    return spinel_core_dc_sp_zalloc(Q(0), C(0), Q(1), C(1), s[0], result);
  if (strcmp(entry, "jreset") == 0)
    return spinel_core_dc_sp_jreset(Q(0), C(0), Q(1), C(1), s[0], result);
  if (strcmp(entry, "exec") == 0)
    return spinel_core_dc_sp_exec(P(0), C(0), P(1), C(1), P(2), C(2), P(3), C(3), P(4), C(4), P(5), C(5),
                                  Q(6), C(6), Q(7), C(7), Q(8), C(8), Q(9), C(9), Q(10), C(10), Q(11), C(11),
                                  Q(12), C(12), Q(13), C(13), Q(14), C(14), Q(15), C(15), Q(16), C(16), s[0],
                                  result);
  if (strcmp(entry, "pwall") == 0)
    return spinel_core_dc_sp_pwall(Q(0), C(0), Q(1), C(1), Q(2), C(2), Q(3), C(3), Q(4), C(4), Q(5), C(5),
                                   s[0], s[1], s[2], s[3], s[4], s[5], s[6], s[7], s[8], result);
  if (strcmp(entry, "pspan") == 0)
    return spinel_core_dc_sp_pspan(Q(0), C(0), Q(1), C(1), Q(2), C(2), Q(3), C(3), Q(4), C(4), Q(5), C(5),
                                   s[0], s[1], s[2], s[3], s[4], s[5], s[6], s[7], s[8], result);
  if (strcmp(entry, "pmask") == 0)
    return spinel_core_dc_sp_pmask(Q(0), C(0), Q(1), C(1), Q(2), C(2), Q(3), C(3), Q(4), C(4), Q(5), C(5),
                                   s[0], s[1], s[2], s[3], s[4], s[5], s[6], s[7], s[8], s[9], s[10], result);
  if (strcmp(entry, "ph1") == 0)
    return spinel_core_dc_sp_ph1(Q(0), C(0), s[0], s[1], result);
  if (strcmp(entry, "ph3") == 0)
    return spinel_core_dc_sp_ph3(Q(0), C(0), s[0], s[1], result);
  if (strcmp(entry, "cdis") == 0)
    return spinel_core_dc_sp_cdis(Q(0), C(0), Q(1), C(1), Q(2), C(2), Q(3), C(3), Q(4), C(4), Q(5), C(5),
                                  s[0], s[1], s[2], s[3], result);
  if (strcmp(entry, "cspan") == 0)
    return spinel_core_dc_sp_cspan(Q(0), C(0), Q(1), C(1), Q(2), C(2), Q(3), C(3), Q(4), C(4), Q(5), C(5),
                                   s[0], s[1], s[2], result);
  if (strcmp(entry, "cmask") == 0)
    return spinel_core_dc_sp_cmask(Q(0), C(0), Q(1), C(1), Q(2), C(2), Q(3), C(3), Q(4), C(4), Q(5), C(5),
                                   Q(6), C(6), Q(7), C(7), s[0], s[1], s[2], s[3], result);
  if (strcmp(entry, "call") == 0)
    return spinel_core_dc_sp_call(Q(0), C(0), Q(1), C(1), Q(2), C(2), Q(3), C(3), Q(4), C(4), Q(5), C(5),
                                  s[0], s[1], s[2], result);
  if (strcmp(entry, "dplanes") == 0)
    return spinel_core_dc_sp_dplanes(Q(0), C(0), Q(1), C(1), Q(2), C(2), Q(3), C(3), Q(4), C(4), Q(5), C(5), Q(6), C(6), Q(7), C(7), Q(8), C(8), Q(9), C(9), Q(10), C(10), Q(11), C(11), Q(12), C(12), Q(13), C(13), Q(14), C(14), Q(15), C(15), Q(16), C(16), Q(17), C(17), Q(18), C(18), Q(19), C(19), Q(20), C(20), Q(21), C(21), Q(22), C(22), Q(23), C(23), Q(24), C(24), Q(25), C(25), Q(26), C(26), Q(27), C(27), Q(28), C(28), Q(29), C(29), Q(30), C(30), Q(31), C(31), Q(32), C(32), Q(33), C(33),
                                     s[0], s[1], s[2], s[3], s[4], s[5], s[6], s[7], s[8], s[9], s[10], s[11], s[12], s[13], s[14], s[15], s[16], s[17], s[18], s[19], s[20], s[21], s[22], result);
  if (strcmp(entry, "cplanes") == 0)
    return spinel_core_dc_sp_cplanes(Q(0), C(0), Q(1), C(1), Q(2), C(2), Q(3), C(3), Q(4), C(4), Q(5), C(5), Q(6), C(6),
                                     Q(7), C(7), Q(8), C(8), s[0], s[1], s[2], s[3], s[4], s[5], s[6], result);
  fprintf(stderr, "edges: unknown entry %s\n", entry);
  exit(2);
}

int main(void) {
  static char line[1 << 16];
  char name[64], entry[32];
  struct buf b[MAXB];
  int64_t s[MAXS];
  int nb = 0, ns = 0;
  while (fgets(line, sizeof line, stdin)) {
    if (sscanf(line, "case %63s %31s", name, entry) == 2) {
      nb = 0;
      ns = 0;
    } else if (strncmp(line, "buf ", 4) == 0) {
      char elem[8];
      int at = -1;
      /* the fill is the rest of the line, however long its list */
      if (nb == MAXB || sscanf(line, "buf %31s %7s %" SCNu64 " %" SCNu64 " %n", b[nb].name, elem,
                               &b[nb].count, &b[nb].alloc, &at) != 4 || at < 0 || line[at] == '\0') {
        fprintf(stderr, "edges: bad buf line: %s", line);
        return 2;
      }
      char *how = line + at;
      how[strcspn(how, "\r\n")] = '\0';
      b[nb].width = strcmp(elem, "i64") == 0 ? 8 : 1;
      fill(&b[nb], how);
      nb++;
    } else if (strncmp(line, "scalars", 7) == 0) {
      char *p = line + 7, *end;
      for (;;) {
        long long v = strtoll(p, &end, 10);
        if (end == p) break;
        if (ns == MAXS) { fprintf(stderr, "edges: too many scalars\n"); return 2; }
        s[ns++] = v;
        p = end;
      }
    } else if (strncmp(line, "end", 3) == 0) {
      int64_t result = SENTINEL;
      int status = call(entry, b, s, &result);
      printf("%s status %d result ", name, status);
      if (result == SENTINEL) printf("untouched"); else printf("%" PRId64, result);
      printf(" changed");
      int any = 0;
      for (int i = 0; i < nb; i++) {
        for (uint64_t k = 0; k < b[i].alloc; k++) {
          if (memcmp(b[i].data + k * b[i].width, b[i].before + k * b[i].width, b[i].width) == 0) continue;
          int64_t v = 0;
          if (b[i].width == 1) v = b[i].data[k]; else memcpy(&v, b[i].data + k * 8, 8);
          printf("%s%s[%" PRIu64 "]=%" PRId64, any ? "," : " ", b[i].name, k, v);
          any = 1;
        }
        free(b[i].data);
        free(b[i].before);
      }
      printf("%s\n", any ? "" : " none");
      nb = 0;
      ns = 0;
    }
  }
  return 0;
}
