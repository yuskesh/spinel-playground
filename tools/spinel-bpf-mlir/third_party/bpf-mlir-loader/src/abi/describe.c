/* abi/describe.c — load した object の map の宣言を ELF の requirements の map の行から返す (E007 — 名前だけで ring buffer を開く
 * spinel の形の shim が使う)。宣言は ELF 自身の行なので、その宣言での照合は ELF と必ず一致する — 呼び手が宣言を持たない形
 * (spinel の ringbuf_open は map の type だけを見る) と同じ強さで、照合を落とす入口ではない。 */
#include "abi/internal.h"

#include <stdlib.h>
#include <string.h>

#include <bpf/libbpf.h>

#include "btf/layout.h"
#include "util/gostr.h"

/* JSON の文字列に escape なしで入る (ASCII の表示できる文字で " と \ を含まない) */
static int plain(const struct bml_str *s)
{
	for (size_t i = 0; i < s->len; i++)
		if (s->p[i] < 0x20 || s->p[i] > 0x7e || s->p[i] == '"' || s->p[i] == '\\')
			return 0;
	return 1;
}

/* record:<S> の ELF の BTF の STRUCT の大きさ (無ければ -1) */
static int64_t struct_size(const struct abi_object *o, const char *name)
{
	struct lbtf b;
	char *err = NULL;
	if (btf_layout_parse(o->elf, o->elf_len, &b, &err) != 0) {
		free(err);
		return -1;
	}
	int64_t size = -1;
	for (size_t i = 0; i < b.n; i++)
		if (b.t[i].kind == 4 && !strcmp(b.t[i].name, name))
			size = b.t[i].size;
	btf_layout_free(&b);
	return size;
}

static int64_t map_describe_body(int64_t obj, const char *name, int64_t name_len)
{
	int64_t e;
	struct abi_object *o = abi_object_get(obj, &e);
	if (!o)
		return e;
	if (name_len < 0 || (!name && name_len))
		return abi_fail(BML_OTHER, "bml: a negative length or a NULL string with a length");
	const struct bml_map *row = NULL;
	for (size_t k = 0; k < o->req->n_maps; k++) {
		const struct bml_map *m = &o->req->maps[k];
		if (m->symbol.len == (size_t)name_len && (name_len == 0 || !memcmp(m->symbol.p, name, (size_t)name_len)))
			row = m; /* bindrt の rows[m.Symbol] = i と同じ後勝ち */
	}
	struct bpf_map *bm = row ? bpf_object__find_map_by_name(bml_obj_bpf(o->lo), row->symbol.p) : NULL;
	if (!row || !bm) {
		struct bml_buf b = {0};
		bml_buf_adds(&b, "bml: the embedded ELF has no map ");
		bml_buf_add_goquote(&b, name ? name : "", (size_t)name_len);
		struct abi_result r = {.kind = BML_STATE, .msg_len = b.len};
		r.msg = bml_buf_take(&b);
		return abi_put(&r);
	}
	if (!plain(&row->symbol) || !plain(&row->map_type) || !plain(&row->key) || !plain(&row->value))
		return abi_fail(BML_OTHER, "bml: map %s: the requirements row has characters that a declaration cannot carry", row->symbol.p);
	int64_t size = bpf_map__value_size(bm);
	if (!strncmp(row->value.p, "record:", 7)) {
		size = struct_size(o, row->value.p + 7);
		if (size < 0)
			return abi_fail(BML_MAP_MISMATCH, "bml: map %s: the ELF BTF has no struct %s", row->symbol.p, row->value.p + 7);
	}
	struct bml_buf b = {0};
	bml_buf_addf(&b, "{\"name\":\"%s\",\"kind\":\"%s\",\"key\":\"%s\",\"value\":\"%s\",\"max_entries\":%llu,\"flags\":%llu}", row->symbol.p,
		     row->map_type.p, row->key.p, row->value.p, (unsigned long long)row->max_entries, (unsigned long long)row->flags);
	struct abi_result r = {.kind = BML_OK, .value = size, .msg_len = b.len};
	r.msg = bml_buf_take(&b);
	return abi_put(&r);
}

/* 走っている呼び出しとして数える (E006 の後半 — run.c の注) */
int64_t bml_map_describe(int64_t obj, const char *name, int64_t name_len)
{
	int64_t e;
	struct abi_object *o = abi_object_acquire(obj, &e);
	if (!o)
		return e;
	e = map_describe_body(obj, name, name_len);
	abi_object_release(o);
	return e;
}
