// test/maps/fuzz_maps_decls.c — libFuzzer の harness: maps.json の読み (§12・§13) と、受理した宣言での map の宣言と records の照合 (E003)。
// ELF は corpus の records の case の 1 つ (環境変数 BML_FUZZ_ELF — scripts/fuzz.sh が渡す) — records の照合が BTF を読む経路を通す。
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "maps/mapdecl.h"
#include "req/from_elf.h"
#include "util/gostr.h"

static char *elf;
static size_t elf_len;
static struct bml_requirements *req;

static void init(void)
{
	const char *p = getenv("BML_FUZZ_ELF");
	FILE *f = p ? fopen(p, "rb") : NULL;
	if (!f)
		abort();
	struct bml_buf b = {0};
	char tmp[65536];
	size_t n;
	while ((n = fread(tmp, 1, sizeof(tmp), f)) > 0)
		bml_buf_add(&b, tmp, n);
	fclose(f);
	elf_len = b.len;
	elf = bml_buf_take(&b);
	struct bml_req_elf_error e;
	if (bml_req_from_elf(elf, elf_len, &req, &e))
		abort();
}

int LLVMFuzzerTestOneInput(const unsigned char *data, size_t size)
{
	if (!req)
		init();
	struct bml_map_decls d;
	char *err = NULL;
	if (bml_map_decls_parse((const char *)data, size, &d, &err)) {
		free(err);
		return 0;
	}
	struct bml_map_problems p;
	if (bml_check_map_decls(req, elf, elf_len, &d, &p) >= 0) {
		for (size_t i = 0; i < p.n; i++)
			free(bml_map_problem_string(&p.p[i]));
		bml_map_problems_free(&p);
	}
	bml_map_decls_free(&d);
	return 0;
}
