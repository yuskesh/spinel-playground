// P029 E157 の uprobe の fixture (cfix・gfix と同じ約束 — 子の process として起動し、stdin の 1 行ごとに system の libc の関数を呼ぶ):
//   lock I    → pthread_mutex_lock(&m[I]) を呼び "lock <&m[I] の 10 進>" を出す (I は 0 / 1)
//   unlock I  → pthread_mutex_unlock(&m[I]) を呼び "unlock <&m[I] の 10 進>" を出す
//   quit      → 終わる
// 最初に "ready <pid>" を出す。probe は libc の pthread_mutex_lock / unlock (target は libc の絶対の path — この binary ではない)。
// build は scripts/build-uprobe-fixtures.sh (再 build で byte 一致 — SHA256SUMS)。
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static pthread_mutex_t m[2] = {PTHREAD_MUTEX_INITIALIZER, PTHREAD_MUTEX_INITIALIZER};

int main(void) {
  char line[256];
  int i;
  setvbuf(stdout, NULL, _IOLBF, 0);
  printf("ready %d\n", (int)getpid());
  while (fgets(line, sizeof line, stdin) != NULL) {
    size_t len = strlen(line);
    if (len > 0 && line[len - 1] == '\n') line[--len] = '\0';
    if (sscanf(line, "lock %d", &i) == 1 && i >= 0 && i < 2) {
      pthread_mutex_lock(&m[i]);
      printf("lock %lu\n", (unsigned long)&m[i]);
    } else if (sscanf(line, "unlock %d", &i) == 1 && i >= 0 && i < 2) {
      pthread_mutex_unlock(&m[i]);
      printf("unlock %lu\n", (unsigned long)&m[i]);
    } else if (strcmp(line, "quit") == 0) {
      break;
    } else {
      printf("error %s\n", line);
    }
  }
  return 0;
}
