// P029 E158 の uprobe の fixture (cfix と同じ約束 — 子の process として起動し、stdin の 1 行ごとに put_buf を呼ぶ — 本体に DWARF):
//   put LEN TEXT  → 256 byte の 0 の buffer の先頭に TEXT を写し put_buf(buf, LEN) — "put <戻り値>" を出す (TEXT は省略可 — 空)
//   putnull LEN   → put_buf(NULL, LEN)
//   quit          → 終わる
// 最初に "ready <pid>" を出す。probe は put_buf (const void *buf — 深さ 1 の pointer、int len)。
// build は scripts/build-uprobe-fixtures.sh (再 build で byte 一致 — SHA256SUMS)。
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

__attribute__((noinline)) int put_buf(const void *buf, int len) {
  __asm__ volatile("" ::"r"(buf), "r"(len) : "memory");
  return len;
}

int main(void) {
  char line[1024], text[512];
  static char buf[256];
  int n;
  setvbuf(stdout, NULL, _IOLBF, 0);
  printf("ready %d\n", (int)getpid());
  while (fgets(line, sizeof line, stdin) != NULL) {
    size_t len = strlen(line);
    if (len > 0 && line[len - 1] == '\n') line[--len] = '\0';
    text[0] = '\0';
    if (sscanf(line, "put %d %511s", &n, text) >= 1) {
      memset(buf, 0, sizeof buf);
      memcpy(buf, text, strlen(text) < sizeof buf ? strlen(text) : sizeof buf);
      printf("put %d\n", put_buf(buf, n));
    } else if (sscanf(line, "putnull %d", &n) == 1) {
      printf("putnull %d\n", put_buf(NULL, n));
    } else if (strcmp(line, "quit") == 0) {
      break;
    } else {
      printf("error %s\n", line);
    }
  }
  return 0;
}
