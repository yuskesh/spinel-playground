/* tools/npu/host/force.h -- declarations the runtime expects from a POSIX libc
 * that picolibc does not provide; force-included into every runtime compile. */
#include <sys/types.h>
#include <stddef.h>
#ifndef CLOCK_MONOTONIC
#define CLOCK_MONOTONIC 4
#endif
int getentropy(void *, size_t);
#include <stdio.h>
FILE *popen(const char *, const char *);
int pclose(FILE *);
