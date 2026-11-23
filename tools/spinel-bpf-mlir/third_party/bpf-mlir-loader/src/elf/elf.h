/* elf.h — ELF の最小の reader (E002)。Go の debug/elf.NewFile と同じ検査を開く時に、section の範囲の検査を読む時に行う
 * (Go と同じ段 — 関係の無い section の壊れた offset では開くことは失敗しない)。ELF32 / ELF64・little / big endian を読む。
 *
 * Go との差 (fail closed の側): SHF_COMPRESSED の section の中身は読まない (Go は zlib / zstd を展開する) — 読めば誤り。
 * libelf は使わない (照合の読みを load の libbpf の経路から独立に保つ — R001 Q3 §1.1)。 */
#ifndef BML_ELF_H
#define BML_ELF_H

#include <stddef.h>
#include <stdint.h>

struct bml_elf_shdr {
	const char *name; /* shstrtab の中 (NUL 終端)。shstrtab が無ければ "" */
	uint32_t type, link, info;
	uint64_t flags, addr, offset, size, addralign, entsize;
};

struct bml_elf_phdr {
	uint32_t type, flags;
	uint64_t offset, vaddr, paddr, filesz, memsz, align;
};

struct bml_elf {
	const uint8_t *data;
	size_t len;
	int is64, big_endian;
	uint16_t type, machine;
	struct bml_elf_shdr *sections;
	size_t n_sections;
	struct bml_elf_phdr *progs;
	size_t n_progs;
};

/* 開く (data は呼び手が持ち、bml_elf_close まで生きていること)。失敗は -1 と *err (malloc の文) */
int bml_elf_open(const void *data, size_t len, struct bml_elf *elf, char **err);
void bml_elf_close(struct bml_elf *elf);

/* 名前の最初の section (Go の File.Section)、無ければ NULL */
const struct bml_elf_shdr *bml_elf_section(const struct bml_elf *elf, const char *name);

/* section の中身 (Go の Section.Data)。file の中を指す (copy しない)。NOBITS・範囲外・圧縮は -1 と *err */
int bml_elf_section_data(const struct bml_elf *elf, const struct bml_elf_shdr *s, const uint8_t **out, size_t *out_len,
			 char **err);

/* 読みの helper (endian を ELF に合わせる — 範囲の検査は呼び手) */
uint16_t bml_elf_u16(const struct bml_elf *elf, const uint8_t *p);
uint32_t bml_elf_u32(const struct bml_elf *elf, const uint8_t *p);
uint64_t bml_elf_u64(const struct bml_elf *elf, const uint8_t *p);

#define BML_SHT_NULL 0
#define BML_SHT_SYMTAB 2
#define BML_SHT_STRTAB 3
#define BML_SHT_REL 9
#define BML_SHT_NOBITS 8
#define BML_SHT_DYNSYM 11
#define BML_SHF_COMPRESSED 0x800


/* symbol (Go の elf.Symbol — index 0 の空の symbol を含まない) */
struct bml_elf_sym {
	const char *name; /* 文字列の表の中 (NUL 終端)、読めない index は "" (Go の getString の失敗と同じ) */
	uint8_t info, other;
	uint16_t shndx;
	uint64_t value, size;
};
#define BML_STT_OBJECT 1
#define BML_STT_FUNC 2
#define BML_ST_TYPE(i) ((i) & 0xf)
#define BML_SHN_UNDEF 0
#define BML_SHF_EXECINSTR 0x4

/* CONTRACT: reads the symbols of type BML_SHT_SYMTAB or BML_SHT_DYNSYM from the first section of that type (version information is not read).
 * A missing or empty section returns -1 and sets *err = "no symbol section". *out is malloc'd (release with free) */
int bml_elf_symbols(const struct bml_elf *elf, uint32_t type, struct bml_elf_sym **out, size_t *n, char **err);

#endif
