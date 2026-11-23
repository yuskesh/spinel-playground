/* print_hold — E026 の試験: libbpf の print の借りを bml_obj (guard 付きの load の単位) の数で — 重なる 2 つの object の 1 つ目の close の後も
 * 2 つ目の間の warning が呼び手の stderr に漏れない・最後の close で戻る・同時の load の集めの log が thread ごと。予測は E026
 * (走らせる前に commit)。load の層を直に (C ABI の登録は同時に 1 つ — その下の重なりを作る)。
 *
 *   print_hold <e25kp.bpf.o>     (root、unshare -n の中。変異は BML_MUTANT で)
 * 各 case は "<id>: … — ok|FAIL" の 1 行 (stdout)。stderr (fd 2) は試験が file に付け替えて数える */
#define _GNU_SOURCE
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <bpf/libbpf.h>

#include "caps/live_caps.h"
#include "load/internal.h"
#include "load/load.h"
#include "req/from_elf.h"

#define REQ_LINE "skipping unrecognized data section(6) .ebpf_requirements"
#define K3_THREADS 4
#define K3_LOADS 30

static int fails, oks;
static void check(const char *id, int good, const char *fmt, ...) __attribute__((format(printf, 3, 4)));
static void check(const char *id, int good, const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	printf("%s: ", id);
	vprintf(fmt, ap);
	printf(" — %s\n", good ? "ok" : "FAIL");
	fflush(stdout);
	va_end(ap);
	fails += !good;
	oks += !!good;
}

static int errfd;
static long err_size(void)
{
	return lseek(errfd, 0, SEEK_END);
}
static void err_from(long off, char *buf, size_t cap)
{
	ssize_t n = pread(errfd, buf, cap - 1, off);
	buf[n > 0 ? n : 0] = 0;
	char *nl = strchr(buf, '\n');
	if (nl)
		*nl = 0;
}

static void provoke(void)
{
	static const char junk[64] = "not an ELF";
	struct bpf_object *o = bpf_object__open_mem(junk, sizeof junk, NULL);
	if (o)
		bpf_object__close(o);
}

static uint8_t *elf;
static size_t elf_n;
static struct bml_requirements *req;
static struct bml_caps caps;

static struct bml_obj *load1(struct bml_load_result *r)
{
	struct bml_obj *o = NULL;
	bml_load_guarded(elf, elf_n, req, &caps, &o, r);
	return o;
}

/* log の中の s の数と行の数 */
static int count(const char *log, const char *s)
{
	int n = 0;
	for (const char *p = log ? strstr(log, s) : NULL; p; p = strstr(p + 1, s))
		n++;
	return n;
}

/* K3: 同時の load — 各々の log が自分の 1 回分 (REQ_LINE ちょうど 1 つ・行 3 つ) */
static int bad_logs;
static pthread_mutex_t bad_mu = PTHREAD_MUTEX_INITIALIZER;
static void *loader(void *arg)
{
	(void)arg;
	for (int i = 0; i < K3_LOADS; i++) {
		struct bml_load_result r;
		struct bml_obj *o = load1(&r);
		int bad = !o || count(r.log, REQ_LINE) != 1 || count(r.log, "\n") != 3;
		pthread_mutex_lock(&bad_mu);
		bad_logs += bad;
		pthread_mutex_unlock(&bad_mu);
		bml_load_result_free(&r);
		bml_obj_close(o);
	}
	return NULL;
}

int main(int argc, char **argv)
{
	if (argc != 2) {
		fprintf(stderr, "print_hold <e25kp.bpf.o>\n");
		return 2;
	}
	FILE *f = fopen(argv[1], "rb");
	if (!f)
		return 2;
	fseek(f, 0, SEEK_END);
	elf_n = (size_t)ftell(f);
	fseek(f, 0, SEEK_SET);
	elf = malloc(elf_n);
	if (!elf || fread(elf, 1, elf_n, f) != elf_n)
		return 2;
	fclose(f);
	struct bml_req_elf_error ee;
	if (bml_req_from_elf(elf, elf_n, &req, &ee) != 0)
		return 2;
	struct bml_live_caps lc = {0};
	bml_live_caps(&lc, &caps);
	char path[] = P_tmpdir "/print_hold_err_XXXXXX";
	errfd = mkstemp(path);
	if (errfd < 0 || dup2(errfd, 2) < 0)
		return 2;
	unlink(path);
	char line[512];

	/* K1: A と B を load し A を閉じた後の B の attach の warning は stderr に出ない */
	struct bml_load_result ra, rb;
	struct bml_obj *a = load1(&ra), *b = load1(&rb);
	bml_load_result_free(&ra);
	bml_load_result_free(&rb);
	bml_obj_close(a);
	long e0 = err_size();
	struct bpf_program *p = b ? bpf_object__find_program_by_name(bml_obj_bpf(b), "kp") : NULL;
	struct bpf_link *l = p ? bpf_program__attach_kprobe(p, false, "bml_e025_no_such_function") : NULL;
	long e1 = err_size();
	err_from(e0, line, sizeof line);
	check("K1", a && b && p && !l && e1 == e0, "A %s B %s, B attach after A's close %s, stderr +%ld bytes \"%s\"", a ? "ok" : "failed", b ? "ok" : "failed",
	      l ? "succeeded (unexpected)" : "failed", e1 - e0, line);
	if (l)
		bpf_link__destroy(l);
	/* K2: 最後の close の後は既定の print (stderr) */
	bml_obj_close(b);
	e0 = err_size();
	provoke();
	e1 = err_size();
	err_from(e0, line, sizeof line);
	check("K2", e1 > e0 && strstr(line, "libbpf:"), "print after the last close: stderr +%ld bytes \"%s\"", e1 - e0, line);
	/* K3: K3_THREADS の thread の同時の load (K3_LOADS 回ずつ) — 各々の log は自分の 1 回分、stderr は増えない (E027 の前の gate で
	 * 2 × 20 では変異 shared_log の race が 3 回とも起きなかった — 数を上げた) */
	e0 = err_size();
	pthread_t th[K3_THREADS];
	for (int i = 0; i < K3_THREADS; i++)
		pthread_create(&th[i], NULL, loader, NULL);
	for (int i = 0; i < K3_THREADS; i++)
		pthread_join(th[i], NULL);
	e1 = err_size();
	check("K3", bad_logs == 0 && e1 == e0, "%d loads: load %d has a log not equal to one run, stderr +%ld bytes", K3_THREADS * K3_LOADS, bad_logs, e1 - e0);
	/* K4: 全て閉じた後は既定の print */
	e0 = err_size();
	provoke();
	e1 = err_size();
	check("K4", e1 > e0, "print after every close: stderr +%ld bytes", e1 - e0);
	bml_live_caps_free(&lc);
	bml_requirements_free(req);
	free(elf);
	printf("print_hold: ok %d, FAIL %d\n", oks, fails);
	return fails ? 1 : 0;
}
