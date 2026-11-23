/* req/parse_v11.c — 形式の版 11 の付随の行 tpfield・extret・extarg・structop の読み (bpf-mlir E425 の go/requirements/companion_v11.go の
 * parseV11Companion の写し — E036)。並び: trace_tp → tpfield (offset の狭義の昇順)、freplace → extret (1 つ) → extarg (index は 0 から連続)、
 * trace_struct_ops → structop (1 つ) → retsig → farg (retsig と farg は parse.c)。 */
#include "req/parse_internal.h"
#include "util/mutation.h"

#include <stdio.h>
#include <string.h>

/* 0 は読めた、-1 は誤り (e に)、-2 は memory の不足 */
int req_v11_companion(struct bml_requirements *r, struct field *f, struct field line, int n, struct bml_parse_error *e)
{
	const char *want = req_eq(f[0], "tpfield") ? "trace_tp" : req_eq(f[0], "structop") ? "trace_struct_ops" : "freplace";
	const char *row = req_eq(f[0], "tpfield") ? "tpfield" : req_eq(f[0], "extret") ? "extret" : req_eq(f[0], "extarg") ? "extarg" : "structop";
	struct bml_attach *a = r->n_attaches ? &r->attaches[r->n_attaches - 1] : NULL;
	if (!a || !req_str_eq(&a->program, f[1]) || !req_str_eq_lit(&a->attach_type, want))
		return req_perr(e, n, row, "order", "%s line %d: %s row out of order %q", SEC, (int64_t)n, row, Q(line));
	if (req_eq(f[0], "tpfield")) {
		/* bpf-mlir E552 (E054): byte の配列 [N]u8 / [N]i8 は版 17 から — strptr・strarray (E546 / E548 — E053) の版 16 の検査と値の検査の前 */
		int array = f[5].n > 0 && f[5].p[0] == '[' && req_kfield_type_ok(f[5]); /* validKFieldByteArray — 綴りは 6 byte まで */
		if (array && r->version < 17 && !BML_MUT("parse.v17_rows_any_version")) {
			char t[8] = {0};
			memcpy(t, f[5].p, f[5].n);
			return req_perr(e, n, row, "min_version", "%s line %d: tpfield type %s needs version 17", SEC, (int64_t)n, t);
		}
		int str = req_eq(f[5], "strptr") || req_eq(f[5], "strarray");
		if (str && r->version < 16 && !BML_MUT("parse.v16_rows_any_version"))
			return req_perr(e, n, row, "min_version", "%s line %d: tpfield type %s needs version 16", SEC, (int64_t)n,
					req_eq(f[5], "strptr") ? "strptr" : "strarray");
		int64_t off, b;
		int e1 = bml_go_atoi(f[3].p, f[3].n, &off), e2 = bml_go_atoi(f[4].p, f[4].n, &b);
		int valid = (b == 1 || b == 2 || b == 4 || b == 8) && (req_eq(f[5], "i") || req_eq(f[5], "u") || (str && b == 8));
		if (array) { /* f[5] が fmt.Sprintf("[%d]u8", b) か "[%d]i8" */
			char u[32], s[32];
			snprintf(u, sizeof u, "[%lld]u8", (long long)b), snprintf(s, sizeof s, "[%lld]i8", (long long)b);
			valid = req_eq(f[5], u) || req_eq(f[5], s);
		}
		if (e1 || e2 || off < 0 || !valid || !req_valid_cname(f[2]))
			return req_perr(e, n, row, "value", "%s line %d: bad tpfield row %q", SEC, (int64_t)n, Q(line));
		if (a->n_tpfields > 0 && off <= a->tpfields[a->n_tpfields - 1].offset)
			return req_perr(e, n, row, "order", "%s line %d: %s row out of order %q", SEC, (int64_t)n, row, Q(line));
		if (GROW(a->tpfields, a->n_tpfields, a->cap_tpfields))
			return -2;
		struct bml_tpfield *t = &a->tpfields[a->n_tpfields];
		memset(t, 0, sizeof *t);
		a->n_tpfields++;
		t->offset = off;
		t->bytes = b;
		if (req_mkstr(&t->field, f[2]) || req_mkstr(&t->sign, f[5]))
			return -2;
		return 0;
	}
	if (req_eq(f[0], "extret")) {
		if (a->ext_nargs >= 0)
			return req_perr(e, n, row, "order", "%s line %d: %s row out of order %q", SEC, (int64_t)n, row, Q(line));
		int64_t na;
		if (bml_go_atoi(f[2].p, f[2].n, &na) || na < 0 || !(req_valid_int_spelling(f[3]) || req_eq(f[3], "void")))
			return req_perr(e, n, row, "value", "%s line %d: bad extret row %q", SEC, (int64_t)n, Q(line));
		a->ext_nargs = na;
		return req_mkstr(&a->ext_ret, f[3]) ? -2 : 0;
	}
	if (req_eq(f[0], "extarg")) {
		if (a->ext_nargs < 0)
			return req_perr(e, n, row, "order", "%s line %d: %s row out of order %q", SEC, (int64_t)n, row, Q(line));
		int64_t idx;
		if (bml_go_atoi(f[2].p, f[2].n, &idx) || !(req_eq(f[3], "-") || req_valid_int_spelling(f[3])))
			return req_perr(e, n, row, "value", "%s line %d: bad extarg row %q", SEC, (int64_t)n, Q(line));
		if (idx != (int64_t)a->n_ext_args)
			return req_perr(e, n, row, "order", "%s line %d: %s row out of order %q", SEC, (int64_t)n, row, Q(line));
		if (idx >= a->ext_nargs)
			return req_perr(e, n, row, "value", "%s line %d: extarg index %d is not below the extret argument count %d %q", SEC, (int64_t)n, idx,
					a->ext_nargs, Q(line));
		if (GROW(a->ext_args, a->n_ext_args, a->cap_ext_args) || req_mkstr(&a->ext_args[a->n_ext_args], f[3]))
			return -2;
		a->n_ext_args++;
		return 0;
	}
	/* structop */
	if (a->sop_struct.len != 0)
		return req_perr(e, n, row, "order", "%s line %d: %s row out of order %q", SEC, (int64_t)n, row, Q(line));
	if (!req_valid_cname(f[2]) || !req_valid_cname(f[3]))
		return req_perr(e, n, row, "value", "%s line %d: bad structop row %q", SEC, (int64_t)n, Q(line));
	return req_mkstr(&a->sop_struct, f[2]) || req_mkstr(&a->sop_member, f[3]) ? -2 : 0;
}
