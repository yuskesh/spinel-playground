/* trace_diff — E012 H4 の差動の driver: 同じ操作の列を mojo の Go の loader (試験の c-archive — -DMOJO) か bml に。各段を 1 行
 * ("<段> kind=<k> …") で印字し、scripts/trace-diff.sh が 2 つの出力を比べる。tid と pid_tgid は値でなく関係で印字 (実行ごとに違う)。
 *
 *   trace_diff <tr.bpf.o> <sha>     (root、unshare -n の中) */
#define _GNU_SOURCE
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

#define S(x) (x), (int64_t)strlen(x)
#define M_CTL "{\"name\":\"ctl\",\"kind\":\"array\",\"key\":\"u32\",\"value\":\"u64\",\"max_entries\":1}"
#define M_HITS "{\"name\":\"hits\",\"kind\":\"array\",\"key\":\"u32\",\"value\":\"u64\",\"max_entries\":8}"
#define MAPS "{\"maps\":[" M_CTL "," M_HITS "]}"

#ifdef MOJO
/* mojo-bpf-mlir loader/main.go の export (5a53a6d — E099 で load は _targets (target と設定値の文書も) だけに) */
int64_t mojobpf_load_checked_targets(const uint8_t *, int64_t, const char *, int64_t, const char *, int64_t, const char *, int64_t, const char *, int64_t,
				     const char *, int64_t, int32_t);
int32_t mojobpf_result_kind(int64_t);
int64_t mojobpf_result_value(int64_t);
void mojobpf_result_free(int64_t);
int64_t mojobpf_attach_fentry(int64_t, const char *, int64_t);
int64_t mojobpf_attach_fexit(int64_t, const char *, int64_t);
int64_t mojobpf_attach_kprobe(int64_t, const char *, int64_t);
int64_t mojobpf_attach_xdp(int64_t, const char *, int64_t, const char *, int64_t);
int64_t mojobpf_test_run_tracing(int64_t, const char *, int64_t, uint32_t);
int64_t mojobpf_detach(int64_t);
int64_t mojobpf_map_get(int64_t, const char *, int64_t, uint32_t);
int64_t mojobpf_map_put(int64_t, const char *, int64_t, uint32_t, uint64_t);
int64_t mojobpf_close(int64_t);
#define R_KIND mojobpf_result_kind
#define R_VALUE mojobpf_result_value
#define R_FREE mojobpf_result_free
#define LOAD(e, n, sha) mojobpf_load_checked_targets(e, n, S(sha), S(MAPS), "", 0, "", 0, "", 0, 0)
#define FENTRY mojobpf_attach_fentry
#define FEXIT mojobpf_attach_fexit
#define KPROBE mojobpf_attach_kprobe
#define RUN(o, p, n) mojobpf_test_run_tracing(o, S(p), (uint32_t)(n))
#define DETACH mojobpf_detach
#define GET(o, k) mojobpf_map_get(o, S(M_HITS), k)
#define PUT_CTL(o, v) mojobpf_map_put(o, S(M_CTL), 0, v)
#define CLOSE mojobpf_close
#else
#include "bml/bml.h"
#define R_KIND bml_result_kind
#define R_VALUE bml_result_value
#define R_FREE bml_result_free
#define LOAD(e, n, sha) bml_load_checked(e, n, S(sha), S(MAPS), 0)
#define FENTRY bml_attach_fentry
#define FEXIT bml_attach_fexit
#define KPROBE bml_attach_kprobe
#define RUN(o, p, n) bml_test_run_tracing(o, S(p), n)
#define DETACH bml_detach
#define GET(o, k) bml_map_get_bits(o, S(M_HITS), k)
#define PUT_CTL(o, v) bml_map_put_bits(o, S(M_CTL), 0, v)
#define CLOSE bml_close
#endif

static int64_t obj;
static pid_t pid, me;

static int64_t kv(int64_t r, int64_t *value)
{
	int64_t k = R_KIND(r);
	if (value)
		*value = R_VALUE(r);
	R_FREE(r);
	return k;
}

/* hits の 7 slot (pid_tgid の slot 1・6 は関係: "self:<tid の名>" か値の 16 進) */
static void dump(const char *step, pid_t run_tid, pid_t worker)
{
	printf("%s hits", step);
	for (int k = 0; k < 7; k++) {
		int64_t v = 0;
		int64_t kind = kv(GET(obj, k), &v);
		uint64_t u = (uint64_t)v;
		if (kind != 0)
			printf(" %d:kind%lld", k, (long long)kind);
		else if ((k == 1 || k == 6) && u && run_tid && u == ((uint64_t)pid << 32 | (uint32_t)run_tid))
			printf(" %d:pid|run", k);
		else if ((k == 1 || k == 6) && u && worker && u == ((uint64_t)pid << 32 | (uint32_t)worker))
			printf(" %d:pid|worker", k);
		else if ((k == 1 || k == 6) && u)
			printf(" %d:other", k);
		else
			printf(" %d:%llu", k, (unsigned long long)u);
	}
	printf("\n");
}

static void *poller(void *arg)
{
	pid_t *tid = arg;
	*tid = (pid_t)syscall(SYS_gettid);
	kv(PUT_CTL(obj, (uint64_t)*tid), NULL);
	syscall(SYS_poll, NULL, 3, 0);
	return NULL;
}
static pid_t poll_on_worker(void)
{
	pthread_t th;
	pid_t tid = 0;
	pthread_create(&th, NULL, poller, &tid);
	pthread_join(th, NULL);
	return tid;
}

static pid_t last_run;
static void run(const char *step, const char *prog, int64_t n)
{
	int64_t v = 0, k = kv(RUN(obj, prog, n), &v);
	pid_t t = (pid_t)v;
	if (k == 0)
		last_run = t;
	printf("%s kind=%lld tid:%s\n", step, (long long)k, k != 0 ? "-" : t > 0 && t != me && t != pid ? "other-thread" : t == me ? "caller" : "bad");
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

int main(int argc, char **argv)
{
	if (argc != 3) {
		fprintf(stderr, "trace_diff <tr.bpf.o> <sha>\n");
		return 2;
	}
	setvbuf(stdout, NULL, _IOLBF, 0);
	pid = getpid();
	me = (pid_t)syscall(SYS_gettid);
	int64_t n = 0;
	uint8_t *elf = slurp(argv[1], &n);
	int64_t k = kv(LOAD(elf, n, argv[2]), &obj);
	free(elf);
	printf("01-load kind=%lld\n", (long long)k);
	if (k != 0)
		return 1;
	int64_t lfe = 0, lfx = 0, lkp = 0;
	printf("02-fentry kind=%lld\n", (long long)kv(FENTRY(obj, S("fe")), &lfe));
	printf("03-fexit kind=%lld\n", (long long)kv(FEXIT(obj, S("fx")), &lfx));
	run("04-run-fe-3", "fe", 3);
	dump("04-run-fe-3", last_run, 0);
	run("05-run-fx-2", "fx", 2);
	dump("05-run-fx-2", last_run, 0);
	printf("06-wrong kinds=%lld,%lld,%lld,%lld,%lld,%lld,%lld,%lld\n", (long long)kv(FENTRY(obj, S("fx")), NULL),
	       (long long)kv(FENTRY(obj, S("xp")), NULL), (long long)kv(FENTRY(obj, S("kp")), NULL), (long long)kv(FEXIT(obj, S("fe")), NULL),
	       (long long)kv(KPROBE(obj, S("fe")), NULL), (long long)kv(KPROBE(obj, S("xp")), NULL), (long long)kv(RUN(obj, "xp", 1), NULL),
	       (long long)kv(RUN(obj, "kp", 1), NULL));
	run("07-run-fe-0", "fe", 0);
	dump("07-run-fe-0", 0, 0);
	printf("08-detach kinds=%lld,%lld\n", (long long)kv(DETACH(lfe), NULL), (long long)kv(DETACH(lfx), NULL));
	run("09-run-fe-1", "fe", 1);
	dump("09-run-fe-1", 0, 0);
	printf("10-kprobe kind=%lld\n", (long long)kv(KPROBE(obj, S("kp")), &lkp));
	pid_t w = poll_on_worker();
	dump("11-poll", 0, w);
	printf("12-detach kind=%lld\n", (long long)kv(DETACH(lkp), NULL));
	poll_on_worker();
	dump("13-poll", 0, w);
	printf("14-close kind=%lld\n", (long long)kv(CLOSE(obj), NULL));
	printf("15-after kinds=%lld,%lld,%lld\n", (long long)kv(FENTRY(obj, S("fe")), NULL), (long long)kv(KPROBE(obj, S("kp")), NULL),
	       (long long)kv(RUN(obj, "fe", 1), NULL));
	return 0;
}
