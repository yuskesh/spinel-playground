/*
 * otlp_roundtrip_test.c — ADR-012 / P003 S0 完了条件の round-trip smoke test
 *
 * nanopb で OTLP の ExportMetricsServiceRequest を手組みして encode し、bytes を
 * argv[1] に書き出す。ランナー (run_otlp_roundtrip.sh) が `protoc --decode` に流し、
 * 期待フィールドが復元されることを検証する。これで「vendored otel-proto → nanopb codegen
 * → C encode → 標準 protoc で decode 一致」のツールチェーンが通ることを証明する。
 *
 * エンコーダ本体は otlp_sample_metrics.h に集約 (S1 送信テストと共有)。
 */
#include <stdio.h>
#include <stdint.h>

#include "otlp_sample_metrics.h"

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <out.pb>\n", argv[0]); return 2; }

    uint8_t buf[8192];
    long n = otlp_build_sample_metrics(buf, sizeof buf);
    if (n < 0) { fprintf(stderr, "encode failed\n"); return 1; }
    fprintf(stderr, "[otlp_roundtrip] encoded %ld bytes\n", n);

    FILE *fp = fopen(argv[1], "wb");
    if (!fp) { perror("fopen"); return 1; }
    if (fwrite(buf, 1, (size_t)n, fp) != (size_t)n) { perror("fwrite"); fclose(fp); return 1; }
    fclose(fp);
    return 0;
}
