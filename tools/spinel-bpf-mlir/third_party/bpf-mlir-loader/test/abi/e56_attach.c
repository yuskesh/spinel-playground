/* e56_attach — E056 の H3 (root で): .dynsym だけの本体 (scripts/e56-fixtures.sh の dynsym) の e56_fn に、製品の照合する load (bml_load_checked_targets —
 * uretprobe の DWARF は分けた file の debug) の後に bml_attach_uprobe / bml_attach_uretprobe で自分の子 process だけに付け、子に 4 回呼ばせて数を読む。
 *
 *   e56_attach <elf> <schema の sha256> <maps.json> <本体> <分けた DWARF>
 * 出力: "load=<kind> up=<kind> ur=<kind> hits=<uprobe>,<uretprobe> calls=<n>" と attach の誤りの文 */
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#include "bml/bml.h"

#define S(s) (s), (int64_t)strlen(s)
static const char *HITS = "{\"name\":\"hits\",\"kind\":\"array\",\"key\":\"u32\",\"value\":\"u64\",\"max_entries\":2}";

static char *slurp(const char *path, int64_t *n)
{
	FILE *f = fopen(path, "rb");
	char *b = NULL;
	long l = f && !fseek(f, 0, SEEK_END) ? ftell(f) : -1;
	if (l >= 0 && !fseek(f, 0, SEEK_SET) && (b = malloc((size_t)l + 1)) && fread(b, 1, (size_t)l, f) == (size_t)l)
		b[l] = 0, *n = l;
	else
		free(b), b = NULL;
	if (f)
		fclose(f);
	return b;
}

static int64_t kind_msg(int64_t r, const char *what)
{
	int64_t k = bml_result_kind(r);
	if (k != 0) {
		char m[512] = "";
		bml_result_message_copy(r, m, sizeof m);
		printf("%s: kind=%lld %s\n", what, (long long)k, m);
	}
	return k;
}

int main(int argc, char **argv)
{
	if (argc != 6) {
		fprintf(stderr, "usage: e56_attach <elf> <sha> <maps.json> <binary> <debug>\n");
		return 2;
	}
	int64_t n, mn;
	char *elf = slurp(argv[1], &n), *maps = slurp(argv[3], &mn), tg[2048];
	if (!elf || !maps)
		return 2;
	snprintf(tg, sizeof tg, "{\"uprobe_targets\":[{\"program\":\"up\",\"path\":\"%s\"},{\"program\":\"ur\",\"path\":\"%s\",\"debug\":\"%s\"}]}", argv[4], argv[4], argv[5]);
	int64_t lr = bml_load_checked_targets((const uint8_t *)elf, n, S(argv[2]), maps, mn, NULL, 0, S(tg), 0);
	int64_t lk = kind_msg(lr, "load"), obj = lk == 0 ? bml_result_value(lr) : 0;
	int in[2], out[2];
	if (lk != 0 || pipe(in) || pipe(out)) {
		printf("load=%lld up=- ur=- hits=-,- calls=0\n", (long long)lk);
		return 1;
	}
	pid_t c = fork();
	if (c == 0) {
		dup2(in[0], 0), dup2(out[1], 1);
		close(in[1]), close(out[0]);
		execl(argv[4], argv[4], (char *)NULL);
		_exit(127);
	}
	close(in[0]), close(out[1]);
	FILE *ci = fdopen(in[1], "w"), *co = fdopen(out[0], "r");
	char line[128] = "";
	if (!fgets(line, sizeof line, co) || strncmp(line, "ready", 5)) { /* 子が待つ所まで来てから付ける */
		printf("child: no ready\n");
		kill(c, SIGKILL);
		return 1;
	}
	int64_t ur_ = bml_attach_uprobe(obj, S("up"), c), rr = bml_attach_uretprobe(obj, S("ur"), c);
	int64_t uk = kind_msg(ur_, "attach up"), rk = kind_msg(rr, "attach ur");
	int calls = 0;
	for (int i = 0; i < 4; i++) {
		fputs("x\n", ci), fflush(ci);
		if (fgets(line, sizeof line, co) && !strncmp(line, "called", 6))
			calls++;
	}
	fputs("q\n", ci), fflush(ci);
	int st;
	waitpid(c, &st, 0);
	int64_t h0 = bml_map_get_bits(obj, S(HITS), 0), h1 = bml_map_get_bits(obj, S(HITS), 1);
	printf("load=%lld up=%lld ur=%lld hits=%lld,%lld calls=%d\n", (long long)lk, (long long)uk, (long long)rk,
	       bml_result_kind(h0) == 0 ? (long long)bml_result_value(h0) : -1LL, bml_result_kind(h1) == 0 ? (long long)bml_result_value(h1) : -1LL, calls);
	if (uk == 0)
		bml_detach(bml_result_value(ur_));
	if (rk == 0)
		bml_detach(bml_result_value(rr));
	bml_close(obj);
	return 0;
}
