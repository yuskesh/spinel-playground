// P020 の uprobe の fixture (E080 / E081 — mojo-bpf-mlir P022 の cfix の写し): 子の process として起動し、stdin の 1 行ごとに関数を呼ぶ (差動の harness が制御する)。
//   sum A B C      → sum_args(int64_t A, uint32_t B, int32_t C) を呼び "sum <結果>" を出す
//   greet N TEXT   → greet(TEXT, N) (TEXT は行の残り — 空なら空文字列)
//   null N         → greet(NULL, N)
//   quit           → 終わる
// 最初に "ready <pid>" を出す。build は scripts/build-uprobe-fixtures.sh (再 build で byte 一致 — SHA256SUMS)。
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

__attribute__((noinline)) int64_t sum_args(int64_t a, uint32_t b, int32_t c) {
  return a + (int64_t)b + (int64_t)c;
}

__attribute__((noinline)) uint32_t greet(const char *s, uint32_t n) {
  if (s == NULL) return n;
  return (uint32_t)strlen(s) + n;
}

int main(void) {
  char line[1024];
  setvbuf(stdout, NULL, _IOLBF, 0);
  printf("ready %d\n", (int)getpid());
  while (fgets(line, sizeof line, stdin) != NULL) {
    size_t len = strlen(line);
    if (len > 0 && line[len - 1] == '\n') line[--len] = '\0';
    int64_t a;
    uint32_t b, n;
    int32_t c;
    int off = 0;
    if (sscanf(line, "sum %" SCNd64 " %" SCNu32 " %" SCNd32, &a, &b, &c) == 3) {
      printf("sum %" PRId64 "\n", sum_args(a, b, c));
    } else if (sscanf(line, "greet %" SCNu32 "%n", &n, &off) == 1) {
      const char *text = line + off;
      if (*text == ' ') text++;
      printf("greet %" PRIu32 "\n", greet(text, n));
    } else if (sscanf(line, "null %" SCNu32, &n) == 1) {
      printf("greet %" PRIu32 "\n", greet(NULL, n));
    } else if (strcmp(line, "quit") == 0) {
      break;
    } else {
      printf("error %s\n", line);
    }
  }
  return 0;
}
