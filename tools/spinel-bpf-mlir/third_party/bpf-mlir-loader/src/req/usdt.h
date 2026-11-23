/* req/usdt.h — USDT の点の読みと引数の記述の読み (bpf-mlir go/requirements/usdt.go の ReadUSDTPoints・ParseUSDTArg の写し — E039、
 * requirements_format.md §8)。照合 (checkUSDT) は check_v12.c */
#ifndef BML_REQ_USDT_H
#define BML_REQ_USDT_H

#include <stddef.h>
#include <stdint.h>

#include "elf/elf.h"

#define BML_USDT_SPEC_MAP_PREFIX "__ebpf_usdt_spec_"

/* note の点 1 つ。文字列は note の中を指さず malloc (provider・name・args — NUL 終端、中に NUL は無い) */
struct bml_usdt_point {
	uint64_t pc, base, semaphore;
	char *provider, *name, *args;
};

struct bml_usdt_points {
	struct bml_usdt_point *p;
	size_t n, cap;
};

/* CONTRACT: ReadUSDTPoints: stapsdt notes (owner "stapsdt", type 3) of every SHT_NOTE section in note order. 0 is success (empty if none),
 * -1 is a broken note (*err, the same text as Go, malloc). Free *out with bml_usdt_points_free (also on failure) */
int bml_usdt_read_points(const struct bml_elf *elf, struct bml_usdt_points *out, char **err);
void bml_usdt_points_free(struct bml_usdt_points *v);

/* USDTArgSpec (kind は "" / "reg" / "deref" / "const"、reg は % を除いた名前か "") */
struct bml_usdt_arg {
	int size, is_signed;
	const char *kind;
	char reg[8];
	int64_t off;
};

/* ParseUSDTArg (s は長さ n — NUL を含みうる)。*size_ok は大きさが読めた。*err は誤り (malloc、無ければ NULL)。-1 は memory の不足 */
int bml_usdt_parse_arg(const char *s, size_t n, struct bml_usdt_arg *spec, int *size_ok, char **err);

/* strings.Fields (Go の unicode.IsSpace で区切る)。区切りの開始と長さを *starts / *lens (malloc) に。-1 は memory の不足 */
int bml_go_fields(const char *s, size_t n, size_t **starts, size_t **lens, size_t *count);

/* note の register の名前 (% を除く) の spec の reg の番号 (UAPI の表の usdtreg の index — ax 0 … r15 15)。知らない名前は -1 */
int bml_usdt_reg_index(const char *r);

/* ---- E044: attach の点の計算 (usdt_points.c — §8 の ref_ctr の契約、bpf-mlir kernel/internal/usdtattach の Points と EncodeUSDTSpec の写し) ---- */
#define BML_USDT_SPEC_SIZE 192    /* 12 の引数 × 16 byte */
#define BML_USDT_ARG_SPEC_SIZE 16 /* kind u8 @+0・reg u8 @+1・6 byte の 0・off i64 @+8 (little endian) */
#define BML_USDT_KIND_CONST 1
#define BML_USDT_KIND_REG 2
#define BML_USDT_KIND_DEREF 3

struct bml_usdt_attach_point {
	size_t index;           /* spec の map の key と cookie (note の順の `<provider>:<name>` の点の番号) */
	uint64_t pc, semaphore; /* note の pc (補正の前) と semaphore の address (0 は無し) */
	uint64_t off, sem_off;  /* uprobe の file offset (prelink の補正の後、実行の PT_LOAD) と semaphore の file offset (0 は無し) */
	uint8_t spec[BML_USDT_SPEC_SIZE];
};

/* EncodeUSDTSpec。-1 は memory の不足 */
int bml_usdt_encode_spec(const char *args, uint8_t spec[BML_USDT_SPEC_SIZE]);
/* Points: binary (data, len) の `<provider>:<name>` の点。0 は成功 (*out は malloc、1 つ以上)、-1 は *err (malloc) */
int bml_usdt_attach_points(const uint8_t *data, size_t len, const char *provider, const char *name, struct bml_usdt_attach_point **out, size_t *n,
			   char **err);

#endif
