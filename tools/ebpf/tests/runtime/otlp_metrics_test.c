/*
 * otlp_metrics_test.c — ADR-012 / P003 S2: per-method RED -> OTLP metrics の変換検証
 *
 * 2 メソッド分の {calls, log2 buckets} を otlp_metrics_method_build に渡し、
 * **part ごとに 1 ファイル**書く (E431: 1 リクエスト = 1 metric)。ランナー
 * (run_otlp_metrics.sh) が `protoc --decode` で 3 つの part を検証する。
 *
 * 期待 (slot s = floor(log2(ns))):
 *   calls        : fib=177, add=500 の Sum。**latency は 1 つも入っていない**こと
 *   latency_exp  : ExponentialHistogram(scale=0) で slot s -> 正 bucket index s。
 *                  fib -> offset 9, bucket_counts [100,0,77], count 177,
 *                  sum = 100*768 + 77*3072 = 313344
 *   latency_hist : 明示バケット (bounds set log2_ns_31)。slot s -> bucket s (s<=26)
 *                  なので同じ数が bucket 9 / 11 / 10 に出る (件数は割れない、E431 D1)
 */
#include <stdio.h>
#include <string.h>
#include <stdint.h>

#include "otlp_metrics.h"

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <outdir>\n", argv[0]); return 2; }
    const char *dir = argv[1];

    otlp_method_metric_t methods[2];
    memset(methods, 0, sizeof methods);
    methods[0].method = "fib"; methods[0].file = "app.rb"; methods[0].line = 1;
    methods[0].calls = 177; methods[0].buckets[9] = 100; methods[0].buckets[11] = 77;
    methods[1].method = "add"; methods[1].file = "app.rb"; methods[1].line = 19;
    methods[1].calls = 500; methods[1].buckets[10] = 500;

    static const struct { const char *file; otlp_method_part_t part; } P[] = {
        { "calls.pb",        OTLP_MPART_CALLS },
        { "latency_exp.pb",  OTLP_MPART_LATENCY_EXP },
        { "latency_hist.pb", OTLP_MPART_LATENCY_HIST },
    };
    for (size_t i = 0; i < sizeof P / sizeof P[0]; i++) {
        uint8_t buf[8192];
        long n = otlp_metrics_method_build(buf, sizeof buf,
                                           "spinel-app", "0.1.0", "spinel-ebpf", P[i].part,
                                           1700000000000000000ULL, 1699999999000000000ULL,
                                           methods, 2);
        if (n < 0) { fprintf(stderr, "build failed: %s\n", P[i].file); return 1; }
        char path[512];
        snprintf(path, sizeof path, "%s/%s", dir, P[i].file);
        FILE *fp = fopen(path, "wb");
        if (!fp) { perror("fopen"); return 1; }
        if (fwrite(buf, 1, (size_t)n, fp) != (size_t)n) { perror("fwrite"); fclose(fp); return 1; }
        fclose(fp);
        fprintf(stderr, "[otlp_metrics] %s: %ld bytes\n", P[i].file, n);
    }
    return 0;
}
