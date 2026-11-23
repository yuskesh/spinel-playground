/* shim/spinel/internal.h — spinel の shim の内部 (result.c・spinel.c — E007) */
#ifndef BML_SHIM_SPINEL_INTERNAL_H
#define BML_SHIM_SPINEL_INTERNAL_H

#include <stdint.h>

/* CONTRACT: handles of results the shim creates itself (spinel text checks, value copies) are in a range disjoint from bml result handles */
#define SH_BASE ((int64_t)1 << 62)

int64_t sh_result(int64_t kind, int64_t value, const char *fmt, ...) __attribute__((format(printf, 3, 4)));
/* bml の結果 r を読み (kind・value・message の写し) 放す */
struct sh_res {
	int64_t kind, value;
	char *msg; /* malloc (NUL を含みうる — len) */
	int64_t len;
};
struct sh_res sh_take(int64_t r);
void sh_res_free(struct sh_res *x);

struct bml_map_decl;
/* 宣言を読む (spinel の ParseMapDecl — 失敗は OTHER の結果、成功は 0) — spinel.c */
int64_t sh_parse_decl(const char *decl, struct bml_map_decl *d);
/* spinel の hashBytes (int64 の配列 → bytes、what は "key" / "value") — 失敗は NULL と *err (結果) — spinel.c */
uint8_t *sh_hash_bytes(const int64_t *a, int64_t n, const char *what, int64_t *err);

/* reader の record の大きさ (ringbuf_open が覚える — 無ければ -1) */
void sh_reader_set(int64_t rb, int64_t size);
int64_t sh_reader_size(int64_t rb);

#endif
