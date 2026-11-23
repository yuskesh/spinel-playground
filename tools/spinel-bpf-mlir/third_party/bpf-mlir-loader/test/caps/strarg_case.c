/* test/caps/strarg_case.c — tpfield / sysarg の strptr・strarray の分類の差動の道具 (E053)。test/oracle/cmd/strarg-live と同じ問いの行を読み、
 * 同じ形 ("<行>\t<ok|unknown|error>\t<答え>") で出す。tracefs の root を引数で作った dir に差し替えられる (無ければ本当の tracefs)。
 *
 *   strarg_case <queries> [<tracefs の root>]
 *
 * 行 (tab 区切り): tp <event> <field> <offset> <byte 数> <sign> (CheckTracepointField)・sys <syscall> <n> <型> (CheckSyscallArg)・
 * tpdepth <宣言> (tpCharPointerDepth)・sysdepth <型の文字列> (syscallCharPointerDepth)・btfdepth <syscall> (__do_sys_<syscall> の全ての引数の
 * syscallBTFCharPointerDepth)、E054: tparray <宣言> (tpByteArrayShape)・tpname <宣言> (tpFieldName) */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "btf/kernel.h"
#include "caps/live.h"
#include "caps/live_internal.h"

static void emit(const char *line, int rc, struct bml_strs *d, char *msg)
{
	if (rc == BML_Q_UNKNOWN)
		printf("%s\tunknown\t%s\n", line, msg ? msg : "");
	else if (rc != BML_Q_OK)
		printf("%s\terror\t%s\n", line, msg ? msg : "");
	else {
		printf("%s\tok\t", line);
		for (size_t i = 0; d && i < d->n; i++)
			printf("%s%s", i ? " || " : "", d->s[i]);
		printf("\n");
	}
	free(msg);
	if (d)
		bml_strs_free(d);
}

static void depth(const char *line, int known, int d)
{
	if (known)
		printf("%s\tok\t%d\n", line, d);
	else
		printf("%s\tunknown\t\n", line);
}

int main(int argc, char **argv)
{
	if (argc != 2 && argc != 3) {
		fprintf(stderr, "usage: strarg_case <queries> [<tracefs root>]\n");
		return 2;
	}
	FILE *q = fopen(argv[1], "r");
	if (!q) {
		perror(argv[1]);
		return 2;
	}
	if (argc == 3) /* 2 つ目の root は無い dir (Go の写しも同じ) */
		lv_tracefs_roots[0] = argv[2], lv_tracefs_roots[1] = "/nonexistent-tracefs-e053";
	struct bml_live l = {0};
	const char *kerr = NULL;
	const struct bml_kbtf *kb = lv_kb(&l, &kerr);
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
		for (char *p = line; nf < 8;) {
			f[nf++] = p;
			char *t = strchr(p, '\t');
			if (!t)
				break;
			*t = 0;
			p = t + 1;
		}
		struct bml_strs d = {0};
		char *msg = NULL;
		int dd = 0;
		if (!strcmp(f[0], "tp") && nf == 6) {
			int rc = bml_live_tp_field(&l, f[1], f[2], strtoll(f[3], NULL, 10), strtoll(f[4], NULL, 10), f[5], &d, &msg);
			emit(orig, rc, &d, msg);
		} else if (!strcmp(f[0], "sys") && nf == 4) {
			int rc = bml_live_syscall_arg(&l, f[1], strtoll(f[2], NULL, 10), f[3], &d, &msg);
			emit(orig, rc, &d, msg);
		} else if (!strcmp(f[0], "tpdepth") && nf == 2) {
			int k = lv_tp_char_depth(f[1], strlen(f[1]), &dd);
			depth(orig, k, dd);
		} else if (!strcmp(f[0], "tparray") && nf == 2) { /* E054: tpByteArrayShape — "<個数> <符号の %q>" */
			int64_t cnt;
			char s;
			if (lv_tp_array_shape(f[1], strlen(f[1]), &cnt, &s))
				printf("%s\tok\t%lld \"%s\"\n", orig, (long long)cnt, s == 'u' ? "u" : s == 'i' ? "i" : "");
			else
				printf("%s\tunknown\t\n", orig);
		} else if (!strcmp(f[0], "tpname") && nf == 2) { /* E054: tpFieldName の名前 (無ければ -) */
			size_t s, e;
			if (lv_tp_field_name(f[1], strlen(f[1]), &s, &e))
				printf("%s\tok\t%.*s\n", orig, (int)(e - s), f[1] + s);
			else
				printf("%s\tok\t-\n", orig);
		} else if (!strcmp(f[0], "sysdepth") && nf == 2) {
			int k = kb && lv_sys_char_depth(kb, f[1], &dd);
			depth(orig, k, dd);
		} else if (!strcmp(f[0], "btfdepth") && nf == 2 && kb) {
			char name[512];
			snprintf(name, sizeof name, "__do_sys_%s", f[1]);
			uint32_t id;
			char *err = NULL;
			if (bml_kbtf_by_name(kb, name, KBTF_FUNC, &id, &err) != 0) {
				printf("%s\terror\tno func\n", orig);
			} else {
				struct kbtf_type fn, fp;
				bml_kbtf_type(kb, id, &fn);
				bml_kbtf_type(kb, fn.size_type, &fp);
				printf("%s\tok\t", orig);
				for (uint32_t i = 0; fp.kind == KBTF_FUNC_PROTO && i < fp.vlen; i++) {
					const char *pn;
					uint32_t pt;
					bml_kbtf_param(kb, &fp, i, &pn, &pt);
					int k = lv_sys_btf_char_depth(kb, pt, &dd);
					printf("%s%u:%s", i ? " " : "", i + 1, k ? "" : "?");
					if (k)
						printf("%d", dd);
				}
				printf("\n");
			}
			free(err);
		} else {
			fprintf(stderr, "strarg_case: bad line %s\n", orig);
			return 2;
		}
		free(orig);
		fflush(stdout);
	}
	free(line);
	fclose(q);
	bml_live_free(&l);
	return 0;
}
