/*
 * otlp_http_duration_test.c — http.server.request.duration (秒・OBI 同一バケット) の検証 (E272 S2)。
 * 既知の duration を持つ span を記録 (fd=-1、addr 省略) → メトリクスを push。
 * 受信側 (mock) が name="http.server.request.duration" / explicit_bounds / 正しいバケット /
 * 属性 (http.request.method / http.route / http.response.status_code) を復元できれば OK。
 *
 * 記録:
 *   series A: route "/fast"  , 2 回 x 3ms   -> bucket index 1 ((0, 0.005])   に 2
 *   series B: route "/slow"  , 1 回 x 1.2s  -> bucket index 11 ((1, 2.5])     に 1
 *
 * 使い方: otlp_http_duration_test <endpoint>
 */
#include <stdio.h>
#include <stdint.h>

#include "otlp_httpspan.h"

int main(int argc, char **argv) {
    const char *ep = (argc > 1) ? argv[1] : "http://127.0.0.1:4318";
    uint64_t t0 = spnl_otlp_now_unix_ns();

    /* series A: /fast x2, 各 3ms */
    spnl_otlp_http_span_fd(-1, NULL, "GET", "/fast", "/fast", 200, t0, t0 + 3000000ULL, ep);
    spnl_otlp_http_span_fd(-1, NULL, "GET", "/fast", "/fast", 200, t0, t0 + 3000000ULL, ep);
    /* series B: /slow x1, 1.2s */
    spnl_otlp_http_span_fd(-1, NULL, "GET", "/slow", "/slow", 200, t0, t0 + 1200000000ULL, ep);

    int st = spnl_otlp_http_metrics_push(ep);
    fprintf(stderr, "[http-duration] %s -> metrics push %d\n", ep, st);
    return st == 200 ? 0 : 1;
}
