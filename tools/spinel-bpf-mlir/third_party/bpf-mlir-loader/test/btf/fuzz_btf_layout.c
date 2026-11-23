// test/btf/fuzz_btf_layout.c — libFuzzer の harness: ELF の .BTF の record の表の読み (btf/layout — go/layout の parseBTF の写し) と、
// 全ての名前の STRUCT の表の文字列 (E003)。Go が panic する壊れた BTF で C は誤りを返す — その経路の memory の安全を見る。
#include <stdlib.h>
#include <string.h>

#include "btf/layout.h"

int LLVMFuzzerTestOneInput(const unsigned char *data, size_t size)
{
	struct lbtf b;
	char *err = NULL;
	if (btf_layout_parse(data, size, &b, &err)) {
		free(err);
		return 0;
	}
	for (size_t i = 0; i < b.n; i++) {
		if (b.t[i].kind != 4 || !b.t[i].name[0])
			continue;
		int missing;
		free(btf_layout_record(&b, b.t[i].name, &missing));
	}
	btf_layout_free(&b);
	return 0;
}
