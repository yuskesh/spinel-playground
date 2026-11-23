/* dwarf_case — E008 の差動 (E055 で判定の版 16 の address の選びに): binary の FUNC symbol の名前 (.symtab の後に .dynsym — 最初に出た順) ごとに
 * bml_uprobe_dwarf_at の答えを test/oracle/cmd/dwarf-oracle と同じ形で印字する (scripts/diff-dwarf.sh が 2 つを比べる)。
 *
 *   dwarf_case <binary>... */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "dwarf/dwarf.h"
#include "elf/elf.h"
#include "req/uprobe.h"
#include "util/gostr.h"

static uint8_t *slurp(const char *path, size_t *n)
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

static void quote(const char *s)
{
	struct bml_buf b = {0};
	bml_buf_add_goquote(&b, s, strlen(s));
	fwrite(b.p ? b.p : "", 1, b.len, stdout);
	bml_buf_free(&b);
}

/* E057: -ptr は全ての仮引数を形式 18 の ptr の要求として問う (dwarf-oracle の -ptr と同じ — 64 まで) */
static uint8_t all_ptr[64];
static const uint8_t *raw_all;

/* dwarfSubprogramAt: DWARF を開けなければその文 (Go は名前ごとに f.DWARF() を開く — 同じ文) */
static void one(const struct bml_elf *elf, struct bml_dwarf *d, const char *derr, const char *name, const char *label)
{
	struct bml_dwarf_sub sp;
	char *err = NULL;
	if (label)
		fputs(label, stdout);
	else
		quote(name);
	if (!d || bml_uprobe_dwarf_at(elf, d, name, 1, raw_all, raw_all ? sizeof all_ptr : 0, &sp, &err) != 0) {
		printf("\terror: %s\n", d ? (err ? err : "") : derr);
		free(err);
		return;
	}
	if (label) { /* 無い名前の行は誤りだけを期待する */
		printf("\tfound\n");
		bml_dwarf_sub_free(&sp);
		return;
	}
	printf("\tlang=%lld cc=%lld producer=", (long long)sp.lang, (long long)sp.cc);
	quote(sp.producer ? sp.producer : "");
	for (size_t i = 0; i < sp.n; i++) {
		putchar('\t');
		quote(sp.params[i].name);
		printf(":%s", raw_all ? (sp.params[i].pointer ? sp.params[i].pointer : "") : sp.params[i].type);
	}
	putchar('\n');
	bml_dwarf_sub_free(&sp);
}

int main(int argc, char **argv)
{
	int a0 = 1;
	if (argc > 1 && !strcmp(argv[1], "-ptr")) {
		memset(all_ptr, 1, sizeof all_ptr);
		raw_all = all_ptr;
		a0 = 2;
	}
	for (int a = a0; a < argc; a++) {
		printf("== %s\n", argv[a]);
		size_t n = 0;
		uint8_t *data = slurp(argv[a], &n);
		struct bml_elf elf;
		char *err = NULL;
		if (!data || bml_elf_open(data, n, &elf, &err) != 0) {
			printf("open: failed\n");
			free(err);
			free(data);
			continue;
		}
		struct bml_dwarf *d = NULL;
		char *derr = NULL;
		bml_dwarf_open(&elf, &d, &derr);
		const char **names = NULL;
		size_t nn = 0;
		for (uint32_t t = 0; t < 2; t++) { /* syms の後に dyn (Go の append(syms, dyn...)) */
			struct bml_elf_sym *syms = NULL;
			size_t ns = 0;
			if (bml_elf_symbols(&elf, t ? BML_SHT_DYNSYM : BML_SHT_SYMTAB, &syms, &ns, &err) != 0) {
				free(err);
				err = NULL;
				continue;
			}
			for (size_t i = 0; i < ns; i++) {
				if (BML_ST_TYPE(syms[i].info) != BML_STT_FUNC)
					continue;
				int seen = 0;
				for (size_t k = 0; k < nn && !seen; k++)
					seen = !strcmp(names[k], syms[i].name);
				if (seen)
					continue;
				const char **nnames = realloc(names, (nn + 1) * sizeof *nnames);
				if (!nnames)
					break;
				names = nnames;
				names[nn++] = syms[i].name; /* ELF の文字列の表の中 (elf が閉じるまで) */
			}
			free(syms);
		}
		for (size_t u = 0; u < nn; u++)
			if (u < 200 || (u + 1) % 50 == 0) /* 見本 (dwarf-oracle と同じ — 先頭の 200 と 50 ごと) */
				one(&elf, d, derr, names[u], NULL);
		free(names);
		one(&elf, d, derr, "bml_no_such_function", "absent");
		bml_dwarf_close(d);
		free(derr);
		bml_elf_close(&elf);
		free(data);
	}
	return 0;
}
