// test/fuzz/fuzz_json.c — libFuzzer の harness: bml_json_parse と書き出しの往復 (E002)。
// 性質: 受理した文字列 (key を含む — 正しい UTF-8) を bml_json_write_string で書き、読み直すと同じ byte に戻る (違えば abort)。
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "json/json.h"

static volatile size_t sink;

static void roundtrip(const char *s, size_t n)
{
	struct bml_buf b = {0};
	bml_json_write_string(&b, s, n);
	struct bml_json *j;
	char *err;
	if (bml_json_parse(b.p, b.len, &j, &err) != 0)
		abort();
	if (j->type != BML_JSON_STRING || j->len != n || memcmp(j->str, s, n) != 0)
		abort();
	bml_json_free(j);
	bml_buf_free(&b);
}

static void walk(const struct bml_json *j)
{
	switch (j->type) {
	case BML_JSON_STRING:
		roundtrip(j->str, j->len);
		break;
	case BML_JSON_NUMBER: {
		uint64_t u;
		int64_t s;
		sink += (size_t)bml_json_uint64(j, &u) + (size_t)bml_json_int64(j, &s);
		break;
	}
	case BML_JSON_ARRAY:
		for (size_t i = 0; i < j->n; i++)
			walk(j->items[i]);
		break;
	case BML_JSON_OBJECT:
		for (size_t i = 0; i < j->n; i++) {
			roundtrip(j->members[i].key, j->members[i].key_len);
			walk(j->members[i].value);
		}
		break;
	default:
		break;
	}
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	struct bml_json *j;
	char *err;
	if (bml_json_parse((const char *)data, size, &j, &err) == 0) {
		walk(j);
		bml_json_free(j);
	} else {
		free(err);
	}
	return 0;
}
