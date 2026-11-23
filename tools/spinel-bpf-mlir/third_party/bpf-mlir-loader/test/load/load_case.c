/* test/load/load_case.c — guard 付きの load の試験の道具 (E005)。ELF ごとに照合 (live の caps — E004) をし、止める Unmet が無ければ
 * guard 付きで load して 1 行を出す:
 *
 *   <ELF>\t<照合の結果 — ok / target_rejected / precheck_failed / requirements_invalid>\t<load の段 — ok / shape / … / ->\t<文>
 *
 *   load_case [--unchecked] <ELF>…
 *
 * 照合の結果が ok でなければ load しない (段は -)。load した object は直ぐ閉じる (attach しない)。 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "caps/live_caps.h"
#include "load/internal.h"
#include "load/load.h"
#include "req/check.h"
#include "req/from_elf.h"

static uint8_t *read_file(const char *p, size_t *n)
{
	FILE *f = fopen(p, "rb");
	if (!f)
		return NULL;
	fseek(f, 0, SEEK_END);
	long l = ftell(f);
	fseek(f, 0, SEEK_SET);
	uint8_t *b = malloc(l > 0 ? (size_t)l : 1);
	if (b && fread(b, 1, (size_t)l, f) != (size_t)l) {
		free(b);
		b = NULL;
	}
	fclose(f);
	*n = (size_t)l;
	return b;
}

static void oneline(char *s)
{
	for (; s && *s; s++)
		if (*s == '\n' || *s == '\t')
			*s = ' ';
}

int main(int argc, char **argv)
{
	struct bml_live_caps lc = {0};
	struct bml_caps caps;
	bml_live_caps(&lc, &caps);
	/* --unchecked: 照合をしない試験の入口 (名前で分ける — guard だけを試す負の対照 — E005)。照合の欄は unchecked */
	if (argc == 2 && strcmp(argv[1], "--secdefs") == 0) { /* E019: libbpf の section_defs の写し (gate が libbpf の source から抜いた表と比べる) */
		lb_secdefs_print();
		return 0;
	}
	int unchecked = argc > 1 && strcmp(argv[1], "--unchecked") == 0;
	for (int i = 1 + unchecked; i < argc; i++) {
		size_t n;
		uint8_t *elf = read_file(argv[i], &n);
		if (!elf) {
			printf("%s\tunreadable\t-\t\n", argv[i]);
			continue;
		}
		struct bml_requirements *req = NULL;
		struct bml_req_elf_error ee;
		if (bml_req_from_elf(elf, n, &req, &ee) != 0) {
			printf("%s\trequirements_invalid\t-\t\n", argv[i]);
			bml_req_elf_error_free(&ee);
			free(elf);
			continue;
		}
		struct bml_unmets u = {0};
		char *err = NULL;
		const char *pre = "ok";
		if (unchecked)
			pre = "unchecked";
		else if (bml_check(req, &caps, &u, &err) != 0)
			pre = "precheck_failed";
		else
			for (size_t k = 0; k < u.n; k++)
				if (bml_unmet_blocks_load(&u.u[k]))
					pre = "target_rejected";
		free(err);
		if (strcmp(pre, "ok") != 0 && !unchecked) {
			printf("%s\t%s\t-\t\n", argv[i], pre);
		} else {
			struct bml_obj *o = NULL;
			struct bml_load_result r;
			bml_load_guarded(elf, n, req, &caps, &o, &r);
			oneline(r.msg);
			printf("%s\t%s\t%s\t%s\n", argv[i], pre, bml_load_stage_name(r.stage), r.msg ? r.msg : "");
			if (getenv("BML_LOAD_LOG") && r.log)
				fprintf(stderr, "== %s\n%s\n", argv[i], r.log);
			bml_load_result_free(&r);
			bml_obj_close(o);
		}
		fflush(stdout);
		bml_unmets_free(&u);
		bml_requirements_free(req);
		free(elf);
	}
	bml_live_caps_free(&lc);
	return 0;
}
