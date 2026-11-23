/* tools/zephyr-full/host/src/host.c -- the Zephyr side of a hosted Spinel
 * program (decision 0038): start the network, run the program, and report
 * on the console in lines the board check reads:
 *   ZFULL BEGIN | ZFULL NET up|none | ZFULL MODE supervisor|user ...
 *   (the program's own output) | ZFULL GC <collections> | ZFULL EXIT <status>
 * (fields separated by tabs). Also the few functions the runtime needs that
 * neither Zephyr nor picolibc defines. */
#include <zephyr/kernel.h>
#include <zephyr/net/net_if.h>
#include <zephyr/net/dhcpv4.h>
#include <zephyr/net/conn_mgr_monitor.h>
#include <stdio.h>
#include <stdlib.h>
extern int sp_app_main(int argc, char **argv);
extern unsigned long long sp_gc_stat_collections;
static K_SEM_DEFINE(up, 0, 1);
static struct net_mgmt_event_callback cb;
static void on_event(struct net_mgmt_event_callback *c, uint64_t ev, struct net_if *i) { k_sem_give(&up); }
static char *argv[] = {"app", NULL};

static void run(void *a, void *b, void *c)
{
	int rc = sp_app_main(1, argv);
	printf("ZFULL\tGC\t%u\nZFULL\tEXIT\t%d\n", (unsigned)sp_gc_stat_collections, rc);
}

#ifdef CONFIG_USERSPACE
#include <zephyr/app_memory/app_memdomain.h>
#include <zephyr/sys/libc-hooks.h>
/* the runtime's and the program's globals (CMakeLists puts both libraries
 * here), with the C library's globals and its malloc arena: all the program
 * may touch in user mode */
K_APPMEM_PARTITION_DEFINE(sp_partition);
static struct k_mem_domain sp_domain;
K_THREAD_STACK_DEFINE(sp_stack, 32768);
static struct k_thread sp_thread;

static void run_user(void)
{
	struct k_mem_partition *parts[] = {
		&sp_partition,
#ifdef Z_LIBC_PARTITION_EXISTS
		&z_libc_partition,
#endif
#ifdef Z_MALLOC_PARTITION_EXISTS
		&z_malloc_partition,
#endif
	};
	int e = k_mem_domain_init(&sp_domain, ARRAY_SIZE(parts), parts);
	printf("ZFULL\tMODE\tuser\t%d\t%u\n", e, (unsigned)ARRAY_SIZE(parts));
	k_tid_t t = k_thread_create(&sp_thread, sp_stack, K_THREAD_STACK_SIZEOF(sp_stack), run, NULL, NULL, NULL,
				    K_PRIO_PREEMPT(1), K_USER, K_FOREVER);
	k_mem_domain_add_thread(&sp_domain, t);
	k_thread_start(t);
	k_thread_join(t, K_FOREVER);
}
#endif

/* the runtime reads these in its own constructors (sp_alloc_floors_from_env,
 * the slab probe), which Zephyr runs before main: set them first */
__attribute__((constructor(101))) static void sp_env(void)
{
	setenv("SPINEL_GC_SLAB", "0", 1);
	setenv("SPINEL_GC_THRESHOLD_KB", "16", 1);
#ifdef SP_PEER
	/* the network peer a program talks to, given at build time */
	setenv("ZFULL_PEER", SP_PEER, 1);
#endif
}

int main(void)
{
	printf("ZFULL\tBEGIN\n");
	net_mgmt_init_event_callback(&cb, on_event, NET_EVENT_L4_CONNECTED);
	net_mgmt_add_event_callback(&cb);
	net_dhcpv4_start(net_if_get_default());
	conn_mgr_mon_resend_status();
	printf("ZFULL\tNET\t%s\n", k_sem_take(&up, K_SECONDS(30)) == 0 ? "up" : "none");
#ifdef CONFIG_USERSPACE
	run_user();
#else
	printf("ZFULL\tMODE\tsupervisor\n");
	run(NULL, NULL, NULL);
#endif
	return 0;
}

#include <errno.h>
#define NOSYS(decl) decl { errno = ENOSYS; return -1; }
NOSYS(int getcontext(void *u))
NOSYS(int setcontext(const void *u))
NOSYS(int swapcontext(void *a, const void *b))
void makecontext(void *u, void (*f)(void), int n, ...) { }
int madvise(void *a, size_t n, int w) { return 0; }
/* isatty: upstream Spinel's runtime asks it of STDOUT at start (820b9a6a6) to
 * write a terminal through. Nothing here is a terminal, so STDOUT keeps the
 * buffering stdio gives it, as before that change. */
int isatty(int fd)
{
	errno = ENOTTY;
	return 0;
}
int posix_memalign(void **m, size_t a, size_t n)
{
	*m = aligned_alloc(a, n);
	return *m ? 0 : ENOMEM;
}

/* lstat: Zephyr's file system API has stat but no lstat (and no links). No
 * file system is configured here, so it fails like stat would. */
struct stat;
NOSYS(int lstat(const char *p, struct stat *s))

/* __freadahead: the bytes stdio has buffered and not yet handed out, which
 * sp_io reads (musl's name) before it waits on a descriptor. picolibc has no
 * such call; its buffered FILE is struct __file_bufio, private to the
 * library. The prefix below is picolibc 1.8.10's (tinystdio/stdio-bufio.h);
 * the build stops on any other version rather than read the wrong fields. */
#include <picolibc.h>
#if __PICOLIBC__ != 1 || __PICOLIBC_MINOR__ != 8 || __PICOLIBC_PATCHLEVEL__ != 10
#error "__freadahead mirrors picolibc 1.8.10's struct __file_bufio"
#endif
struct sp_bufio_prefix {
	struct __file_ext xfile;
	const void *ptr;
	uint8_t dir;
	uint8_t bflags;
	__off_t pos;
	char *buf;
	int size;
	int len;
	int off;
};
size_t __freadahead(FILE *f)
{
	size_t n = 0;

	if (f->flags & __SBUF) {
		struct sp_bufio_prefix *b = (struct sp_bufio_prefix *)f;

		if (b->dir == __SRD && b->len > b->off) {
			n = (size_t)(b->len - b->off);
		}
	}
	return n + (f->unget != 0);
}

/* exit() from the program (an uncaught exception, exit 1) ends here; Zephyr's
 * weak _exit prints only "exit", so print the same lines main prints */
void _exit(int status)
{
	printf("ZFULL\tGC\t%u\nZFULL\tEXIT\t%d\n", (unsigned)sp_gc_stat_collections, status);
	for (;;)
		k_sleep(K_FOREVER);
}

#ifdef SP_TRACE_IO
/* linked with --wrap: each call's result and errno, on the console */
#include <stdarg.h>
#include <sys/types.h>
#include <sys/socket.h>
ssize_t __real_read(int fd, void *b, size_t n);
ssize_t __wrap_read(int fd, void *b, size_t n)
{
	ssize_t r = __real_read(fd, b, n); int e = errno;
	printk("TRACE\tread\t%d\t%u\t%d\t%d\n", fd, (unsigned)n, (int)r, e); errno = e; return r;
}
int __real_fcntl(int fd, int cmd, ...);
int __wrap_fcntl(int fd, int cmd, ...)
{
	va_list ap; va_start(ap, cmd); intptr_t a = va_arg(ap, intptr_t); va_end(ap);
	int r = __real_fcntl(fd, cmd, a); int e = errno;
	printk("TRACE\tfcntl\t%d\t%d\t%ld\t%d\t%d\n", fd, cmd, (long)a, r, e); errno = e; return r;
}
ssize_t __real_send(int fd, const void *b, size_t n, int fl);
ssize_t __wrap_send(int fd, const void *b, size_t n, int fl)
{
	ssize_t r = __real_send(fd, b, n, fl); int e = errno;
	printk("TRACE\tsend\t%d\t%u\t%d\t%d\t%d\n", fd, (unsigned)n, fl, (int)r, e); errno = e; return r;
}
ssize_t __real_recv(int fd, void *b, size_t n, int fl);
ssize_t __wrap_recv(int fd, void *b, size_t n, int fl)
{
	ssize_t r = __real_recv(fd, b, n, fl); int e = errno;
	printk("TRACE\trecv\t%d\t%u\t%d\t%d\t%d\n", fd, (unsigned)n, fl, (int)r, e); errno = e; return r;
}
int __real_connect(int fd, const struct sockaddr *a, socklen_t l);
int __wrap_connect(int fd, const struct sockaddr *a, socklen_t l)
{
	int r = __real_connect(fd, a, l); int e = errno;
	printk("TRACE\tconnect\t%d\t%d\t%d\n", fd, r, e); errno = e; return r;
}
int __real_poll(void *p, unsigned n, int t);
int __wrap_poll(void *p, unsigned n, int t)
{
	int r = __real_poll(p, n, t); int e = errno;
	printk("TRACE\tpoll\t%u\t%d\t%d\t%d\n", n, t, r, e); errno = e; return r;
}
#endif

/* picolibc's fdopen and fileno, renamed in CMakeLists.txt; --wrap sends the
 * runtime's calls and picolibc's own fopen here instead of to Zephyr's */
FILE *sp_picolibc_fdopen(int fd, const char *mode);
int sp_picolibc_fileno(FILE *f);
FILE *__wrap_fdopen(int fd, const char *mode) { return sp_picolibc_fdopen(fd, mode); }
int __wrap_fileno(FILE *f) { return sp_picolibc_fileno(f); }
