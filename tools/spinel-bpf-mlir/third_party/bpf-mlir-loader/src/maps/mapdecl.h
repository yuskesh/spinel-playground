/* mapdecl.h — map の宣言と record の照合 (bpf-mlir docs/requirements_format.md §12、go/bindrt/mapdecl.go と go/layout の
 * BTFRecords・parseBTF・spell の写し — E003) */
#ifndef BML_MAPDECL_H
#define BML_MAPDECL_H

#include <stddef.h>
#include <stdint.h>

#include "json/json.h"
#include "req/req.h"

struct bml_map_decl {
	char *name, *kind, *key, *value;
	uint64_t max_entries;
	int has_flags; /* Go の *uint64 が nil でない */
	uint64_t flags;
	int has_map_extra;
	uint64_t map_extra; /* E061: arena only; absent and explicit zero are distinct. */
	/* bpf-mlir E460 (E039): innermap の雛形 (任意 — Go の *InnerDecl が nil でない)。flags と max_entries の省略は 0 */
	int has_inner;
	char *inner_kind, *inner_key, *inner_value;
	uint64_t inner_max_entries, inner_flags;
	char *struct_ops; /* bpf-mlir E485 (E042): 宣言の struct_ops の綴り (NULL は無し — 照合しない) */
};

struct bml_record_member {
	char *name;
	uint32_t offset;
	char *type;
};

struct bml_record_decl {
	char *name;
	uint32_t size;
	struct bml_record_member *members;
	size_t n_members;
};

/* global 変数の宣言 (E308 — section は "rodata" / "bss"、type は u8…i64 (be を許す)) */
struct bml_global_decl {
	char *name, *section, *type;
};

struct bml_map_decls {
	int allow_undeclared;
	int has_maps; /* "maps" の key が在り null でない (Go の Maps が nil でない — 下流の load は nil を誤りにする) */
	struct bml_map_decl *maps;
	size_t n_maps;
	struct bml_record_decl *records;
	size_t n_records;
	/* E308: has_globals は Go の Globals が nil でない ("globals" の key が在り null でない — `[]` は「global は無い」の宣言)。
	 * 0 なら global を照合しない */
	int has_globals;
	struct bml_global_decl *globals;
	size_t n_globals;
	int allow_undeclared_globals;
};

struct bml_map_problem {
	char *map;
	const char *field; /* missing_in_elf・undeclared・kind・key・value・max_entries・flags・decl・format・record・record_missing・
			      global・global_missing_in_elf・global_undeclared (E308) */
	char *declared, *elf;
};

struct bml_map_problems {
	struct bml_map_problem *p;
	size_t n, cap;
};

/* maps.json を読む (Go の MapDecls への DisallowUnknownFields の decode の規則 + E002 の厳しい JSON)。失敗は -1 と *err */
int bml_map_decls_parse(const char *data, size_t len, struct bml_map_decls *out, char **err);
/* 同じ、§13 の規則付き */
int bml_map_decls_parse_rule(const char *data, size_t len, struct bml_map_decls *out, char **err, enum bml_json_rule *rule);
void bml_map_decls_free(struct bml_map_decls *d);
/* 宣言 1 つ (Go の DecodeStrictJSON(&MapDecl) — E006 の map の操作)。失敗は -1 と *err */
int bml_map_decl_parse_one(const char *data, size_t len, struct bml_map_decl *out, char **err);
void bml_map_decl_free(struct bml_map_decl *x);
/* records の文書 (map[string]RecordDecl) — *is_null は null の文書。records だけが入る */
int bml_record_decls_parse(const char *data, size_t len, struct bml_map_decls *out, int *is_null, char **err);

/* Parsed.CheckMapDecls。elf は requirements の section だけのとき NULL (records は format の問題)。問題は *out (呼び手が解放)。
 * 返り値: 0 は一致 (out は空)、1 は食い違い、-1 は memory の不足 */
int bml_check_map_decls(const struct bml_requirements *req, const void *elf, size_t elf_len, const struct bml_map_decls *d,
			struct bml_map_problems *out);
void bml_map_problems_free(struct bml_map_problems *v);
/* MapDeclProblem.String (malloc) */
char *bml_map_problem_string(const struct bml_map_problem *p);

#endif
