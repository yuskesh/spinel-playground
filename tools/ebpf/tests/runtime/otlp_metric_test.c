/*
 * otlp_metric_test.c — 汎用 keyed メトリクス (任意ラベル、--instrument 非依存) の検証 (E271)。
 * 2 series (function=read/write、pid ラベル付き) を組んで送信。受信側 (mock) が
 * メトリクス名 + 任意ラベル + count/latency を復元できればよい。libbpf 非依存 (build 関数を直叩き)。
 * E431: rate と latency は **別リクエスト**で送る (同梱をやめた)。
 * 使い方: otlp_metric_test <endpoint>
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>

#include "otlp_metrics.h"   /* otlp_series_t / 型別 build / otlp_kv_t */
#include "otlp_json.h"      /* otlp_want_json */
#include "otlp_grpc.h"      /* otlp_transport_send + OTLP_GRPC_PATH_METRICS */

/* E429: 型別 build (Gauge のみ / ExponentialHistogram のみ) を 1 payload ずつ落とす。
 * E291 が Splunk の 500 を型に切り分けられなかったのは、当時の汎用 builder が Sum と
 * ExpHist を必ず対で出して「片方だけ」を作れなかったから。E431 で本番経路もこちらに
 * 寄せたので、この口は実験用ではなく**本番の出し方そのもの**になった。
 * (送信はしない — 決めるのは呼び出し側 shell の protoc assert)。 */
static int dump_kinds(const char *dir) {
    otlp_kv_t l[1] = { { "function", "read" } };
    otlp_series_t s;
    memset(&s, 0, sizeof s);
    s.count = 5; s.buckets[10] = 3; s.buckets[11] = 2; s.labels = l; s.nlabels = 1;
    uint64_t t = 1700000000000000000ULL, start = 1699999999000000000ULL;

    static const struct { const char *file; int exphist; const char *name; const char *unit; } K[] = {
        { "gauge.pb",   0, "probe_gauge",      "1"  },
        { "exphist.pb", 1, "probe_latency_ns", "ns" },
    };
    for (size_t i = 0; i < sizeof K / sizeof K[0]; i++) {
        static uint8_t b[1 << 16];
        long n = K[i].exphist
            ? otlp_metrics_exphist_build(b, sizeof b, "spinel-probe", NULL, "spinel-ebpf",
                                         K[i].name, K[i].unit, t, start, &s, 1)
            : otlp_metrics_gauge_build(b, sizeof b, "spinel-probe", NULL, "spinel-ebpf",
                                       K[i].name, K[i].unit, t, start, &s, 1);
        if (n < 0) { fprintf(stderr, "[metric] encode failed: %s\n", K[i].file); return 1; }
        char path[512];
        snprintf(path, sizeof path, "%s/%s", dir, K[i].file);
        FILE *f = fopen(path, "wb");
        if (!f) { perror("fopen"); return 1; }
        fwrite(b, 1, (size_t)n, f);
        fclose(f);
        fprintf(stderr, "[metric] wrote %s (%ld bytes)\n", path, n);
    }
    return 0;
}

int main(int argc, char **argv) {
    const char *ep = (argc > 1) ? argv[1] : "http://127.0.0.1:4318";
    if (argc > 2 && strcmp(argv[1], "--dump-kinds") == 0) return dump_kinds(argv[2]);

    otlp_kv_t l0[2] = { { "function", "read" }, { "pid", "100" } };
    otlp_kv_t l1[2] = { { "function", "write" }, { "pid", "100" } };
    otlp_series_t s[2];
    memset(s, 0, sizeof s);
    s[0].count = 5; s[0].buckets[10] = 3; s[0].buckets[11] = 2; s[0].labels = l0; s[0].nlabels = 2;
    s[1].count = 7; s[1].buckets[5]  = 7;                        s[1].labels = l1; s[1].nlabels = 2;

    uint64_t t = 1700000000000000000ULL, start = 1699999999000000000ULL;
    static uint8_t pbuf[1 << 16];
    static char    jbuf[1 << 16];
    const int json = otlp_want_json() && strncmp(ep, "grpc", 4) != 0;

    /* E431: 1 リクエスト = 1 metric。rate と latency を別々に送る。 */
    for (int part = 0; part < 2; part++) {
        const char *name = part ? "probe_latency_ns" : "probe_calls";
        long n; const char *ct; const uint8_t *body;
        if (json) {
            n = part ? otlp_json_metrics_exphist_build(jbuf, sizeof jbuf, "spinel-probe", NULL,
                                                       "spinel-ebpf", name, "ns", t, start, s, 2)
                     : otlp_json_metrics_sum_build(jbuf, sizeof jbuf, "spinel-probe", NULL,
                                                   "spinel-ebpf", name, "1", t, start, s, 2);
            body = (const uint8_t *)jbuf; ct = "application/json";
        } else {
            n = part ? otlp_metrics_exphist_build(pbuf, sizeof pbuf, "spinel-probe", NULL,
                                                  "spinel-ebpf", name, "ns", t, start, s, 2)
                     : otlp_metrics_sum_build(pbuf, sizeof pbuf, "spinel-probe", NULL,
                                              "spinel-ebpf", name, "1", t, start, s, 2);
            body = pbuf; ct = "application/x-protobuf";
        }
        if (n < 0) { fprintf(stderr, "encode failed: %s\n", name); return 1; }
        int status = 0; char err[256] = {0};
        int rc = otlp_transport_send(ep, "/v1/metrics", OTLP_GRPC_PATH_METRICS,
                                     ct, body, (size_t)n, &status, err, sizeof err);
        if (rc != 0) { fprintf(stderr, "[metric] transport error: %s\n", err); return 2; }
        fprintf(stderr, "[metric] %s %s -> status %d (%ld bytes)\n", name, ep, status, n);
        if (status != 200) return 3;
    }
    return 0;
}
