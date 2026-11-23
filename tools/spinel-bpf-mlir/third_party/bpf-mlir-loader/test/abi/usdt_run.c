/* usdt_run — E044 の差動の C の側 (Go の側は test/oracle/cmd/usdt-attach-oracle — 同じ入力・起こし方・同じ形の行):
 *   usdt_run points <fixture>                                   点の計算 (attach しない — 非 root)
 *   usdt_run run <ELF> <schema の sha256> <fixture> <mode>       root — mode は point (製品の形)・multi・multi_perf (試験の口 bml_testonly_usdt_mode)
 * run は ELF を試験の口の照合しない load (fixture を uhit・ugrd の target に)、fixture の写しを子 process で走らせ、bml_attach_usdt を子の PID で、
 * spec の map の全ての key・fixture の stdout・ring buffer の event・残りの link の数を書く。multi_perf は attach の結果 (kernel の答え) だけを書く。
 * ref_ctr を渡さない対照は変異 usdt.no_ref_ctr (tools-mut)。 */
#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#include <bpf/bpf.h>
#include <bpf/libbpf.h>

#include "abi/internal.h"
#include "bml/bml.h"
#include "bml/bml_testonly.h"
#include "load/load.h"
#include "req/usdt.h"

#define S(x) (x), (int64_t)strlen(x)

static const uint64_t lines[4][2] = {{5, 100}, {4294967295u, 18446744073709551615ull}, {0, 0}, {123456, 1ull << 40}};
static const char *const probes[2][2] = {{"uhit", "hit"}, {"ugrd", "guarded"}};

#define M_EVENTS "{\"name\":\"events\",\"kind\":\"ringbuf\",\"key\":\"-\",\"value\":\"record:ev\",\"max_entries\":4096}"
#define R_EV                                                                                                                       \
	"{\"ev\":{\"size\":48,\"members\":[{\"name\":\"prog\",\"offset\":0,\"type\":\"u64\"},{\"name\":\"cookie\",\"offset\":8,\"type\":\"u64\"},"     \
	"{\"name\":\"v1\",\"offset\":16,\"type\":\"i64\"},{\"name\":\"st1\",\"offset\":24,\"type\":\"i64\"},{\"name\":\"v2\",\"offset\":32,\"type\":\"u64\"}," \
	"{\"name\":\"st2\",\"offset\":40,\"type\":\"i64\"}]}}"

static void die(const char *fmt, const char *a)
{
	fprintf(stderr, "usdt_run: ");
	fprintf(stderr, fmt, a);
	fprintf(stderr, "\n");
	exit(1);
}

static uint8_t *slurp(const char *path, size_t *n)
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
	*n = (size_t)l;
	return p;
}

static void hex(const uint8_t *b, size_t n)
{
	for (size_t i = 0; i < n; i++)
		printf("%02x", b[i]);
}

static int points(const char *fx)
{
	size_t len;
	uint8_t *data = slurp(fx, &len);
	if (!data)
		die("cannot read %s", fx);
	for (int k = 0; k < 2; k++) {
		struct bml_usdt_attach_point *pts;
		size_t n;
		char *err;
		if (bml_usdt_attach_points(data, len, "p1d", probes[k][1], &pts, &n, &err) != 0)
			die("%s", err ? err : "out of memory");
		for (size_t i = 0; i < n; i++) {
			printf("point %s %zu pc=0x%llx off=0x%llx sem=0x%llx semoff=0x%llx spec=", /* Go の %#x (0 は 0x0) */ probes[k][1], pts[i].index, (unsigned long long)pts[i].pc,
			       (unsigned long long)pts[i].off, (unsigned long long)pts[i].semaphore, (unsigned long long)pts[i].sem_off);
			hex(pts[i].spec, BML_USDT_SPEC_SIZE);
			printf("\n");
		}
		free(pts);
	}
	free(data);
	return 0;
}

static int64_t take(int64_t r, const char *what)
{
	if (bml_result_kind(r) != 0) {
		int64_t ml;
		const char *m = bml_result_message(r, &ml);
		fprintf(stderr, "usdt_run: %s: kind %lld: %.*s\n", what, (long long)bml_result_kind(r), (int)ml, m);
		exit(1);
	}
	int64_t v = bml_result_value(r);
	bml_result_free(r);
	return v;
}

/* Go の %#x と同じ (0 は "0x0") */
static int run(const char *elfp, const char *sha, const char *fx, const char *mode)
{
	int prod = !strcmp(mode, "point") || !strcmp(mode, "checked") || !strcmp(mode, "product");
	take(bml_testonly_usdt_mode(prod ? "" : mode, prod ? 0 : (int64_t)strlen(mode)), "usdt_mode");
	size_t elen;
	uint8_t *elf = slurp(elfp, &elen);
	if (!elf)
		die("cannot read %s", elfp);
	char targets[2048];
	snprintf(targets, sizeof targets, "{\"uprobe_targets\":[{\"program\":\"uhit\",\"path\":\"%s\"},{\"program\":\"ugrd\",\"path\":\"%s\"}]}", fx, fx);
	int in[2], out[2];
	if (pipe(in) || pipe(out))
		die("%s", "pipe");
	pid_t child = fork();
	if (child == 0) {
		dup2(in[0], 0);
		dup2(out[1], 1);
		close(in[1]);
		close(out[0]);
		execl(fx, fx, (char *)NULL);
		_exit(127);
	}
	close(in[0]);
	close(out[1]);
	FILE *cin = fdopen(in[1], "w"), *cout = fdopen(out[0], "r");
	/* compiler の spec の map (__ebpf_usdt_spec_<program>) は schema に無い — 宣言の外を許す (Go の CheckMapDecls も同じく undeclared で止める) */
	const char *maps = "{\"allow_undeclared\":true,\"globals\":[],\"maps\":[" M_EVENTS "]}";
	if (!strcmp(mode, "checked")) { /* H6: 製品の照合する load (preset bml-libbpf-v1.7 — usdt_attach を宣言しない) の答え */
		int64_t r = bml_load_checked_targets(elf, (int64_t)elen, S(sha), S(maps), "", 0, S(targets), 0);
		printf("checked kind=%lld unmet=", (long long)bml_result_kind(r));
		for (int64_t i = 0; i < bml_result_unmet_count(r); i++) {
			int64_t l;
			const char *k = bml_result_unmet_field(r, i, 0, &l);
			printf("%s%.*s", i ? "," : "", (int)l, k);
		}
		printf("\n");
		if (bml_result_kind(r) == 0)
			bml_close(bml_result_value(r));
		bml_result_free(r);
		free(elf);
		fclose(cin);
		waitpid(child, NULL, 0);
		return 0;
	}
	fprintf(stderr, "usdt_run: load\n");
	/* E046: product は製品の照合する load (C ABI の宣言 — E052 から cilium-v0.22-usdt-ksyscall) — 他の mode は試験の口の照合しない load */
	int64_t obj = take(!strcmp(mode, "product") ? bml_load_checked_targets(elf, (int64_t)elen, S(sha), S(maps), "", 0, S(targets), 0)
						    : bml_testonly_load_unchecked_targets(elf, (int64_t)elen, S(sha), S(maps), "", 0, S(targets)),
			   "load");
	{ /* load した program の expected_attach_type (製品は 0、multi / multi_perf は libbpf の BPF_TRACE_UPROBE_MULTI の見込み) を stderr に */
		struct abi_object *lo = abi_object_get(obj, &(int64_t){0});
		for (int k = 0; lo && k < 2; k++) {
			struct bpf_program *p = bpf_object__find_program_by_name(bml_obj_bpf(lo->lo), probes[k][0]);
			fprintf(stderr, "usdt_run: %s expected_attach_type %d (BPF_TRACE_UPROBE_MULTI is %d)\n", probes[k][0],
				p ? (int)bpf_program__expected_attach_type(p) : -1, (int)BPF_TRACE_UPROBE_MULTI);
		}
	}
	fprintf(stderr, "usdt_run: attach\n");
	free(elf);
	int64_t links[2];
	for (int k = 0; k < 2; k++) {
		int64_t r = bml_attach_usdt(obj, S(probes[k][0]), child);
		if (!strcmp(mode, "multi_perf")) { /* kernel の答えだけ (UPROBE_MULTI の program を点ごとの uprobe で) */
			int64_t ml;
			const char *m = bml_result_message(r, &ml);
			printf("attach %s kind=%lld %.*s\n", probes[k][0], (long long)bml_result_kind(r), (int)ml, m);
			if (bml_result_kind(r) == 0)
				bml_detach(bml_result_value(r));
			bml_result_free(r);
			links[k] = 0;
			continue;
		}
		links[k] = take(r, "attach");
	}
	if (!strcmp(mode, "multi_perf")) {
		fclose(cin);
		waitpid(child, NULL, 0);
		take(bml_close(obj), "close");
		return 0;
	}
	struct abi_object *o = abi_object_get(obj, &(int64_t){0});
	for (int k = 0; k < 2; k++) {
		char mn[64];
		snprintf(mn, sizeof mn, "%s%s", BML_USDT_SPEC_MAP_PREFIX, probes[k][0]);
		struct bpf_map *m = bpf_object__find_map_by_name(bml_obj_bpf(o->lo), mn);
		uint8_t v[BML_USDT_SPEC_SIZE];
		for (uint32_t key = 0; m && key < bpf_map__max_entries(m); key++) {
			if (bpf_map__lookup_elem(m, &key, sizeof key, v, sizeof v, 0) != 0)
				die("%s", "spec lookup");
			printf("spec %s %u ", probes[k][0], key);
			hex(v, sizeof v);
			printf("\n");
		}
	}
	char buf[512];
	for (int i = 0; i < 4; i++) {
		fprintf(cin, "%llu %llu\n", (unsigned long long)lines[i][0], (unsigned long long)lines[i][1]);
		fflush(cin);
		while (fgets(buf, sizeof buf, cout)) {
			buf[strcspn(buf, "\n")] = 0;
			printf("stdout %s\n", buf);
			if (!strncmp(buf, "ok", 2))
				break;
		}
	}
	fprintf(cin, "q\n");
	fclose(cin);
	waitpid(child, NULL, 0);
	/* link の kernel の id (detach の後に残らないことを確かめる) */
	uint32_t ids[64];
	size_t nid = 0;
	for (int k = 0; k < 2; k++) {
		struct abi_link *al = abi_handle_get(links[k], H_LINK);
		for (size_t i = 0; al && i < 1 + al->n_more && nid < 64; i++) {
			struct bpf_link *l = i == 0 ? al->l : al->more[i - 1];
			struct bpf_link_info info;
			uint32_t il = sizeof info;
			memset(&info, 0, sizeof info);
			if (bpf_link_get_info_by_fd(bpf_link__fd(l), &info, &il) == 0)
				ids[nid++] = info.id;
		}
		take(bml_detach(links[k]), "detach");
	}
	int64_t rd = take(bml_ringbuf_open(obj, S(M_EVENTS), S(R_EV), 48), "ringbuf_open");
	uint8_t ev[48];
	for (;;) {
		int64_t r = bml_ringbuf_read(rd, 500, ev, sizeof ev);
		if (bml_result_kind(r) != 0 || bml_result_value(r) == 0) {
			bml_result_free(r);
			break;
		}
		bml_result_free(r);
		uint64_t f[6];
		memcpy(f, ev, sizeof f);
		printf("event prog=%llu cookie=%llu v1=%lld st1=%lld v2=%llu st2=%lld\n", (unsigned long long)f[0], (unsigned long long)f[1], (long long)f[2],
		       (long long)f[3], (unsigned long long)f[4], (long long)f[5]);
	}
	take(bml_ringbuf_close(rd), "ringbuf_close");
	int left = 0;
	for (size_t i = 0; i < nid; i++) {
		int fd = bpf_link_get_fd_by_id(ids[i]);
		if (fd >= 0) {
			left++;
			close(fd);
		}
	}
	printf("left %d\n", left);
	take(bml_close(obj), "close");
	return 0;
}

int main(int argc, char **argv)
{
	setvbuf(stdout, NULL, _IOLBF, 0); /* 途中で止まった時に何処までかを見る */
	if (argc == 3 && !strcmp(argv[1], "points"))
		return points(argv[2]);
	if (argc == 6 && !strcmp(argv[1], "run") &&
	    (!strcmp(argv[5], "point") || !strcmp(argv[5], "multi") || !strcmp(argv[5], "multi_perf") || !strcmp(argv[5], "checked") ||
	     !strcmp(argv[5], "product")))
		return run(argv[2], argv[3], argv[4], argv[5]);
	fprintf(stderr, "usage: usdt_run points <fixture> | run <ELF> <sha256> <fixture> <point|multi|multi_perf>\n");
	return 2;
}
