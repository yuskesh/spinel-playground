/* attach_wave1 — E035 の差動の C の側: bpf-mlir の kernel/cmd/traceattach (cilium) と同じ入力 (kernel/{rawtp,retprobe,iter,fmodret} の mlir) を
 * bml で照合する load → E035 の attach → 同じ起こし方 → 同じ観測の文を 1 行目に出す (traceattach の ebpf の arm の観測と byte で比べる)。
 * 2 行目からは C ABI の対照 "check <名前> <kind>" (取り違え・小さな buffer・map 無しの iter 等 — 予測は scripts/attach-wave1-target.sh)。
 *
 *   attach_wave1 <mode> <ELF> <schema の sha256> <maps.json の文字列> [N | <fixture の binary>]
 *     mode: rawtp N | kretprobe N | uretprobe <binary> | iter | fmodret
 *   attach が失敗したときは 1 行目が "attach <kind>" (変異の対照 — 文は stderr)。root で (sudo unshare -n) */
#define _GNU_SOURCE
#include <errno.h>
#include <linux/bpf.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>

#include <bpf/bpf.h>
#include <bpf/libbpf.h>

#include "bml/bml.h"

#define S(x) (x), (int64_t)strlen(x)

static const char *maps_doc;

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

/* maps.json の map name の宣言 (要素の JSON をそのまま — 試験の文書は 1 行で要素の順は schema のまま) */
static char *decl_of(const char *name)
{
	char key[64];
	snprintf(key, sizeof key, "{\"name\":\"%s\"", name);
	const char *s = strstr(maps_doc, key);
	if (!s)
		return NULL;
	const char *e = strchr(s, '}');
	return strndup(s, (size_t)(e - s + 1));
}

static int64_t kind_of(int64_t r)
{
	int64_t k = bml_result_kind(r);
	if (k != 0) {
		int64_t mn = 0;
		const char *m = bml_result_message(r, &mn);
		fprintf(stderr, "attach_wave1: kind %lld: %.*s\n", (long long)k, (int)mn, m ? m : "");
	}
	return k;
}

/* 結果の kind を出して放す */
static void check(const char *name, int64_t r)
{
	printf("check %s %lld\n", name, (long long)kind_of(r));
	bml_result_free(r);
}

static uint64_t get(int64_t obj, const char *map, int64_t key)
{
	char *d = decl_of(map);
	int64_t r = bml_map_get_bits(obj, S(d), key);
	uint64_t v = bml_result_kind(r) == 0 ? (uint64_t)bml_result_value(r) : (uint64_t)-1;
	bml_result_free(r);
	free(d);
	return v;
}

static void set_cfg(int64_t obj, uint32_t v)
{
	char *d = decl_of("cfg");
	bml_result_free(bml_map_put_bits(obj, S(d), 0, v));
	free(d);
}

/* attach の結果 (失敗なら 1 行目に "attach <kind>" を出して -1) */
static int64_t take_link(int64_t r)
{
	int64_t k = kind_of(r);
	int64_t l = k == 0 ? bml_result_value(r) : -1;
	bml_result_free(r);
	if (k != 0)
		printf("attach %lld\n", (long long)k);
	return l;
}

static int mode_rawtp(int64_t obj, int n)
{
	int64_t l = take_link(bml_attach_raw_tp(obj, S("rawtp")));
	if (l < 0)
		return 1;
	set_cfg(obj, (uint32_t)getpid());
	for (int i = 0; i < n; i++)
		syscall(SYS_getppid);
	printf("tp=sys_enter getppid=%u\n", (uint32_t)get(obj, "out", 1));
	bml_result_free(bml_detach(l));
	check("kprobe_on_rawtp", bml_attach_kprobe(obj, S("rawtp")));
	check("iter_open_rawtp_link", bml_iter_open(l)); /* detach 済みの link — STATE */
	return 0;
}

/* bpf_fentry_test1 の fentry の小さな program (起こし — traceattach と同じ: test run が bpf_fentry_test1(1) を呼ぶ) */
static int trigger_prog(void)
{
	int id = libbpf_find_vmlinux_btf_id("bpf_fentry_test1", BPF_TRACE_FENTRY);
	if (id < 0)
		return -1;
	struct bpf_insn ins[2] = {{.code = BPF_ALU64 | BPF_MOV | BPF_K, .dst_reg = 0, .imm = 0}, {.code = BPF_JMP | BPF_EXIT}};
	LIBBPF_OPTS(bpf_prog_load_opts, po, .expected_attach_type = BPF_TRACE_FENTRY, .attach_btf_id = (uint32_t)id);
	return bpf_prog_load(BPF_PROG_TYPE_TRACING, "trig", "GPL", ins, 2, &po);
}

static int mode_kretprobe(int64_t obj, int n)
{
	int64_t l = take_link(bml_attach_kretprobe(obj, S("kret")));
	if (l < 0)
		return 1;
	set_cfg(obj, (uint32_t)getpid());
	int t = trigger_prog();
	if (t < 0) {
		fprintf(stderr, "attach_wave1: trigger program: %s\n", strerror(errno));
		return 2;
	}
	for (int i = 0; i < n; i++) {
		LIBBPF_OPTS(bpf_test_run_opts, to);
		if (bpf_prog_test_run_opts(t, &to) != 0) {
			fprintf(stderr, "attach_wave1: trigger test run: %s\n", strerror(errno));
			return 2;
		}
	}
	close(t);
	printf("fn=bpf_fentry_test1 last=%lld count=%llu sum=%llu\n", (long long)get(obj, "out", 0), (unsigned long long)get(obj, "out", 1),
	       (unsigned long long)get(obj, "out", 2));
	bml_result_free(bml_detach(l));
	check("kprobe_on_kretprobe", bml_attach_kprobe(obj, S("kret")));
	check("fentry_on_kretprobe", bml_attach_fentry(obj, S("kret")));
	check("uretprobe_on_kretprobe", bml_attach_uretprobe(obj, S("kret"), 0));
	return 0;
}

static const uint64_t pairs[5][2] = {{1, 2}, {10, 20}, {4294967295ULL, 1ULL << 40}, {0, 0}, {7, 9}};

static int mode_uretprobe(int64_t obj, const char *bin)
{
	int in[2], out[2];
	if (pipe(in) || pipe(out))
		return 2;
	pid_t pid = fork();
	if (pid == 0) {
		dup2(in[0], 0);
		dup2(out[1], 1);
		close(in[1]);
		close(out[0]);
		execl(bin, bin, (char *)NULL);
		_exit(127);
	}
	close(in[0]);
	close(out[1]);
	FILE *w = fdopen(in[1], "w"), *r = fdopen(out[0], "r");
	set_cfg(obj, (uint32_t)pid);
	int64_t l = take_link(bml_attach_uretprobe(obj, S("uret"), 0));
	int rc = 0;
	if (l < 0) {
		rc = 1;
		goto done;
	}
	uint64_t sum = 0;
	for (int i = 0; i < 5; i++) {
		char resp[256];
		fprintf(w, "%llu %llu\n", (unsigned long long)pairs[i][0], (unsigned long long)pairs[i][1]);
		fflush(w);
		if (!fgets(resp, sizeof resp, r) || strncmp(resp, "ok ", 3) != 0) {
			fprintf(stderr, "attach_wave1: fixture: %s\n", resp);
			rc = 2;
			goto done;
		}
		sum += pairs[i][0] + pairs[i][1];
	}
	(void)sum;
	printf("sym=probe_target last=%llu count=%llu sum=%llu\n", (unsigned long long)get(obj, "out", 0), (unsigned long long)get(obj, "out", 1),
	       (unsigned long long)get(obj, "out", 2));
	{
		int64_t fr = bml_uprobe_link_file(obj, l);
		check("uprobe_link_file_of_uretprobe", fr);
	}
	bml_result_free(bml_detach(l));
	check("uprobe_on_uretprobe", bml_attach_uprobe(obj, S("uret"), 0));
	check("kretprobe_on_uretprobe", bml_attach_kretprobe(obj, S("uret")));
done:
	fprintf(w, "q\n");
	fclose(w);
	fclose(r);
	waitpid(pid, NULL, 0);
	return rc;
}

static int mode_iter(int64_t obj)
{
	int m = bpf_map_create(BPF_MAP_TYPE_ARRAY, "iter_elems", 4, 4, 4, NULL);
	if (m < 0)
		return 2;
	int64_t nm = bml_attach_iter(obj, S("elem"), -1); /* check の行は観測の行の後に (1 行目は観測) */
	int64_t nmk = kind_of(nm);
	bml_result_free(nm);
	int64_t l = take_link(bml_attach_iter(obj, S("elem"), m));
	if (l < 0)
		return 1;
	uint8_t buf[4096];
	int64_t rr = bml_iter_read(l, buf, sizeof buf);
	int64_t n = kind_of(rr) == 0 ? bml_result_value(rr) : -1;
	bml_result_free(rr);
	printf("bytes=%lld records=", (long long)n);
	for (int64_t off = 0; off + 16 <= n; off += 16) {
		uint64_t seq;
		uint32_t mark;
		memcpy(&seq, buf + off, 8);
		memcpy(&mark, buf + off + 8, 4);
		printf("%s%llu/%#x", off ? "," : "", (unsigned long long)seq, mark);
	}
	if (n > 0 && n % 16)
		printf(" tail=%lld", (long long)(n % 16));
	printf("\n");
	printf("check iter_no_map %lld\n", (long long)nmk);
	check("iter_read_short", bml_iter_read(l, buf, n > 0 ? n - 1 : 0));
	check("iter_read_exact", bml_iter_read(l, buf, n));
	/* iter_open の fd を呼び手として読む — iter_read と同じ byte か */
	int64_t orr = bml_iter_open(l);
	if (bml_result_kind(orr) == 0) {
		int fd = (int)bml_result_value(orr);
		uint8_t b2[4096];
		ssize_t got = 0, x;
		while ((x = read(fd, b2 + got, sizeof b2 - (size_t)got)) > 0)
			got += x;
		close(fd);
		printf("check iter_open_same %d\n", got == n && !memcmp(b2, buf, (size_t)n) ? 0 : 1);
	} else
		printf("check iter_open_same %lld\n", (long long)bml_result_kind(orr));
	bml_result_free(orr);
	bml_result_free(bml_detach(l));
	check("fentry_on_iter", bml_attach_fentry(obj, S("elem")));
	close(m);
	return 0;
}

/* この process の fd の中の名前の tracing の program (library が持つ fd を dup) — test run の retval を読むため (bml の tracing の test run は
 * tid を返す)。BPF_PROG_GET_NEXT_ID は CAP_SYS_ADMIN が要るので使わない (bpf+perfmon でも動く形) */
static int prog_by_name(const char *name)
{
	for (int fd = 3; fd < 1024; fd++) {
		struct bpf_prog_info info;
		uint32_t len = sizeof info;
		memset(&info, 0, sizeof info);
		if (bpf_prog_get_info_by_fd(fd, &info, &len) == 0 && info.type == BPF_PROG_TYPE_TRACING && !strcmp(info.name, name))
			return dup(fd);
	}
	return -1;
}

static int mode_fmodret(int64_t obj)
{
	int64_t l = take_link(bml_attach_fmod_ret(obj, S("modret")));
	if (l < 0)
		return 1;
	int fd = prog_by_name("modret");
	LIBBPF_OPTS(bpf_test_run_opts, to);
	if (fd < 0 || bpf_prog_test_run_opts(fd, &to) != 0) {
		fprintf(stderr, "attach_wave1: test run: %s\n", strerror(errno));
		return 2;
	}
	close(fd);
	printf("retval=%d a=%u\n", (int32_t)to.retval, (uint32_t)get(obj, "out", 0));
	bml_result_free(bml_detach(l));
	check("fentry_on_fmodret", bml_attach_fentry(obj, S("modret")));
	check("raw_tp_on_fmodret", bml_attach_raw_tp(obj, S("modret")));
	return 0;
}

int main(int argc, char **argv)
{
	if (argc < 5) {
		fprintf(stderr, "attach_wave1 <mode> <ELF> <sha> <maps.json> [N | binary]\n");
		return 2;
	}
	const char *mode = argv[1];
	maps_doc = argv[4];
	int64_t elen = 0;
	uint8_t *elf = slurp(argv[2], &elen);
	if (!elf)
		return 2;
	int64_t lr;
	if (!strcmp(mode, "uretprobe")) {
		char tg[4096];
		snprintf(tg, sizeof tg, "{\"uprobe_targets\":[{\"program\":\"uret\",\"path\":\"%s\"}]}", argc > 5 ? argv[5] : "");
		lr = bml_load_checked_targets(elf, elen, S(argv[3]), S(maps_doc), "", 0, S(tg), 0);
	} else
		lr = bml_load_checked(elf, elen, S(argv[3]), S(maps_doc), 0);
	free(elf);
	if (kind_of(lr) != 0) {
		printf("load %lld\n", (long long)bml_result_kind(lr));
		bml_result_free(lr);
		return 1;
	}
	int64_t obj = bml_result_value(lr);
	bml_result_free(lr);
	int n = argc > 5 ? atoi(argv[5]) : 0, rc;
	if (!strcmp(mode, "rawtp"))
		rc = mode_rawtp(obj, n);
	else if (!strcmp(mode, "kretprobe"))
		rc = mode_kretprobe(obj, n);
	else if (!strcmp(mode, "uretprobe"))
		rc = mode_uretprobe(obj, argv[5]);
	else if (!strcmp(mode, "iter"))
		rc = mode_iter(obj);
	else if (!strcmp(mode, "fmodret"))
		rc = mode_fmodret(obj);
	else
		rc = 2;
	bml_result_free(bml_close(obj));
	return rc;
}
