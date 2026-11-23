/* tools/wasm/shim_flockfile.h -- the stdio lock prototypes, visible to every TU.
 *
 * wasi-libc declares flockfile/funlockfile only under POSIX feature macros.
 * The pinned runtime's spinel_rt.h calls flockfile(stdout) from inline code
 * that lands in the GENERATED TU, which defines none of them and is compiled
 * with -Wno-everything, so the call became an implicit `int flockfile()`.
 * stubs.c defines them as returning void; with the two signatures disagreeing,
 * wasm-ld replaced the call with a trapping stub (its "function signature
 * mismatch" warning), and the program would have died at its first locked
 * write. Declaring the real prototype here makes every call site agree.
 *
 * Added in this repository (the pinned runtime is newer than spinel-llvm's).
 */
#ifndef SPINEL_WASM_SHIM_FLOCKFILE_H
#define SPINEL_WASM_SHIM_FLOCKFILE_H
#include <stdio.h>
void flockfile(FILE *);
void funlockfile(FILE *);
#endif
