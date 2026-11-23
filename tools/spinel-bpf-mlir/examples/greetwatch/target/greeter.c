// greeter — P020 E083 の例 greetwatch の uprobe の target (C)。最初に "ready <pid>" を出し、stdin の 1 行ごとに greet(名前, 回数) を呼んで
// 返事の行を出す (回数は行の番号 — 1 から)。行 "(null)" は greet(NULL, 回数)。build は scripts/build-uprobe-fixtures.sh (再 build で byte 一致 — SHA256SUMS)。
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

__attribute__((noinline)) uint32_t greet(const char *name, uint32_t count) {
  if (name == NULL) return count;
  return (uint32_t)strlen(name) + count;
}

int main(void) {
  char line[1024];
  uint32_t count = 0;
  setvbuf(stdout, NULL, _IOLBF, 0);
  printf("ready %d\n", (int)getpid());
  while (fgets(line, sizeof line, stdin) != NULL) {
    size_t len = strlen(line);
    if (len > 0 && line[len - 1] == '\n') line[--len] = '\0';
    count++;
    if (strcmp(line, "(null)") == 0) {
      printf("greeted %" PRIu32 "\n", greet(NULL, count));
    } else {
      printf("greeted %" PRIu32 "\n", greet(line, count));
    }
  }
  return 0;
}
