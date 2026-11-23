/*
 * otlp_tls_smoke.c — ADR-013 T0: mbedTLS TLS クライアントの handshake smoke。
 *
 * host:port に TCP connect → otlp_tls_connect で TLS handshake → "GET /" を送って応答を読む。
 * 検証モード (system CA / OTEL_EXPORTER_OTLP_CERTIFICATE / INSECURE_SKIP_VERIFY) は env。
 * 成功 (handshake + "HTTP/" 応答) で 0。
 */
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <netdb.h>
#include <sys/socket.h>
#include <sys/types.h>

#include "otlp_tls.h"

int main(int argc, char **argv) {
    const char *host = (argc > 1) ? argv[1] : "localhost";
    const char *port = (argc > 2) ? argv[2] : "8443";

    struct addrinfo hints, *res = NULL, *ai;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host, port, &hints, &res) != 0) { fprintf(stderr, "[tls-smoke] resolve failed\n"); return 2; }
    int fd = -1;
    for (ai = res; ai; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) continue;
        if (connect(fd, ai->ai_addr, ai->ai_addrlen) == 0) break;
        close(fd); fd = -1;
    }
    freeaddrinfo(res);
    if (fd < 0) { fprintf(stderr, "[tls-smoke] connect failed\n"); return 2; }

    char err[256] = {0};
    otlp_tls_t *t = otlp_tls_connect(fd, host, NULL, err, sizeof err);
    if (!t) { fprintf(stderr, "[tls-smoke] %s\n", err); close(fd); return 3; }

    const char *req = "GET / HTTP/1.0\r\nHost: localhost\r\n\r\n";
    if (otlp_tls_write(t, req, strlen(req)) != 0) { fprintf(stderr, "[tls-smoke] write failed\n"); otlp_tls_free(t); close(fd); return 4; }
    char buf[512];
    int n = otlp_tls_read(t, buf, sizeof buf - 1);
    otlp_tls_free(t);
    close(fd);
    if (n <= 0) { fprintf(stderr, "[tls-smoke] read failed (%d)\n", n); return 5; }
    buf[n] = '\0';
    fprintf(stderr, "[tls-smoke] handshake OK, read %d bytes\n", n);
    return (strncmp(buf, "HTTP/", 5) == 0) ? 0 : 6;
}
