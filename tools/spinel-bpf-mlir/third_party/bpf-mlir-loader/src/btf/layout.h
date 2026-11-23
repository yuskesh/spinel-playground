/* CONTRACT: record table of the ELF BTF.
 *
 * Parse applies the boundary checks (header ranges in uint64, string table ending in NUL, type records inside the range by kind and vlen)
 * and the stable English error text byte for byte. The recursion in spell (array elements) has no limit in Go,
 * where a cyclic BTF overflows the stack; C stops at depth 64 with "?btf_kind_0" (a known difference). */
#ifndef BML_BTF_LAYOUT_H
#define BML_BTF_LAYOUT_H

#include <stddef.h>
#include <stdint.h>

struct lmember {
	const char *name; /* raw の中 (NUL 終端) */
	uint32_t type_id, offset;
};

/* DATASEC の var_secinfo (Go の varSecinfo — E308)。pos は offset の field の .BTF の section の中の byte の位置 (.rel.BTF の r_offset と比べる) */
struct lsecinfo {
	uint32_t type_id, offset, size, pos;
};

struct ltype {
	uint32_t kind;
	const char *name;
	int is_signed;
	uint32_t size, type_id, nelems;
	struct lmember *members;
	uint32_t n_members;
	int bitfield;
	struct lsecinfo *secinfo;
	uint32_t n_secinfo;
};

struct lbtf {
	struct ltype *t;
	size_t n;
};

/* 表の文字列の 1 つの member (offset の順に並べる — 同じ offset は元の順 idx) */
struct btf_indexed {
	struct {
		const char *name;
		uint32_t offset;
		char *type;
	} m;
	size_t idx;
};

/* ELF の .BTF を読む (go/layout の parseBTF)。失敗は -1 と *err (malloc — Go の文、または壊れた BTF の C の文) */
int btf_layout_parse(const void *elf_data, size_t elf_len, struct lbtf *b, char **err);
void btf_layout_free(struct lbtf *b);
/* typedef・const・volatile・restrict・type_tag を剥がす (Go の resolve — 深さ 32、範囲の外と上限は kind 0 の空の型) */
const struct ltype *btf_layout_resolve(const struct lbtf *b, uint32_t id);
/* 名前の STRUCT の表の文字列 (BTFRecords の lookup — malloc)。無ければ NULL と *missing */
char *btf_layout_record(const struct lbtf *b, const char *name, int *missing);
/* size=N;name:off:type;… (ms を offset の順に安定に並べ替える — malloc) */
char *btf_shape_string(uint32_t size, struct btf_indexed *ms, size_t n);

#endif
