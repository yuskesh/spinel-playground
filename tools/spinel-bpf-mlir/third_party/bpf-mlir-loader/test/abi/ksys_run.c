/* ksys_run — E049 の差動の C の側 (Go の側は test/oracle/cmd/ksys-attach-oracle — 同じ入力・起こし方・同じ形の行):
 *   ksys_run run <count.bpf.o> <sha> <args.bpf.o> <sha> <nosys.bpf.o> <sha>    root — 試験の口の照合しない load と bml_attach_ksyscall
 *   ksys_run product <count.bpf.o> <sha> <args.bpf.o> <sha> <nosys.bpf.o> <sha> root — run と同じで load は製品の照合する load (E052)。
 *                                                                              nosys は照合が止める — 行は "nosys checked kind=… unmet=…"
 *   ksys_run checked <count.bpf.o> <sha>                                       製品の照合する load (C ABI の宣言 — E052 から
 *                                                                              cilium-v0.22-usdt-ksyscall) の答え
 * 変異 ksys.* と abi.decl_* は tools-mut で (BML_MUTANT)。 */
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <unistd.h>

#include <bpf/bpf.h>
#include <bpf/libbpf.h>

#include "abi/internal.h"
#include "bml/bml.h"
#include "bml/bml_testonly.h"

#define S(x) (x), (int64_t)strlen(x)
#define M_CFG "{\"name\":\"cfg\",\"kind\":\"array\",\"key\":\"u32\",\"value\":\"u32\",\"max_entries\":1}"
#define M_OUT "{\"name\":\"out\",\"kind\":\"array\",\"key\":\"u32\",\"value\":\"u64\",\"max_entries\":8}"
#define MAPS "{\"globals\":[],\"maps\":[" M_CFG "," M_OUT "]}"

static uint8_t *slurp(const char *path, int64_t *n)
{
	FILE *f = fopen(path, "rb");
	if (!f)
		return NULL;
	fseek(f, 0, SEEK_END);
	long l = ftell(f);
	fseek(f, 0, SEEK_SET);
	uint8_t *p = malloc(l > 0 ? (size_t)l : 1);
	if (p && fread(p, 1, (size_t)l, f) != (size_t)l) {
		free(p);
		p = NULL;
	}
	fclose(f);
	*n = l;
	return p;
}

static int64_t take(int64_t r, const char *what)
{
	if (bml_result_kind(r) != 0) {
		int64_t ml;
		const char *m = bml_result_message(r, &ml);
		fprintf(stderr, "ksys_run: %s: kind %lld: %.*s\n", what, (long long)bml_result_kind(r), (int)ml, m);
		exit(1);
	}
	int64_t v = bml_result_value(r);
	bml_result_free(r);
	return v;
}

static int product; /* E052: 1 なら製品の照合する load */

static int64_t load_raw(const char *path, const char *sha)
{
	int64_t n;
	uint8_t *elf = slurp(path, &n);
	if (!elf) {
		fprintf(stderr, "ksys_run: cannot read %s\n", path);
		exit(1);
	}
	int64_t r = product ? bml_load_checked(elf, n, S(sha), S(MAPS), 0)
			    : bml_testonly_load_unchecked_targets(elf, n, S(sha), S(MAPS), "", 0, "", 0);
	free(elf);
	return r;
}

/* 照合の答えの 1 行 ("<what> kind=… unmet=<kind>,…") */
static void print_checked(const char *what, int64_t r)
{
	printf("%s kind=%lld unmet=", what, (long long)bml_result_kind(r));
	for (int64_t i = 0; i < bml_result_unmet_count(r); i++) {
		int64_t l;
		const char *k = bml_result_unmet_field(r, i, 0, &l);
		printf("%s%.*s", i ? "," : "", (int)l, k);
	}
	printf("\n");
}

static int64_t load(const char *path, const char *sha)
{
	int64_t obj = take(load_raw(path, sha), "load");
	take(bml_map_put_bits(obj, S(M_CFG), 0, (int64_t)getpid()), "cfg");
	return obj;
}

static uint64_t out(int64_t obj, int64_t k)
{
	return (uint64_t)take(bml_map_get_bits(obj, S(M_OUT), k), "out");
}

/* 付けた link の kernel の id と kprobe の関数の名前 */
static uint32_t target(int64_t link, const char *prog)
{
	int64_t e = 0;
	int fd = abi_link_dup_fd(link, &e);
	if (fd < 0) {
		fprintf(stderr, "ksys_run: link fd\n");
		exit(1);
	}
	char fn[256];
	abi_kprobe_link_name(fd, BPF_PERF_EVENT_KPROBE, fn, sizeof fn);
	struct bpf_link_info info;
	uint32_t il = sizeof info;
	memset(&info, 0, sizeof info);
	bpf_link_get_info_by_fd(fd, &info, &il);
	close(fd);
	printf("target %s %s\n", prog, fn);
	return info.id;
}

/* detach の後に残る link (count と args の kernel の id) の数 */
static void print_left(const uint32_t *ids)
{
	int left = 0;
	for (int i = 0; i < 2; i++) {
		int fd = bpf_link_get_fd_by_id(ids[i]);
		if (fd >= 0) {
			left++;
			close(fd);
		}
	}
	printf("left %d\n", left);
}

static int run(char **a)
{
	uint32_t ids[2];
	int64_t cc = load(a[0], a[1]);
	int64_t lc = take(bml_attach_ksyscall(cc, S("count")), "attach count");
	ids[0] = target(lc, "count");
	for (int i = 0; i < 1000; i++)
		getppid();
	printf("count %llu\n", (unsigned long long)out(cc, 0));
	take(bml_detach(lc), "detach");
	/* E049 の 2 回目の停止: C ABI は同じ embedded object の 2 重の load を STATE で拒否する (製品の規則) — 次の ELF の前に閉じる */
	take(bml_close(cc), "close count");
	int64_t ca = load(a[2], a[3]);
	int64_t la = take(bml_attach_ksyscall(ca, S("args")), "attach args");
	ids[1] = target(la, "args");
	int einval = 0;
	for (int i = 0; i < 5; i++)
		if (prctl(0x4e472, 0x1111, 0x2222, 0x3333, 0x4444) < 0 && errno == EINVAL)
			einval++;
	uint64_t v[6];
	for (int i = 0; i < 6; i++)
		v[i] = out(ca, i);
	printf("args %llu 0x%llx 0x%llx 0x%llx 0x%llx 0x%llx %d\n", /* Go の %#x (0 は 0x0) */ (unsigned long long)v[0], (unsigned long long)v[1], (unsigned long long)v[2],
	       (unsigned long long)v[3], (unsigned long long)v[4], (unsigned long long)v[5], einval);
	take(bml_detach(la), "detach");
	take(bml_close(ca), "close args");
	if (product) { /* E052: 無い syscall の wrapper は照合が load の前に止める (run の mode では attach が誤り) */
		int64_t r = load_raw(a[4], a[5]);
		print_checked("nosys checked", r);
		if (bml_result_kind(r) == 0)
			bml_close(bml_result_value(r));
		bml_result_free(r);
		print_left(ids);
		return 0;
	}
	int64_t cn = load(a[4], a[5]);
	int64_t r = bml_attach_ksyscall(cn, S("nosys"));
	printf("nosys %s\n", bml_result_kind(r) == 0 ? "ok" : "error");
	if (bml_result_kind(r) == 0)
		bml_detach(bml_result_value(r));
	bml_result_free(r);
	print_left(ids);
	bml_close(cn);
	return 0;
}

int main(int argc, char **argv)
{
	setvbuf(stdout, NULL, _IOLBF, 0);
	if (argc == 8 && !strcmp(argv[1], "run"))
		return run(argv + 2);
	if (argc == 8 && !strcmp(argv[1], "product")) {
		product = 1;
		return run(argv + 2);
	}
	if (argc == 4 && !strcmp(argv[1], "checked")) { /* E049 の H6・E052 の H4: 製品の照合する load の答え */
		product = 1;
		int64_t r = load_raw(argv[2], argv[3]);
		print_checked("checked", r);
		if (bml_result_kind(r) == 0)
			bml_close(bml_result_value(r));
		bml_result_free(r);
		return 0;
	}
	fprintf(stderr, "usage: ksys_run run|product <count.o> <sha> <args.o> <sha> <nosys.o> <sha> | checked <count.o> <sha>\n");
	return 2;
}
