/* mapfield.h — map の field の使用の導出 (bpf-mlir docs/requirements_format.md §7、go/requirements/mapfield.go と
 * requirements.go の scanFuncs の写し — E002)。3 値: 導出していない・導出した・失敗した (理由)。 */
#ifndef BML_MAPFIELD_H
#define BML_MAPFIELD_H

#include <stddef.h>

#include "elf/elf.h"

enum bml_mf_state { BML_MF_NOT_DERIVED, BML_MF_DERIVED, BML_MF_FAILED };

struct bml_mf_use {
	char *map;
	const char *field; /* "bpf_spin_lock" か "bpf_timer" (静的) */
};

struct bml_mf_prog {
	char *program; /* FUNC symbol の名前 */
	struct bml_mf_use *uses; /* map の名前の順、map の中は field の名前の順 (Go と同じ) */
	size_t n_uses;
};

struct bml_map_fields {
	enum bml_mf_state state;
	char *reason; /* FAILED の理由 */
	struct bml_mf_prog *progs; /* 使用を 1 つ以上持つ program だけ */
	size_t n_progs;
};

/* Go の deriveMapFields (FromELF の中)。out は呼び手が 0 で初期化したもの */
void bml_map_fields_derive(const struct bml_elf *elf, struct bml_map_fields *out);
void bml_map_fields_free(struct bml_map_fields *mf);
const struct bml_mf_prog *bml_map_fields_uses(const struct bml_map_fields *mf, const char *program);

#endif
