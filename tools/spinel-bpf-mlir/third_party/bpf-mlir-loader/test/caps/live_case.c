/* test/caps/live_case.c — live の caps の vmlinux の BTF と host の問い合わせ (src/caps/live_btf.c・live_host.c) の差動の道具 (E004)。
 * test/oracle/cmd/kbtf-live と同じ問いの行を読み、同じ形 ("<行>\t<ok|unknown|error>\t<答え>") で出す。 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "btf/kernel.h"
#include "caps/live.h"

static int msg_too; /* 今の行の Unknown の文を印字する (func_param・func_args — Go の kbtf-live と同じ) */
static void emit(const char *line, int rc, struct bml_strs *d, char *msg)
{
	if (rc == BML_Q_UNKNOWN)
		printf(msg_too && msg ? "%s\tunknown\t%s\n" : "%s\tunknown\n", line, msg); /* E009 H5 — func_param・func_args は Unknown の文も */
	else if (rc != BML_Q_OK)
		printf("%s\terror\n", line);
	else {
		printf("%s\tok\t", line);
		for (size_t i = 0; i < d->n; i++)
			printf("%s%s", i ? " || " : "", d->s[i]);
		printf("\n");
	}
	free(msg);
	bml_strs_free(d);
}

static struct bml_str mk(char *s)
{
	struct bml_str r = {s, strlen(s)};
	return r;
}

int main(int argc, char **argv)
{
	if (argc != 2) {
		fprintf(stderr, "usage: live_case <queries>\n");
		return 2;
	}
	FILE *q = fopen(argv[1], "r");
	if (!q) {
		perror(argv[1]);
		return 2;
	}
	struct bml_live l = {0};
	/* E018: 作った BTF (E326 の循環・共有 — scripts/diff-kfield-cycle.sh) を vmlinux の代わりに (kload の Once を読めた形に) */
	const char *vp = getenv("BML_TEST_VMLINUX");
	if (vp) {
		FILE *vf = fopen(vp, "rb");
		long vl = vf && !fseek(vf, 0, SEEK_END) ? ftell(vf) : -1;
		uint8_t *raw = vl > 0 ? malloc((size_t)vl) : NULL;
		char *verr = NULL;
		if (!vf || !raw || fseek(vf, 0, SEEK_SET) || fread(raw, 1, (size_t)vl, vf) != (size_t)vl ||
		    bml_kbtf_from_raw(raw, (size_t)vl, &l.kb, &verr) != 0) { /* from_raw は名前の索引も作る */
			fprintf(stderr, "live_case: BML_TEST_VMLINUX %s: %s\n", vp, verr ? verr : "unreadable");
			return 2;
		}
		fclose(vf);
		l.kb_done = 1;
		l.kb_rc = 0;
	}
	char *line = NULL;
	size_t cap = 0;
	ssize_t n;
	while ((n = getline(&line, &cap, q)) > 0) {
		if (line[n - 1] == '\n')
			line[--n] = 0;
		if (!n)
			continue;
		char *orig = strdup(line);
		char *f[8] = {0};
		int nf = 0;
		for (char *s = line; nf < 8;) {
			f[nf++] = s;
			char *t = strchr(s, '\t');
			if (!t)
				break;
			*t = 0;
			s = t + 1;
		}
		struct bml_strs d = {0};
		char *msg = NULL;
		int rc;
		msg_too = !strcmp(f[0], "func_param") || !strcmp(f[0], "func_args");
		if (!strcmp(f[0], "func"))
			rc = bml_live_func(&l, f[1], &d, &msg);
		else if (!strcmp(f[0], "func_sig"))
			rc = bml_live_func_sig(&l, f[1], atoll(f[2]), f[3], &d, &msg);
		else if (!strcmp(f[0], "func_args")) { /* v0.17.0 E319 (E009) */
			struct bml_str args[64];
			size_t na = 0;
			for (char *s = f[2]; s && na < 64;) {
				char *c = strchr(s, ',');
				if (c)
					*c = 0;
				args[na++] = mk(s);
				s = c ? c + 1 : NULL;
			}
			rc = bml_live_func_args(&l, f[1], args, na, &d, &msg);
		} else if (!strcmp(f[0], "func_param"))
			rc = bml_live_func_param(&l, f[1], atoll(f[2]), f[3], &d, &msg);
		else if (!strcmp(f[0], "struct_field"))
			rc = bml_live_struct_field(&l, f[1], f[2], atoll(f[3]), atoll(f[4]), &d, &msg);
		else if (!strcmp(f[0], "tracepoint")) {
			struct bml_str args[64];
			size_t na = 0;
			if (strcmp(f[2], "-") != 0)
				for (char *s = f[2]; s && na < 64;) {
					char *c = strchr(s, ',');
					if (c)
						*c = 0;
					args[na++] = mk(s);
					s = c ? c + 1 : NULL;
				}
			rc = bml_live_tracepoint(&l, f[1], args, na, &d, &msg);
		} else if (!strcmp(f[0], "kfields")) {
			struct bml_kfield kf[16];
			size_t nk = 0;
			for (char *s = f[1]; s && nk < 16;) {
				char *c = strchr(s, ';');
				if (c)
					*c = 0;
				char *p[4];
				p[0] = s;
				for (int i = 1; i < 4; i++) {
					p[i] = strchr(p[i - 1], ' ');
					*p[i]++ = 0;
				}
				kf[nk].program = mk(p[0]);
				kf[nk].strct = mk(p[1]);
				kf[nk].field = mk(p[2]);
				kf[nk].type = mk(p[3]);
				nk++;
				s = c ? c + 1 : NULL;
			}
			rc = bml_live_kfields(&l, kf, nk, &d, &msg);
		} else if (!strcmp(f[0], "ksym")) {
			int v;
			rc = bml_live_kernel_symbol(f[1] ? f[1] : "", &v, &msg);
			if (rc == BML_Q_OK) {
				printf("%s\tok\t%s\n", orig, v ? "true" : "false");
				free(orig);
				continue;
			}
		} else if (!strcmp(f[0], "arch")) {
			char *v = NULL;
			rc = bml_live_arch(&v, &msg);
			if (rc == BML_Q_OK) {
				printf("%s\tok\t%s\n", orig, v);
				free(v);
				free(orig);
				continue;
			}
		} else {
			printf("%s\tbad query\n", orig);
			free(orig);
			continue;
		}
		emit(orig, rc, &d, msg);
		free(orig);
	}
	free(line);
	fclose(q);
	bml_live_free(&l);
	return 0;
}
