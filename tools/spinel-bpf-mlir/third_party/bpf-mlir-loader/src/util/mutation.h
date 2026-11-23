/* mutation.h — 変異の対照の hook (試験の build だけ — E002)。
 *
 * -DBML_MUTATION の build では BML_MUT("名前") が環境変数 BML_MUTANT と名前の一致で真になる。製品の build (build-libs.sh) では
 * 定数 0 で、hook の code も symbol も残らない (gate が nm で確かめる)。変異の名前と「落ちるはずの case」は E002 の表。 */
#ifndef BML_MUTATION_H
#define BML_MUTATION_H

#ifdef BML_MUTATION
#include <stdlib.h>
#include <string.h>
static inline int bml_mutant_active(const char *name)
{
	const char *m = getenv("BML_MUTANT");
	return m && strcmp(m, name) == 0;
}
#define BML_MUT(name) bml_mutant_active(name)
#else
#define BML_MUT(name) 0
#endif

#endif
