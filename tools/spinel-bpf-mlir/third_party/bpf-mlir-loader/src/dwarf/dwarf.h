/* dwarf/dwarf.h — uprobe の target の DWARF の仮引数の読み (E008 — bpf-mlir go/requirements/uprobe.go の dwarfParams を、Go の debug/elf の
 * File.DWARF() と debug/dwarf の Reader・Type の振る舞いのうち dwarfParams が使う分と共に写す)。 */
#ifndef BML_DWARF_H
#define BML_DWARF_H

#include <stddef.h>
#include <stdint.h>

#include "elf/elf.h"

/* bpf-mlir E557 (E055): 分けた DWARF の file の上限 (byte) と debug の section の展開の合計の上限 */
#define BML_DEBUG_RAW_LIMIT 268435456
#define BML_DEBUG_EXPANDED_LIMIT 536870912

struct bml_dwarf_param {
	char *name;
	char *type;    /* i8〜u64・ptr・strptr、読めなければ "" (dwarfSpelling) — ptr を要る引数では作らない ("") */
	char *pointer; /* bpf-mlir E559 (E057): ptr を要る引数だけ — ptr・non-pointer・ptr(depth=…,width=…)、"" は Unknown (他の引数は NULL) */
};

/* dwarfSubprogram: 選んだ DW_TAG_subprogram と、それを含む compile unit */
struct bml_dwarf_sub {
	int64_t lang;   /* DW_AT_language (無ければ −1) */
	char *producer; /* DW_AT_producer (無ければ "") */
	int64_t cc;     /* DW_AT_calling_convention (無ければ −1) */
	struct bml_dwarf_param *params;
	size_t n;
};

/* 開いた DWARF (Go の *dwarf.Data — ELF の byte は閉じるまで生きていること)。開けない・読めないは -1 と *err (`no DWARF: …` — malloc) */
struct bml_dwarf;
int bml_dwarf_open(const struct bml_elf *elf, struct bml_dwarf **out, char **err);
void bml_dwarf_close(struct bml_dwarf *d);
/* dwarfSubprogramFromData (bpf-mlir E556 / E557 — 判定の版 16 — E055): 全ての CU の DW_TAG_subprogram のうち宣言でなく直接の DW_AT_low_pc が
 * address (本体の FUNC の st_value — 呼び手が決める) のものがちょうど 1 つ。その CU の言語・producer と呼び出し規約、parameters なら直下の
 * formal_parameter (結果を除く)。名前は文だけに使う。0 / 2 以上は `DWARF has N non-declaration DW_TAG_subprogram definitions at <name>
 * (0x<address>), want exactly one`、読みの誤りは Go の DecodeError の文 — -1 と *err (malloc) */
int bml_dwarf_subprogram_at(struct bml_dwarf *d, uint64_t address, const char *name, int parameters, struct bml_dwarf_sub *out, char **err);
/* 同じ、raw_ptr[i] (i は 1 始まりの仮引数の番号、n_raw まで) が真の引数は pointer の綴り (形式 18 の ptr — E057) */
int bml_dwarf_subprogram_at_ptr(struct bml_dwarf *d, uint64_t address, const char *name, int parameters, const uint8_t *raw_ptr, size_t n_raw,
				struct bml_dwarf_sub *out, char **err);
void bml_dwarf_sub_free(struct bml_dwarf_sub *s);

/* 試験 (E008 の差動) と fuzz: DWARF の「名前を持ち子を持つ subprogram」の名前を出現の順に (重複を含む)。失敗は -1 と *err */
int bml_dwarf_subprogram_names(const struct bml_elf *elf, char ***names, size_t *n, char **err);

#endif
