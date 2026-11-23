/* checked_load — E053 の H7: 製品の照合する load (bml_load_checked — live の caps と C ABI の宣言 cilium-v0.22-usdt-ksyscall) の答え。
 * load だけ (attach も test run もしない — load できれば閉じる)。
 *
 *   checked_load <elf> <schema の sha256> <maps.json> [<targets.json> (E055 — bml_load_checked_targets)]
 * 出力は "<elf の basename> kind=N unmet=<kind>,…" の 1 行 (ksys_run の checked と同じ形) */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "bml/bml.h"

static char *slurp(const char *path, int64_t *n)
{
	FILE *f = fopen(path, "rb");
	if (!f)
		return NULL;
	char *b = NULL;
	long l = !fseek(f, 0, SEEK_END) ? ftell(f) : -1;
	if (l >= 0 && !fseek(f, 0, SEEK_SET) && (b = malloc((size_t)l + 1)) && fread(b, 1, (size_t)l, f) == (size_t)l) {
		b[l] = 0;
		*n = l;
	} else {
		free(b);
		b = NULL;
	}
	fclose(f);
	return b;
}

int main(int argc, char **argv)
{
	if (argc != 4 && argc != 5) {
		fprintf(stderr, "usage: checked_load <elf> <sha> <maps.json> [<targets.json>]\n");
		return 2;
	}
	int64_t n, mn, tn = 0;
	char *elf = slurp(argv[1], &n), *maps = slurp(argv[3], &mn), *targets = argc == 5 ? slurp(argv[4], &tn) : NULL;
	if (!elf || !maps || (argc == 5 && !targets)) {
		fprintf(stderr, "checked_load: cannot read %s, %s or the targets\n", argv[1], argv[3]);
		return 1;
	}
	/* E055: targets (bml_load_checked_targets の uprobe_targets・debug・debug_root) が在れば、その口で */
	int64_t r = targets ? bml_load_checked_targets((const uint8_t *)elf, n, argv[2], (int64_t)strlen(argv[2]), maps, mn, NULL, 0, targets, tn, 0)
			    : bml_load_checked((const uint8_t *)elf, n, argv[2], (int64_t)strlen(argv[2]), maps, mn, 0);
	const char *base = strrchr(argv[1], '/');
	printf("%s kind=%lld unmet=", base ? base + 1 : argv[1], (long long)bml_result_kind(r));
	for (int64_t i = 0; i < bml_result_unmet_count(r); i++) {
		int64_t l;
		const char *k = bml_result_unmet_field(r, i, 0, &l);
		printf("%s%.*s", i ? "," : "", (int)l, k);
	}
	printf("\n");
	if (bml_result_kind(r) == 0)
		bml_close(bml_result_value(r));
	bml_result_free(r);
	free(elf);
	free(maps);
	free(targets);
	return 0;
}
