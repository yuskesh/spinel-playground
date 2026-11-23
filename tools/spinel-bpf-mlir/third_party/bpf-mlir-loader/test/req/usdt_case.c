// test/req/usdt_case.c — USDT の読みの差動の C の側 (E039 — test/oracle/cmd/usdt-oracle と同じ形を出す)。
//   usdt_case < inputs     # 行 "A <16 進>" は Fields と 1 つずつの ParseUSDTArg、"N <path>" は ReadUSDTPoints
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "elf/elf.h"
#include "req/usdt.h"
#include "util/gostr.h"

static unsigned char *read_file(const char *path, size_t *len)
{
	FILE *f = fopen(path, "rb");
	if (!f)
		return NULL;
	size_t cap = 1 << 16, n = 0;
	unsigned char *p = malloc(cap);
	size_t k;
	while (p && (k = fread(p + n, 1, cap - n, f)) > 0) {
		n += k;
		if (n == cap) {
			unsigned char *q = realloc(p, cap *= 2);
			if (!q)
				free(p);
			p = q;
		}
	}
	fclose(f);
	*len = n;
	return p;
}

static void q(struct bml_buf *b, const char *s, size_t n)
{
	bml_buf_add_goquote(b, s, n);
}

static void arg_line(const char *hex)
{
	size_t hn = strlen(hex), n = hn / 2;
	char *s = malloc(n + 1);
	if (!s || hn % 2)
		exit(2);
	for (size_t i = 0; i < n; i++) {
		unsigned v;
		if (sscanf(hex + 2 * i, "%2x", &v) != 1)
			exit(2);
		s[i] = (char)v;
	}
	s[n] = 0;
	size_t *st, *ln, nf;
	if (bml_go_fields(s, n, &st, &ln, &nf))
		exit(2);
	printf("A %s fields=%zu\n", hex, nf);
	for (size_t i = 0; i < nf; i++) {
		struct bml_usdt_arg a;
		int ok;
		char *err;
		if (bml_usdt_parse_arg(s + st[i], ln[i], &a, &ok, &err))
			exit(2);
		struct bml_buf b = {0};
		bml_buf_adds(&b, "  ");
		q(&b, s + st[i], ln[i]);
		bml_buf_addf(&b, " size=%d signed=%s kind=", a.size, a.is_signed ? "true" : "false");
		q(&b, a.kind, strlen(a.kind));
		bml_buf_adds(&b, " reg=");
		q(&b, a.reg, strlen(a.reg));
		bml_buf_addf(&b, " off=%lld ok=%s err=", (long long)a.off, ok ? "true" : "false");
		q(&b, err ? err : "", err ? strlen(err) : 0);
		char *line = bml_buf_take(&b);
		if (!line)
			exit(2);
		printf("%s\n", line);
		free(line);
		free(err);
	}
	free(st);
	free(ln);
	free(s);
}

static void note_line(const char *path)
{
	size_t len;
	unsigned char *data = read_file(path, &len);
	struct bml_elf elf;
	char *err = NULL;
	if (!data || bml_elf_open(data, len, &elf, &err)) {
		printf("N %s open-error\n", path);
		free(err);
		free(data);
		return;
	}
	struct bml_usdt_points pts;
	struct bml_buf b = {0};
	if (bml_usdt_read_points(&elf, &pts, &err)) {
		if (!err)
			exit(2);
		bml_buf_addf(&b, "N %s err=", path);
		q(&b, err, strlen(err));
		free(err);
	} else {
		bml_buf_addf(&b, "N %s points=%zu", path, pts.n);
		for (size_t i = 0; i < pts.n; i++) {
			const struct bml_usdt_point *p = &pts.p[i];
			bml_buf_addf(&b, "\n  pc=0x%llx base=0x%llx sem=0x%llx ", (unsigned long long)p->pc, (unsigned long long)p->base,
				     (unsigned long long)p->semaphore);
			q(&b, p->provider, strlen(p->provider));
			bml_buf_adds(&b, " ");
			q(&b, p->name, strlen(p->name));
			bml_buf_adds(&b, " ");
			q(&b, p->args, strlen(p->args));
		}
	}
	bml_usdt_points_free(&pts);
	char *out = bml_buf_take(&b);
	if (!out)
		exit(2);
	printf("%s\n", out);
	free(out);
	bml_elf_close(&elf);
	free(data);
}

int main(void)
{
	static char line[1 << 20];
	while (fgets(line, sizeof line, stdin)) {
		size_t n = strlen(line);
		if (n && line[n - 1] == '\n')
			line[--n] = 0;
		if (!strncmp(line, "A ", 2))
			arg_line(line + 2);
		else if (!strncmp(line, "N ", 2))
			note_line(line + 2);
	}
	return 0;
}
