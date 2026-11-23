/* req_elf.h — ELF から `.ebpf_requirements` を読む (Go の requirements.FromELF の section の読み — E002) */
#ifndef BML_REQ_ELF_H
#define BML_REQ_ELF_H

#include "elf/elf.h"
#include "req/req.h"

enum bml_req_elf_stage {
	BML_REQ_ELF_OK,
	BML_REQ_ELF_OPEN,       /* ELF として開けない (Go の elf.NewFile の誤り) */
	BML_REQ_ELF_NO_SECTION, /* section が無い */
	BML_REQ_ELF_DATA,       /* section の中身を読めない */
	BML_REQ_ELF_PARSE,      /* Parse の誤り (parse に中身) */
};

struct bml_req_elf_error {
	enum bml_req_elf_stage stage;
	char *msg; /* OPEN・NO_SECTION・DATA の文 */
	struct bml_parse_error parse;
};

int bml_req_from_elf(const void *data, size_t len, struct bml_requirements **out, struct bml_req_elf_error *e);
void bml_req_elf_error_free(struct bml_req_elf_error *e);
/* bpf-mlir checkSleepableSections (E660 — E066 — from_elf_sleepable.c): 0 は良い、-1 と *err (malloc) */
int bml_req_check_sleepable_sections(const struct bml_elf *elf, const struct bml_requirements *r, char **err);

#endif
