/* uprobe.h — uprobe の照合の部品 (bpf-mlir go/requirements/uprobe.go の写し — E002): binary の SHA-256、symbol、DWARF の引数の型は dwarf/dwarf.h (E008) */
#ifndef BML_UPROBE_H
#define BML_UPROBE_H

#include <stddef.h>
#include <stdint.h>

#include "dwarf/dwarf.h"
#include "elf/elf.h"

/* SHA-256 を小文字の 16 進 (64 文字 + NUL) に */
void bml_sha256_hex(const uint8_t *data, size_t len, char out[65]);

/* uprobeSymbol: symbol がちょうど 1 つの FUNC (値の違うもの) として実行可能な PT_LOAD に在れば NULL、違えば食い違いの文 (malloc) */
char *bml_uprobe_symbol(const struct bml_elf *elf, const char *name);
/* E056: uprobe の attach の file offset — 照合と同じ symbol の規則 (bml_uprobe_symbol)、offset は cilium と同じ v − p_vaddr + p_offset。
 * 0 は *off (と NULL でなければ symbol の値 *value と含む segment の p_vaddr *seg_vaddr)、-1 は *why (照合と同じ文 — malloc) */
int bml_uprobe_file_offset(const struct bml_elf *elf, const char *name, uint64_t *off, uint64_t *value, uint64_t *seg_vaddr, char **why);

/* dwarfSubprogramFromData (bpf-mlir E556 / E557 — E055): body の uprobeSymbol が通らなければ `cannot resolve DWARF address: <文>`、通れば
 * .symtab → .dynsym の名前の一致する最初の STT_FUNC の address で d (body の埋め込みか分けた file の DWARF) から選ぶ。0 は *out、-1 は *err */
int bml_uprobe_dwarf_at(const struct bml_elf *body, struct bml_dwarf *d, const char *name, int parameters, const uint8_t *raw, size_t n_raw,
			struct bml_dwarf_sub *out, char **err); /* raw: 形式 18 の ptr を要る仮引数の番号 (E057 — NULL は無し) */

#endif
