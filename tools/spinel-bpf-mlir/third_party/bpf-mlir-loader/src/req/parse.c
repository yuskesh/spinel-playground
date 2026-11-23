/* req_parse.c — requirements.Parse (bpf-mlir go/requirements/requirements.go:120-388) の写し (E002)。
 *
 * 分岐の順・規則・誤りの文は Go のまま。行は bufio.Scanner の ScanLines (末尾の \r を 1 つ外す・64 KiB 以上の行で走査を止める)、
 * field は strings.Split(line, "\t")、数は strconv の 10 進 (gostr.c)。 */
#include "req/parse_internal.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "util/mutation.h"

#define OOM() goto oom

int bml_req_parse(const char *data, size_t len, struct bml_requirements **out, struct bml_parse_error *e)
{
	struct scanner sc = {.data = data, .len = len};
	*out = NULL;
	memset(e, 0, sizeof(*e));
	e->row = "";
	e->rule = "";
	if (!req_scan(&sc))
		return req_perr(e, 1, "", "header", "%s: empty", SEC);
	struct bml_requirements *r = calloc(1, sizeof(*r));
	if (!r)
		return req_perr(e, 0, "", "", "out of memory");
	for (int v = 1; v <= BML_MAX_FORMAT_VERSION + BML_MUT("parse.version_max19"); v++) {
		char h[32];
		int hn = snprintf(h, sizeof(h), "ebpf-requirements %d", v);
		if (sc.tok.n == (size_t)hn && memcmp(sc.tok.p, h, (size_t)hn) == 0)
			r->version = v;
	}
	if (r->version == 0) {
		bml_requirements_free(r);
		return req_perr(e, 1, "", "header", "%s: unknown header %q (want \"ebpf-requirements 1\" .. \"%d\")", SEC,
			    Q(sc.tok), (int64_t)BML_MAX_FORMAT_VERSION);
	}
	struct field *fields = calloc(MAXF, sizeof(*fields));
	if (!fields)
		OOM();
	int n = 1;
	long last_map = -1; /* E039: 直前の行が map の行ならその添字 (innermap の位置) */
	int last_attach = 0; /* E042 (bpf-mlir E499): 物理的に直前の行が attach の行か (field の数の検めの前に — Go の lastPhysicalRow) */
	while (req_scan(&sc)) {
		n++;
		struct field line = sc.tok;
		struct field *f = fields;
		size_t nf = req_split(line, f);
		int after_attach = last_attach;
		last_attach = req_eq(f[0], "attach");
		const struct bml_row_kind *rk = req_row_kind(f[0]);
		struct field *guarded = NULL;
		size_t ng = 0;
		int has_guarded = 0;
		if (rk && !(req_eq(f[0], "map") && r->version < 2) && nf > (size_t)rk->fields && req_eq(f[rk->fields], "guarded")) {
			guarded = &f[rk->fields + 1];
			ng = nf - (size_t)rk->fields - 1;
			nf = (size_t)rk->fields;
			has_guarded = 1;
			if (!req_eq(f[0], "ksymvar") && !req_eq(f[0], "kfield") && r->version >= rk->min_version) {
				req_perr(e, n, rk->name, "guard_kind", "%s line %d: only ksymvar and kfield rows can be guarded, got %q", SEC, (int64_t)n, Q(line));
				goto fail;
			}
			if (r->version < 24) {
				req_perr(e, n, rk->name, "min_version", "%s line %d: the guarded suffix needs version %d", SEC, (int64_t)n, (int64_t)24);
				goto fail;
			}
		}
		size_t want = 4;
		if (rk && !(req_eq(f[0], "map") && r->version < 2))
			want = (size_t)rk->fields;
		if (rk && req_eq(f[0], "kfunc") && nf >= want && nf <= 9) /* bpf-mlir E480 (E041): RowMaxFields — kfunc は 4..9 */
			want = nf;
		if (nf != want) {
			if (!rk)
				goto fail_unknown_fields;
			req_perr(e, n, rk->name, "fields", "%s line %d: want %d tab-separated fields, got %q", SEC, (int64_t)n,
			     (int64_t)want, Q(line));
			goto fail;
		}
		if (!rk) {
			req_perr(e, n, "", "unknown_kind", "%s line %d: unknown row kind %q", SEC, (int64_t)n, Q(f[0]));
			goto fail;
		}
		const char *row = rk->name;
		if (r->version < rk->min_version && !(BML_MUT("parse.v9_rows_any_version") && req_eq(f[0], "ctxaccess")) &&
		    !(BML_MUT("parse.v12_rows_any_version") && rk->min_version == 12) && !(BML_MUT("parse.v13_rows_any_version") && rk->min_version == 13) &&
		    !(BML_MUT("parse.v14_rows_any_version") && rk->min_version == 14) &&
		    !(BML_MUT("parse.fibflags_any_version") && req_eq(f[0], "fibflags")) && !(BML_MUT("parse.target_rows_any_version") && rk->min_version >= 31)) {
			if (req_eq(f[0], "schema"))
				req_perr(e, n, row, "min_version", "%s line %d: bad schema row %q", SEC, (int64_t)n, Q(line));
			else
				req_perr(e, n, row, "min_version", "%s line %d: %s rows need version %d", SEC, (int64_t)n, row,
				     (int64_t)rk->min_version);
			goto fail;
		}
		/* bpf-mlir E456 (版 12 — E039): 行の前の pending の検め (multi の mtarget の不足・of_maps の innermap) と版 12 の行 (parse_v12.c) */
		long after_map = last_map;
		last_map = -1;
		if (req_v12_pending(r, n, row, after_map, e))
			goto fail;
		if (req_eq(f[0], "arena") || req_eq(f[0], "datakptr") || req_eq(f[0], "enumval") || req_eq(f[0], "coreenum") ||
		    req_eq(f[0], "fibflags") || req_eq(f[0], "kstructsize") || req_eq(f[0], "ksymvar") || req_eq(f[0], "kconfig") || req_eq(f[0], "guard")) {
			int rc;
			if (req_eq(f[0], "arena") || req_eq(f[0], "datakptr")) rc = req_parse_loader_row(r, f, line, n, e);
			else if (req_eq(f[0], "guard")) rc = req_parse_guard(r, f, line, n, e);
			else if (req_eq(f[0], "ksymvar") || req_eq(f[0], "kconfig")) rc = req_parse_extern(r, f, guarded, ng, has_guarded, line, n, e);
			else rc = req_parse_kernel_value(r, f, line, n, e);
			if (rc == -2) OOM();
			if (rc) goto fail;
			continue;
		}
		if (req_eq(f[0], "helper_target") || req_eq(f[0], "sleepable")) { /* E066 — parse_target_rows.c */
			int rc = req_parse_target_row(r, f, line, n, after_attach, e);
			if (rc == -2) OOM();
			if (rc) goto fail;
			continue;
		}
		if (req_eq(f[0], "sysarg") || req_eq(f[0], "mtargetarg") || req_eq(f[0], "kfunc") || req_eq(f[0], "tpbuf")) { /* E041 — parse_v13.c、E042 — parse_v14.c */
			int rc = req_eq(f[0], "tpbuf")	 ? req_v14_tpbuf(r, f, line, n, after_attach, e)
				 : req_eq(f[0], "kfunc") ? req_v13_kfunc(r, f, nf, line, n, e)
							 : req_v13_companion(r, f, line, n, e);
			if (rc == -2)
				OOM();
			if (rc)
				goto fail;
			continue;
		}
		if (req_eq(f[0], "mtarget") || req_eq(f[0], "usdtsem") || req_eq(f[0], "usdtarg") || req_eq(f[0], "innermap")) {
			int rc = req_eq(f[0], "innermap") ? req_v12_innermap(r, f, line, n, after_map, e) : req_v12_companion(r, f, line, n, e);
			if (rc == -2)
				OOM();
			if (rc)
				goto fail;
			continue;
		}
		if (req_eq(f[0], "schema")) {
			if (r->schema_sha256.len != 0) {
				req_perr(e, n, row, "order", "%s line %d: bad schema row %q", SEC, (int64_t)n, Q(line));
				goto fail;
			}
			if (!req_eq(f[1], "sha256") || f[2].n != 64) {
				req_perr(e, n, row, "value", "%s line %d: bad schema row %q", SEC, (int64_t)n, Q(line));
				goto fail;
			}
			if (req_mkstr(&r->schema_sha256, f[2]))
				OOM();
			continue;
		}
		if (req_eq(f[0], "btf")) {
			if (!bml_known_btf_feature(f[1].p, f[1].n)) {
				req_perr(e, n, row, "value", "%s line %d: unknown BTF feature %q", SEC, (int64_t)n, Q(f[1]));
				goto fail;
			}
			int mv = req_btf_feature_min_version(f[1]); /* bpf-mlir E480 (E041): type_tag は版 13 から */
			if (r->version < mv && !BML_MUT("parse.v13_rows_any_version")) {
				req_perr(e, n, row, "min_version", "%s line %d: BTF feature %q needs version %d", SEC, (int64_t)n, Q(f[1]), (int64_t)mv);
				goto fail;
			}
			if (GROW(r->btf_features, r->n_btf_features, r->cap_btf_features) ||
			    req_mkstr(&r->btf_features[r->n_btf_features], f[1]))
				OOM();
			r->n_btf_features++;
			continue;
		}
		if (req_eq(f[0], "tailslot")) {
			if (req_find_program(r, f[3]) < 0) {
				req_perr(e, n, row, "order", "%s line %d: tailslot for unknown program %q", SEC, (int64_t)n, Q(f[3]));
				goto fail;
			}
			struct bml_map *mp = NULL;
			for (size_t i = 0; i < r->n_maps; i++)
				if (req_str_eq(&r->maps[i].symbol, f[1]))
					mp = &r->maps[i];
			if (!mp) {
				req_perr(e, n, row, "order", "%s line %d: tailslot for %q, which is not a prog_array map row", SEC,
				     (int64_t)n, Q(f[1]));
				goto fail;
			}
			if (!req_str_eq_lit(&mp->map_type, "prog_array")) {
				req_perr(e, n, row, "value", "%s line %d: tailslot for %q, which is not a prog_array map row", SEC,
				     (int64_t)n, Q(f[1]));
				goto fail;
			}
			uint64_t slot;
			if (bml_go_parse_uint(f[2].p, f[2].n, 32, &slot) || slot >= mp->max_entries) {
				req_perr(e, n, row, "value", "%s line %d: bad slot %q for %q (max_entries %u)", SEC, (int64_t)n,
				     Q(f[2]), Q(f[1]), mp->max_entries);
				goto fail;
			}
			for (size_t i = 0; i < r->n_tailslots; i++) {
				if (req_str_eq(&r->tailslots[i].map, f[1]) && r->tailslots[i].slot == (uint32_t)slot) {
					req_perr(e, n, row, "value", "%s line %d: slot %u of %q appears twice", SEC, (int64_t)n,
					     slot, Q(f[1]));
					goto fail;
				}
			}
			if (GROW(r->tailslots, r->n_tailslots, r->cap_tailslots))
				OOM();
			struct bml_tailslot *t = &r->tailslots[r->n_tailslots];
			t->slot = (uint32_t)slot;
			if (req_mkstr(&t->map, f[1]) || req_mkstr(&t->program, f[3]))
				OOM();
			r->n_tailslots++;
			continue;
		}
		if (req_eq(f[0], "argtag")) {
			if (req_find_program(r, f[1]) < 0) {
				req_perr(e, n, row, "order", "%s line %d: argtag for unknown program %q", SEC, (int64_t)n, Q(f[1]));
				goto fail;
			}
			if (!req_eq(f[2], "arg:nonnull") || !req_eq(f[3], "mem")) {
				req_perr(e, n, row, "value", "%s line %d: unknown argtag %q %q (known: arg:nonnull mem)", SEC,
				     (int64_t)n, Q(f[2]), Q(f[3]));
				goto fail;
			}
			if (GROW(r->argtags, r->n_argtags, r->cap_argtags))
				OOM();
			struct bml_argtag *t = &r->argtags[r->n_argtags];
			if (req_mkstr(&t->program, f[1]) || req_mkstr(&t->tag, f[2]) || req_mkstr(&t->cls, f[3]))
				OOM();
			r->n_argtags++;
			continue;
		}
		/* E425 (版 11 — E036): trace_perf の付随の行は arch だけ (1 つ) */
		if (req_eq(f[0], "arch") && r->n_attaches && req_str_eq_lit(&r->attaches[r->n_attaches - 1].attach_type, "trace_perf")) {
			struct bml_attach *a = &r->attaches[r->n_attaches - 1];
			if (!req_str_eq(&a->program, f[1]) || a->arch.len != 0) {
				req_perr(e, n, row, "order", "%s line %d: %s row out of order %q", SEC, (int64_t)n, row, Q(line));
				goto fail;
			}
			if (f[2].n == 0) {
				req_perr(e, n, row, "value", "%s line %d: bad arch row %q", SEC, (int64_t)n, Q(line));
				goto fail;
			}
			if (req_mkstr(&a->arch, f[2]))
				OOM();
			continue;
		}
		if (req_eq(f[0], "tpfield") || req_eq(f[0], "extret") || req_eq(f[0], "extarg") || req_eq(f[0], "structop")) { /* E425 — parse_v11.c */
			int rc = req_v11_companion(r, f, line, n, e);
			if (rc == -2)
				OOM();
			if (rc)
				goto fail;
			continue;
		}
		if (req_eq(f[0], "arch") || req_eq(f[0], "ctxfield") || req_eq(f[0], "kprobearg") || req_eq(f[0], "binary") ||
		    req_eq(f[0], "uprobearg")) { /* probe の族の付随の行 — parse_probe.c */
			int rc = req_probe_companion(r, f, line, n, row, e);
			if (rc == -2)
				OOM();
			if (rc)
				goto fail;
			continue;
		}
		if (req_eq(f[0], "funcret")) {
			struct bml_attach *a = r->n_attaches ? &r->attaches[r->n_attaches - 1] : NULL;
			if (!a || !req_str_eq(&a->program, f[1]) || !req_str_eq_lit(&a->attach_type, "trace_fexit") || a->ret_nargs >= 0 || a->func_ret.len) {
				req_perr(e, n, row, "order", "%s line %d: funcret row out of order or malformed %q", SEC, (int64_t)n, Q(line)); goto fail;
			}
			if (!req_valid_int_spelling(f[2])) {
				req_perr(e, n, row, "value", "%s line %d: funcret type must be i8…u64, got %q", SEC, (int64_t)n, Q(f[2])); goto fail;
			}
			if (req_mkstr(&a->func_ret, f[2])) OOM();
			continue;
		}
		if (req_eq(f[0], "retsig")) {
			struct bml_attach *a = r->n_attaches ? &r->attaches[r->n_attaches - 1] : NULL;
			/* E404 (版 10 — E032): trace_fmod_ret も (戻り値を書き換える)。E425 (版 11 — E036): trace_struct_ops は structop の後・farg の前、void も */
			int sops = a && req_str_eq_lit(&a->attach_type, "trace_struct_ops");
			if (!a || !req_str_eq(&a->program, f[1]) ||
			    (!req_str_eq_lit(&a->attach_type, "trace_fexit") && !req_str_eq_lit(&a->attach_type, "trace_fmod_ret") && !sops) ||
			    a->ret_nargs >= 0 || a->func_ret.len || (sops && (a->sop_struct.len == 0 || a->n_fargs > 0))) {
				req_perr(e, n, row, "order", "%s line %d: retsig row out of order or malformed %q", SEC, (int64_t)n,
				     Q(line));
				goto fail;
			}
			int64_t na;
			if (bml_go_atoi(f[2].p, f[2].n, &na) || na < 0 || !(req_valid_int_spelling(f[3]) || (sops && req_eq(f[3], "void")))) {
				req_perr(e, n, row, "value", "%s line %d: retsig row out of order or malformed %q", SEC, (int64_t)n,
				     Q(line));
				goto fail;
			}
			a->ret_nargs = na;
			if (req_mkstr(&a->ret_type, f[3]))
				OOM();
			continue;
		}
		if (req_eq(f[0], "attach") || req_eq(f[0], "arg")) {
			if (req_find_program(r, f[1]) < 0) {
				req_perr(e, n, row, "order", "%s line %d: %s for unknown program %q", SEC, (int64_t)n, row, Q(f[1]));
				goto fail;
			}
			if (req_eq(f[0], "attach")) { /* 付随の行の族と汎用の attach の行 (bpf-mlir E388 — parse_v9.c) */
				int rc = req_v9_attach(r, f, line, n, e);
				if (rc == -2)
					OOM();
				if (rc)
					goto fail;
				continue;
			}
			struct bml_attach *a = r->n_attaches ? &r->attaches[r->n_attaches - 1] : NULL;
			int64_t idx;
			int aerr = bml_go_atoi(f[2].p, f[2].n, &idx);
			if (!a || !req_str_eq(&a->program, f[1]) || !req_str_eq_lit(&a->attach_type, "trace_raw_tp")) {
				req_perr(e, n, row, "order", "%s line %d: arg row out of order or malformed %q", SEC, (int64_t)n, Q(line));
				goto fail;
			}
			if (aerr || f[3].n == 0) {
				req_perr(e, n, row, "value", "%s line %d: arg row out of order or malformed %q", SEC, (int64_t)n, Q(line));
				goto fail;
			}
			if (idx < 0 || (uint64_t)idx != a->n_args) {
				req_perr(e, n, row, "order", "%s line %d: arg row out of order or malformed %q", SEC, (int64_t)n, Q(line));
				goto fail;
			}
			if (GROW(a->args, a->n_args, a->cap_args) || req_mkstr(&a->args[a->n_args], f[3]))
				OOM();
			a->n_args++;
			continue;
		}
		if (req_eq(f[0], "farg")) { /* bpf-mlir v0.17.0 E319 — 直前の trace_fentry の attach に位置で結び付く (順・値・添字の連続の順) */
			struct bml_attach *a = r->n_attaches ? &r->attaches[r->n_attaches - 1] : NULL;
			int64_t idx;
			int aerr = bml_go_atoi(f[2].p, f[2].n, &idx);
			/* E404 (版 10 — E032): trace_fmod_ret の farg は retsig の後で、値は整数の綴りか - */
			int fmod = a && req_str_eq_lit(&a->attach_type, "trace_fmod_ret");
			/* E425 (版 11 — E036): trace_lsm の farg は struct・整数・- 、trace_struct_ops の farg も同じ域で structop (と retsig) の後 */
			/* E480 (版 13 — E041): trace_lsm_cgroup も trace_lsm と同じ */
			int lsm = a && (req_str_eq_lit(&a->attach_type, "trace_lsm") || req_str_eq_lit(&a->attach_type, "trace_lsm_cgroup")),
			    sops = a && req_str_eq_lit(&a->attach_type, "trace_struct_ops");
			if (!a || !req_str_eq(&a->program, f[1]) || !(req_str_eq_lit(&a->attach_type, "trace_fentry") || fmod || lsm || sops) ||
			    (fmod && a->ret_nargs < 0) || (sops && a->sop_struct.len == 0)) {
				req_perr(e, n, row, "order", "%s line %d: farg row out of order or malformed %q", SEC, (int64_t)n, Q(line));
				goto fail;
			}
			if (aerr || f[3].n == 0 || (fmod && !req_eq(f[3], "-") && !req_valid_int_spelling(f[3]))) {
				req_perr(e, n, row, "value", "%s line %d: farg row out of order or malformed %q", SEC, (int64_t)n, Q(line));
				goto fail;
			}
			if (f[3].n >= 5 && !memcmp(f[3].p, "enum:", 5)) {
				if (!sops || !req_enum_bits(f[3])) {
					req_perr(e, n, row, "value", "%s line %d: farg enum type must be enum:8, enum:16, enum:32 or enum:64 after trace_struct_ops, got %q", SEC, (int64_t)n, Q(f[3])); goto fail;
				}
				if (r->version < 19) {
					req_perr(e, n, row, "min_version", "%s line %d: farg type %q needs version %d", SEC, (int64_t)n, Q(f[3]), (int64_t)19); goto fail;
				}
			}
			if (idx < 0 || (uint64_t)idx != a->n_fargs) {
				req_perr(e, n, row, "order", "%s line %d: farg row out of order or malformed %q", SEC, (int64_t)n, Q(line));
				goto fail;
			}
			if (GROW(a->fargs, a->n_fargs, a->cap_fargs) || req_mkstr(&a->fargs[a->n_fargs], f[3]))
				OOM();
			a->n_fargs++;
			continue;
		}
		if (req_eq(f[0], "ctxaccess")) { /* bpf-mlir E388 (版 9) — parse_v9.c */
			int rc = req_v9_ctxaccess(r, f, line, n, e);
			if (rc == -2)
				OOM();
			if (rc)
				goto fail;
			continue;
		}
		if (req_eq(f[0], "kfield")) {
			if (req_kfield_path_row(r, f, n, row, e)) /* bpf-mlir E553 (E054): 経路と struct:T は版 17 から (program の検査の前) */
				goto fail;
			if (req_find_program(r, f[1]) < 0) {
				req_perr(e, n, row, "order", "%s line %d: kfield for unknown program %q", SEC, (int64_t)n, Q(f[1]));
				goto fail;
			}
			int strptr = req_eq(f[4], "strptr"); /* bpf-mlir E539 (E047): char * の field — 最小の版 15 */
			if (!req_kfield_type_ok(f[4]) && !strptr && !req_kfield_struct_type(f[4])) { /* v0.17.0 E315 / E318 / E320、E553 の struct:T */
				req_perr(e, n, row, "value",
					 "%s line %d: kfield type must be i8, u8, i16, u16, i32, u32, i64, u64, ptr:<struct>, ptr:void, [N]i8 / [N]u8 (N 1..64), strptr or enum:<8|16|32|64>, got %q",
					 SEC, (int64_t)n, Q(f[4]));
				goto fail;
			}
			int mv = req_eq(f[4], "ptr:void") ? 25 : req_enum_bits(f[4]) ? 22 : strptr ? 15 : req_kfield_struct_type(f[4]) ? 17 : 0;
			if (r->version < mv && !(mv == 15 && BML_MUT("parse.v15_rows_any_version")) && !(mv == 17 && BML_MUT("parse.v17_rows_any_version"))) {
				req_perr(e, n, row, "min_version", "%s line %d: kfield type %q needs version %d", SEC, (int64_t)n, Q(f[4]), (int64_t)mv);
				goto fail;
			}
			if (GROW(r->kfields, r->n_kfields, r->cap_kfields))
				OOM();
			struct bml_kfield *k = &r->kfields[r->n_kfields];
			r->n_kfields++;
			if (req_mkstr(&k->program, f[1]) || req_mkstr(&k->strct, f[2]) || req_mkstr(&k->field, f[3]) || req_mkstr(&k->type, f[4]))
				OOM();
			if (has_guarded) {
				int rc = req_parse_guard_list(guarded, ng, n, row, line, &k->guards, e);
				if (rc == -2) OOM();
				if (rc) goto fail;
			}
			if (req_note_guarded_row(r, n, -1, (long)r->n_kfields - 1)) OOM();
			continue;
		}
		/* program・helper・map (Go の switch の前の ParseInt) */
		int64_t id;
		if (bml_go_parse_int(f[3].p, f[3].n, 64, &id)) {
			req_perr(e, n, row, "value", "%s line %d: bad number %q", SEC, (int64_t)n, Q(f[3]));
			goto fail;
		}
		if (req_eq(f[0], "program")) {
			if (req_find_program(r, f[1]) >= 0) {
				req_perr(e, n, row, "order", "%s line %d: program %q appears twice", SEC, (int64_t)n, Q(f[1]));
				goto fail;
			}
			if (GROW(r->programs, r->n_programs, r->cap_programs))
				OOM();
			struct bml_program *p = &r->programs[r->n_programs];
			memset(p, 0, sizeof(*p));
			r->n_programs++;
			p->prog_type_id = id;
			if (req_mkstr(&p->symbol, f[1]) || req_mkstr(&p->prog_type, f[2]))
				OOM();
		} else if (req_eq(f[0], "helper")) {
			int i = req_find_program(r, f[1]);
			if (i < 0) {
				req_perr(e, n, row, "order", "%s line %d: helper for unknown program %q", SEC, (int64_t)n, Q(f[1]));
				goto fail;
			}
			struct bml_program *p = &r->programs[i];
			if (GROW(p->helpers, p->n_helpers, p->cap_helpers))
				OOM();
			p->helpers[p->n_helpers].id = id;
			if (req_mkstr(&p->helpers[p->n_helpers].name, f[2]))
				OOM();
			p->n_helpers++;
		} else if (req_eq(f[0], "map")) {
			if (GROW(r->maps, r->n_maps, r->cap_maps))
				OOM();
			struct bml_map *m = &r->maps[r->n_maps];
			memset(m, 0, sizeof(*m));
			r->n_maps++;
			m->id = id;
			if (req_mkstr(&m->symbol, f[1]) || req_mkstr(&m->map_type, f[2]))
				OOM();
			if (r->version >= 2) {
				if (req_mkstr(&m->key, f[4]) || req_mkstr(&m->value, f[5]))
					OOM();
				if (bml_go_parse_uint(f[6].p, f[6].n, 64, &m->max_entries)) {
					req_perr(e, n, row, "value", "%s line %d: bad max_entries %q", SEC, (int64_t)n, Q(f[6]));
					goto fail;
				}
				if (bml_go_parse_uint(f[7].p, f[7].n, 64, &m->flags)) {
					req_perr(e, n, row, "value", "%s line %d: bad flags %q", SEC, (int64_t)n, Q(f[7]));
					goto fail;
				}
			}
			last_map = (long)(r->n_maps - 1);
		}
		continue;

	fail_unknown_fields:
		req_perr(e, n, "", "unknown_kind", "%s line %d: want %d tab-separated fields, got %q", SEC, (int64_t)n,
		     (int64_t)want, Q(line));
		goto fail;
	}
	if (req_v12_pending(r, 0, "", last_map, e)) /* E039: 文書の終わり (line 0) */
		goto fail;
	if (req_check_arena_rows(r, e)) goto fail;
	if (r->n_programs == 0) {
		req_perr(e, 0, "", "document", "%s: no programs", SEC);
		goto fail;
	}
	if (r->version >= 2 && r->schema_sha256.len == 0) {
		req_perr(e, 0, "", "document", "%s: version %d without a schema row", SEC, (int64_t)r->version);
		goto fail;
	}
	if (req_kfield_prefixes(r, e)) /* bpf-mlir E553 (E054): checkKFieldPrefixes */
		goto fail;
	int guards_rc = req_check_guard_bindings(r, e);
	if (guards_rc == -2) OOM();
	if (guards_rc) goto fail;
	free(fields);
	*out = r;
	if (sc.too_long)
		return req_perr(e, 0, "", "", "bufio.Scanner: token too long");
	return 0;

oom:
	free(fields);
	bml_requirements_free(r);
	return req_perr(e, 0, "", "", "out of memory");
fail:
	free(fields);
	bml_requirements_free(r);
	return -1;
}
