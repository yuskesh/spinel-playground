/* tools/npu/host/src/host.c -- the small POSIX surface the hosted Spinel
 * runtime needs on Zephyr. A true no-op may be a stub. An answer the runtime
 * would act on is not faked: files, sockets, processes and fibers fail.
 * The one exception: clock_gettime answers uptime for every clock. */
#include <zephyr/kernel.h>
#include <zephyr/sys/printk.h>
#include <errno.h>
#include <stddef.h>
#include <string.h>

extern int sp_app_main(int argc, char **argv);
extern unsigned long long sp_gc_stat_collections;

int main(void)
{
	static char *argv[] = {"app", NULL};
	int rc = sp_app_main(1, argv);

	printk("spinel-npu: collections %u\n", (unsigned int)sp_gc_stat_collections);
	printk("spinel-npu: exit %d\n", rc);
	return 0;
}

/* No slab allocator, and a low first collection: this board has 320 KB. */
char *getenv(const char *n)
{
	if (strcmp(n, "SPINEL_GC_SLAB") == 0) {
		return "0";
	}
	if (strcmp(n, "SPINEL_GC_THRESHOLD_KB") == 0) {
		return "16";
	}
	return NULL;
}

long write(int fd, const void *b, size_t n)
{
	const char *c = b;

	for (size_t i = 0; i < n; i++) {
		printk("%c", c[i]);
	}
	return (long)n;
}

struct sp_timespec { long long tv_sec; long tv_nsec; };

int clock_gettime(int c, struct sp_timespec *t)
{
	int64_t ms = k_uptime_get();

	t->tv_sec = ms / 1000;
	t->tv_nsec = (long)(ms % 1000) * 1000000L;
	return 0;
}

#define NOSYS(decl) decl { errno = ENOSYS; return -1; }
long read(int fd, void *b, size_t n) { return 0; }
int close(int fd) { return 0; }
NOSYS(int open(const char *p, int f, ...))
NOSYS(long lseek(int fd, long o, int w))
NOSYS(int stat(const char *p, void *s))
NOSYS(int getcontext(void *u))
NOSYS(int setcontext(const void *u))
NOSYS(int swapcontext(void *a, const void *b))
void makecontext(void *u, void (*f)(void), int n, ...) {}
long sysconf(int n) { return 4096; }
/* Only sp_slab references it, and the slab allocator is off (getenv above). */
int posix_memalign(void **m, size_t a, size_t n)
{
	extern void *aligned_alloc(size_t, size_t);

	*m = aligned_alloc(a, n);
	return *m ? 0 : ENOMEM;
}
int sigaction(int s, const void *a, void *o) { return 0; }
int sigprocmask(int h, const void *s, void *o) { return 0; }
/* A failed mapping keeps the program on Zephyr's main stack. */
void *mmap(void *a, size_t n, int p, int f, int fd, long o) { return (void *)-1; }
int munmap(void *a, size_t n) { return 0; }
int mprotect(void *a, size_t n, int p) { return 0; }
int madvise(void *a, size_t n, int w) { return 0; }
