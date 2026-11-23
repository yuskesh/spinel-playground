/* abi_dead — E014 の試験: .rodata の設定値が死んだ code を生む program の load (B4 の部分列の照合 — 予測は E014、走らせる前に commit)。
 *
 *   abi_dead <dead.bpf.o> <sha>     (root、unshare -n の中 — 変異は BML_MUTANT で)
 * 各 case は "<id>: … — ok|FAIL" の 1 行。kernel と object の line_info の数は abi の内部 (試験は同じ層) から読む */
#define _GNU_SOURCE
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <bpf/bpf.h>
#include <bpf/libbpf.h>

#include "abi/internal.h"
#include "bml/bml.h"

#define S(x) (x), (int64_t)strlen(x)
#define M_CNT "{\"name\":\"cnt\",\"kind\":\"array\",\"key\":\"u32\",\"value\":\"u64\",\"max_entries\":2}"
#define G_WANT "{\"name\":\"want\",\"section\":\"rodata\",\"type\":\"u32\"}"
#define MAPS "{\"globals\":[" G_WANT "],\"maps\":[" M_CNT "]}"

static int fails;
static void check(const char *id, int good, const char *fmt, ...) __attribute__((format(printf, 3, 4)));
static void check(const char *id, int good, const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	printf("%s: ", id);
	vprintf(fmt, ap);
	printf(" — %s\n", good ? "ok" : "FAIL");
	va_end(ap);
	fails += !good;
}

struct res {
	int64_t kind, value;
	char msg[2048];
};
static struct res take(int64_t r)
{
	struct res x = {bml_result_kind(r), bml_result_value(r), ""};
	int64_t n = 0;
	const char *m = bml_result_message(r, &n);
	snprintf(x.msg, sizeof x.msg, "%.*s", (int)n, m ? m : "");
	bml_result_free(r);
	return x;
}

static uint8_t *slurp(const char *path, int64_t *n)
{
	FILE *f = fopen(path, "rb");
	if (!f)
		return NULL;
	fseek(f, 0, SEEK_END);
	long l = ftell(f);
	fseek(f, 0, SEEK_SET);
	uint8_t *p = malloc((size_t)l + 1);
	if (p && fread(p, 1, (size_t)l, f) != (size_t)l) {
		free(p);
		p = NULL;
	}
	fclose(f);
	*n = l;
	return p;
}

/* 読み込んだ program の object と kernel の line_info の数 */
static void counts(int64_t obj, uint32_t *oli, uint32_t *kli)
{
	int64_t e;
	struct abi_object *o = abi_object_get(obj, &e);
	*oli = *kli = UINT32_MAX;
	if (!o) {
		bml_result_free(e);
		return;
	}
	struct bpf_program *p = bpf_object__find_program_by_name(bml_obj_bpf(o->lo), "prog");
	struct bpf_prog_info pi;
	uint32_t l = sizeof pi;
	memset(&pi, 0, sizeof pi);
	if (p && bpf_prog_get_info_by_fd(bpf_program__fd(p), &pi, &l) == 0) {
		*oli = bpf_program__line_info_cnt(p);
		*kli = pi.nr_line_info;
	}
}

static uint8_t *elf;
static int64_t elf_n;
static const char *sha;

/* config で load → test run を runs 回 → cnt → close。load の結果を返す */
static struct res load_run(const char *config, int runs, uint64_t *c0, uint64_t *c1, uint32_t *oli, uint32_t *kli)
{
	struct res r = take(bml_load_checked_config(elf, elf_n, S(sha), S(MAPS), S(config), 0));
	*c0 = *c1 = UINT64_MAX;
	*oli = *kli = 0;
	if (r.kind != 0)
		return r;
	counts(r.value, oli, kli);
	for (int i = 0; i < runs; i++)
		take(bml_test_run_xdp(r.value, S("prog"), 1));
	struct res a = take(bml_map_get_bits(r.value, S(M_CNT), 0)), b = take(bml_map_get_bits(r.value, S(M_CNT), 1));
	*c0 = a.kind == 0 ? (uint64_t)a.value : UINT64_MAX;
	*c1 = b.kind == 0 ? (uint64_t)b.value : UINT64_MAX;
	take(bml_close(r.value));
	return r;
}

int main(int argc, char **argv)
{
	if (argc != 3) {
		fprintf(stderr, "abi_dead <dead.bpf.o> <sha>\n");
		return 2;
	}
	elf = slurp(argv[1], &elf_n);
	sha = argv[2];
	uint64_t c0, c1;
	uint32_t oli, kli;
	/* D1: want を置かない (optional — 0) — else の枝が死んだ code */
	struct res r = load_run("{\"optional\":[\"want\"]}", 2, &c0, &c1, &oli, &kli);
	check("D1", r.kind == 0 && kli < oli && c0 == 0 && c1 == 0, "load %lld \"%s\", line_info object %u / kernel %u, cnt 0=%llu 1=%llu", (long long)r.kind,
	      r.msg, oli, kli, (unsigned long long)c0, (unsigned long long)c1);
	/* D2: want = 3 — 刈り込み無し */
	r = load_run("{\"set\":{\"want\":3}}", 2, &c0, &c1, &oli, &kli);
	check("D2", r.kind == 0 && kli == oli && c0 == 2 && c1 == 6, "load %lld \"%s\", line_info object %u / kernel %u, cnt 0=%llu 1=%llu", (long long)r.kind,
	      r.msg, oli, kli, (unsigned long long)c0, (unsigned long long)c1);
	printf("abi_dead: FAIL %d\n", fails);
	free(elf);
	return fails ? 1 : 0;
}
