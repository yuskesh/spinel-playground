/* spinel-typedump -- an in-process, NODE-ID-keyed typed AST dump. [E041]
 *
 * Reads a .rb through the real upstream pipeline in ONE process
 *   sp_parse_file -> slc_nt_copy -> comp_new -> analyze_program
 * and prints what the LLVM/MLIR backend actually needs: for every AST node, its
 * id, its kind, and its inferred TyKind. Everything it touches in upstream goes
 * through tools/contract/spinel_contract.h.
 *
 * The point is the KEY. `spinel --emit-types` walks the same node array but
 * prints {file,line,col,type} and drops the id, so the consumer has to join on
 * position -- and positions are shared by several nodes with different types
 * (E018 罠 3, E040 §5). Here the id survives, so the type lookup is exact.
 *
 * Modes:
 *   nodes        (default) TSV: id kind type scope_idx scope_name line col detail
 *   json                   the same, as JSON
 *   ast          the PRISTINE parse (N/S/I/F/R/A lines, same schema as
 *                `spinel --dump-ast`) with two structural guarantees the
 *                text-mode producer does not give [E087]:
 *                  (1) every node's `N` line precedes all of its attribute
 *                      lines (E018 罠 1 -- src/spinel_parse.c streams
 *                      node_line AHEAD of the N macro -- cannot occur), and
 *                  (2) positions are ALWAYS stamped, because this process
 *                      sets the parser's debug mode itself
 *                      (slc_enable_positions; forgetting it silently drops
 *                      every node_line).
 *   methods      TSV: scope_idx name class ret nparams params abi_ok
 *   locals       TSV: scope scope_name slot name type is_param is_cell
 *                nullable_int -- the inferred type of every local SLOT [E077]
 *   emit-types   TSV: file line col type   -- the record SET `--emit-types`
 *                emits, reproduced from the same array with the same filters,
 *                for a differential against the JSON (results/E041/diff.py)
 *   features     TSV: feature required(0|1) -- for every NAME given after the
 *                mode, whether `require "NAME"` RESOLVED during the pre-parse
 *                splice (verbatim spelling, transitive requires included --
 *                E089 P4 path (B); [E090] the input of the T-3 menu check).
 *                The names to ask about come from the caller (the capability
 *                ledger, tools/platform/menus.yaml) -- this tool knows no
 *                vocabulary of its own, and there is no enumeration: the
 *                backing table is static in vendor (sp_req_feats)
 *   globals      TSV: name type -- one row per GLOBAL VARIABLE ($g) the
 *                whole-program analysis knows, with the widened type every
 *                write agreed on ([E093] the input of arenacheck's escape
 *                check).  The name carries its '$'; `type` is the same tag
 *                the other modes print
 *   positions    TSV: file line col n_nodes n_types node_ids kinds types
 *                -- the position-collision census (罠 3 made measurable)
 *   gate         TSV: the freestanding/int-only subset gate answered per NODE
 *                instead of per position (E040 §5 demo)
 *   info         TSV: table sizes + how many nodes analysis synthesized
 *
 * Options:
 *   --method NAME   restrict nodes/json/gate to the subtree of that `def`
 *   --typed-only    nodes/json: skip TY_UNKNOWN / TY_VOID nodes
 *   --ast-only      skip nodes analysis synthesized (not in the pristine parse)
 *   -I DIR          [E090] add a `require` feature root (repeatable), exactly
 *                   bin/spinel's -I.  Applied before the parse, so requires
 *                   that resolve through it are spliced in and marked
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "spinel_contract.h"

static const char *PROG = "spinel-typedump";

static void die(const char *msg, const char *arg) {
  if (arg) fprintf(stderr, "%s: %s: %s\n", PROG, msg, arg);
  else     fprintf(stderr, "%s: %s\n", PROG, msg);
  exit(2);
}

/* ---- node subtree selection ------------------------------------------- */

/* Mark the subtree at `root` (generic child walk: ref fields + array fields). */
static void mark_subtree(const SlcProgram *p, int root, unsigned char *mark) {
  if (root < 0 || root >= slc_node_count(p) || mark[root]) return;
  mark[root] = 1;
  int nr = slc_num_refs(p, root);
  for (int i = 0; i < nr; i++) mark_subtree(p, slc_ref_at(p, root, i), mark);
  int na = slc_num_arrs(p, root);
  for (int i = 0; i < na; i++) {
    int n = 0;
    const int *ids = slc_arr_at(p, root, i, &n);
    for (int j = 0; j < n; j++) mark_subtree(p, ids[j], mark);
  }
}

/* The scope index of the `def NAME` at top level, or -1. */
static int find_method_scope(const SlcProgram *p, const char *name) {
  for (int si = 1; si < slc_nscopes(p); si++) {
    Scope *s = slc_scope(p, si);
    const char *n = slc_scope_name(s);
    if (n && strcmp(n, name) == 0) return si;
  }
  return -1;
}

/* ---- helpers ----------------------------------------------------------- */

static const char *kind_name(const SlcProgram *p, int id) {
  const char *t = slc_node_type(p, id);
  return t ? t : "-";
}

/* A short human hint for the node: its `name` field, else its content. */
static const char *detail_of(const SlcProgram *p, int id) {
  const char *d = slc_node_str(p, id, "name");
  if (!d) d = slc_node_str(p, id, "value");
  if (!d) d = slc_node_content(p, id);
  return d ? d : "";
}

static void json_esc(FILE *f, const char *s) {
  for (; s && *s; s++) {
    if (*s == '"' || *s == '\\') fprintf(f, "\\%c", *s);
    else if ((unsigned char)*s < 0x20) fprintf(f, "\\u%04x", *s);
    else fputc(*s, f);
  }
}

/* ---- modes ------------------------------------------------------------- */

static void mode_nodes(const SlcProgram *p, const unsigned char *sel,
                       int typed_only, int ast_only, int as_json) {
  char tag[256];
  if (as_json) printf("{\"nodes\":[\n");
  int first = 1;
  if (!as_json)
    printf("id\tkind\ttype\tscope\tscope_name\tline\tcol\tdetail\n");
  for (int id = 0; id < slc_node_count(p); id++) {
    if (sel && !sel[id]) continue;
    if (ast_only && !slc_ast_has_node(p, id)) continue;
    TyKind t = slc_node_ty(p, id);
    if (typed_only && (slc_ty_is_unknown(t) || slc_ty_is_void(t))) continue;
    slc_ty_tag(p, t, tag, sizeof tag);
    int si = slc_node_scope(p, id);
    const char *sn = (si >= 0 && si < slc_nscopes(p) && slc_scope_name(slc_scope(p, si)))
                     ? slc_scope_name(slc_scope(p, si)) : "(top)";
    if (as_json) {
      if (!first) printf(",\n");
      first = 0;
      printf("  {\"id\":%d,\"kind\":\"", id);
      json_esc(stdout, kind_name(p, id));
      printf("\",\"type\":\"");
      json_esc(stdout, tag);
      printf("\",\"scope\":%d,\"scope_name\":\"", si);
      json_esc(stdout, sn);
      printf("\",\"line\":%d,\"col\":%d,\"detail\":\"",
             slc_node_line(p, id), slc_node_col(p, id));
      json_esc(stdout, detail_of(p, id));
      printf("\"}");
    } else {
      printf("%d\t%s\t%s\t%d\t%s\t%d\t%d\t%s\n",
             id, kind_name(p, id), tag, si, sn,
             slc_node_line(p, id), slc_node_col(p, id), detail_of(p, id));
    }
  }
  if (as_json) printf("\n]}\n");
}

static void mode_methods(const SlcProgram *p) {
  char tag[256], ptag[256];
  printf("scope\tname\tclass\tret\tnparams\tparams\tabi_scalar\n");
  for (int si = 1; si < slc_nscopes(p); si++) {
    Scope *s = slc_scope(p, si);
    const char *n = slc_scope_name(s);
    if (!n || !*n) continue;
    slc_ty_tag(p, slc_scope_ret(s), tag, sizeof tag);
    int ci = slc_scope_class_id(s);
    const char *cn = (ci >= 0 && ci < slc_nclasses(p)) ? slc_class_name(slc_class(p, ci)) : "-";
    printf("%d\t%s\t%s\t%s\t%d\t", si, n, cn ? cn : "-", tag, slc_scope_nparams(s));
    int abi_ok = slc_ty_is_abi_scalar(slc_scope_ret(s)) || slc_scope_ret(s) == TY_INT;
    for (int i = 0; i < slc_scope_nparams(s); i++) {
      TyKind pt = slc_param_type(s, i);
      slc_ty_tag(p, pt, ptag, sizeof ptag);
      if (pt != TY_INT) abi_ok = 0;
      printf("%s%s:%s", i ? "," : "", slc_scope_pname(s, i), ptag);
    }
    if (slc_scope_nparams(s) == 0) printf("-");
    printf("\t%s\n", (abi_ok && slc_scope_ret(s) == TY_INT) ? "yes" : "no");
  }
}

/* The record set `build_types_json` (src/codegen.c) emits, reproduced with the
   SAME filters (raw ntype, skip UNKNOWN/VOID, skip node_line <= 0). Printed as
   TSV so a set comparison against the JSON is a sort|diff. */
static void mode_emit_types(const SlcProgram *p) {
  char tag[256];
  for (int id = 0; id < slc_node_count(p); id++) {
    TyKind t = slc_node_ty(p, id);
    if (slc_ty_is_unknown(t) || slc_ty_is_void(t)) continue;
    int ln = slc_node_line(p, id);
    if (ln <= 0) continue;
    slc_ty_tag(p, t, tag, sizeof tag);
    printf("%s\t%d\t%d\t%s\n", slc_file_path(p, slc_node_file_id(p, id)),
           ln, slc_node_col(p, id), tag);
  }
}

/* Position-collision census: for every (file,line,col) that carries at least
   one typed node, how many nodes and how many DISTINCT types sit there. A row
   with n_types > 1 is a position on which the old join is ambiguous. */
static void mode_positions(const SlcProgram *p) {
  int n = slc_node_count(p);
  int *order = (int *)malloc(sizeof(int) * (size_t)(n > 0 ? n : 1));
  int m = 0;
  for (int id = 0; id < n; id++) {
    TyKind t = slc_node_ty(p, id);
    if (slc_ty_is_unknown(t) || slc_ty_is_void(t)) continue;
    if (slc_node_line(p, id) <= 0) continue;
    order[m++] = id;
  }
  /* insertion sort by (file_id, line, col, id): m is small (hundreds). */
  for (int i = 1; i < m; i++) {
    int v = order[i], j = i - 1;
    while (j >= 0) {
      int a = order[j];
      int fa = slc_node_file_id(p, a), fv = slc_node_file_id(p, v);
      int la = slc_node_line(p, a),    lv = slc_node_line(p, v);
      int ca = slc_node_col(p, a),     cv = slc_node_col(p, v);
      int gt = (fa > fv) || (fa == fv && (la > lv || (la == lv && (ca > cv || (ca == cv && a > v)))));
      if (!gt) break;
      order[j + 1] = order[j];
      j--;
    }
    order[j + 1] = v;
  }
  printf("file\tline\tcol\tn_nodes\tn_types\tnode_ids\tkinds\ttypes\n");
  char tag[256];
  int i = 0;
  while (i < m) {
    int j = i;
    int f = slc_node_file_id(p, order[i]), l = slc_node_line(p, order[i]), c = slc_node_col(p, order[i]);
    while (j < m && slc_node_file_id(p, order[j]) == f
                 && slc_node_line(p, order[j]) == l
                 && slc_node_col(p, order[j]) == c) j++;
    /* distinct type tags in [i,j) */
    char seen[32][256]; int nseen = 0;
    for (int k = i; k < j; k++) {
      slc_ty_tag(p, slc_node_ty(p, order[k]), tag, sizeof tag);
      int dup = 0;
      for (int q = 0; q < nseen; q++) if (strcmp(seen[q], tag) == 0) { dup = 1; break; }
      if (!dup && nseen < 32) { snprintf(seen[nseen], sizeof seen[0], "%s", tag); nseen++; }
    }
    printf("%s\t%d\t%d\t%d\t%d\t", slc_file_path(p, f), l, c, j - i, nseen);
    for (int k = i; k < j; k++) printf("%s%d", k > i ? "," : "", order[k]);
    printf("\t");
    for (int k = i; k < j; k++) printf("%s%s", k > i ? "," : "", kind_name(p, order[k]));
    printf("\t");
    for (int q = 0; q < nseen; q++) printf("%s%s", q ? "," : "", seen[q]);
    printf("\n");
    i = j;
  }
  free(order);
}

/* The int-only subset gate, answered per NODE. `spinel-mlirgen` asks the same
   question through the position join and has to accept "some unboxed scalar is
   reported at this position" (E040 §5). Here each node answers for itself. */
static void mode_gate(const SlcProgram *p, const unsigned char *sel) {
  char tag[256];
  int n_ok = 0, n_none = 0, n_ref = 0;
  printf("id\tkind\ttype\tverdict\tline\tcol\tdetail\n");
  for (int id = 0; id < slc_node_count(p); id++) {
    if (sel && !sel[id]) continue;
    TyKind t = slc_node_ty(p, id);
    slc_ty_tag(p, t, tag, sizeof tag);
    const char *v;
    /* Three verdicts, and the middle one is the point. `--emit-types` cannot
       express it: it simply omits TY_UNKNOWN / TY_VOID nodes, so "the analyzer
       has NO evidence for this expression" arrives at the consumer looking
       exactly like "some other node at this position was reported instead".
       E040 §5 is that confusion. */
    if (slc_ty_is_int(t) || slc_ty_is_bool(t))              { v = "ok";     n_ok++; }
    else if (slc_ty_is_unknown(t) || slc_ty_is_void(t))     { v = "none";   n_none++; }
    else                                                    { v = "REFUSE"; n_ref++; }
    printf("%d\t%s\t%s\t%s\t%d\t%d\t%s\n", id, kind_name(p, id), tag, v,
           slc_node_line(p, id), slc_node_col(p, id), detail_of(p, id));
  }
  printf("#summary\tok=%d\tno-evidence=%d\trefuse=%d\n", n_ok, n_none, n_ref);
}

/* [E077] Every local SLOT of every method, with the type inference gave it.
   `nodes` answers "what type does this expression have"; this answers "what
   type does this variable have", which is a different question and the one a
   code generator needs before it can emit a block signature: a merge block in
   func/cf carries the whole environment as block ARGUMENTS, so the generator
   has to know each local's MLIR type at the point it opens the loop header --
   before it has walked the body that would reveal it.

   The position join could never answer this at all.  A local's Read/Write
   nodes are scattered over the body and share positions with the expressions
   around them (E077 measured `a` and `a[i]` at the SAME line:col, one
   int_array and one int), so "join on position, take the type" cannot even
   name the variable it is talking about.  Here the slot is the key.

   Columns: scope, scope_name, slot index, name, type tag, is_param, is_cell,
   nullable_int.  `slot` order is upstream's: parameters first, body locals
   after (spinel_contract.h, Scope.locals). */
static void mode_locals(const SlcProgram *p, const char *only) {
  char tag[256];
  printf("scope\tscope_name\tslot\tname\ttype\tis_param\tis_cell\tnullable_int\n");
  for (int si = 1; si < slc_nscopes(p); si++) {
    Scope *s = slc_scope(p, si);
    const char *n = slc_scope_name(s);
    if (!n || !*n) continue;
    if (only && strcmp(n, only) != 0) continue;
    for (int k = 0; k < slc_scope_nlocals(s); k++) {
      slc_ty_tag(p, slc_local_type_at(s, k), tag, sizeof tag);
      printf("%d\t%s\t%d\t%s\t%s\t%d\t%d\t%d\n", si, n, k,
             slc_local_name(s, k) ? slc_local_name(s, k) : "-", tag,
             slc_local_is_param_at(s, k), slc_local_is_cell_at(s, k),
             slc_local_nullable_int_at(s, k));
    }
  }
}

/* [E087] The pristine parse, re-serialized node-atomically.  Replaces
   `SPINEL_LINE_MAP=1 spinel --dump-ast` as spinel-mlirgen's STRUCTURE source.

   The schema is upstream's own (N/S/I/F/R/A -- spinel_parse.c's flatten()),
   so the consumer-side loader stays a 30-line line reader; what changes is the
   PRODUCER's guarantees: node ids ascend, each node is emitted whole (N line
   first), and positions are always present.  The E018 traps were properties of
   the streaming producer, and this producer is not streaming -- it prints a
   table that already exists.

   Values are escaped with upstream's own table (escape_str, spinel_parse.c:
   %, \n, \r, \t, space, NUL -> %XX) so that a consumer unescaping with a
   generic %XX decoder gets back byte-for-byte what the table stores. */
static void ast_esc(FILE *f, const char *s, size_t len) {
  static const char hex[] = "0123456789ABCDEF";
  for (size_t i = 0; i < len; i++) {
    unsigned char c = (unsigned char)s[i];
    if (c == '%' || c == '\n' || c == '\r' || c == '\t' || c == ' ' || c == 0) {
      fputc('%', f); fputc(hex[c >> 4], f); fputc(hex[c & 15], f);
    } else {
      fputc(c, f);
    }
  }
}

static void mode_ast(const SlcProgram *p) {
  if (slc_ast_source_file(p)) {
    printf("SOURCE_FILE ");
    ast_esc(stdout, slc_ast_source_file(p), strlen(slc_ast_source_file(p)));
    printf("\n");
  }
  for (int i = 0; i < slc_ast_nfiles(p); i++) {
    if (!slc_ast_file(p, i)) continue;
    printf("FILE %d ", i);
    ast_esc(stdout, slc_ast_file(p, i), strlen(slc_ast_file(p, i)));
    printf("\n");
  }
  printf("ROOT %d\n", slc_ast_root(p));
  for (int id = 0; id < slc_ast_ncount(p); id++) {
    const char *ty = slc_ast_type(p, id);
    if (!ty) continue;                 /* an unused slot: never declared */
    printf("N %d %s\n", id, ty);
    for (int i = 0; i < slc_ast_nstr(p, id); i++) {
      size_t len = 0;
      const char *v = slc_ast_str_val(p, id, i, &len);
      printf("S %d %s ", id, slc_ast_str_key(p, id, i));
      ast_esc(stdout, v ? v : "", v ? len : 0);
      printf("\n");
    }
    for (int i = 0; i < slc_ast_nint(p, id); i++)
      printf("I %d %s %lld\n", id, slc_ast_int_key(p, id, i), slc_ast_int_val(p, id, i));
    /* F carries no key in the node table (the loader ignores it); upstream's
       only emitter is F("value", ...) on FloatNode, so "value" restores the
       spelling the text consumer joins on. */
    if (slc_ast_fcontent(p, id))
      printf("F %d value %s\n", id, slc_ast_fcontent(p, id));
    for (int i = 0; i < slc_ast_nref(p, id); i++)
      printf("R %d %s %d\n", id, slc_ast_ref_key(p, id, i), slc_ast_ref_val(p, id, i));
    for (int i = 0; i < slc_ast_narr(p, id); i++) {
      int n = 0;
      const int *ids = slc_ast_arr_val(p, id, i, &n);
      printf("A %d %s ", id, slc_ast_arr_key(p, id, i));
      for (int j = 0; j < n; j++) printf("%s%d", j ? "," : "", ids[j]);
      printf("\n");
    }
  }
}

/* How far the analyzed table drifted from the pristine parse, plus the table
   sizes. `synthesized` is the count of nodes analyze_program appended (they
   exist only in the analyzed table, and any consumer that also reads the
   pristine AST has to know they are there). */
static void mode_info(const SlcProgram *p) {
  int an = slc_node_count(p);
  int ast = p->ast->count;
  int typed = 0, unknown = 0;
  for (int id = 0; id < an; id++) {
    TyKind t = slc_node_ty(p, id);
    if (slc_ty_is_unknown(t) || slc_ty_is_void(t)) unknown++; else typed++;
  }
  printf("key\tvalue\n");
  printf("source_file\t%s\n", slc_source_file(p) ? slc_source_file(p) : "-");
  printf("ast_nodes\t%d\n", ast);
  printf("analyzed_nodes\t%d\n", an);
  printf("synthesized_by_analysis\t%d\n", an - ast);
  printf("typed_nodes\t%d\n", typed);
  printf("untyped_nodes\t%d\n", unknown);
  printf("scopes\t%d\n", slc_nscopes(p));
  printf("classes\t%d\n", slc_nclasses(p));
}

/* [E093] globals mode: one row per global variable the whole-program analysis
   knows, with its widened type.  arenacheck's escape check asks exactly this:
   a global outlives the request, so a heap type here is a reference that
   survives the arena reset.  Reading Compiler.gvars (rather than joining the
   write sites' value expressions) is what makes a widening across two writes
   visible in one row. */
static void mode_globals(const SlcProgram *p) {
  char tag[256];
  printf("name\ttype\n");
  for (int i = 0; i < slc_ngvars(p); i++) {
    const char *n = slc_gvar_name(p, i);
    if (!n) continue;
    slc_ty_tag(p, slc_gvar_type(p, i), tag, sizeof tag);
    printf("$%s\t%s\n", n, tag);
  }
}

/* [E090] features mode: one row per NAME the caller asked about.  The answer
   is slc_feature_required's, i.e. "this require string resolved", verbatim on
   the spelling.  TSV with a header, like the other table modes. */
static void mode_features(const char **names, int n_names) {
  printf("feature\trequired\n");
  for (int i = 0; i < n_names; i++)
    printf("%s\t%d\n", names[i], slc_feature_required(names[i]));
}

/* ------------------------------------------------------------------------ */

static void usage(void) {
  fprintf(stderr,
    "usage: %s <file.rb> [nodes|json|ast|methods|locals|emit-types|globals|positions|gate|info]\n"
    "                     [--method NAME] [--typed-only] [--ast-only] [-I DIR] [--int-width=32|64]\n"
    "                     [--keep-method=NAME ...]\n"
    "       %s <file.rb> features NAME [NAME...] [-I DIR]\n", PROG, PROG);
}

/* Provided by the vendor frontend (src/spinel_parse.c), the one place every
   load goes through. The ledger is a fork patch of the pinned tree, so a vendor
   tree without it (upstream, before the fork stack is rebased onto it) builds
   this reader without --inputs-out; build.sh decides by looking for the
   functions in the vendor source. */
#ifdef SPINEL_HAVE_INPUTS_LEDGER
int sp_inputs_write(const char *path);
void sp_inputs_enable(void);
#endif
/* The --core identities (src/codegen_util.c), which the fork's prune of
   unnamed methods keeps. build.sh defines SPINEL_HAVE_CORE_ROOTS only when
   the vendor prune reads them. */
#ifdef SPINEL_HAVE_CORE_ROOTS
extern const char **g_core_roots;
extern int g_core_root_count;
#endif

int main(int argc, char **argv) {
  const char *path = NULL, *mode = "nodes", *method = NULL;
  /* --inputs-out: the ledger of files THIS reader opened. The driver needs each
     analysis to account for its own inputs; a ledger from a separate hosted run
     describes that run, not this one. Provided by the vendor frontend, which is
     the one place every load goes through. */
  const char *inputs_out = NULL;
  const char *names[256]; int n_names = 0;
  int typed_only = 0, ast_only = 0, mode_set = 0;
  for (int i = 1; i < argc; i++) {
    const char *a = argv[i];
    if (strcmp(a, "--method") == 0)      { if (++i < argc) method = argv[i]; }
    else if (strncmp(a, "--inputs-out=", 13) == 0) {
      inputs_out = a + 13;
#ifdef SPINEL_HAVE_INPUTS_LEDGER
      /* Before the parse: recording starts at the first read. */
      sp_inputs_enable();
#else
      die("--inputs-out needs the vendor input ledger (sp_inputs_*), which this "
          "vendor tree does not have", inputs_out);
#endif
    }
    else if (strncmp(a, "--int-width=", 12) == 0) {
      const char *width = a + 12;
      if (strcmp(width, "32") != 0 && strcmp(width, "64") != 0)
        die("--int-width must be 32 or 64", width);
      if (!slc_set_target_int_bits(atoi(width))) die("unsupported int-width", width);
    }
    else if (strncmp(a, "--keep-method=", 14) == 0) {
      /* A method the caller lowers from outside the program text (a CORE
         root). The fork's prune of unnamed methods keeps the --core
         identities; this reader runs the analysis in process, so it adds the
         name to the same list bin/spinel's --core fills. */
#ifdef SPINEL_HAVE_CORE_ROOTS
      if (!a[14]) die("--keep-method needs a method name", a);
      g_core_roots = (const char **)realloc((void *)g_core_roots,
                                            (size_t)(g_core_root_count + 1) * sizeof(char *));
      if (!g_core_roots) die("out of memory", a);
      g_core_roots[g_core_root_count++] = a + 14;
#else
      die("--keep-method needs the vendor prune's keep list (g_core_roots), "
          "which this vendor tree does not have", a);
#endif
    }
    else if (strcmp(a, "--typed-only") == 0) typed_only = 1;
    else if (strcmp(a, "--ast-only") == 0)   ast_only = 1;
    else if (strcmp(a, "-I") == 0) {
      /* [E090] a feature root.  Recorded with upstream before the parse below;
         order-preserving, exactly like bin/spinel's -I. */
      if (++i >= argc) die("-I needs a directory", NULL);
      slc_add_feature_root(argv[i]);
    }
    else if (strcmp(a, "-h") == 0 || strcmp(a, "--help") == 0) { usage(); return 0; }
    else if (a[0] == '-') die("unknown option", a);
    else if (!path) path = a;
    else if (!mode_set) { mode = a; mode_set = 1; }
    else if (strcmp(mode, "features") == 0) {
      /* positionals after the mode are the names features asks about.  Before
         E090 a third positional silently REPLACED the mode; refusing it in the
         other modes is strictly louder. */
      if (n_names >= (int)(sizeof names / sizeof names[0]))
        die("too many feature names", a);
      names[n_names++] = a;
    }
    else die("unexpected argument (only `features` takes names)", a);
  }
  if (!path) { usage(); return 2; }
  if (strcmp(mode, "features") == 0 && n_names == 0)
    die("features mode needs at least one capability name to ask about "
        "(the caller's ledger supplies them; there is no enumeration)", NULL);

  slc_enable_positions();
  slc_disable_builtins();
  SlcProgram p;
  if (!slc_open(&p, path, argv[0])) die("parse/analyze failed for", path);
  /* Written after the parse, which is when every load has happened, and before
     any output: a caller that asked for the ledger must not get a report the
     ledger does not describe. A failure here fails the run. */
#ifdef SPINEL_HAVE_INPUTS_LEDGER
  if (inputs_out && sp_inputs_write(inputs_out) != 0)
    die("cannot write the input ledger", inputs_out);
#endif

  unsigned char *sel = NULL;
  if (method) {
    int si = find_method_scope(&p, method);
    if (si < 0) die("no such method", method);
    int def = slc_scope_def_node(slc_scope(&p, si));
    if (def < 0) die("method has no def node", method);
    sel = (unsigned char *)calloc((size_t)slc_node_count(&p), 1);
    mark_subtree(&p, def, sel);
  }

  if      (strcmp(mode, "nodes") == 0)      mode_nodes(&p, sel, typed_only, ast_only, 0);
  else if (strcmp(mode, "json") == 0)       mode_nodes(&p, sel, typed_only, ast_only, 1);
  else if (strcmp(mode, "ast") == 0)        mode_ast(&p);
  else if (strcmp(mode, "methods") == 0)    mode_methods(&p);
  else if (strcmp(mode, "locals") == 0)     mode_locals(&p, method);
  else if (strcmp(mode, "emit-types") == 0) mode_emit_types(&p);
  else if (strcmp(mode, "features") == 0)   mode_features(names, n_names);
  else if (strcmp(mode, "globals") == 0)    mode_globals(&p);
  else if (strcmp(mode, "positions") == 0)  mode_positions(&p);
  else if (strcmp(mode, "gate") == 0)       mode_gate(&p, sel);
  else if (strcmp(mode, "info") == 0)       mode_info(&p);
  else die("unknown mode", mode);

  free(sel);
  /* Deliberately no slc_close(): upstream's analysis allocates through the
     Compiler and a few interned tables that comp_free does not reclaim, and a
     one-shot dumper exiting is cheaper (and quieter under ASan-less builds)
     than chasing them. Kept as a documented choice, not an oversight. */
  return 0;
}
