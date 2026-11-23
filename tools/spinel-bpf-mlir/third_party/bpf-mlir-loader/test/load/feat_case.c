/* test/load/feat_case.c — 予測と libbpf の実際の照合の表 (E005 の H2): btf の 11 の機能の C の live の答え (E004) と、対応する libbpf の
 * feat_supported、加えて guard が見る libbpf の feature (sanitize の 8・書き換えの 5) を 1 行ずつ。
 *
 *   feat_case     # "btf\t<機能>\t<live: true|false|unknown|error>\t<libbpf の feature>\t<supported|missing>" と "libbpf\t<feature>\t<…>"
 *
 * libbpf の probe の前に libbpf_set_memlock_rlim(0) (guard と同じ — RLIMIT_MEMLOCK を上げさせない)。 */
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <bpf/bpf.h>

#include "caps/live.h"
#include "load/internal.h"

int main(void)
{
	libbpf_set_memlock_rlim(0);
	struct bml_live l = {0};
	static const struct {
		const char *f;
		int feat;
	} t[] = {
		{"int", LBF_BTF}, {"ptr", LBF_BTF}, {"const", LBF_BTF}, {"array", LBF_BTF}, {"struct", LBF_BTF},
		{"func", LBF_BTF_FUNC}, {"func_proto", LBF_BTF_FUNC}, {"func_global", LBF_BTF_GLOBAL_FUNC},
		{"var", LBF_BTF_DATASEC}, {"datasec", LBF_BTF_DATASEC}, {"decl_tag", LBF_BTF_DECL_TAG},
	};
	for (size_t i = 0; i < sizeof t / sizeof *t; i++) {
		int v = 0;
		char *m = NULL;
		int rc = bml_live_btf_feature(&l, t[i].f, &v, &m);
		free(m);
		const char *live = rc == BML_Q_OK ? (v ? "true" : "false") : rc == BML_Q_UNKNOWN ? "unknown" : "error";
		printf("btf\t%s\t%s\t%s\t%s\n", t[i].f, live, lb_feat_name(t[i].feat), feat_supported(NULL, t[i].feat) ? "supported" : "missing");
	}
	static const int more[] = {LBF_BTF_FLOAT, LBF_BTF_TYPE_TAG, LBF_BTF_ENUM64, LBF_BTF_QMARK_DATASEC, LBF_PROG_NAME,
				   LBF_GLOBAL_DATA, LBF_ARRAY_MMAP, LBF_EXP_ATTACH_TYPE, LBF_PROBE_READ_KERN};
	for (size_t i = 0; i < sizeof more / sizeof *more; i++)
		printf("libbpf\t%s\t%s\n", lb_feat_name(more[i]), feat_supported(NULL, more[i]) ? "supported" : "missing");
	bml_live_free(&l);
	return 0;
}
