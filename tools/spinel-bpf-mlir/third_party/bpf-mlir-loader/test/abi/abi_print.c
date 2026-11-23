/* abi_print — E025 の試験: object が load されている間の libbpf の print (attach の warning) が呼び手の stderr にも呼び手の callback にも
 * 出ず、object の close の後は呼び手の print (既定の stderr か呼び手の callback) に戻る。予測は E025 (走らせる前に commit)。
 * 試験の build (bml_testonly_ — asan / mut) だけ。
 *
 *   abi_print <e25kp.bpf.o> <sha>     (root、unshare -n の中。変異は BML_MUTANT で)
 * 各 case は "<id>: … — ok|FAIL" の 1 行 (stdout)。stderr (fd 2) は試験が file に付け替えて数える */
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <bpf/libbpf.h>

#include "bml/bml.h"
#include "bml/bml_testonly.h"

#define S(x) (x), (int64_t)strlen(x)
#define M_HITS "{\"name\":\"hits\",\"kind\":\"array\",\"key\":\"u32\",\"value\":\"u64\",\"max_entries\":8}"
#define MAPS "{\"globals\":[],\"maps\":[" M_HITS "]}"

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

struct res {
	int64_t kind, value;
	char msg[1024];
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

/* 呼び手の callback: 呼ばれた数と最初の行 */
static int cb_calls;
static char cb_first[256];
static int my_print(enum libbpf_print_level level, const char *fmt, va_list ap)
{
	(void)level;
	if (cb_calls++ == 0) {
		vsnprintf(cb_first, sizeof cb_first, fmt, ap);
		cb_first[strcspn(cb_first, "\n")] = 0; /* case の行を 1 行に */
	}
	return 0;
}

/* fd 2 の file の今の大きさと、off から先の最初の行 */
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

/* libbpf の print を起こす (壊れた ELF の open — libbpf の pr_warn) */
static void provoke(void)
{
	static const char junk[64] = "not an ELF";
	struct bpf_object *o = bpf_object__open_mem(junk, sizeof junk, NULL);
	if (o)
		bpf_object__close(o);
}

static uint8_t *elf;
static int64_t elf_n;
static const char *sha;

/* 照合しない load → attach (存在しない関数 — libbpf が warning を print) → 結果 */
static struct res load_attach(int64_t *obj)
{
	struct res r = take(bml_testonly_load_unchecked_targets(elf, elf_n, S(sha), S(MAPS), "", 0, "", 0));
	*obj = r.kind == 0 ? r.value : 0;
	if (r.kind != 0)
		return r;
	return take(bml_attach_kprobe(*obj, S("kp")));
}

int main(int argc, char **argv)
{
	if (argc != 3) {
		fprintf(stderr, "abi_print <e25kp.bpf.o> <sha>\n");
		return 2;
	}
	FILE *f = fopen(argv[1], "rb");
	if (!f)
		return 2;
	fseek(f, 0, SEEK_END);
	elf_n = ftell(f);
	fseek(f, 0, SEEK_SET);
	elf = malloc((size_t)elf_n);
	if (!elf || fread(elf, 1, (size_t)elf_n, f) != (size_t)elf_n)
		return 2;
	fclose(f);
	sha = argv[2];
	char path[] = P_tmpdir "/abi_print_err_XXXXXX";
	errfd = mkstemp(path);
	if (errfd < 0 || dup2(errfd, 2) < 0)
		return 2;
	unlink(path);
	char line[512];

	/* Q1: 呼び手は libbpf の既定の print (stderr)。object の間の attach の warning は stderr に出ない */
	int64_t obj;
	long e0 = err_size();
	struct res a = load_attach(&obj);
	long e1 = err_size();
	err_from(e0, line, sizeof line);
	check("Q1", obj != 0 && a.kind == 5 && e1 == e0, "attach %lld \"%s\", stderr +%ld byte \"%s\"", (long long)a.kind, a.msg, e1 - e0, line);
	/* Q2: close の後は既定の print に戻る (stderr に出る) */
	struct res c = take(bml_close(obj));
	e0 = err_size();
	provoke();
	e1 = err_size();
	err_from(e0, line, sizeof line);
	check("Q2", c.kind == 0 && e1 > e0 && strstr(line, "libbpf:"), "close %lld, print after close: stderr +%ld bytes \"%s\"", (long long)c.kind, e1 - e0,
	      line);
	/* Q3: 呼び手の callback。object の間の attach の warning は callback にも stderr にも届かない */
	libbpf_set_print(my_print);
	cb_calls = 0;
	e0 = err_size();
	a = load_attach(&obj);
	e1 = err_size();
	check("Q3", obj != 0 && a.kind == 5 && cb_calls == 0 && e1 == e0, "attach %lld, callback %d times \"%s\", stderr +%ld bytes", (long long)a.kind,
	      cb_calls, cb_first, e1 - e0);
	/* Q4: close の後は呼び手の callback に戻る */
	c = take(bml_close(obj));
	cb_calls = 0;
	cb_first[0] = 0;
	provoke();
	check("Q4", c.kind == 0 && cb_calls > 0, "close %lld, print after close: callback %d times \"%s\"", (long long)c.kind, cb_calls, cb_first);
	libbpf_set_print(NULL);
	printf("abi_print: ok %d, FAIL %d\n", oks, fails);
	return fails ? 1 : 0;
}
