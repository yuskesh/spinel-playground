// test/min/min.c — 最小の実行 file (E001): libbml + libbpf + libelf + zlib を静的に link し、大きさ・NEEDED・
// signal / thread / rlimit を測る。ELF を bpf_object__open_mem で開き load して最初の map を key 0 で引く。
//
//   min [ELF]     # ELF が無ければ版を出して終わる (link の測定だけ)
//
// P001 の固定の option: RLIMIT_MEMLOCK を変えない・BPF token を作らない・libbpf の print を stderr に出さない。
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <bpf/bpf.h>
#include <bpf/libbpf.h>

#include "bml/bml.h"

static int quiet_print(enum libbpf_print_level level, const char *fmt, va_list ap)
{
	(void)level;
	(void)fmt;
	(void)ap;
	return 0;
}

static void *read_file(const char *path, size_t *len)
{
	FILE *f = fopen(path, "rb");
	if (!f)
		return NULL;
	char *buf = NULL;
	size_t cap = 0, n = 0;
	for (;;) {
		if (n == cap) {
			cap = cap ? cap * 2 : 65536;
			char *nb = realloc(buf, cap);
			if (!nb) {
				free(buf);
				fclose(f);
				return NULL;
			}
			buf = nb;
		}
		size_t r = fread(buf + n, 1, cap - n, f);
		n += r;
		if (r == 0)
			break;
	}
	fclose(f);
	*len = n;
	return buf;
}

int main(int argc, char **argv)
{
	printf("%s\n", bml_version());
#ifndef MIN_CONTROL_NO_MEMLOCK_OPT /* 変異の対照 (E001): 外すと権限の無い load で libbpf が RLIMIT_MEMLOCK を上げる */
	if (libbpf_set_memlock_rlim(0))
		return 2;
#endif
	libbpf_set_print(quiet_print);
	if (argc < 2)
		return 0;

	size_t len;
	void *buf = read_file(argv[1], &len);
	if (!buf) {
		fprintf(stderr, "min: %s: %s\n", argv[1], strerror(errno));
		return 1;
	}
	LIBBPF_OPTS(bpf_object_open_opts, opts, .object_name = "min", .bpf_token_path = "");
	struct bpf_object *obj = bpf_object__open_mem(buf, len, &opts);
	if (!obj) {
		fprintf(stderr, "min: open: %s\n", strerror(errno));
		free(buf);
		return 1;
	}
	int err = bpf_object__load(obj);
	if (err) {
		fprintf(stderr, "min: load: %s\n", strerror(-err));
		bpf_object__close(obj);
		free(buf);
		return 1;
	}
	struct bpf_map *m = bpf_object__next_map(obj, NULL);
	if (m) {
		unsigned char key[64] = {0}, val[4096];
		size_t ks = bpf_map__key_size(m), vs = bpf_map__value_size(m);
		if (ks <= sizeof(key) && vs <= sizeof(val)) {
			int r = bpf_map_lookup_elem(bpf_map__fd(m), key, val);
			printf("map %s: lookup(0) = %d\n", bpf_map__name(m), r);
		}
	}
	printf("loaded\n");
	bpf_object__close(obj);
	free(buf);
	return 0;
}
