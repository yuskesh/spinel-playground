// test/dwarf/fuzz_dwarf.c — libFuzzer の harness: ELF の byte → 分けた DWARF の検査 (E055) と DWARF の subprogram の名前 → 各々の名前の
// symbol の address での選び (bml_uprobe_dwarf_at — E055 で bml_dwarf_params から) (E008 H6)。
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

#include "dwarf/dwarf.h"
#include "dwarf/split.h"
#include "elf/elf.h"
#include "req/uprobe.h"

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	struct bml_elf elf;
	char *err = NULL;
	if (bml_elf_open(data, size, &elf, &err) != 0) {
		free(err);
		return 0;
	}
	uint8_t *id = NULL;
	size_t idn;
	uint32_t crc;
	int has;
	if (bml_debug_build_id(&elf, "the binary", &id, &idn, &err))
		free(err), err = NULL;
	free(id);
	if (bml_debug_link_crc(&elf, &crc, &has, &err))
		free(err), err = NULL;
	if (bml_debug_open_checks(&elf, &err) || bml_debug_split_checks(&elf, &err))
		free(err), err = NULL;
	struct bml_dwarf *d = NULL;
	if (bml_dwarf_open(&elf, &d, &err) != 0) {
		free(err);
		bml_elf_close(&elf);
		return 0;
	}
	char **names = NULL;
	size_t n = 0;
	if (bml_dwarf_subprogram_names(&elf, &names, &n, &err) != 0)
		free(err), err = NULL;
	for (size_t i = 0; i < n; i++) {
		if (i < 50) {
			struct bml_dwarf_sub sp;
			static const uint8_t all[8] = {1, 1, 1, 1, 1, 1, 1, 1}; /* E057: 半分は全ての仮引数を ptr として (DIE を直接歩く綴り) */
			if (bml_uprobe_dwarf_at(&elf, d, names[i], 1, i % 2 ? all : NULL, i % 2 ? 8 : 0, &sp, &err) == 0)
				bml_dwarf_sub_free(&sp);
			else
				free(err), err = NULL;
		}
		free(names[i]);
	}
	free(names);
	struct bml_dwarf_sub sp;
	if (bml_dwarf_subprogram_at(d, 0, "bml_no_such_function", 1, &sp, &err) == 0) /* address 0 — 低い pc の無い宣言を数えないこと */
		bml_dwarf_sub_free(&sp);
	else
		free(err);
	bml_dwarf_close(d);
	bml_elf_close(&elf);
	return 0;
}
