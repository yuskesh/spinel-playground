/* btf/globals.h — global 変数の ELF の symbol・BTF の DATASEC・宣言の照合 (go/layout の GlobalSymbols・GlobalProblems・checkGlobal・
 * btfRelocs の写し — bpf-mlir E099 / E298 / E308)。文は Go と byte で同じ (maps.json の問題の文に入る)。 */
#ifndef BML_BTF_GLOBALS_H
#define BML_BTF_GLOBALS_H

#include <stddef.h>
#include <stdint.h>

/* .rodata / .bss の GLOBAL の OBJECT の symbol (Go の map — 同じ名前は後勝ち)。名前の昇順 */
struct btf_gsym {
	const char *name;    /* ELF の文字列の表の中 */
	const char *section; /* ".rodata" / ".bss" */
};

/* CONTRACT: *out is malloc'd (release with free). Each name points into the elf data, so it is valid only while elf is alive. Failure returns -1 and sets *err (malloc'd text) */
int btf_global_symbols(const void *elf, size_t len, struct btf_gsym **out, size_t *n, char **err);

/* CONTRACT: returns the problems joined with "; " (malloc'd; an empty string means a match). section is ".rodata" or ".bss"; size is in bytes.
 * An unreadable ELF or BTF returns NULL and sets *err (malloc'd). Out of memory returns NULL with *err = NULL */
char *btf_global_problems(const void *elf, size_t len, const char *name, const char *section, uint32_t size, int is_signed, char **err);

/* Go の GlobalOffset: 名前の最初の OBJECT の symbol の st_value と st_size (section の中の offset — E308 の照合が DATASEC と一致を確かめた
 * 後に使う)。無い・読めないは -1 */
int btf_global_offset(const void *elf, size_t len, const char *name, uint64_t *off, uint64_t *size);

#endif
