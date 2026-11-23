/*
 * otlp_xlayer_span_test.c — E274: L2–L8 横断・単一レコード相関の "1 record = 全層同居" を検証する
 * host 側ハーネス (libbpf 非依存 = span builder + transport のみ)。
 *
 * 実 loopback TCP を 1 本張って accept 済み fd を作り、spnl_otlp_http_span_fd_x に渡す:
 *   L3   : client.address (getpeername 由来)
 *   L4   : server.port (getsockname 由来) + net.tcp.established / net.tcp.state_changes
 *   L7   : http.request.method / url.path / http.route / http.response.status_code / latency(span duration)
 *   L8   : tenant + W3C traceparent 継承 (traceId が incoming と一致)
 *
 * established / state_changes の値は「横断 lookup が返す L3/L4 値」を模して引数で渡す。その値が
 * 実 bpf_hist_keyed map から fd 経由で引けること (= 4-tuple join の成立) は container の
 * otlp_xlayer_join_test で別途実証済 (E274 Edoc 参照)。本ハーネスは "全層が 1 span に同居する"
 * 組み立て + trace 継承を host で決定論的に検証する。
 *
 * 使い方: otlp_xlayer_span_test <endpoint> [traceparent] [tenant] [established] [state_changes] [status]
 */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#include "otlp_httpspan.h"

/* 127.0.0.1 に自己接続し server 側 accept fd を返す (client fd は *client_out)。失敗で -1。 */
static int self_connect(int *client_out) {
    int ln = socket(AF_INET, SOCK_STREAM, 0);
    if (ln < 0) return -1;
    struct sockaddr_in a;
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    a.sin_port = 0;
    if (bind(ln, (struct sockaddr *)&a, sizeof a) != 0) { close(ln); return -1; }
    if (listen(ln, 1) != 0) { close(ln); return -1; }
    socklen_t sl = sizeof a;
    if (getsockname(ln, (struct sockaddr *)&a, &sl) != 0) { close(ln); return -1; }
    int cl = socket(AF_INET, SOCK_STREAM, 0);
    if (cl < 0) { close(ln); return -1; }
    if (connect(cl, (struct sockaddr *)&a, sizeof a) != 0) { close(ln); close(cl); return -1; }
    int sv = accept(ln, NULL, NULL);
    close(ln);
    if (sv < 0) { close(cl); return -1; }
    *client_out = cl;
    return sv;
}

int main(int argc, char **argv) {
    const char *ep = (argc > 1) ? argv[1] : "http://127.0.0.1:4318";
    const char *tp = (argc > 2) ? argv[2]
        : "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01";
    const char *tenant = (argc > 3) ? argv[3] : "acme";
    long est = (argc > 4) ? atol(argv[4]) : 1;   /* net.tcp.established   (横断 lookup 値を模す) */
    long chg = (argc > 5) ? atol(argv[5]) : 3;   /* net.tcp.state_changes (横断 lookup 値を模す) */
    int status = (argc > 6) ? atoi(argv[6]) : 200;

    int cl = -1;
    int sv = self_connect(&cl);   /* server 側 accept fd (無ければ -1 = addr 省略) */

    uint64_t t0 = spnl_otlp_now_unix_ns();
    uint64_t t1 = t0 + 1234567;   /* ~1.2ms latency (span duration = L7 latency) */
    int st = spnl_otlp_http_span_fd_x(sv, tp, "GET", "/hello", "/hello", status,
                                      t0, t1, tenant, est, chg, ep);
    fprintf(stderr, "[xlayer-span] %s tenant=%s established=%ld state_changes=%ld status=%d -> otlp %d\n",
            ep, tenant, est, chg, status, st);

    if (sv >= 0) close(sv);
    if (cl >= 0) close(cl);
    return st == 200 ? 0 : 1;
}
