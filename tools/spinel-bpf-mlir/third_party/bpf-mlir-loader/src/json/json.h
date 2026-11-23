/* json.h — 厳しい JSON の parser と、Go の encoding/json と同じ文字列の escape の writer (E002・E290 に揃えた E002 の追記)。
 *
 * 規則は bpf-mlir docs/requirements_format.md §13 (E290 — Go の requirements.DecodeStrictJSON と同じ): byte の水準の規則
 * (duplicate_key・key_case・invalid_utf8・unpaired_surrogate・trailing_data・nesting_too_deep・syntax) を入力の先頭から最初に
 * 当たったもので止め、型への読み (unknown_key・type) は読む側 (recorded.c・mapdecl.c) が。key_case は型の記述 (desc) の
 * struct の object でだけ見る (map の key は自由) — Go の strictScanner と同じ走査の順。
 * lenient は Go の json.Unmarshal の寛容さ (重複は後勝ち・不正な UTF-8 と対の無い surrogate は U+FFFD・深さ 10000) — ebpf-caps 1 の
 * 形式の先読み (E289) にだけ使う。 */
#ifndef BML_JSON_H
#define BML_JSON_H

#include <stddef.h>
#include <stdint.h>

#include "util/gostr.h"

#define BML_JSON_MAX_DEPTH 128

enum bml_json_type { BML_JSON_NULL, BML_JSON_BOOL, BML_JSON_NUMBER, BML_JSON_STRING, BML_JSON_ARRAY, BML_JSON_OBJECT };

/* §13 の規則 (Go の requirements.JSONRule*) */
enum bml_json_rule {
	BML_JR_NONE,
	BML_JR_SYNTAX,
	BML_JR_DUPLICATE_KEY,
	BML_JR_KEY_CASE,
	BML_JR_INVALID_UTF8,
	BML_JR_UNPAIRED_SURROGATE,
	BML_JR_TRAILING_DATA,
	BML_JR_NESTING_TOO_DEEP,
	BML_JR_NUL, /* E302 (bpf-mlir v0.13.0) — 文字列の中の \u0000 */
	BML_JR_UNKNOWN_KEY,
	BML_JR_TYPE,
	BML_JR_OOM,
	/* bpf-mlir E457 (E039): JSON の規則でなく caps.json の形式の規則 (CapsFormatError) — 形式より新しい key / 問い合わせ */
	BML_JR_CAPS_KEY_NEWER_FORMAT,
	BML_JR_CAPS_FORMAT_UNKNOWN, /* bpf-mlir E480 (E041): 知らない形式 (typed の decode の前) */
};
const char *bml_json_rule_name(enum bml_json_rule r);

/* 型の記述 (Go の reflect.Type の代わり — key_case の検査の範囲)。NULL は「型の分からない所」 */
struct bml_json_desc;
struct bml_json_field {
	const char *name;
	const struct bml_json_desc *desc;
};
struct bml_json_desc {
	enum { BML_JD_SCALAR, BML_JD_STRUCT, BML_JD_MAP, BML_JD_ARRAY, BML_JD_STRING, BML_JD_BOOL, BML_JD_UINT, BML_JD_INT } kind;
	int bits; /* UINT・INT の幅 */
	const struct bml_json_field *fields; /* STRUCT */
	size_t n_fields;
	const struct bml_json_desc *child; /* MAP の値・ARRAY の要素 */
};

struct bml_json;

struct bml_json_member {
	char *key; /* CONTRACT: unescaped and NUL-terminated, but \u0000 can put a NUL inside the key, so read its length from key_len */
	size_t key_len;
	struct bml_json *value;
};

struct bml_json {
	enum bml_json_type type;
	int boolean;
	char *str; /* STRING: unescape 済みの byte (NUL 終端)、NUMBER: 元の綴り */
	size_t len;
	struct bml_json **items; /* ARRAY */
	struct bml_json_member *members; /* OBJECT (文書の順) */
	size_t n;
};

/* 成功は 0 と *out (bml_json_free)。失敗は -1 と *err (malloc の文 — "offset N: …")。 */
int bml_json_parse(const char *data, size_t len, struct bml_json **out, char **err);
/* 型の記述と規則付き。lenient は上の注 */
int bml_json_parse_ex(const char *data, size_t len, const struct bml_json_desc *desc, int lenient, struct bml_json **out,
		      char **err, enum bml_json_rule *rule);
void bml_json_free(struct bml_json *j);

/* Go の標準の decoder の型への読み (DisallowUnknownFields) の検査を文書の順で — 最初の unknown_key か type。field の名前は
 * encoding/json の畳み (ASCII の大小・U+017F ſ → s・U+212A K → k) で結び付け、畳んで一致した key は field の名前に書き換える
 * (key_case は parse の走査で先に止まるので、ここに来るのは ſ の類だけ)。null はどこでも「設定しない」。 */
int bml_json_validate(struct bml_json *j, const struct bml_json_desc *desc, char **err, enum bml_json_rule *rule);

/* object の key の値 (無ければ NULL — 同じ key が複数なら最後 — Go の後勝ち) */
const struct bml_json *bml_json_get(const struct bml_json *obj, const char *key);
/* NUMBER を Go の json の uint64 / int64 への decode と同じ規則で読む (小数・指数・範囲外は -1) */
int bml_json_uint64(const struct bml_json *j, uint64_t *out);
int bml_json_int64(const struct bml_json *j, int64_t *out);

/* Go の encoding/json (SetEscapeHTML(false)) と同じ文字列の書き出し: \" \\ \n \r \t、他の制御文字は \u00XX、
 * U+2028 / U+2029 は \u2028 / \u2029、不正な UTF-8 の byte は \ufffd。 */
void bml_json_write_string(struct bml_buf *b, const char *s, size_t n);
/* 同じ、Go の json.Marshal の既定 (HTML の < > & を < > & に — bpf-mlir E499 の KfuncLoadKey・ContextIdentity — E042) */
void bml_json_write_string_html(struct bml_buf *b, const char *s, size_t n);

#endif
