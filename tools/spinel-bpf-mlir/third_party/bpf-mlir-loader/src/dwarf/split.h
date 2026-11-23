/* dwarf/split.h — 分けた DWARF の結び付けと読む前の検査 (bpf-mlir E557 — E055)。失敗は -1 と *why (固定の ASCII の文 — malloc) */
#ifndef BML_DWARF_SPLIT_H
#define BML_DWARF_SPLIT_H

#include <stddef.h>
#include <stdint.h>

#include "dwarf/dwarf.h"
#include "elf/elf.h"

/* debugBuildID: owner は "the binary" か "separate DWARF"。*id は malloc */
int bml_debug_build_id(const struct bml_elf *e, const char *owner, uint8_t **id, size_t *n, char **why);
/* debugLinkCRC: 無ければ 0 と *has = 0 */
int bml_debug_link_crc(const struct bml_elf *e, uint32_t *crc, int *has, char **why);
/* crc32.ChecksumIEEE */
uint32_t bml_crc32_ieee(const uint8_t *p, size_t n);
/* hasDebugInfo: .debug_info か .zdebug_info の section が在る (NOBITS・大きさ 0 も) */
int bml_debug_has_info(const struct bml_elf *e);
/* elf.NewFile の圧縮の header の読み (段 6 の unreadable の一部 — bml_elf_open の後に) */
int bml_debug_open_checks(const struct bml_elf *f, char **why);
/* 段 9〜11 の前半: altlink・debug 宛の REL / RELA・type units・section ごとの上限・info の有無 */
int bml_debug_split_checks(const struct bml_elf *f, char **why);

#endif
