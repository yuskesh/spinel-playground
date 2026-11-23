/* tests/core-boundary/fixtures/failure-sites/harness.c -- one call of fs_entry.
 *
 *   harness A K [SITES]   prints "status result site"
 *
 * The result word is set to 77 first, so a failure that leaves it alone shows
 * 77. With SITES (the object was built with --failure-sites) the site global
 * is read after the call; without it the field is "-". A second call of
 * fs_entry(1, 1) follows when the first failed, to show the wrapper clears the
 * site: its line is "again status result site". */
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include "k.h"
#ifdef SITES
extern int32_t spinel_core_fs_entry_failure_site;
#define SITE(x) printf(" %" PRId32 "\n", (x))
#else
#define SITE(x) printf(" -\n")
#endif
int main(int argc, char **argv)
{
	if (argc < 3) return 2;
	int64_t r = 77;
	int32_t st = spinel_core_fs_entry(strtoll(argv[1], 0, 0), strtoll(argv[2], 0, 0), &r);
	printf("%" PRId32 " %" PRId64, st, r);
#ifdef SITES
	SITE(spinel_core_fs_entry_failure_site);
#else
	SITE(0);
#endif
	if (st != 0) {
		r = 77;
		st = spinel_core_fs_entry(1, 1, &r);
		printf("again %" PRId32 " %" PRId64, st, r);
#ifdef SITES
		SITE(spinel_core_fs_entry_failure_site);
#else
		SITE(0);
#endif
	}
	return 0;
}
