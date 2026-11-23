/*
 * otlp_grpc.h — OTLP/gRPC transport (ADR-012 / P003 S5)
 *
 * 最小の HTTP/2 unary gRPC クライアント (POSIX socket のみ、依存追加なし)。
 * 送る protobuf は HTTP transport と同じ ExportXServiceRequest。gRPC は HTTP/2 上で
 *   HEADERS(:method/:path/:scheme/:authority + content-type: application/grpc) +
 *   DATA(1B compressed-flag=0 + 4B BE length + protobuf) + END_STREAM
 * を送る。応答は HPACK decode せず、stream 完了 (END_STREAM) / GOAWAY・RST でエラー判定。
 * 正しさの権威は受信側 (grpcio mock / 実 Collector) が request を decode できること。
 */
#ifndef SPNL_OTLP_GRPC_H
#define SPNL_OTLP_GRPC_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define OTLP_GRPC_PATH_METRICS "/opentelemetry.proto.collector.metrics.v1.MetricsService/Export"
#define OTLP_GRPC_PATH_TRACES  "/opentelemetry.proto.collector.trace.v1.TraceService/Export"
#define OTLP_GRPC_PATH_LOGS    "/opentelemetry.proto.collector.logs.v1.LogsService/Export"

/*
 * body (ExportXServiceRequest protobuf) を grpc_path に unary gRPC で送る。
 * connect は最大 max_retries 回まで指数バックオフ (0 = 既定 5)。
 * 成功 (送信 + stream 完了): 0 を返し *ok=1。GOAWAY/RST で *ok=0。
 * 転送失敗 (名前解決/接続/送受信): -1、err にメッセージ。
 */
/* tls != 0 のとき grpcs:// (HTTP/2 over TLS、要 OTLP_WITH_TLS ビルド)。0 は平文 h2c。 */
int otlp_grpc_export(const char *host, const char *port, const char *grpc_path,
                     const uint8_t *body, size_t body_len, int tls, int max_retries,
                     int *ok, char *err, size_t errlen);

/*
 * endpoint の scheme で transport を選ぶ: "grpc://..." なら OTLP/gRPC、それ以外は
 * OTLP/HTTP POST。status には HTTP ステータス (http) / grpc ok の 200・not-ok の 0 を返す。
 * 成功で 0、転送失敗で -1。metrics/traces/logs の送出口を 1 本化する。
 */
/* content_type は HTTP 経路の Content-Type (例 application/x-protobuf / application/json)。
 * gRPC 経路では無視 (application/grpc+proto 固定)。 */
int otlp_transport_send(const char *endpoint, const char *http_path, const char *grpc_path,
                        const char *content_type,
                        const uint8_t *body, size_t body_len, int *status, char *err, size_t errlen);

#ifdef __cplusplus
}
#endif

#endif /* SPNL_OTLP_GRPC_H */
