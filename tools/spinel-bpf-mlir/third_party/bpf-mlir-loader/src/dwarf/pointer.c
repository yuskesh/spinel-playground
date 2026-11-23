/* dwarf/pointer.c — 形式 18 の uprobe の引数の型 ptr の DWARF の綴り (bpf-mlir E559 の go/requirements/uprobe_pointer.go の dwarfPointerSpelling の
 * 写し — E057)。Data.Type を使わず DIE を直接歩く (pointer の先の member 等は decode しない)。typedef / const / volatile / restrict を剥がす鎖は
 * 外側と先で各 64 回まで、再訪は共有の offset の集合で Unknown。修飾の DW_AT_type の欠けは void、typedef の欠けと壊れた参照・atomic・知らない tag は
 * Unknown。幅は正の DW_AT_byte_size か、その pointer の DIE を含む unit の address_size。"" は Unknown (malloc の文字列で返す) */
#include "dwarf/internal.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "util/mutation.h"

struct walk {
	struct dw *d;
	uint64_t *seen;
	size_t n, cap;
	int oom;
};

/* 読んだ entry の tag と、DW_AT_type・DW_AT_byte_size と unit の asize。1 は読めた、0 は読めない・再訪 */
struct die {
	uint64_t off, tag;
	int has_type, type_ok, has_size, size_ok;
	uint64_t type;
	int64_t size;
	int asize;
};

static int read_die(struct walk *w, uint64_t off, struct die *out)
{
	for (size_t i = 0; i < w->n; i++)
		if (w->seen[i] == off)
			return 0;
	if (w->n == w->cap) {
		size_t nc = w->cap ? w->cap * 2 : 16;
		uint64_t *ns = realloc(w->seen, nc * sizeof *ns);
		if (!ns)
			return (w->oom = 1, 0);
		w->seen = ns, w->cap = nc;
	}
	w->seen[w->n++] = off;
	struct dw_reader r;
	dw_reader_init(&r, w->d);
	dw_seek(&r, off);
	struct dw_entry e;
	int k = r.err ? -1 : dw_next(&r, &e);
	int ok = k == 1 && e.off == off;
	if (ok) {
		memset(out, 0, sizeof *out);
		out->off = off, out->tag = e.tag;
		out->asize = w->d->u[r.unit].asize;
		const struct dw_val *t = dw_val(&e, 0x49), *s = dw_val(&e, 0x0b); /* DW_AT_type・DW_AT_byte_size */
		out->has_type = t != NULL, out->type_ok = t && t->kind == DV_OFF, out->type = t ? t->u : 0;
		out->has_size = s != NULL, out->size_ok = s && s->kind == DV_INT, out->size = s ? s->i : 0;
	}
	if (k == 1)
		dw_entry_free(&e);
	dw_reader_free(&r);
	return ok;
}

/* strip: 修飾を剥がした終点 (*out)。1 は既知の tag、0 は Unknown */
static int strip(struct walk *w, uint64_t off, struct die *out)
{
	for (int n = 0; n < 64; n++) {
		if (!read_die(w, off, out))
			return 0;
		switch (out->tag) {
		case 0x16: case 0x26: case 0x35: case 0x37: /* typedef・const・volatile・restrict */
			if (out->tag != 0x16 && !out->has_type) { /* 修飾の void (DWARF は型の参照を省く) */
				out->tag = 0x3b;              /* unspecified_type */
				return 1;
			}
			if (!out->type_ok)
				return 0;
			off = out->type;
			break;
		case 0x0f: case 0x24: case 0x13: case 0x02: case 0x17: case 0x01: case 0x04: case 0x15: case 0x3b: case 0x10: case 0x42:
			return 1; /* pointer・base・struct・class・union・array・enum・subroutine・unspecified・reference・rvalue_reference */
		default:          /* atomic (0x47) と知らない tag */
			return 0;
		}
	}
	return 0;
}

char *dw_pointer_spelling(struct dw *d, uint64_t off)
{
	struct walk w = {d, NULL, 0, 0, 0};
	struct die e, p;
	char buf[64] = "";
	int64_t width;
	if (!strip(&w, off, &e))
		goto out;
	if (e.tag != 0x0f) {
		snprintf(buf, sizeof buf, "non-pointer");
		goto out;
	}
	width = e.asize;
	if (e.has_size) {
		if (!e.size_ok || e.size <= 0)
			goto out;
		width = e.size; /* Go は int (64 bit) に切り詰めずに出す */
	}
	if (width <= 0)
		goto out;
	int deep = 0;
	if (e.has_type) {
		if (!e.type_ok || !strip(&w, e.type, &p))
			goto out;
		deep = p.tag == 0x0f && !BML_MUT("dwarf.ptr_depth_any");
	}
	if (!deep && width == 8)
		snprintf(buf, sizeof buf, "ptr");
	else
		snprintf(buf, sizeof buf, deep ? "ptr(depth>=2,width=%lld)" : "ptr(depth=1,width=%lld)", (long long)width);
out:
	free(w.seen);
	return w.oom ? NULL : strdup(buf);
}
