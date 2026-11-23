/* spinel_contract.h -- the COMPLETE dependency surface of upstream spinel
 * internals that spinel-llvm's in-process readers touch. [P001 Phase 3 増分② / E041]
 *
 * Every layout-dependent read of the upstream Compiler / Scope / ClassInfo /
 * LocalVar / NodeTable structs goes through ONE accessor here, so that:
 *   (1) if upstream renames or moves a field, THIS is the single file to fix;
 *   (2) a reviewer sees the entire spinel-llvm -> upstream-internals coupling
 *       at a glance (tools/contract/README.md tabulates it).
 *
 * Form deliberately mirrors spinel-ebpf's src/codegen_c/spinel_upstream_contract.h
 * (prefix `sce_` there, `slc_` here) so the two can be merged later if the
 * sister projects ever want one shared header.
 *
 * WHY IT EXISTS (the short version): the pre-E041 input contract was
 * `spinel --dump-ast` + `spinel --emit-types`, joined on source POSITION.
 * `build_types_json` (src/codegen.c) walks node ids but prints only
 * {file,line,col,type} -- the node id, the only unique key, is dropped. Several
 * nodes routinely share one (line,col) and each carries its own inferred type,
 * so the join is ambiguous by construction (E018 罠 3, E040 §5). Reading the
 * Compiler in-process keeps the node id and makes the type lookup exact.
 *
 * BUILD: this header is only usable in a TU linked against the upstream
 * compiler objects (vendor/spinel/build/csrc/ objects minus main.o) with
 * -I vendor/spinel/src. See tools/contract/build.sh.
 *
 * vendor/spinel is READ-ONLY: nothing here modifies it, and the whole coupling
 * is "#include its headers and call its functions".
 */
#ifndef SPINEL_LLVM_CONTRACT_H
#define SPINEL_LLVM_CONTRACT_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "node_table.h"  /* NodeTable / SpNode / NodeKind / nt_* */
#include "types.h"       /* TyKind / ty_name / ty_is_object / ... */
#include "compiler.h"    /* Compiler / Scope / ClassInfo / LocalVar */
#include "analyze.h"     /* analyze_program */
#include "spinel_nt_copy.h"  /* slc_nt_copy: the second, id-identical table */

/* Upstream entry points declared here rather than pulled in via extra include
   paths (src/spinel_parse.c has no public header; main.c declares it the same
   way). Part of the coupling surface -- see the README table. */
NodeTable *sp_parse_file(const char *source_file, const char *argv0);

/* ==========================================================================
 * 0. Program handle -- parse + analyze in one process
 * ========================================================================== */

/* Two tables of the SAME parse:
     - `ast` stays pristine, for structural reads (analyze_program rewrites the
       table in place: block-param alpha-rename, desugaring, synthetic nodes);
     - `an`  is the table the Compiler owns and analysis mutated.
   `an` is an id-preserving copy of `ast` (spinel_nt_copy.h), so an id read off
   `c` indexes correctly into `ast`. (The same arrangement as
   tools/ebpf/tools/spinel_ebpf_inproc.c.) Nodes appended by desugaring exist
   only in `an` -- slc_ast_has_node() tells the two apart. */
typedef struct {
  NodeTable *ast;
  NodeTable *an;
  Compiler  *c;
} SlcProgram;

/* Positions are stamped by the parser only under one of the globals
   g_opt_debug, g_opt_line_map or g_opt_positions (src/spinel_parse.c,
   sp_parse_positions_from_opts). The driver sets them from its options
   (src/main.c), and `spinel --emit-types`, which this reader stands in for,
   forces the debug mode. An in-process reader has no driver, so it sets
   g_opt_debug itself, or every node_line comes back 0. Call before slc_open.
   (Before upstream 556c840b1 these were the environment variables
   SPINEL_DEBUG / SPINEL_LINE_MAP, which the parser no longer reads.) */
static inline void slc_enable_positions(void) { g_opt_debug = 1; }

/* The compiler-owned builtins (the .rb files under builtins/) are looked for beside the
   RUNNING EXECUTABLE (src/spinel_parse.c, sp_lib_dir: /proc/self/exe or
   _NSGetExecutablePath), never beside this reader's sources, so an in-process
   reader outside the vendor tree does not find them. The pinned parser then
   spliced nothing and went on (sp_splice_builtins); upstream (2026-10) exits
   instead. Setting SPINEL_NO_BUILTINS keeps the pinned reader's behaviour --
   the analysis this reader reports has never included the builtins -- and
   is a choice to revisit, not a fact about the hosted compiler, which does
   splice them. Call before slc_open. */
static inline void slc_disable_builtins(void) { setenv("SPINEL_NO_BUILTINS", "1", 1); }

/* Select the target before parsing. This changes analysis, not the host ABI. */
extern int sp_target_int_bits;
static inline int slc_set_target_int_bits(int bits) {
  if (bits != 32 && bits != 64) return 0;
  sp_target_int_bits = bits;
  return 1;
}

/* Parse + analyze `path`. Returns 0 on failure (message on stderr by upstream).
   argv0 is passed through to the parser for its self-locating logic. */
static inline int slc_open(SlcProgram *p, const char *path, const char *argv0) {
  memset(p, 0, sizeof *p);
  /* One parse. A second sp_parse_file in this process would see the files the
     first one spliced as already included, and build a different tree. */
  p->ast = sp_parse_file(path, argv0);
  if (!p->ast) return 0;
  p->an = slc_nt_copy(p->ast);
  if (!p->an) return 0;
  p->c = comp_new(p->an);
  if (!p->c) return 0;
  analyze_program(p->c);
  return 1;
}

static inline void slc_close(SlcProgram *p) {
  if (p->c) comp_free(p->c);
  if (p->ast) nt_free(p->ast);
  /* comp_free does not own `an` (comp_new takes a const NodeTable *). */
  if (p->an) nt_free(p->an);
  memset(p, 0, sizeof *p);
}

/* [E090, P008 T-3] The resolved-require set.  Both upstream functions are
   extern in compiler.h; wrapped here so the coupling stays on this one page.
     slc_add_feature_root  adds a `-I` feature root; MUST be called BEFORE
                           slc_open (require is a pre-parse text splice --
                           E089 P1 -- so the roots have to exist by then).
     slc_feature_required  answers, verbatim on the spelling of the require
                           string, whether a require RESOLVED during the
                           splice (sp_feature_mark, src/spinel_parse.c:1800).
                           Unresolved requires are never marked; the backing
                           table holds 128 names and silently stops marking
                           beyond that (E089 P4 honest boundary). */
static inline void slc_add_feature_root(const char *dir) { sp_add_feature_root(dir); }
static inline int  slc_feature_required(const char *name) { return sp_feature_required(name); }

/* ==========================================================================
 * 1. Nodes -- structure, keyed by NODE ID (never by position)
 * ========================================================================== */

static inline const NodeTable *slc_nt(const SlcProgram *p)  { return p->an; }
static inline const NodeTable *slc_ast(const SlcProgram *p) { return p->ast; }
static inline int   slc_node_count(const SlcProgram *p)     { return p->an->count; }
static inline int   slc_root(const SlcProgram *p)           { return p->an->root_id; }
static inline const char *slc_source_file(const SlcProgram *p) { return p->an->source_file; }
/* 1 iff node id also exists in the pristine parse (i.e. it is not a node that
   analysis synthesized). */
static inline int   slc_ast_has_node(const SlcProgram *p, int id) { return id >= 0 && id < p->ast->count; }

static inline const char *slc_node_type(const SlcProgram *p, int id) { return nt_type(p->an, id); }
static inline NodeKind    slc_node_kind(const SlcProgram *p, int id) { return nt_kind(p->an, id); }

/* Field reads. Keys are upstream's parser field names ("name", "receiver", ...);
   the key strings themselves are part of the coupling surface but are not
   layout-dependent, so callers pass them through. */
static inline const char *slc_node_str(const SlcProgram *p, int id, const char *k) { return nt_str(p->an, id, k); }
static inline long long   slc_node_int(const SlcProgram *p, int id, const char *k, long long d) { return nt_int(p->an, id, k, d); }
static inline int         slc_node_ref(const SlcProgram *p, int id, const char *k) { return nt_ref(p->an, id, k); }
static inline const int  *slc_node_arr(const SlcProgram *p, int id, const char *k, int *n) { return nt_arr(p->an, id, k, n); }
static inline const char *slc_node_content(const SlcProgram *p, int id) { return nt_content(p->an, id); }

/* Generic child iteration (structural walks that do not know field names). */
static inline int         slc_num_refs(const SlcProgram *p, int id)          { return nt_num_refs(p->an, id); }
static inline int         slc_ref_at(const SlcProgram *p, int id, int i)     { return nt_ref_at(p->an, id, i); }
static inline int         slc_num_arrs(const SlcProgram *p, int id)          { return nt_num_arrs(p->an, id); }
static inline const int  *slc_arr_at(const SlcProgram *p, int id, int i, int *n) { return nt_arr_at(p->an, id, i, n); }

/* ==========================================================================
 * 1b. Pristine-parse field ENUMERATION -- for the `ast` dump mode [E087]
 *
 * The named-field READS above answer "give me field K of node N".  A structure
 * DUMP needs the reverse question -- "what fields does node N have, in which
 * category, under which names" -- which the nt_* API does not expose, so these
 * read the SpNode field arrays directly.  They are the reason the coupling
 * table (README) gained the SpStrField/SpIntField/SpRefField/SpArrField rows.
 *
 * All of them read the PRISTINE table (p->ast): the `ast` mode replaces
 * `spinel --dump-ast`, which prints the parse text BEFORE analysis mutates
 * anything, and the consumer (spinel-mlirgen) walks exactly that structure.
 * String values are returned with their length (SpStrField.val_len) because a
 * NUL byte inside a string literal is data, not a terminator (upstream #722).
 * ========================================================================== */

static inline int         slc_ast_ncount(const SlcProgram *p)  { return p->ast->count; }
static inline int         slc_ast_root(const SlcProgram *p)    { return p->ast->root_id; }
static inline const char *slc_ast_source_file(const SlcProgram *p) { return p->ast->source_file; }
static inline int         slc_ast_nfiles(const SlcProgram *p)  { return p->ast->nfiles; }
static inline const char *slc_ast_file(const SlcProgram *p, int i) { return p->ast->files[i]; }
static inline const char *slc_ast_type(const SlcProgram *p, int id) { return nt_type(p->ast, id); }
static inline const char *slc_ast_fcontent(const SlcProgram *p, int id) { return nt_content(p->ast, id); }

static inline const SpNode *slc_ast_node_(const SlcProgram *p, int id) { return &p->ast->nodes[id]; }
/* string fields */
static inline int         slc_ast_nstr(const SlcProgram *p, int id) { return slc_ast_node_(p, id)->ns; }
static inline const char *slc_ast_str_key(const SlcProgram *p, int id, int i) { return slc_ast_node_(p, id)->s[i].key; }
static inline const char *slc_ast_str_val(const SlcProgram *p, int id, int i, size_t *len) {
  const SpStrField *f = &slc_ast_node_(p, id)->s[i];
  if (len) *len = f->val_len;
  return f->val;
}
/* int fields. A node's four position ints (node_line, node_file, node_col,
   node_bi) are fields of its struct with a mask of which are set (upstream
   3fd464a5a), not entries of its int array. They are listed first, in
   NT_POS_KEYS order -- the order the parser emits them in, ahead of the
   node's other ints -- then the int array. */
static inline int slc_ast_npos_(const SpNode *n) {
  int c = 0;
  for (int k = 0; k < 4; k++) c += (n->posmask >> k) & 1;
  return c;
}
static inline int slc_ast_pos_slot_(const SpNode *n, int i) {
  for (int k = 0; k < 4; k++)
    if ((n->posmask >> k) & 1 && i-- == 0) return k;
  return -1;
}
static inline int slc_ast_nint(const SlcProgram *p, int id) {
  const SpNode *n = slc_ast_node_(p, id);
  return slc_ast_npos_(n) + n->ni;
}
static inline const char *slc_ast_int_key(const SlcProgram *p, int id, int i) {
  const SpNode *n = slc_ast_node_(p, id);
  int np = slc_ast_npos_(n);
  return i < np ? NT_POS_KEYS[slc_ast_pos_slot_(n, i)] : n->i[i - np].key;
}
static inline long long slc_ast_int_val(const SlcProgram *p, int id, int i) {
  const SpNode *n = slc_ast_node_(p, id);
  int np = slc_ast_npos_(n);
  return i < np ? n->pos[slc_ast_pos_slot_(n, i)] : n->i[i - np].val;
}
/* ref fields */
static inline int         slc_ast_nref(const SlcProgram *p, int id) { return slc_ast_node_(p, id)->nr; }
static inline const char *slc_ast_ref_key(const SlcProgram *p, int id, int i) { return slc_ast_node_(p, id)->r[i].key; }
static inline int         slc_ast_ref_val(const SlcProgram *p, int id, int i) { return slc_ast_node_(p, id)->r[i].ref; }
/* array fields */
static inline int         slc_ast_narr(const SlcProgram *p, int id) { return slc_ast_node_(p, id)->na; }
static inline const char *slc_ast_arr_key(const SlcProgram *p, int id, int i) { return slc_ast_node_(p, id)->a[i].key; }
static inline const int  *slc_ast_arr_val(const SlcProgram *p, int id, int i, int *n) {
  const SpArrField *f = &slc_ast_node_(p, id)->a[i];
  if (n) *n = f->n;
  return f->ids;
}

/* Positions. Kept in the contract ONLY so a reader can (a) print human-readable
   diagnostics and (b) reproduce / audit the old position-joined path. NOTHING
   in the new path may key a type lookup on these. */
static inline int slc_node_line(const SlcProgram *p, int id) { return (int)nt_int(p->an, id, "node_line", 0); }
static inline int slc_node_col(const SlcProgram *p, int id)  { return (int)nt_int(p->an, id, "node_col", 0); }
static inline int slc_node_file_id(const SlcProgram *p, int id) { return (int)nt_int(p->an, id, "node_file", 0); }
static inline const char *slc_file_path(const SlcProgram *p, int fid) {
  const char *path = nt_file_path(p->an, fid);
  if (!path) path = p->an->source_file;
  if (!path || !*path) path = "source.rb";
  return path;                       /* mirrors emit_file_path (src/codegen.c) */
}

/* ==========================================================================
 * 2. Types -- the whole point of the exercise
 * ========================================================================== */

/* The RAW per-node inferred type, exactly the array `build_types_json` reads.
   Deliberately not comp_ntype(): that applies codegen-time refinements
   (TY_STRBUF demotion, the yield-site hook) which the analysis result does not
   have, and which would make our dump differ from --emit-types for no reason. */
static inline TyKind slc_node_ty(const SlcProgram *p, int id) {
  if (id < 0 || id >= p->an->count || id >= p->c->node_cap) return TY_UNKNOWN;
  return p->c->ntype[id];
}
/* The codegen-facing view (TY_STRBUF demotion applied). A backend that emits
   code rather than reports types wants this one. */
static inline TyKind slc_node_ty_codegen(const SlcProgram *p, int id) { return comp_ntype(p->c, id); }

/* Owning scope index of a node (index into the scope table), -1 if none. */
static inline int slc_node_scope(const SlcProgram *p, int id) {
  if (id < 0 || id >= p->an->count || id >= p->c->node_cap) return -1;
  return p->c->nscope[id];
}

/* The legacy string tag ("int", "int_array", "obj_Foo"). Reproduces
   ty_tag_into (src/codegen.c, static) so a dump can be compared byte-for-byte
   with `--emit-types`. */
static inline void slc_ty_tag(const SlcProgram *p, TyKind t, char *out, size_t n) {
  if (ty_is_object(t)) {
    int cid = ty_object_class(t);
    if (cid >= 0 && cid < p->c->nclasses && p->c->classes[cid].name)
      snprintf(out, n, "obj_%s", p->c->classes[cid].name);
    else
      snprintf(out, n, "object");
    return;
  }
  snprintf(out, n, "%s", ty_name(t));
}

/* Classifiers the LLVM/MLIR side actually asks for. Named here so the callers
   never spell TyKind constants themselves. */
static inline int slc_ty_is_int(TyKind t)    { return t == TY_INT; }
static inline int slc_ty_is_bool(TyKind t)   { return t == TY_BOOL; }
static inline int slc_ty_is_float(TyKind t)  { return t == TY_FLOAT; }
static inline int slc_ty_is_poly(TyKind t)   { return t == TY_POLY; }
static inline int slc_ty_is_bigint(TyKind t) { return t == TY_BIGINT; }
static inline int slc_ty_is_unknown(TyKind t){ return t == TY_UNKNOWN; }
static inline int slc_ty_is_void(TyKind t)   { return t == TY_VOID; }
/* "unboxed scalar the canonical value ABI (`mrb_int(mrb_int,…)`) can carry". */
static inline int slc_ty_is_abi_scalar(TyKind t) { return t == TY_INT || t == TY_BOOL; }
/* "the analysis lost the unboxed representation here" -- what the ABI gate and
   the freestanding subset gate both actually want to refuse. */
static inline int slc_ty_is_boxed(TyKind t) { return t == TY_POLY || ty_is_object(t); }

/* ==========================================================================
 * 3. Scopes (one per `def`; scope 0 is the top level) = the method table
 * ========================================================================== */

static inline int    slc_nscopes(const SlcProgram *p)       { return p->c->nscopes; }
static inline Scope *slc_scope(const SlcProgram *p, int i)  { return &p->c->scopes[i]; }

static inline const char *slc_scope_name(const Scope *s)      { return s->name; }
static inline int         slc_scope_def_node(const Scope *s)  { return s->def_node; }
static inline int         slc_scope_body(const Scope *s)      { return s->body; }
static inline int         slc_scope_class_id(const Scope *s)  { return s->class_id; }
static inline int         slc_scope_reachable(const Scope *s) { return s->reachable; }
static inline int         slc_scope_is_cmethod(const Scope *s){ return s->is_cmethod; }
static inline int         slc_scope_yields(const Scope *s)    { return s->yields; }
static inline TyKind      slc_scope_ret(const Scope *s)       { return s->ret; }
static inline int         slc_scope_nparams(const Scope *s)   { return s->nparams; }
/* nrequired is "index past the LAST required param", NOT a count (upstream
   comment on the field). Exposed under a name that says so. */
static inline int         slc_scope_required_end(const Scope *s) { return s->nrequired; }
static inline int         slc_scope_rest_idx(const Scope *s)  { return s->rest_idx; }
static inline int         slc_scope_kwrest_idx(const Scope *s){ return s->kwrest_idx; }
static inline const char *slc_scope_pname(const Scope *s, int i) { return s->pnames[i]; }
static inline int         slc_scope_pdefault(const Scope *s, int i) { return s->pdefault ? s->pdefault[i] : -1; }
static inline const char *slc_scope_blk_param(const Scope *s) { return s->blk_param; }

/* Locals (params first, then body locals). */
static inline int         slc_scope_nlocals(const Scope *s)        { return s->nlocals; }
static inline const char *slc_local_name(const Scope *s, int k)    { return s->locals[k].name; }
static inline TyKind      slc_local_type_at(const Scope *s, int k) { return s->locals[k].type; }
static inline int         slc_local_is_param_at(const Scope *s, int k) { return s->locals[k].is_param; }
static inline int         slc_local_is_cell_at(const Scope *s, int k)  { return s->locals[k].is_cell; }
/* An unboxed scalar slot that can hold the reserved nil sentinel -- the
   property a `mrb_int` boundary cannot express (E018 §6's SP_INT_NIL story). */
static inline int         slc_local_nullable_int_at(const Scope *s, int k) { return s->locals[k].nullable_int; }

/* Resolve a local by name within a scope (upstream scope_local; NULL if none). */
static inline LocalVar   *slc_local(Scope *s, const char *name) { return scope_local(s, name); }
static inline TyKind      slc_local_type(const LocalVar *v)     { return v ? v->type : TY_UNKNOWN; }
static inline int         slc_local_is_param(const LocalVar *v) { return v ? v->is_param : 0; }

/* Parameter type by index: the ONE query the ABI gate needs. Before E041 this
   was answered by string-matching the generated C prototype
   (`static mrb_int sp_<name>(mrb_int lv_<p>, ...);`), which drifted twice
   (E040 §1: `inline`, then `__attribute__((always_inline))`). */
static inline TyKind slc_param_type(Scope *s, int i) {
  if (i < 0 || i >= s->nparams) return TY_UNKNOWN;
  LocalVar *v = scope_local(s, s->pnames[i]);
  return (v && v->type != TY_UNKNOWN) ? v->type : TY_POLY;
}

/* Top-level (class_id < 0) method scope index by name, or -1. */
static inline int slc_method_index(const SlcProgram *p, const char *name) {
  return comp_method_index(p->c, name);
}

/* ==========================================================================
 * 4. Classes
 * ========================================================================== */

static inline int        slc_nclasses(const SlcProgram *p)      { return p->c->nclasses; }
static inline ClassInfo *slc_class(const SlcProgram *p, int i)  { return &p->c->classes[i]; }
static inline const char *slc_class_name(const ClassInfo *cl)   { return cl->name; }
static inline const char *slc_class_c_name(const ClassInfo *cl) { return cl->c_name; }
static inline int         slc_class_parent(const ClassInfo *cl) { return cl->parent; }
static inline int         slc_class_def_node(const ClassInfo *cl) { return cl->def_node; }
static inline int         slc_class_nivars(const ClassInfo *cl)  { return cl->nivars; }
static inline const char *slc_class_ivar_name(const ClassInfo *cl, int j) { return cl->ivars[j]; }
static inline TyKind      slc_class_ivar_type(const ClassInfo *cl, int j) { return cl->ivar_types[j]; }

/* ==========================================================================
 * 5. Global variables ($g)  [E093, P008 Phase 3]
 * ==========================================================================
 * The Compiler keeps ONE whole-program entry per global (Compiler.gvars, a
 * LocalVar table keyed by the name WITHOUT the '$'), and its `type` is the
 * widened type every write to that global agreed on.  That is exactly the
 * question arenacheck asks -- "does anything that outlives the request hold a
 * heap value?" -- so the escape check reads the inferred type here rather than
 * re-deriving it from the write sites (E018 罠 3: a position join over the
 * value expressions is ambiguous, and a widening across two writes is only
 * visible in this table).
 * Alias resolution ($copy -> $orig) is upstream's; comp_resolve_gvar is the
 * accessor for it. */

static inline int         slc_ngvars(const SlcProgram *p)     { return p->c->ngvars; }
/* Name WITHOUT the leading '$' (upstream stores it that way). */
static inline const char *slc_gvar_name(const SlcProgram *p, int i) { return p->c->gvars[i].name; }
static inline TyKind      slc_gvar_type(const SlcProgram *p, int i) { return p->c->gvars[i].type; }
static inline const char *slc_gvar_resolve(const SlcProgram *p, const char *name) {
  return comp_resolve_gvar(p->c, name);
}

#endif /* SPINEL_LLVM_CONTRACT_H */
