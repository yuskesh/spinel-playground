#pragma once
#include <stddef.h>
#include <sys/types.h>
#define PROT_NONE 0
#define PROT_READ 1
#define PROT_WRITE 2
#define MAP_PRIVATE 2
#define MAP_ANONYMOUS 0x20
#define MAP_ANON MAP_ANONYMOUS
#define MAP_SHARED 1
#define MAP_FAILED ((void *)-1)
#define MADV_DONTNEED 4
void *mmap(void *, size_t, int, int, int, off_t);
int munmap(void *, size_t);
int madvise(void *, size_t, int);
int mprotect(void *, size_t, int);
