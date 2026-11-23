/* elf_maps — E007 の差動の操作の列の入力: ELF の requirements の map の行と program の行、key と value の byte の大きさ (綴りと BTF から)。
 *
 *   elf_maps <ELF>
 *   出力 (tab 区切り): `sha <schema の sha256>`、`prog <名前> <type>`、`map <名前> <kind> <key> <value> <max_entries> <flags> <key の大きさ> <value の大きさ>`
 *   大きさの分からない綴りは -1。読めない ELF は `error <文>` と rc 1。 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "btf/layout.h"
#include "req/from_elf.h"
#include "req/req.h"

static int64_t spell_size(const struct lbtf *b, const char *s)
{
	if (!strcmp(s, "u8") || !strcmp(s, "i8"))
		return 1;
	if (!strncmp(s, "u16", 3) || !strncmp(s, "i16", 3))
		return 2;
	if (!strncmp(s, "u32", 3) || !strncmp(s, "i32", 3))
		return 4;
	if (!strncmp(s, "u64", 3) || !strncmp(s, "i64", 3))
		return 8;
	if (s[0] == '[') {
		char *end;
		long n = strtol(s + 1, &end, 10);
		if (*end != ']')
			return -1;
		int64_t e = spell_size(b, end + 1);
		return e < 0 ? -1 : n * e;
	}
	if (!strncmp(s, "record:", 7) && b)
		for (size_t i = 0; i < b->n; i++)
			if (b->t[i].kind == 4 && !strcmp(b->t[i].name, s + 7))
				return b->t[i].size;
	return -1;
}

static uint8_t *read_file(const char *path, size_t *n)
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
	*n = (size_t)l;
	return p;
}

int main(int argc, char **argv)
{
	if (argc != 2) {
		fprintf(stderr, "elf_maps <ELF>\n");
		return 2;
	}
	size_t n;
	uint8_t *elf = read_file(argv[1], &n);
	if (!elf) {
		printf("error\tcannot read %s\n", argv[1]);
		return 1;
	}
	struct bml_requirements *req = NULL;
	struct bml_req_elf_error ee;
	if (bml_req_from_elf(elf, n, &req, &ee) != 0) {
		const char *m = ee.stage == BML_REQ_ELF_PARSE ? ee.parse.msg : ee.msg;
		printf("error\t%s\n", m ? m : "");
		bml_req_elf_error_free(&ee);
		free(elf);
		return 1;
	}
	struct lbtf b;
	char *err = NULL;
	int have_btf = btf_layout_parse(elf, n, &b, &err) == 0;
	free(err);
	printf("sha\t%s\n", req->schema_sha256.p ? req->schema_sha256.p : "");
	for (size_t i = 0; i < req->n_programs; i++)
		printf("prog\t%s\t%s\n", req->programs[i].symbol.p, req->programs[i].prog_type.p);
	for (size_t k = 0; k < req->n_maps; k++) {
		const struct bml_map *m = &req->maps[k];
		printf("map\t%s\t%s\t%s\t%s\t%llu\t%llu\t%lld\t%lld\n", m->symbol.p, m->map_type.p, m->key.p, m->value.p,
		       (unsigned long long)m->max_entries, (unsigned long long)m->flags, (long long)spell_size(have_btf ? &b : NULL, m->key.p),
		       (long long)spell_size(have_btf ? &b : NULL, m->value.p));
	}
	if (have_btf)
		btf_layout_free(&b);
	bml_requirements_free(req);
	free(elf);
	return 0;
}
