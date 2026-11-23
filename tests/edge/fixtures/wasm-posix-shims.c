/* Compile for WASI against the driver runtime objects and run under WASI.
 * Unsupported operations fail with ENOSYS and leave supplied masks unchanged;
 * MADV_DONTNEED preserves the allocator's zero-filled-memory contract. */
#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <signal.h>
#include <sys/file.h>
#include <sys/mman.h>
#include <string.h>

int main(void) {
  sigset_t mask, previous;
  memset(&mask, 7, sizeof(mask));
  memset(&previous, 9, sizeof(previous));
  sigset_t empty;
  memset(&empty, 0, sizeof(empty));
  assert(sigemptyset(&mask) == 0);
  assert(memcmp(&mask, &empty, sizeof(mask)) == 0);
  memset(&mask, 7, sizeof(mask));
  sigset_t saved_mask = mask, saved_previous = previous;
  errno = 0;
  assert(sigaction(SIGTERM, NULL, NULL) == -1 && errno == ENOSYS);
  errno = 0;
  assert(sigaltstack(NULL, NULL) == -1 && errno == ENOSYS);
  errno = 0;
  assert(kill(1, SIGTERM) == -1 && errno == ENOSYS);
  errno = 0;
  assert(flock(0, LOCK_EX | LOCK_NB) == -1 && errno == ENOSYS);
  errno = 0;
  assert(flock(0, LOCK_UN) == -1 && errno == ENOSYS);
  errno = 0;
  assert(sigaddset(&mask, 1) == -1 && errno == ENOSYS && memcmp(&mask, &saved_mask, sizeof(mask)) == 0);
  errno = 0;
  assert(sigprocmask(SIG_BLOCK, &mask, &previous) == -1 && errno == ENOSYS);
  assert(memcmp(&mask, &saved_mask, sizeof(mask)) == 0 && memcmp(&previous, &saved_previous, sizeof(previous)) == 0);
  errno = 0;
  assert(sigprocmask(SIG_UNBLOCK, &mask, &previous) == -1 && errno == ENOSYS);
  errno = 0;
  assert(sigprocmask(SIG_SETMASK, NULL, &previous) == -1 && errno == ENOSYS);
  assert(memcmp(&mask, &saved_mask, sizeof(mask)) == 0);
  assert(memcmp(&previous, &saved_previous, sizeof(previous)) == 0);
  char page[32];
  memset(page, 0x5a, sizeof(page));
  assert(madvise(page, sizeof(page), MADV_DONTNEED) == 0);
  for (unsigned i = 0; i < sizeof(page); ++i) assert(page[i] == 0);
  puts("PASS: POSIX refusals preserve masks; MADV_DONTNEED zeroes memory");
  return 0;
}
