/* kbtf_index — E022 の試験: この kernel の vmlinux の BTF の名前の索引を、新しい形 (鍵の前計算) と前の形 (reference — 比べごとに decode) で作り、
 * id の列を byte で比べ、各々の時間の中央値を印字する。試験の build (-DBML_TEST_CAPS — asan / mut) だけ。root 不要。
 *
 *   [BML_TEST_VMLINUX=<raw の BTF>] kbtf_index [N]     →"kbtf_index: named <数> same <yes|no> new <ms> reference <ms>" */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "btf/kernel.h"

static double now(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

static int cmp(const void *a, const void *b)
{
	double x = *(const double *)a, y = *(const double *)b;
	return x < y ? -1 : x > y;
}

int main(int argc, char **argv)
{
	int n = argc > 1 ? atoi(argv[1]) : 11;
	if (n < 1 || n > 1000)
		n = 11;
	struct bml_kbtf kb;
	char *err = NULL;
	/* E022: 他の kernel の BTF (build の tree の vmlinux の .BTF を objcopy で取り出した raw) を file で — sudo も VM も要らない */
	const char *vp = getenv("BML_TEST_VMLINUX");
	if (vp) {
		FILE *vf = fopen(vp, "rb");
		long vl = vf && !fseek(vf, 0, SEEK_END) ? ftell(vf) : -1;
		uint8_t *raw = vl > 0 ? malloc((size_t)vl) : NULL;
		if (!vf || !raw || fseek(vf, 0, SEEK_SET) || fread(raw, 1, (size_t)vl, vf) != (size_t)vl ||
		    bml_kbtf_from_raw(raw, (size_t)vl, &kb, &err) != 0) {
			printf("kbtf_index: BML_TEST_VMLINUX %s: %s\n", vp, err ? err : "unreadable");
			return 1;
		}
		fclose(vf);
	} else if (bml_kbtf_load_kernel(&kb, &err) != 0) {
		printf("kbtf_index: the kernel BTF cannot be read: %s\n", err ? err : "");
		return 1;
	}
	double *tn = calloc((size_t)n, sizeof *tn), *tr = calloc((size_t)n, sizeof *tr);
	uint32_t *first = NULL, nfirst = 0;
	int same = 1;
	for (int i = 0; i < n; i++) {
		free(kb.idx);
		kb.idx = NULL;
		kb.nidx = 0;
		double t0 = now();
		if (bml_kbtf_build_index(&kb, &err) != 0)
			return 1;
		tn[i] = now() - t0;
		if (!first) {
			nfirst = kb.nidx;
			first = malloc((size_t)nfirst * sizeof *first);
			memcpy(first, kb.idx, (size_t)nfirst * sizeof *first);
		}
		free(kb.idx);
		kb.idx = NULL;
		kb.nidx = 0;
		t0 = now();
		if (bml_kbtf_build_index_reference(&kb, &err) != 0)
			return 1;
		tr[i] = now() - t0;
		same &= kb.nidx == nfirst && !memcmp(kb.idx, first, (size_t)nfirst * sizeof *first);
	}
	qsort(tn, (size_t)n, sizeof *tn, cmp);
	qsort(tr, (size_t)n, sizeof *tr, cmp);
	printf("kbtf_index: named %u same %s new %.3f reference %.3f\n", nfirst, same ? "yes" : "no", tn[n / 2], tr[n / 2]);
	free(first);
	free(tn);
	free(tr);
	bml_kbtf_free(&kb);
	return same ? 0 : 1;
}
