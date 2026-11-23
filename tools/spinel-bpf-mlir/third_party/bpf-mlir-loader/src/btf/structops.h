/* btf/structops.h — ELF の struct_ops の表 (bpf-mlir E485 の go/layout の StructOpsTables — E042) */
#ifndef BML_BTF_STRUCTOPS_H
#define BML_BTF_STRUCTOPS_H

#include <stddef.h>

/* 大域変数 1 つの表 (spelling は Go の StructOpsTable.Spelling) */
struct bml_struct_ops_table {
	char *var, *spelling;
};

/* 表を読む。struct_ops の section が無ければ 0 個。失敗は -1 と *err (Go の文 — malloc) */
int bml_struct_ops_tables(const void *elf, size_t len, struct bml_struct_ops_table **out, size_t *n, char **err);
void bml_struct_ops_tables_free(struct bml_struct_ops_table *t, size_t n);

#endif
