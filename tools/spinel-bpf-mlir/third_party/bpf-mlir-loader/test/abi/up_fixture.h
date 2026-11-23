/* up_fixture.h — E015 の試験の共通 (abi_up.c・up_diff.c): fixture up.mlir の宣言、target の binary (bpf-mlir kernel/uprobe/fixture/bin/fixture —
 * stdin の "<a> <b>" ごとに probe_target(a, b) を呼び "ok <和>" を返す) を子の process として動かす helper (試験の側 — loader の機能でない) */
#ifndef BML_TEST_UP_FIXTURE_H
#define BML_TEST_UP_FIXTURE_H

#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#define S(x) (x), (int64_t)strlen(x)
#define M_HITS "{\"name\":\"hits\",\"kind\":\"array\",\"key\":\"u32\",\"value\":\"u64\",\"max_entries\":2}"
#define UP_MAPS "{\"maps\":[" M_HITS "]}"

static inline uint8_t *slurp(const char *path, int64_t *n)
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

/* targets の文書 (program と path を 1 つ) */
static inline void targets_doc(char *out, size_t cap, const char *prog, const char *path)
{
	snprintf(out, cap, "{\"uprobe_targets\":[{\"program\":\"%s\",\"path\":\"%s\"}]}", prog, path);
}

struct child {
	pid_t pid;
	FILE *in, *out;
};

static inline int child_start(struct child *c, const char *path)
{
	int to[2], from[2];
	if (pipe(to) || pipe(from))
		return -1;
	c->pid = fork();
	if (c->pid < 0)
		return -1;
	if (c->pid == 0) {
		dup2(to[0], 0);
		dup2(from[1], 1);
		close(to[1]);
		close(from[0]);
		execl(path, path, (char *)NULL);
		_exit(127);
	}
	close(to[0]);
	close(from[1]);
	c->in = fdopen(to[1], "w");
	c->out = fdopen(from[0], "r");
	return c->in && c->out ? 0 : -1;
}

/* probe_target(a, b) を子に呼ばせる — 戻り値 (a + b) を返す、誤りは -1 */
static inline long long child_call(struct child *c, unsigned a, unsigned long long b)
{
	char line[64];
	fprintf(c->in, "%u %llu\n", a, b);
	fflush(c->in);
	if (!fgets(line, sizeof line, c->out))
		return -1;
	unsigned long long v;
	return sscanf(line, "ok %llu", &v) == 1 ? (long long)v : -1;
}

static inline void child_stop(struct child *c)
{
	fprintf(c->in, "q\n");
	fclose(c->in);
	fclose(c->out);
	waitpid(c->pid, NULL, 0);
}

#endif
