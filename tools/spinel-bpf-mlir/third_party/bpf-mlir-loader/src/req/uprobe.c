/* uprobe.c — go/requirements/uprobe.go の uprobeSymbol の写し (E002)。dwarfParams は src/dwarf/ (E008)、呼び出し規約 (E306) は check_attach.c。 */
#include "req/uprobe.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "util/gostr.h"
#include "util/mutation.h"

#define PT_LOAD 1
#define PF_X 1

char *bml_uprobe_symbol(const struct bml_elf *elf, const char *name)
{
	/* Go: syms, _ := f.Symbols(); dyn, _ := f.DynamicSymbols() — 誤りは空として無視する */
	struct bml_elf_sym *syms = NULL, *dyn = NULL;
	size_t ns = 0, nd = 0;
	char *err = NULL;
	if (bml_elf_symbols(elf, BML_SHT_SYMTAB, &syms, &ns, &err))
		free(err), ns = 0;
	err = NULL;
	if (bml_elf_symbols(elf, BML_SHT_DYNSYM, &dyn, &nd, &err))
		free(err), nd = 0;
	uint64_t *vals = malloc((ns + nd + 1) * sizeof(*vals));
	size_t nv = 0;
	if (!vals) {
		free(syms);
		free(dyn);
		return strdup("out of memory");
	}
	for (size_t i = 0; i < ns + nd; i++) {
		const struct bml_elf_sym *s = i < ns ? &syms[i] : &dyn[i - ns];
		if (strcmp(s->name, name) != 0 || BML_ST_TYPE(s->info) != BML_STT_FUNC)
			continue;
		int seen = 0;
		for (size_t k = 0; k < nv; k++)
			if (vals[k] == s->value)
				seen = 1;
		if (seen)
			continue;
		vals[nv++] = s->value;
	}
	free(syms);
	free(dyn);
	struct bml_buf b = {0};
	if (nv != 1) {
		free(vals);
		bml_buf_addf(&b, "the binary has %zu FUNC symbols named %s (want exactly one)", nv, name);
		return bml_buf_take(&b);
	}
	for (size_t i = 0; i < elf->n_progs; i++) {
		const struct bml_elf_phdr *p = &elf->progs[i];
		if (p->type == PT_LOAD && (p->flags & PF_X) && p->vaddr <= vals[0] && vals[0] < p->vaddr + p->memsz)
			return free(vals), NULL;
	}
	bml_buf_addf(&b, "%s (0x%llx) is not in an executable PT_LOAD of the binary", name, (unsigned long long)vals[0]);
	free(vals);
	return bml_buf_take(&b);
}

/* E056: attach の file offset — 照合 (bml_uprobe_symbol) と同じ symbol の表と規則 (.symtab → .dynsym の名前の一致する最初の STT_FUNC、address で一意、
 * PF_X の PT_LOAD の memsz の中)。offset は cilium の Executable.load と同じ v − p_vaddr + p_offset (その address を含む最初の PF_X の PT_LOAD)。
 * 変異 uprobe.attach_symtab_only は E056 の前の attach の規則 (.symtab の定義された FUNC だけ・filesz・size を見ない) */
int bml_uprobe_file_offset(const struct bml_elf *elf, const char *name, uint64_t *off, uint64_t *value, uint64_t *seg_vaddr, char **why)
{
	*why = NULL;
	int legacy = BML_MUT("uprobe.attach_symtab_only");
	if (!legacy && (*why = bml_uprobe_symbol(elf, name)))
		return -1;
	uint64_t v = 0, size = 0;
	size_t n = 0;
	for (uint32_t t = 0; t < 2 && (legacy || !n); t++) {
		struct bml_elf_sym *syms = NULL;
		size_t ns = 0;
		char *err = NULL;
		if (legacy && t == 1)
			break;
		if (bml_elf_symbols(elf, t ? BML_SHT_DYNSYM : BML_SHT_SYMTAB, &syms, &ns, &err) != 0) {
			free(err);
			continue;
		}
		for (size_t i = 0; i < ns && (legacy || !n); i++)
			if (!strcmp(syms[i].name, name) && BML_ST_TYPE(syms[i].info) == BML_STT_FUNC && (!legacy || syms[i].shndx != BML_SHN_UNDEF))
				v = syms[i].value, size = syms[i].size, n++;
		free(syms);
	}
	struct bml_buf b = {0};
	if (legacy && n != 1) {
		bml_buf_addf(&b, "the target has %zu FUNC symbols named %s (want exactly one)", n, name);
		return (*why = bml_buf_take(&b), -1);
	}
	for (size_t i = 0; i < elf->n_progs; i++) {
		const struct bml_elf_phdr *p = &elf->progs[i];
		if (p->type == PT_LOAD && (p->flags & PF_X) && p->vaddr <= v && v < p->vaddr + (legacy ? p->filesz : p->memsz)) {
/* cilium's Executable.address: refuses offset (always 0 in bml) >= the symbol's size (a FUNC of size 0 — a hand-written asm function without .size, a crt
 * stub). The match does not look at the size, so, as in the Go loader, the match passes and attach stops (E056 — the bpf-mlir coordinator's decision (A)) */
			if (!legacy && size == 0) {
				bml_buf_addf(&b, "offset 0 is out of range of symbol %s", name);
				return (*why = bml_buf_take(&b), -1);
			}
			*off = v - p->vaddr + p->offset;
			if (value)
				*value = v;
			if (seg_vaddr)
				*seg_vaddr = p->vaddr;
			return 0;
		}
	}
	bml_buf_addf(&b, "%s (0x%llx) is not in an executable PT_LOAD of the binary", name, (unsigned long long)v);
	return (*why = bml_buf_take(&b), -1);
}

