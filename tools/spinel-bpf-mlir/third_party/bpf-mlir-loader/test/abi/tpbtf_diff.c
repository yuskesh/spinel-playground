/* tpbtf_diff — E024 の差動の C の側: 試験の口の照合しない load (bml_testonly_load_unchecked_targets — cilium の NewCollection と同じく照合を
 * 飛ばす) の後に tp_btf の program の test run・bml_attach_tp_btf・fork 8 回・detach の後を、test/oracle/cmd/tpbtf-oracle と同じ欄の 1 行に出す。
 * tp= は attach の照らしが通れば宣言の名前 (bml は link の info を宣言と照らした後にだけ OK を返す)。権限の組は呼び手 (setpriv) が決める。
 *
 *   tpbtf_diff <label> <ELF> <sha> <prog> <tracepoint>
 *   → "<label> load=<c> run=<c> attach=<c> tp=<名前|-> fork8=<yes|no> detached=<quiet|moved>" (c は ok・eperm・efault・other) */
#define _GNU_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#include "bml/bml.h"
#include "bml/bml_testonly.h"

#define S(x) (x), (int64_t)strlen(x)
#define M_HITS "{\"name\":\"hits\",\"kind\":\"array\",\"key\":\"u32\",\"value\":\"u64\",\"max_entries\":8}"
#define MAPS "{\"globals\":[],\"maps\":[" M_HITS "]}"

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

static const char *cls(const struct res *r)
{
	if (r->kind == 0)
		return "ok";
	if (strstr(r->msg, "operation not permitted"))
		return "eperm";
	if (strstr(r->msg, "bad address"))
		return "efault";
	return "other";
}

static uint64_t hits(int64_t o)
{
	struct res r = take(bml_map_get_bits(o, S(M_HITS), 0));
	return r.kind == 0 ? (uint64_t)r.value : UINT64_MAX;
}

static void forks(int n)
{
	for (int i = 0; i < n; i++) {
		pid_t c = fork();
		if (c == 0)
			_exit(0);
		if (c > 0)
			waitpid(c, NULL, 0);
	}
}

int main(int argc, char **argv)
{
	if (argc != 6) {
		fprintf(stderr, "tpbtf_diff <label> <ELF> <sha> <prog> <tracepoint>\n");
		return 2;
	}
	const char *label = argv[1], *prog = argv[4], *tpn = argv[5];
	FILE *f = fopen(argv[2], "rb");
	if (!f)
		return 2;
	fseek(f, 0, SEEK_END);
	long l = ftell(f);
	fseek(f, 0, SEEK_SET);
	uint8_t *elf = malloc((size_t)l);
	if (!elf || fread(elf, 1, (size_t)l, f) != (size_t)l)
		return 2;
	fclose(f);
	struct res r = take(bml_testonly_load_unchecked_targets(elf, l, S(argv[3]), S(MAPS), "", 0, "", 0));
	free(elf);
	if (r.kind != 0) {
		fprintf(stderr, "load: %lld %s\n", (long long)r.kind, r.msg);
		printf("%s load=%s run=- attach=- tp=- fork8=- detached=-\n", label, cls(&r));
		return 0;
	}
	int64_t o = r.value;
	struct res run = take(bml_test_run_tracing(o, S(prog), 1));
	if (run.kind != 0)
		fprintf(stderr, "run: %s\n", run.msg);
	struct res a = take(bml_attach_tp_btf(o, S(prog)));
	if (a.kind != 0) {
		fprintf(stderr, "attach: %lld %s\n", (long long)a.kind, a.msg);
		printf("%s load=ok run=%s attach=%s tp=- fork8=- detached=-\n", label, cls(&run), cls(&a));
		take(bml_close(o));
		return 0;
	}
	uint64_t h0 = hits(o);
	forks(8);
	const char *fork8 = hits(o) >= h0 + 8 ? "yes" : "no";
	take(bml_detach(a.value));
	h0 = hits(o);
	forks(8);
	const char *det = hits(o) == h0 ? "quiet" : "moved";
	printf("%s load=ok run=%s attach=ok tp=%s fork8=%s detached=%s\n", label, cls(&run), tpn, fork8, det);
	take(bml_close(o));
	return 0;
}
