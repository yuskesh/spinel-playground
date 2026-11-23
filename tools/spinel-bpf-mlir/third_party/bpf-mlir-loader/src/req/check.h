/* check.h — requirements の照合 (bpf-mlir docs/requirements_format.md §5・§6・§9 — go/requirements/requirements.go の Check と
 * Unmet、go/bindrt の classify の写し — 判定の版 3、E002)。 */
#ifndef BML_CHECK_H
#define BML_CHECK_H

#include <stddef.h>
#include <stdint.h>

#include "caps/caps.h"
#include "req/req.h"

#define BML_POLICY_VERSION 27 /* E060: enumval17・fibflags18・datakptr19・extern/guard20・coreenum21・funcret22・kstructsize23・arena24。E066: netkit25・helper_target26・sleepable27。 */

struct bml_unmet {
	const char *kind; /* UnmetKinds の 1 つ (静的) */
	char *program, *name;
	int64_t id;
	char *detail;
};

struct bml_unmets {
	struct bml_unmet *u;
	size_t n, cap;
};

/* Go の Unmet.Unknown / BlocksLoad */
int bml_unmet_unknown(const struct bml_unmet *u);
int bml_unmet_blocks_load(const struct bml_unmet *u);
/* Go の Unmet.String (malloc) */
char *bml_unmet_string(const struct bml_unmet *u);
void bml_unmets_free(struct bml_unmets *v);

/* Go の Check。成功は 0 (*out に全ての Unmet — 照合の順)、照合の誤りは -1 と *err (malloc) */
int bml_check(const struct bml_requirements *req, const struct bml_caps *caps, struct bml_unmets *out, char **err);


#endif
