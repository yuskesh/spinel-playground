/* Use the pinned runtime's WASI POSIX compatibility layer, with Extended's
 * stricter answers for observed unsupported operations. Upstream declarations
 * and definitions stay together; renamed alternatives are discarded at link.
 * madvise is supplied by stubs.c, including MADV_DONTNEED zeroing. */
#define flock sp_wasi_upstream_flock
#define sigemptyset sp_wasi_upstream_sigemptyset
#define sigaddset sp_wasi_upstream_sigaddset
#define sigprocmask sp_wasi_upstream_sigprocmask
#define madvise sp_wasi_upstream_madvise
#include "sp_wasi.c"
#undef flock
#undef sigemptyset
#undef sigaddset
#undef sigprocmask
#undef madvise

#include <string.h>

int sigemptyset(sigset_t *mask) {
  memset(mask, 0, sizeof(*mask));
  return 0;
}

int flock(int fd, int operation) {
  (void)fd; (void)operation;
  errno = ENOSYS;
  return -1;
}
int sigaddset(sigset_t *mask, int signal_number) {
  (void)mask; (void)signal_number;
  errno = ENOSYS;
  return -1;
}
int sigprocmask(int how, const sigset_t *mask, sigset_t *previous) {
  (void)how; (void)mask; (void)previous;
  errno = ENOSYS;
  return -1;
}
