// P029 E156 の uprobe の fixture (cfix と同じ約束 — 子の process として起動し、stdin の 1 行ごとに system の libc の関数を呼ぶ):
//   gai HOST SERV  → getaddrinfo(HOST, SERV, {AI_NUMERICHOST | AI_NUMERICSERV}, &r) を呼び "gai <戻り値>" を出す (成功なら freeaddrinfo — 網に出ない)
//   quit           → 終わる
// 最初に "ready <pid>" を出す。probe は libc の getaddrinfo (target は libc の絶対の path — この binary ではない)。
// build は scripts/build-uprobe-fixtures.sh (再 build で byte 一致 — SHA256SUMS)。
#include <netdb.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

int main(void) {
  char line[1024], host[512], serv[512];
  setvbuf(stdout, NULL, _IOLBF, 0);
  printf("ready %d\n", (int)getpid());
  while (fgets(line, sizeof line, stdin) != NULL) {
    size_t len = strlen(line);
    if (len > 0 && line[len - 1] == '\n') line[--len] = '\0';
    if (sscanf(line, "gai %511s %511s", host, serv) == 2) {
      struct addrinfo hints, *r = NULL;
      memset(&hints, 0, sizeof hints);
      hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV;
      hints.ai_socktype = SOCK_STREAM;
      int rc = getaddrinfo(host, serv, &hints, &r);
      if (rc == 0) freeaddrinfo(r);
      printf("gai %d\n", rc);
    } else if (strcmp(line, "quit") == 0) {
      break;
    } else {
      printf("error %s\n", line);
    }
  }
  return 0;
}
