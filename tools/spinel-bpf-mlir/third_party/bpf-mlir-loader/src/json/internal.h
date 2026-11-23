/* json/internal.h — JSON の parser の内部 (json/ の中だけ — E003 の前の構造の整理で json.c を分けた) */
#ifndef BML_JSON_INTERNAL_H
#define BML_JSON_INTERNAL_H

#include <stddef.h>
#include <stdint.h>

#include "json/json.h"

struct parser {
	const unsigned char *s;
	size_t len, pos;
	int depth, lenient;
	char *err;
	enum bml_json_rule rule;
};

int json_fail(struct parser *p, enum bml_json_rule rule, const char *fmt, ...) __attribute__((format(printf, 3, 4)));
void json_skip_ws(struct parser *p);
/* UTF-8 の 1 文字の長さ (ASCII は 1、overlong・surrogate・範囲外は 0) */
size_t json_utf8_seq(const unsigned char *s, size_t n);
void json_put_utf8(struct bml_buf *b, uint32_t cp);
/* p->pos は開きの " の後 */
int json_parse_string(struct parser *p, char **out, size_t *out_len);
int json_parse_number(struct parser *p, struct bml_json *j);
int json_lit(struct parser *p, const char *w);

#endif
