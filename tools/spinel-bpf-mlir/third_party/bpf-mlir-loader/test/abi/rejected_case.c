/* E060: 同じbyte列と長さを純粋helperへ。位置はhexで出す。kernelを使わない。 */
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "abi/rejected.h"
#include "util/gostr.h"
#ifdef BML_REJECTED_LEGACY
#include "rejected_legacy.h"
#endif

int main(int argc, char **argv)
{
	if (argc != 3) return 2;
	char *end;
	unsigned long cap = strtoul(argv[2], &end, 10);
	if (*end || cap > 1u << 20) return 2;
	FILE *f = fopen(argv[1], "rb");
	if (!f) return 2;
	struct bml_buf b = {0}; char chunk[4096]; size_t n;
	while ((n = fread(chunk, 1, sizeof(chunk), f))) bml_buf_add(&b, chunk, n);
	int bad = ferror(f); fclose(f);
	if (bad || b.oom) { bml_buf_free(&b); return 2; }
	char *out = calloc(cap ? cap : 1, 1);
	if (!out) { bml_buf_free(&b); return 2; }
#ifdef BML_REJECTED_LEGACY
	int ok = legacy_rejected_at(b.p, b.len, out, cap);
#else
	int ok = bml_rejected_at(b.p, b.len, out, cap);
#endif
	printf("%d\t", !!ok);
	if (ok) for (const unsigned char *p = (unsigned char *)out; *p; p++) printf("%02x", *p);
	putchar('\n'); free(out); bml_buf_free(&b); return 0;
}
