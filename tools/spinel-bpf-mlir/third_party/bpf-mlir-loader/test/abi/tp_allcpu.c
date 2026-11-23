/* tp_allcpu — E040 の差動の C の側: bml_attach_tracepoint (online の全ての CPU で perf の event を開く — bpf-mlir U1 の回避) を照合する load
 * (ASan) → attach → 試験の thread を online の各 CPU に順に固定して N 回ずつ起こす → detach して map を読む。観測の文 ("obs …" — Go の
 * test/oracle/cmd/attach-tp-oracle の allcpu の arm (livecaps.AttachTracepointAllCPUs) と byte で比べる。変異 attach.tp_cpu0_only は cilium の arm
 * (link.Tracepoint) と) と C ABI の対照 ("check <名前> <kind> [named|kernel]")。root で (perf の event)。試験の thread の affinity は元に戻す。
 *
 *   tp_allcpu tpw <ELF> <sha> <maps.json>       sys_enter_write の fd 900 の 7 byte の write (bpf-mlir kernel/tracepoint/mlir/g14_tpw)
 *   tp_allcpu tp <ELF> <sha> <maps.json>        sys_enter_getppid (tp.mlir)
 *   tp_allcpu nosuch <ELF> <sha> <maps.json>    tracefs に無い event (bpf-mlir E419 の nosuch — 照合は attach_target_unknown で load する)
 *   tp_allcpu kind <ELF> <sha> <maps.json> <prog>  tracepoint でない program の取り違え (E038 の socket_filter の sf) */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "abi/tp_cpus.h"
#include "bml/bml.h"

#define S(x) (x), (int64_t)strlen(x)
#define N 10

static const char *maps_doc;
static int *cpus;
static size_t ncpu;

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

static const char *decl(const char *map, int64_t *len)
{
	char key[64];
	snprintf(key, sizeof key, "{\"name\":\"%s\"", map);
	const char *s = strstr(maps_doc, key);
	const char *e = s ? strchr(s, '}') : NULL;
	*len = e ? (int64_t)(e - s + 1) : 0;
	return s;
}

static uint32_t get(int64_t obj, const char *map, int64_t key)
{
	int64_t dl;
	const char *d = decl(map, &dl);
	int64_t r = bml_map_get_bits(obj, d, dl, key);
	uint32_t v = bml_result_kind(r) == 0 ? (uint32_t)bml_result_value(r) : 0xffffffffu;
	bml_result_free(r);
	return v;
}

static void put(int64_t obj, const char *map, int64_t key, int64_t v)
{
	int64_t dl;
	const char *d = decl(map, &dl);
	bml_result_free(bml_map_put_bits(obj, d, dl, key, v));
}

/* 自分の process の perf の event の fd の数 (/proc/self/fd の anon_inode:[perf_event]) */
static int perf_fds(void)
{
	DIR *d = opendir("/proc/self/fd");
	int n = 0;
	struct dirent *e;
	while (d && (e = readdir(d))) {
		char p[300], t[64];
		snprintf(p, sizeof p, "/proc/self/fd/%s", e->d_name);
		ssize_t k = readlink(p, t, sizeof t - 1);
		if (k > 0) {
			t[k] = 0;
			n += strcmp(t, "anon_inode:[perf_event]") == 0;
		}
	}
	if (d)
		closedir(d);
	return n;
}

/* 数を ncpu と N の形で (attachcheck の want と同じ綴り) */
static void count(char *buf, size_t n, uint32_t v)
{
	if (v == ncpu * N)
		snprintf(buf, n, "ncpu*N");
	else if (v == N)
		snprintf(buf, n, "1*N");
	else
		snprintf(buf, n, "%u", v);
}

static void delta(char *buf, size_t n, int d)
{
	if (d > 0 && (size_t)d == ncpu)
		snprintf(buf, n, "+ncpu");
	else
		snprintf(buf, n, "%+d", d);
}

static void pin(int cpu)
{
	cpu_set_t s;
	CPU_ZERO(&s);
	CPU_SET(cpu, &s);
	sched_setaffinity(0, sizeof s, &s);
}

static void trigger(int write_mode)
{
	for (int i = 0; i < N; i++) {
		if (write_mode) {
			if (write(900, "e040tp\n", 7) != 7)
				fprintf(stderr, "tp_allcpu: write: %s\n", strerror(errno));
		} else {
			getppid();
		}
	}
}

/* 1 つの case: cfg を置き、out を 0 に、(attach) → 起こす (each: online の各 CPU に固定して N 回ずつ、any: 固定なしの N 回) → detach → 観測 */
static void run_case(int64_t obj, const char *prog, const char *name, int attach, int each, int write_mode, uint32_t tgid, cpu_set_t *orig)
{
	put(obj, "cfg", 0, tgid);
	for (int k = 0; k < 3; k++)
		put(obj, "out", k, 0);
	int before = perf_fds(), during = before;
	int64_t link = 0;
	if (attach) {
		int64_t r = bml_attach_tracepoint(obj, prog, (int64_t)strlen(prog), 0);
		if (bml_result_kind(r) != 0) {
			int64_t mn = 0;
			const char *m = bml_result_message(r, &mn);
			printf("obs %s attach=%lld\n", name, (long long)bml_result_kind(r));
			fprintf(stderr, "tp_allcpu: %s: %.*s\n", name, (int)mn, m ? m : "");
			bml_result_free(r);
			return;
		}
		link = bml_result_value(r);
		bml_result_free(r);
		during = perf_fds();
	}
	if (each)
		for (size_t i = 0; i < ncpu; i++) {
			pin(cpus[i]);
			trigger(write_mode);
		}
	else
		trigger(write_mode);
	sched_setaffinity(0, sizeof *orig, orig);
	if (link)
		bml_result_free(bml_detach(link));
	int after = perf_fds();
	uint32_t o0 = get(obj, "out", 0), o1 = get(obj, "out", 1);
	char c0[32], dd[16], da[16];
	count(c0, sizeof c0, o0);
	delta(dd, sizeof dd, during - before);
	delta(da, sizeof da, after - before);
	if (write_mode) {
		uint32_t o2 = get(obj, "out", 2);
		char c2[32];
		if (o2 == 7 * o0)
			snprintf(c2, sizeof c2, "7*out0");
		else
			snprintf(c2, sizeof c2, "%u", o2);
		printf("obs %s out0=%s out1=%u out2=%s perf=%s,%s\n", name, c0, o1, c2, dd, da);
	} else {
		printf("obs %s out0=%s out1=%u perf=%s,%s\n", name, c0, o1, dd, da);
	}
}

static void check(const char *name, int64_t r, const char *named)
{
	int64_t k = bml_result_kind(r), mn = 0;
	const char *m = bml_result_message(r, &mn);
	const char *how = k == BML_OTHER ? (m && named && strstr(m, named) ? " named" : " kernel") : "";
	printf("check %s %lld%s\n", name, (long long)k, how);
	if (k)
		fprintf(stderr, "tp_allcpu: %s: %.*s\n", name, (int)mn, m ? m : "");
	if (k == 0) /* 対照で attach できてしまった — 外す */
		bml_result_free(bml_detach(bml_result_value(r)));
	bml_result_free(r);
}

int main(int argc, char **argv)
{
	if (argc < 5) {
		fprintf(stderr, "tp_allcpu <tpw|tp|nosuch|kind> <ELF> <sha> <maps.json> [prog]\n");
		return 2;
	}
	const char *mode = argv[1];
	maps_doc = argv[4];
	char *cerr = NULL;
	if (bml_tp_cpus(0, &cpus, &ncpu, &cerr) != 0) {
		fprintf(stderr, "tp_allcpu: %s\n", cerr ? cerr : "cpus");
		return 2;
	}
	cpu_set_t orig;
	sched_getaffinity(0, sizeof orig, &orig);
	int64_t n = 0;
	uint8_t *elf = slurp(argv[2], &n);
	if (!elf)
		return 2;
	int64_t lr = bml_load_checked(elf, n, S(argv[3]), S(maps_doc), 0);
	free(elf);
	if (bml_result_kind(lr) != 0) {
		int64_t mn = 0;
		const char *m = bml_result_message(lr, &mn);
		printf("obs load=%lld\n", (long long)bml_result_kind(lr));
		fprintf(stderr, "tp_allcpu: load: %.*s\n", (int)mn, m ? m : "");
		return 1;
	}
	int64_t obj = bml_result_value(lr);
	bml_result_free(lr);
	uint32_t me = (uint32_t)getpid();
	if (!strcmp(mode, "tpw")) {
		int nul = open("/dev/null", O_WRONLY | O_CLOEXEC);
		if (nul < 0 || dup3(nul, 900, O_CLOEXEC) < 0)
			return 2;
		close(nul);
		run_case(obj, "tpw", "none-each", 0, 1, 1, me, &orig);
		run_case(obj, "tpw", "allcpu-each", 1, 1, 1, me, &orig);
		run_case(obj, "tpw", "allcpu-any", 1, 0, 1, me, &orig);
		run_case(obj, "tpw", "allcpu-other", 1, 1, 1, 0xffffffffu, &orig);
		/* C ABI の対照 */
		int64_t r = bml_attach_tracepoint(obj, S("tpw"), 0);
		int64_t l1 = bml_result_kind(r) == 0 ? bml_result_value(r) : 0;
		bml_result_free(r);
		int before = perf_fds();
		check("second_attach_same_program", bml_attach_tracepoint(obj, S("tpw"), 0), "file exists");
		printf("check second_attach_perf %+d\n", perf_fds() - before);
		if (l1)
			bml_result_free(bml_detach(l1));
		check("unknown_flags", bml_attach_tracepoint(obj, S("tpw"), 2), NULL);
		check("no_such_program", bml_attach_tracepoint(obj, S("nope"), 0), NULL);
		close(900);
	} else if (!strcmp(mode, "tp")) {
		run_case(obj, "tp", "none-each", 0, 1, 0, me, &orig);
		run_case(obj, "tp", "allcpu-each", 1, 1, 0, me, &orig);
	} else if (!strcmp(mode, "nosuch")) {
		int before = perf_fds();
		check("missing_event", bml_attach_tracepoint(obj, S("tp"), 0), "syscalls/no_such_event");
		printf("check missing_event_perf %+d\n", perf_fds() - before);
	} else if (!strcmp(mode, "kind") && argc == 6) {
		check("tracepoint_on_other_kind", bml_attach_tracepoint(obj, argv[5], (int64_t)strlen(argv[5]), 0), NULL);
	} else {
		return 2;
	}
	bml_result_free(bml_close(obj));
	free(cpus);
	return 0;
}
