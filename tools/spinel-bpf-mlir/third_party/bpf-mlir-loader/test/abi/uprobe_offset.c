/* uprobe_offset — E056 の H1: binary の STT_FUNC の名前 (.symtab の後に .dynsym — 最初に出た順) ごとに、attach の file offset (bml_uprobe_file_offset —
 * 照合と同じ規則) を test/oracle/cmd/uprobe-offset (cilium の Executable.address の写し) と同じ形で印字する (scripts/diff-uprobe-offset.sh が比べる)。
 *
 *   uprobe_offset <binary>...
 * 行: "<名前>\t0x<offset>" か "<名前>\terror\t<文>" */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "elf/elf.h"
#include "req/uprobe.h"

int main(int argc, char **argv)
{
	for (int a = 1; a < argc; a++) {
		printf("== %s\n", argv[a]);
		FILE *f = fopen(argv[a], "rb");
		long l = f && !fseek(f, 0, SEEK_END) ? ftell(f) : -1;
		uint8_t *data = l >= 0 ? malloc((size_t)l + 1) : NULL;
		if (!f || !data || fseek(f, 0, SEEK_SET) || fread(data, 1, (size_t)l, f) != (size_t)l) {
			printf("open: failed\n");
			if (f)
				fclose(f);
			free(data);
			continue;
		}
		fclose(f);
		struct bml_elf elf;
		char *err = NULL;
		if (bml_elf_open(data, (size_t)l, &elf, &err) != 0) {
			printf("open: failed\n");
			free(err);
			free(data);
			continue;
		}
		const char **names = NULL;
		size_t nn = 0;
		for (uint32_t t = 0; t < 2; t++) {
			struct bml_elf_sym *syms = NULL;
			size_t ns = 0;
			if (bml_elf_symbols(&elf, t ? BML_SHT_DYNSYM : BML_SHT_SYMTAB, &syms, &ns, &err) != 0) {
				free(err);
				err = NULL;
				continue;
			}
			for (size_t i = 0; i < ns; i++) {
				if (BML_ST_TYPE(syms[i].info) != BML_STT_FUNC || !syms[i].name[0])
					continue;
				int seen = 0;
				for (size_t k = 0; k < nn && !seen; k++)
					seen = !strcmp(names[k], syms[i].name);
				const char **nm = seen ? names : realloc(names, (nn + 1) * sizeof *nm);
				if (!seen && nm)
					names = nm, names[nn++] = syms[i].name; /* 文字列の表の中 (elf が閉じるまで) */
			}
			free(syms);
		}
		for (size_t i = 0; i < nn; i++) {
			uint64_t off;
			char *why = NULL;
			if (bml_uprobe_file_offset(&elf, names[i], &off, NULL, NULL, &why) == 0)
				printf("%s\t0x%llx\n", names[i], (unsigned long long)off);
			else
				printf("%s\terror\t%s\n", names[i], why ? why : "");
			free(why);
		}
		free(names);
		bml_elf_close(&elf);
		free(data);
	}
	return 0;
}
