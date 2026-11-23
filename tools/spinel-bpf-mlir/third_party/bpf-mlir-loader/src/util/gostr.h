/* gostr.h — Go の stdlib の文字列の規則の写し (bpf-mlir の Go の実装と同じ判定のため — E002)。
 *
 * 数の読みは Go の strconv (10 進) と同じ: C の strtol は先頭の空白・0x・後ろのごみを受けるので使わない。 */
#ifndef BML_GOSTR_H
#define BML_GOSTR_H

#include <stddef.h>
#include <stdint.h>

/* strconv.ParseInt(s, 10, bits): 任意の符号 (+ / -) と 1 つ以上の 10 進の数字だけ。範囲外・空・他の文字は -1。 */
int bml_go_parse_int(const char *s, size_t n, int bits, int64_t *out);

/* strconv.ParseUint(s, 10, bits): 符号を受けない。 */
int bml_go_parse_uint(const char *s, size_t n, int bits, uint64_t *out);

/* strconv.Atoi (64 bit の int): ParseInt(s, 10, 0) と同じ受理。 */
int bml_go_atoi(const char *s, size_t n, int64_t *out);

/* 伸びる文字列の buffer (malloc)。失敗は abort しない — oom を立て、以後の追記を捨てる。 */
struct bml_buf {
	char *p;
	size_t len, cap;
	int oom;
};
void bml_buf_add(struct bml_buf *b, const char *s, size_t n);
void bml_buf_adds(struct bml_buf *b, const char *s);
void bml_buf_addf(struct bml_buf *b, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
/* Go の %q (strconv.Quote) の写し: 表示できる ASCII はそのまま、\a \b \f \n \r \t \v \\ \" は escape、他の byte は
 * 正しい UTF-8 の多 byte の文字ならそのまま (Go の IsPrint の細部 — 表示できない多 byte の文字の \u の escape — は写さない)、
 * 不正な byte は \xNN。 */
void bml_buf_add_goquote(struct bml_buf *b, const char *s, size_t n);
/* 中身を NUL 終端の文字列として取り出し、b を空にする (oom なら NULL)。 */
char *bml_buf_take(struct bml_buf *b);
/* Go の syscall.Errno の文 (glibc の strerror の最初の文字を小文字に — Go の表と同じ綴り) — 静的な buffer ではなく malloc */
char *bml_go_errno_str(int err);
void bml_buf_free(struct bml_buf *b);

#endif
