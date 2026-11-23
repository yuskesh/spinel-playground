// test/fuzz/fuzz_req_elf.c — libFuzzer の harness: bml_req_from_elf (ELF の読み → section → Parse) (E002)。
#include <stddef.h>
#include <stdint.h>

#include "req/from_elf.h"

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	struct bml_requirements *r;
	struct bml_req_elf_error e;
	if (bml_req_from_elf(data, size, &r, &e) == 0)
		bml_requirements_free(r);
	else
		bml_req_elf_error_free(&e);
	return 0;
}
