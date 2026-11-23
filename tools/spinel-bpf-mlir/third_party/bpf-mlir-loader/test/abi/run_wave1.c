/* run_wave1 — E034 の差動の C の側: fixture の ELF を照合する load (bml_load_checked) して波 1 の test run の関数を走らせ、case ごとに 1 行
 * (Go の側は test/oracle/cmd/run-oracle — 同じ入力の file を読み同じ形で出す)。
 *
 *   run_wave1 <e34_runs.txt> <ELF の dir>     (dir に <fixture>.bpf.o と <fixture>.sha)
 *   → "<id>\tok\t<戻り値 int32>\t<出力の hex|->" / "<id>\terr\t<errno の文>" / "<id>\tvalue_range" / "<id>\tstate" / "<id>\tload\t<kind>" */
#define _GNU_SOURCE
#include <linux/bpf.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "bml/bml.h"

#define S(x) (x), (int64_t)strlen(x)

static char maps_of[16][2][512];
static int n_maps;

static uint8_t *unhex(const char *h, int64_t *n)
{
	if (!strcmp(h, "-")) {
		*n = 0;
		return NULL;
	}
	size_t l = strlen(h) / 2;
	uint8_t *b = calloc(l ? l : 1, 1);
	for (size_t i = 0; i < l; i++)
		sscanf(h + 2 * i, "%2hhx", &b[i]);
	*n = (int64_t)l;
	return b;
}

static void hex(const uint8_t *b, int64_t n)
{
	if (!b || n <= 0) {
		printf("-");
		return;
	}
	for (int64_t i = 0; i < n; i++)
		printf("%02x", b[i]);
}

static uint8_t *slurp(const char *path, int64_t *n)
{
	FILE *f = fopen(path, "rb");
	if (!f)
		return NULL;
	fseek(f, 0, SEEK_END);
	long l = ftell(f);
	fseek(f, 0, SEEK_SET);
	uint8_t *p = malloc((size_t)l);
	if (p && fread(p, 1, (size_t)l, f) != (size_t)l) {
		free(p);
		p = NULL;
	}
	fclose(f);
	*n = l;
	return p;
}

int main(int argc, char **argv)
{
	if (argc != 3) {
		fprintf(stderr, "run_wave1 <e34_runs.txt> <ELF dir>\n");
		return 2;
	}
	if (sizeof(struct bpf_flow_keys) != 56) /* 入力の file の keys_cap の前提 */
		fprintf(stderr, "run_wave1: struct bpf_flow_keys is %zu bytes, the input assumes 56\n", sizeof(struct bpf_flow_keys));
	FILE *in = fopen(argv[1], "r");
	if (!in)
		return 2;
	char line[4096];
	while (fgets(line, sizeof line, in)) {
		line[strcspn(line, "\n")] = 0;
		char *f[10] = {0};
		int nf = 0;
		for (char *s = line, *t; nf < 10 && (t = strsep(&s, "\t"));)
			f[nf++] = t;
		if (!strcmp(f[0], "M") && nf == 3 && n_maps < 16) {
			snprintf(maps_of[n_maps][0], 512, "%s", f[1]);
			snprintf(maps_of[n_maps][1], 512, "%s", f[2]);
			n_maps++;
			continue;
		}
		if (strcmp(f[0], "C") != 0 || nf != 10)
			continue;
		const char *id = f[1], *fx = f[2], *prog = f[3], *fn = f[4];
		const char *maps = "";
		for (int i = 0; i < n_maps; i++)
			if (!strcmp(maps_of[i][0], fx))
				maps = maps_of[i][1];
		char path[1024], shap[1024], sha[80] = "";
		snprintf(path, sizeof path, "%s/%s.bpf.o", argv[2], fx);
		snprintf(shap, sizeof shap, "%s/%s.sha", argv[2], fx);
		FILE *sf = fopen(shap, "r");
		if (sf) {
			if (fscanf(sf, "%79s", sha) != 1)
				sha[0] = 0;
			fclose(sf);
		}
		int64_t elen = 0;
		uint8_t *elf = slurp(path, &elen);
		int64_t lr = bml_load_checked(elf, elen, S(sha), S(maps), 0);
		free(elf);
		if (bml_result_kind(lr) != 0) {
			printf("%s\tload\t%lld\n", id, (long long)bml_result_kind(lr));
			bml_result_free(lr);
			continue;
		}
		int64_t obj = bml_result_value(lr);
		bml_result_free(lr);
		int64_t dn, cn;
		uint8_t *data = unhex(f[5], &dn), *ctx = unhex(f[6], &cn);
		int64_t keys_cap = atoll(f[9]);
		uint8_t *keys = keys_cap > 0 ? calloc((size_t)keys_cap, 1) : NULL;
		int64_t r;
		const uint8_t *out = NULL;
		int64_t on = 0;
		if (!strcmp(fn, "skb"))
			r = bml_test_run_skb_data(obj, S(prog), data, dn);
		else if (!strcmp(fn, "flow"))
			r = bml_test_run_flow_dissector(obj, S(prog), data, dn, keys, keys_cap), out = keys, on = keys_cap;
		else if (!strcmp(fn, "ctx"))
			r = bml_test_run_ctx_inout(obj, S(prog), ctx, cn), out = strcmp(prog, "rawtp") ? ctx : NULL, on = cn;
		else
			r = bml_test_run_netfilter(obj, S(prog), data, dn, atoll(f[7]), atoll(f[8]));
		int64_t k = bml_result_kind(r);
		if (k == 0) {
			printf("%s\tok\t%lld\t", id, (long long)(int32_t)bml_result_value(r));
			hex(out, on);
			printf("\n");
		} else if (k == BML_VALUE_RANGE) {
			printf("%s\tvalue_range\n", id);
		} else if (k == BML_STATE) {
			printf("%s\tstate\n", id);
		} else {
			int64_t mn = 0;
			const char *m = bml_result_message(r, &mn);
			const char *e = m ? strrchr(m, ':') : NULL;
			printf("%s\terr\t%s\n", id, e ? e + 2 : "?");
			fprintf(stderr, "%s: %.*s\n", id, (int)mn, m ? m : "");
		}
		bml_result_free(r);
		free(data);
		free(ctx);
		free(keys);
		bml_result_free(bml_close(obj));
	}
	fclose(in);
	return 0;
}
