/* E060: bindrt.RejectedAt の純粋な写し。capは終端NUL込み、足りなければ位置無し。 */
#ifndef BML_ABI_REJECTED_H
#define BML_ABI_REJECTED_H
#include <stddef.h>
int bml_rejected_at(const char *log, size_t n, char *out, size_t cap);
#endif
