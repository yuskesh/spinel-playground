/* Declarations the runtime uses that Zephyr's POSIX headers leave out.
 * Only declarations: what links is up to Zephyr, picolibc and host.c. */
#include <sys/types.h>
#include <stddef.h>
#include <stdio.h>
int fork(void);
int execl(const char *, const char *, ...);
int execvp(const char *, char *const[]);
int pipe(int[2]);
FILE *popen(const char *, const char *);
int pclose(FILE *);
ssize_t pread(int, void *, size_t, off_t);
int getppid(void);
int getentropy(void *, size_t);
int madvise(void *, size_t, int);
#ifndef MADV_DONTNEED
#define MADV_DONTNEED 4
#endif
#ifndef F_GETFD
#define F_GETFD 1
#define F_SETFD 2
#define FD_CLOEXEC 1
#endif
ssize_t pwrite(int, const void *, size_t, off_t);
int symlink(const char *, const char *);
int link(const char *, const char *);
int mprotect(void *, size_t, int);
struct stat;
int lstat(const char *, struct stat *);
int isatty(int);
int dup(int);
int dup2(int, int);
uid_t geteuid(void);
gid_t getegid(void);
/* The real ids: upstream Spinel's File::Stat access tests (c78f461dd). */
uid_t getuid(void);
gid_t getgid(void);
#ifndef AT_FDCWD
#define AT_FDCWD (-100)
#define AT_SYMLINK_NOFOLLOW 0x100
#endif
#ifndef TIOCGWINSZ
#define TIOCGWINSZ 0x5413
struct winsize { unsigned short ws_row, ws_col, ws_xpixel, ws_ypixel; };
#endif
#ifndef RLIM_INFINITY
typedef unsigned long long rlim_t;
struct rlimit { rlim_t rlim_cur, rlim_max; };
#define RLIM_INFINITY (~0ULL)
#define RLIMIT_STACK 3
#define RLIMIT_NOFILE 7
int getrlimit(int, struct rlimit *);
int setrlimit(int, const struct rlimit *);
#endif
#ifndef R_OK
#define R_OK 4
#define W_OK 2
#define X_OK 1
#endif
#ifndef RLIMIT_CPU
#define RLIMIT_CPU 0
#endif
#ifndef WCOREDUMP
#define WCOREDUMP(s) ((s) & 0x80)
#endif
int access(const char *, int);
int faccessat(int, const char *, int, int);
int chdir(const char *);
int fchdir(int);
char *getcwd(char *, size_t);
int chown(const char *, uid_t, gid_t);
int truncate(const char *, off_t);
ssize_t readlink(const char *, char *, size_t);
int setpgid(pid_t, pid_t);
int pause(void);
int getpriority(int, id_t);
int getgroups(int, gid_t *);
struct passwd;
struct passwd *getpwnam(const char *);
