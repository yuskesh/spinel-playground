/* btf/map_values.h — map の値の STRUCT の直下の bpf_timer / bpf_spin_lock の member (Go の mapValueFields の .BTF の最小の読み —
 * E002、mapfield.c から分けた)。.BTF は Go と同じく little endian に固定して読む。 */
#ifndef BML_BTF_MAP_VALUES_H
#define BML_BTF_MAP_VALUES_H

#include <stddef.h>

#include "elf/elf.h"

struct mapfields {
	const char *map;
	const char *fields[64]; /* "bpf_spin_lock" か "bpf_timer" (静的)、名前の順 */
	size_t n;
};

/* needed の map ごとの field。*out は malloc (map の名前は needed の中を指す)。失敗は -1 と *err (malloc) — Go の文 */
int btf_map_value_fields(const struct bml_elf *e, const char **needed, size_t n_needed, struct mapfields **out, size_t *n_out,
			 char **err);

#endif
