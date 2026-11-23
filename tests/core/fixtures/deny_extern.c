/* Positive control for the undefined-symbol gate.
 *
 * The checks on a real core object establish that the gate ALLOWS what the
 * profile declares. That direction alone would also pass if the gate allowed
 * everything. This object deliberately reaches two symbols the host profile
 * does not permit -- an allocator, and an extern nobody declared -- so the
 * gate has to refuse it, and has to say why.
 *
 * It is C rather than Ruby on purpose: the generator would refuse to emit
 * either of these from a kernel, so a refusing gate could never be observed
 * through that path. */
#include <stddef.h>
extern void *malloc(size_t);
extern int platform_thing(int);
void *use_malloc(size_t n) { return malloc(n); }
int use_thing(int x) { return platform_thing(x); }
