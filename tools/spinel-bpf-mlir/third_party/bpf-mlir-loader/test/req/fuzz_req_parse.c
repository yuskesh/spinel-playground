// test/fuzz/fuzz_req_parse.c — libFuzzer の harness: bml_req_parse (E002)。ASan + UBSan と組で build する (scripts/fuzz.sh)。
// 受理した requirements は全ての field を読んで (境界の外の読みを ASan に見せる) 解放する。
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "req/req.h"

static volatile size_t sink;

static void touch(const struct bml_str *s)
{
	if (s->p)
		sink += s->len + (unsigned char)s->p[s->len]; /* NUL 終端まで読める */
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	struct bml_requirements *r = NULL;
	struct bml_parse_error e;
	int rc = bml_req_parse((const char *)data, size, &r, &e);
	if (r) {
		touch(&r->schema_sha256);
		for (size_t i = 0; i < r->n_programs; i++) {
			touch(&r->programs[i].symbol);
			for (size_t j = 0; j < r->programs[i].n_helpers; j++)
				touch(&r->programs[i].helpers[j].name);
		}
		for (size_t i = 0; i < r->n_attaches; i++) {
			const struct bml_attach *a = &r->attaches[i];
			touch(&a->target);
			for (size_t j = 0; j < a->n_args; j++)
				touch(&a->args[j]);
			for (size_t j = 0; j < a->n_fargs; j++)
				touch(&a->fargs[j]);
			for (size_t j = 0; j < a->n_ctxfields; j++)
				touch(&a->ctxfields[j].field);
			for (size_t j = 0; j < a->n_uprobe_args; j++)
				touch(&a->uprobe_args[j].type);
		}
		for (size_t i = 0; i < r->n_maps; i++)
			touch(&r->maps[i].value);
		bml_requirements_free(r);
	}
	if (rc) {
		sink += strlen(e.msg ? e.msg : "") + strlen(e.rule) + strlen(e.row);
		bml_parse_error_free(&e);
	}
	return 0;
}
