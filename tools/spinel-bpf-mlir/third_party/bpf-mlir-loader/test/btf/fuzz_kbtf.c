/* test/btf/fuzz_kbtf.c — kernel の BTF の reader (src/btf/kernel*) の libFuzzer の harness (E004)。入力は raw の BTF。
 * 読めたら全ての型の書式・UnderlyingType・Sizeof・member・引数と、全ての名前の全ての kind の名前引きを通す。 */
#include <stdlib.h>
#include <string.h>

#include "btf/kernel.h"

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	uint8_t *raw = malloc(size ? size : 1);
	if (!raw)
		return 0;
	memcpy(raw, data, size);
	struct bml_kbtf kb;
	char *err = NULL;
	if (bml_kbtf_from_raw(raw, size, &kb, &err) != 0) {
		free(err);
		return 0;
	}
	for (uint32_t id = 0; id < kb.n && id < 4096; id++) {
		struct bml_buf b = {0};
		struct kbtf_type t;
		int cyc;
		int64_t sz;
		bml_kbtf_type(&kb, id, &t);
		bml_kbtf_format(&kb, &b, id, 0, 'v');
		uint32_t u = bml_kbtf_underlying(&kb, id, &cyc);
		bml_kbtf_format(&kb, &b, u, cyc, 'v');
		bml_kbtf_gotype(&kb, &b, u, cyc);
		if (bml_kbtf_sizeof(&kb, id, &sz, &err) != 0)
			free(err);
		if (t.kind == KBTF_STRUCT || t.kind == KBTF_UNION)
			for (uint32_t i = 0; i < t.vlen; i++) {
				struct kbtf_member m;
				bml_kbtf_member(&kb, &t, i, &m);
				bml_buf_adds(&b, m.name);
			}
		if (t.kind == KBTF_FUNC_PROTO)
			for (uint32_t i = 0; i < t.vlen; i++) {
				const char *pn;
				uint32_t pt;
				bml_kbtf_param(&kb, &t, i, &pn, &pt);
				bml_buf_adds(&b, pn);
			}
		if (t.name[0])
			for (uint32_t k = 1; k < KBTF_NKINDS; k++) {
				uint32_t fid;
				if (bml_kbtf_by_name(&kb, t.name, k, &fid, &err) != 0)
					free(err);
			}
		bml_buf_free(&b);
	}
	bml_kbtf_free(&kb);
	return 0;
}
