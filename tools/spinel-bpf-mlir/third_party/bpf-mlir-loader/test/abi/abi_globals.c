/* abi_globals — E006 の後半: .rodata の設定値を load の引数に (bml_load_checked_config) と bml_global_get。予測は E006 の「後半の予測」の表
 * (走らせる前に commit)。入力は bpf-mlir kernel/globals/mlir/multi.mlir の ELF (.rodata r8・r16・r32・r64・r32b、.bss b32・b64a・b64b)。
 *
 *   abi_globals all <multi.bpf.o> <sha>       G1〜G10・P (root、unshare -n の中)
 *   abi_globals notset <multi.bpf.o> <sha>    G5 だけ (strace が BPF_PROG_LOAD と BPF_MAP_CREATE を数える) */
#define _GNU_SOURCE
#include <dirent.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>

#include <errno.h>

#include <bpf/bpf.h>

#include "bml/bml.h"

static int fails;
static uint8_t *elf;
static int64_t elf_len;
static const char *sha;

static void check(const char *id, int ok, const char *fmt, ...) __attribute__((format(printf, 3, 4)));
static void check(const char *id, int ok, const char *fmt, ...)
{
	va_list ap;
	printf("%s: ", id);
	va_start(ap, fmt);
	vprintf(fmt, ap);
	va_end(ap);
	printf(" — %s\n", ok ? "ok" : "FAIL");
	fails += !ok;
	fflush(stdout);
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

#define S(x) (x), (int64_t)strlen(x)
#define G(n, s, t) "{\"name\":\"" n "\",\"section\":\"" s "\",\"type\":\"" t "\"}"
#define GLOBALS                                                                                                                    \
	"[" G("r8", "rodata", "u8") "," G("r16", "rodata", "u16") "," G("r32", "rodata", "u32") "," G("r64", "rodata", "u64") ","       \
	    G("r32b", "rodata", "u32") "," G("b32", "bss", "u32") "," G("b64a", "bss", "u64") "," G("b64b", "bss", "u64") "]"
#define MAPS "{\"globals\":" GLOBALS ",\"maps\":[]}"
#define MAPS_NOGLOBALS "{\"allow_undeclared_globals\":true,\"maps\":[]}"

static struct res load(const char *maps, const char *cfg, int64_t *obj)
{
	int64_t r = bml_load_checked_config(elf, elf_len, S(sha), S(maps), cfg, cfg ? (int64_t)strlen(cfg) : 0, 0);
	*obj = bml_result_kind(r) == BML_OK ? bml_result_value(r) : -1;
	return take(r);
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

static int64_t gget(int64_t obj, const char *decl, int64_t *kind)
{
	struct res x = take(bml_global_get(obj, S(decl)));
	*kind = x.kind;
	return x.value;
}

struct pstate {
	struct sigaction sa[65];
	int sa_rc[65], threads, fds;
	struct rlimit memlock;
};
static int count_fds(void)
{
	DIR *d = opendir("/proc/self/fd");
	int n = 0;
	struct dirent *e;
	while (d && (e = readdir(d)))
		n += e->d_name[0] != '.';
	if (d)
		closedir(d);
	return n - 1;
}
static int count_threads(void)
{
	FILE *f = fopen("/proc/self/status", "r");
	char line[256];
	int n = -1;
	while (f && fgets(line, sizeof line, f))
		if (sscanf(line, "Threads: %d", &n) == 1)
			break;
	if (f)
		fclose(f);
	return n;
}
static void snap(struct pstate *s)
{
	memset(s, 0, sizeof *s);
	for (int i = 1; i <= 64; i++)
		s->sa_rc[i] = sigaction(i, NULL, &s->sa[i]);
	s->threads = count_threads();
	s->fds = count_fds();
	getrlimit(RLIMIT_MEMLOCK, &s->memlock);
}

static void run_all(void)
{
	struct pstate s0, s1;
	snap(&s0);
	int64_t obj, k;
	struct res a = load(MAPS, "{", &obj), b = load(MAPS, "{\"set\":{\"r8\":-1}}", &obj), c = load(MAPS, "{\"sett\":{}}", &obj);
	check("G1", a.kind == 2 && b.kind == 2 && c.kind == 2, "%lld / %lld / %lld", (long long)a.kind, (long long)b.kind, (long long)c.kind);
	a = load(MAPS_NOGLOBALS, "{\"set\":{\"r8\":1}}", &obj);
	check("G2", a.kind == 2, "%lld \"%.120s\"", (long long)a.kind, a.msg);
	a = load(MAPS, "{\"set\":{\"nope\":1}}", &obj);
	b = load(MAPS, "{\"set\":{\"b64a\":1}}", &obj);
	check("G3", a.kind == 8 && b.kind == 8, "%lld / %lld", (long long)a.kind, (long long)b.kind);
	a = load(MAPS, "{\"set\":{\"r8\":256}}", &obj);
	b = load(MAPS, "{\"set\":{\"r16\":65536}}", &obj);
	check("G4", a.kind == 9 && b.kind == 9, "%lld / %lld", (long long)a.kind, (long long)b.kind);
	a = load(MAPS, NULL, &obj);
	check("G5", a.kind == 10 && strstr(a.msg, "r8, r16, r32, r64, r32b"), "%lld \"%s\"", (long long)a.kind, a.msg);
	a = load(MAPS, "{\"set\":{\"r8\":7},\"optional\":[\"r16\",\"r32\",\"r64\",\"r32b\"]}", &obj);
	int64_t v16 = gget(obj, G("r16", "rodata", "u16"), &k), k8, v8 = gget(obj, G("r8", "rodata", "u8"), &k8);
	check("G6", a.kind == 0 && k == 0 && v16 == 0 && k8 == 0 && v8 == 7, "load %lld, r16 %lld/%lld, r8 %lld/%lld \"%.120s\"", (long long)a.kind,
	      (long long)k, (long long)v16, (long long)k8, (long long)v8, a.msg);
	take(bml_close(obj));
	a = load(MAPS, "{\"set\":{\"r8\":1,\"r16\":2,\"r32\":3,\"r64\":4,\"r32b\":5}}", &obj);
	static const uint8_t frame[64];
	int runs = 0;
	for (int i = 0; i < 3; i++)
		runs += take(bml_test_run_xdp_data(obj, S("prog"), frame, 64)).kind == 0;
	int64_t ka, kb2, kc, kd;
	int64_t b64a = gget(obj, G("b64a", "bss", "u64"), &ka), b32 = gget(obj, G("b32", "bss", "u32"), &kb2), b64b = gget(obj, G("b64b", "bss", "u64"), &kc),
		r32 = gget(obj, G("r32", "rodata", "u32"), &kd);
	check("G7", a.kind == 0 && runs == 3 && !ka && !kb2 && !kc && !kd && b64a == 45 && b32 == 18 && b64b == 3 && r32 == 3,
	      "load %lld, run %d, b64a %lld, b32 %lld, b64b %lld, r32 %lld", (long long)a.kind, runs, (long long)b64a, (long long)b32, (long long)b64b,
	      (long long)r32);
	/* G10 (レビュー役の P3): libbpf が freeze した .rodata への直の update は kernel が EPERM で拒む */
	int frozen_fd = -1, n_frozen = 0;
	DIR *dd = opendir("/proc/self/fd");
	struct dirent *de;
	while (dd && (de = readdir(dd))) {
		char path[300], line[128];
		snprintf(path, sizeof path, "/proc/self/fdinfo/%s", de->d_name);
		FILE *f = fopen(path, "r");
		while (f && fgets(line, sizeof line, f))
			if (!strcmp(line, "frozen:\t1\n")) {
				n_frozen++;
				frozen_fd = atoi(de->d_name);
			}
		if (f)
			fclose(f);
	}
	if (dd)
		closedir(dd);
	int uerr = 0;
	if (frozen_fd >= 0) {
		struct bpf_map_info mi = {0};
		uint32_t il = sizeof mi, key0 = 0;
		uint8_t *zero = bpf_map_get_info_by_fd(frozen_fd, &mi, &il) == 0 ? calloc(1, mi.value_size ? mi.value_size : 1) : NULL;
		uerr = zero && bpf_map_update_elem(frozen_fd, &key0, zero, BPF_ANY) != 0 ? errno : 0;
		free(zero);
	}
	int64_t k10, r32b = gget(obj, G("r32", "rodata", "u32"), &k10);
	check("G10", n_frozen == 1 && uerr == EPERM && k10 == 0 && r32b == 3, "frozen map %d, update errno %d (EPERM %d), r32 %lld/%lld", n_frozen, uerr, EPERM,
	      (long long)k10, (long long)r32b);
	int64_t k1, k2, k3;
	gget(obj, G("r32", "rodata", "u16"), &k1);
	gget(obj, G("nope", "rodata", "u32"), &k2);
	take(bml_close(obj));
	gget(obj, G("r32", "rodata", "u32"), &k3);
	check("G8", k1 == 8 && k2 == 6 && k3 == 6, "wrong type %lld, nope %lld, after close %lld", (long long)k1, (long long)k2, (long long)k3);
	a = load(MAPS, "{\"set\":{\"r8\":10,\"r16\":20,\"r32\":30,\"r64\":40,\"r32b\":50}}", &obj);
	runs = 0;
	for (int i = 0; i < 2; i++)
		runs += take(bml_test_run_xdp_data(obj, S("prog"), frame, 64)).kind == 0;
	b64a = gget(obj, G("b64a", "bss", "u64"), &ka);
	b32 = gget(obj, G("b32", "bss", "u32"), &kb2);
	b64b = gget(obj, G("b64b", "bss", "u64"), &kc);
	int64_t r8 = gget(obj, G("r8", "rodata", "u8"), &kd);
	check("G9", a.kind == 0 && runs == 2 && b64a == 300 && b32 == 88 && b64b == 2 && r8 == 10, "load %lld, run %d, b64a %lld, b32 %lld, b64b %lld, r8 %lld",
	      (long long)a.kind, runs, (long long)b64a, (long long)b32, (long long)b64b, (long long)r8);
	take(bml_close(obj));
	snap(&s1);
	int sd = 0;
	for (int i = 1; i <= 64; i++)
		sd += s0.sa_rc[i] != s1.sa_rc[i] || (s0.sa_rc[i] == 0 && (s0.sa[i].sa_handler != s1.sa[i].sa_handler || s0.sa[i].sa_flags != s1.sa[i].sa_flags));
	check("P", sd == 0 && s0.threads == s1.threads && s0.memlock.rlim_cur == s1.memlock.rlim_cur && s0.fds == s1.fds,
	      "sigaction differs %d, thread %d -> %d, fd %d -> %d", sd, s0.threads, s1.threads, s0.fds, s1.fds);
}

int main(int argc, char **argv)
{
	if (argc != 4) {
		fprintf(stderr, "abi_globals all|notset <multi.bpf.o> <sha>\n");
		return 2;
	}
	elf = slurp(argv[2], &elf_len);
	sha = argv[3];
	if (!elf)
		return 2;
	if (!strcmp(argv[1], "all"))
		run_all();
	else {
		int64_t obj;
		struct res a = load(MAPS, NULL, &obj);
		check("G5s", a.kind == 10, "%lld (count BPF_PROG_LOAD and BPF_MAP_CREATE with strace)", (long long)a.kind);
	}
	free(elf);
	printf("abi_globals: FAIL %d\n", fails);
	return fails ? 1 : 0;
}
