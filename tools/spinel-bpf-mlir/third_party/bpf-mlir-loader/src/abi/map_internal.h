/* abi/map_internal.h — map の操作の共通 (map.c・hash.c・percpu.c・ringbuf.c — E006) */
#ifndef BML_ABI_MAP_INTERNAL_H
#define BML_ABI_MAP_INTERNAL_H

#include "abi/internal.h"

struct bpf_map;

/* 宣言を読み ELF と照合した map (object は registry が持つ — m->o は abi_map_open が abi_object_acquire で走っている呼び出しとして数え、
 * abi_map_close が数を戻す: 同じ object の close は数が 0 でなければ STATE — E006 の後半の追補の契約) */
struct abi_map {
	struct abi_object *o;
	struct bml_map_decl d;
	int has_d;
	struct bpf_map *map;
	int fd;
	uint32_t key_size, value_size;
};

/* 宣言 (decl) と records の文書 (0 個以上 — 空は飛ばす) を読み、宣言 1 つの片方向の照合 (AllowUndeclared) をして map を開く。
 * 成功は 0、失敗は結果の handle (呼び手はそれを返す) */
int64_t abi_map_open(int64_t h, const char *decl, int64_t decl_len, const char *const *records, const int64_t *records_len,
		     size_t n_records, struct abi_map *m);
/* 同じ、宣言の kind を先に見る (kinds は NULL 終端の許す kind、what は "a hash map" 等 — 違えば MAP_MISMATCH。下流の順: kind → 照合) */
int64_t abi_map_open_kind(int64_t h, const char *decl, int64_t decl_len, const char *const *kinds, const char *what,
			  const char *const *records, const int64_t *records_len, size_t n_records, struct abi_map *m);
void abi_map_close(struct abi_map *m);

/* object の close が先に閉じる (ringbuf.c・hash.c) */
void abi_reader_free(void *p);
void abi_iter_free(void *p);

#endif
