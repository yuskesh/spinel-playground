/* tests/doom-core/native/bound_map.c — a session image's resource part, mapped read-only.
 *
 * bound.rb binds every resource field to an offset in this mapping (decision
 * 0021). PROT_READ is the point: the adapter refuses every write to bound
 * storage, and if one got past it, the page would fault rather than be
 * written. Answers the address, or a negative number naming the step that
 * failed: -1 open, -2 fstat or an empty file, -3 mmap.
 */
#include <fcntl.h>
#include <stdint.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

int64_t doom_bound_map(const char *path) {
  int fd = open(path, O_RDONLY);
  if (fd < 0) return -1;
  struct stat st;
  if (fstat(fd, &st) != 0 || st.st_size == 0) {
    close(fd);
    return -2;
  }
  void *p = mmap(0, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
  close(fd);
  if (p == MAP_FAILED) return -3;
  return (int64_t)(uintptr_t)p;
}
