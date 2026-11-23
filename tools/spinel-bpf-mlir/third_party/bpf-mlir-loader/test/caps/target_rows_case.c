/* E066: 記録した caps の読みと FromELF の sleepable の照合を行ごとに出す (Go の target-rows-oracle と diff)。shape は load の入口の section の検査。
 * kernel に触れない — target_rows_case caps|elf|shape <file>... */
#include "caps/recorded.h"
#include "json/json.h"
#include "load/internal.h"
#include "req/from_elf.h"

#include <bpf/libbpf.h>
#include <libgen.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint8_t *slurp(const char *p, size_t *n)
{
	FILE *f = fopen(p, "rb");
	if (!f || fseek(f, 0, SEEK_END))
		exit(2);
	long s = ftell(f);
	if (s < 0 || fseek(f, 0, SEEK_SET))
		exit(2);
	uint8_t *d = malloc((size_t)s + 1);
	if (!d || fread(d, 1, (size_t)s, f) != (size_t)s || fclose(f))
		exit(2);
	*n = (size_t)s;
	return d;
}

static const char *base(const char *p)
{
	const char *s = strrchr(p, '/');
	return s ? s + 1 : p;
}

static void caps(const char *p)
{
	size_t n;
	uint8_t *d = slurp(p, &n);
	char *err = NULL;
	enum bml_json_rule rule = BML_JR_NONE;
	struct bml_recorded *r = bml_recorded_parse_rule((const char *)d, n, ".", &err, &rule);
	if (r)
		printf("%s\tok\n", base(p));
	else
		printf("%s\terr\t%s\t%s\n", base(p), rule == BML_JR_NONE ? "" : bml_json_rule_name(rule), err ? err : "");
	bml_recorded_free(r);
	free(err);
	free(d);
}

static void elf(const char *p)
{
	size_t n;
	uint8_t *d = slurp(p, &n);
	struct bml_requirements *req = NULL;
	struct bml_req_elf_error e = {0};
	if (bml_req_from_elf(d, n, &req, &e))
		printf("%s\terr\t%s\n", base(p), e.parse.msg ? e.parse.msg : "(not a parse error)");
	else
		printf("%s\tok\n", base(p));
	bml_requirements_free(req);
	bml_req_elf_error_free(&e);
	free(d);
}

static void shape(const char *p)
{
	size_t n;
	uint8_t *d = slurp(p, &n);
	struct bml_load_result r = {0};
	int rc = lb_check_shape(d, n, &r);
	printf("%s\trc=%d\tstage=%s\t%s\n", base(p), rc, bml_load_stage_name(r.stage), r.msg ? r.msg : "");
	bml_load_result_free(&r);
	free(d);
}

/* E067 追補 2: libbpf の open (kernel に触れない) の直後の印だけ — 非 root の load はこの前の feature の段で止まるので直接呼ぶ */
static void guard(const char *p)
{
	size_t n;
	uint8_t *d = slurp(p, &n);
	struct bml_load_result r = {0};
	struct bpf_object *o = bpf_object__open_mem(d, n, NULL);
	if (!o) {
		printf("%s\topen_failed\n", base(p));
	} else {
		int rc = lb_mark_sleepable(o, &r);
		struct bpf_program *prog = bpf_object__next_program(o, NULL);
		printf("%s\trc=%d\tsleepable=%d\n", base(p), rc, prog && (bpf_program__flags(prog) & BPF_F_SLEEPABLE) != 0);
		bpf_object__close(o);
	}
	bml_load_result_free(&r);
	free(d);
}

int main(int argc, char **argv)
{
	if (argc < 3)
		return 2;
	void (*fn)(const char *) = !strcmp(argv[1], "caps") ? caps : !strcmp(argv[1], "elf") ? elf : !strcmp(argv[1], "shape") ? shape : !strcmp(argv[1], "guard") ? guard : NULL;
	if (!fn)
		return 2;
	for (int i = 2; i < argc; i++)
		fn(argv[i]);
	return 0;
}
