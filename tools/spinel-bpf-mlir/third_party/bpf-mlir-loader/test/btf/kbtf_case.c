/* test/btf/kbtf_case.c — kernel の BTF の reader (src/btf/kernel*) の差動の道具 (E004)。Go の test/oracle/cmd/kbtf-oracle と同じ出力。
 *
 *   kbtf_case <raw の BTF の file | -kernel> <問いの file>
 *
 * 問いの行は "<Go の型の名前> <名前>" (Func・Struct・Union・Typedef・Int・Enum・Fwd・Var・Datasec・Float)。行ごとに TypeByName の結果と、
 * 見つかれば %v・%s・UnderlyingType の %v と %T・Sizeof・member / 引数を出す。BTF が読めなければ "load error" の 1 行 (文は比べない)。 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "btf/kernel.h"

static uint32_t kind_of(const char *g)
{
	for (uint32_t k = 1; k < KBTF_NKINDS; k++)
		if (strcmp(bml_kbtf_goname(k), g) == 0)
			return k;
	return 0;
}

static void put_type(const struct bml_kbtf *kb, struct bml_buf *b, uint32_t id)
{
	int cyc;
	bml_kbtf_format(kb, b, id, 0, 'v');
	bml_buf_adds(b, " | ");
	bml_kbtf_format(kb, b, id, 0, 's');
	uint32_t u = bml_kbtf_underlying(kb, id, &cyc);
	bml_buf_adds(b, " | u=");
	bml_kbtf_format(kb, b, u, cyc, 'v');
	bml_buf_adds(b, " ");
	bml_kbtf_gotype(kb, b, u, cyc);
	int64_t sz;
	char *err;
	if (bml_kbtf_sizeof(kb, id, &sz, &err) == 0)
		bml_buf_addf(b, " | size=%lld", (long long)sz);
	else {
		bml_buf_addf(b, " | size error: %s", err);
		free(err);
	}
}

int main(int argc, char **argv)
{
	if (argc != 3) {
		fprintf(stderr, "usage: kbtf_case <raw BTF | -kernel> <queries>\n");
		return 2;
	}
	struct bml_kbtf kb;
	char *err = NULL;
	int rc;
	if (strcmp(argv[1], "-kernel") == 0)
		rc = bml_kbtf_load_kernel(&kb, &err);
	else {
		FILE *f = fopen(argv[1], "rb");
		if (!f) {
			perror(argv[1]);
			return 2;
		}
		fseek(f, 0, SEEK_END);
		long n = ftell(f);
		fseek(f, 0, SEEK_SET);
		uint8_t *raw = malloc(n > 0 ? (size_t)n : 1);
		if (!raw || fread(raw, 1, (size_t)n, f) != (size_t)n) {
			fprintf(stderr, "read %s\n", argv[1]);
			return 2;
		}
		fclose(f);
		rc = bml_kbtf_from_raw(raw, (size_t)n, &kb, &err);
	}
	if (rc != 0) {
		printf("load error\n");
		fprintf(stderr, "%s\n", err);
		free(err);
		return 0;
	}
	FILE *q = fopen(argv[2], "r");
	if (!q) {
		perror(argv[2]);
		return 2;
	}
	char line[4096];
	while (fgets(line, sizeof line, q)) {
		line[strcspn(line, "\n")] = 0;
		char *sp = strchr(line, ' ');
		if (!sp)
			continue;
		*sp = 0;
		const char *name = sp + 1;
		struct bml_buf b = {0};
		uint32_t id;
		bml_buf_addf(&b, "%s %s: ", line, name);
		int r = bml_kbtf_by_name(&kb, name, kind_of(line), &id, &err);
		if (r != 0) {
			bml_buf_addf(&b, "error %s", err);
			free(err);
		} else {
			struct kbtf_type t;
			bml_kbtf_type(&kb, id, &t);
			put_type(&kb, &b, id);
			if (t.kind == KBTF_STRUCT || t.kind == KBTF_UNION)
				for (uint32_t i = 0; i < t.vlen; i++) {
					struct kbtf_member m;
					bml_kbtf_member(&kb, &t, i, &m);
					bml_buf_addf(&b, "\n  member %s off=%u bf=%u ", m.name, m.offset, m.bitfield_size);
					put_type(&kb, &b, m.type);
				}
			if (t.kind == KBTF_FUNC) {
				struct kbtf_type fp;
				bml_kbtf_type(&kb, t.size_type, &fp);
				if (fp.kind == KBTF_FUNC_PROTO) {
					bml_buf_adds(&b, "\n  return ");
					put_type(&kb, &b, fp.size_type);
					for (uint32_t i = 0; i < fp.vlen; i++) {
						const char *pn;
						uint32_t pt;
						bml_kbtf_param(&kb, &fp, i, &pn, &pt);
						bml_buf_addf(&b, "\n  param %s ", pn);
						put_type(&kb, &b, pt);
					}
				}
			}
			if (t.kind == KBTF_TYPEDEF) {
				bml_buf_adds(&b, "\n  target ");
				put_type(&kb, &b, t.size_type);
			}
		}
		char *s = bml_buf_take(&b);
		printf("%s\n", s ? s : "oom");
		free(s);
	}
	fclose(q);
	bml_kbtf_free(&kb);
	return 0;
}
