/* spinel_nt_copy.h -- an id-preserving copy of a parsed node table.
 *
 * Upstream c5964c6f4 removed the text round trip: sp_parse_file() fills a
 * NodeTable directly, and there is no nt_load_text to load the same text
 * twice. The in-process readers still need two tables with identical ids --
 * one pristine for structural reads, one for analyze_program to rewrite --
 * so the second is a copy of the first.
 *
 * Parsing twice is NOT a substitute: the parser marks the entry file and every
 * spliced file as included, so a second parse in the same process sees a
 * `require_relative` as already satisfied and builds a different tree.
 *
 * nt_import_subtree renumbers, so it cannot be used either. This copies node
 * by node through the table's own fill functions (nt_put_*), keeping each id,
 * each field's key and value, and the order of the fields within each kind --
 * the order `--dump-ast` and the typedump's ast mode print them in.
 *
 * Shared by tools/contract/spinel_contract.h and
 * tools/ebpf/tools/spinel_ebpf_inproc.c; it needs only node_table.h.
 */
#ifndef SPINEL_NT_COPY_H
#define SPINEL_NT_COPY_H

#include <stdlib.h>
#include <string.h>

#include "node_table.h"

/* A copy of `src` with the same ids, root, source file and file map, or NULL
   when `src` is NULL. Allocation failure aborts inside the vendor allocator,
   as it does for the parser. The caller frees the copy with nt_free. */
static inline NodeTable *slc_nt_copy(const NodeTable *src) {
  if (!src) return NULL;
  NodeTable *dst = nt_new_table();
  for (int id = 0; id < src->count; id++) {
    const SpNode *n = &src->nodes[id];
    if (n->type) nt_put_type(dst, id, n->type);
    if (n->content) nt_put_content(dst, id, n->content);
    for (int j = 0; j < n->ns; j++)
      nt_put_str(dst, id, n->s[j].key, n->s[j].val, n->s[j].val_len);
    /* A node's four position ints are fields of its struct (upstream
       3fd464a5a), not entries of its int array: set them as upstream's own
       nt_import_subtree does, before the other ints. */
    for (int k = 0; k < 4; k++)
      if ((n->posmask >> k) & 1) nt_node_set_int(dst, id, NT_POS_KEYS[k], n->pos[k]);
    for (int j = 0; j < n->ni; j++)
      nt_put_int(dst, id, n->i[j].key, n->i[j].val);
    for (int j = 0; j < n->nr; j++)
      nt_put_ref(dst, id, n->r[j].key, n->r[j].ref);
    for (int j = 0; j < n->na; j++) {
      /* nt_put_arr takes ownership of the id array */
      int *ids = (int *)malloc(sizeof(int) * (size_t)(n->a[j].n ? n->a[j].n : 1));
      if (!ids) abort();
      if (n->a[j].n) memcpy(ids, n->a[j].ids, sizeof(int) * (size_t)n->a[j].n);
      nt_put_arr(dst, id, n->a[j].key, ids, n->a[j].n);
    }
  }
  /* A slot counts once something is put into it, so the two counts agree
     unless the source ends in a slot holding nothing -- which the fill
     functions cannot produce. A copy that disagrees is refused, not used. */
  if (dst->count != src->count) {
    nt_free(dst);
    return NULL;
  }
  dst->root_id = src->root_id;
  dst->has_cext_decls = src->has_cext_decls;
  if (src->source_file) nt_put_source_file(dst, src->source_file);
  for (int f = 0; f < src->nfiles; f++)
    if (src->files[f]) nt_put_file(dst, f, src->files[f]);
  return dst;
}

#endif /* SPINEL_NT_COPY_H */
