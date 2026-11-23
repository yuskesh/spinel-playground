/* req/kfunc_profile.h — kfunc の使用許可の初期の profile (bpf-mlir E499 — E042) */
#ifndef BML_REQ_KFUNC_PROFILE_H
#define BML_REQ_KFUNC_PROFILE_H

#include "elf/elf.h"
#include "req/req.h"
#include "util/gostr.h"

/* Go の json.Marshal(Attach) (blank_program は Program を "" に — ContextIdentity)。HTML の <>& の escape まで */
void bml_req_attach_json(struct bml_buf *b, const struct bml_attach *a, int blank_program);
/* deriveKfuncProfiles (FromELF の中)。-1 は memory の不足 */
int bml_req_kfunc_profiles_derive(const struct bml_elf *elf, struct bml_requirements *r);
void bml_req_kfunc_profiles_free(struct bml_requirements *r);
/* kfuncProfileFor: 在れば profile、無ければ NULL と *why (Go の err.Error() — malloc) */
const struct bml_kfunc_profile_entry *bml_req_kfunc_profile_for(const struct bml_requirements *r, const char *program, char **why);

#endif
