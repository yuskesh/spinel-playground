/*
 * otlp_json.h — OTLP/HTTP+JSON エンコーダ (proto3 JSON mapping、デバッグ/interop 用)
 *
 * `OTEL_EXPORTER_OTLP_PROTOCOL=http/json` のとき protobuf の代わりに JSON で送る。
 * HTTP のみ (gRPC は protobuf 固定)。protobuf 版 (otlp_metrics/traces/logs) と同じ
 * 入力構造体を取り、同じデータを JSON で出す。64bit 整数は proto3 JSON 規約で文字列、
 * trace_id/span_id は hex、enum は数値。
 */
#ifndef SPNL_OTLP_JSON_H
#define SPNL_OTLP_JSON_H

#include <stddef.h>
#include <stdint.h>

#include "otlp_metrics.h"  /* otlp_method_metric_t */
#include "otlp_traces.h"   /* otlp_span_t / otlp_method_meta_t */
#include "otlp_logs.h"     /* otlp_log_record_t */

#ifdef __cplusplus
extern "C" {
#endif

/* OTEL_EXPORTER_OTLP_PROTOCOL == "http/json" のとき真。 */
int otlp_want_json(void);

/* endpoint が grpc:// / grpcs:// のとき真 (gRPC は JSON 非対応 → protobuf 固定)。 */
int otlp_endpoint_is_grpc(const char *endpoint);

/* 各シグナルの OTLP/JSON を buf に書く。成功でバイト数、buf 不足/失敗で -1。 */

/* `--instrument` の per-method RED、**1 リクエスト 1 metric** (E431、protobuf 側
 * otlp_metrics_method_build と対)。`part` は otlp_method_part_t の値だが、この
 * ヘッダは otlp_metrics.h を include しないので int で受ける (両者が同じ数を意味する
 * ことは otlp_json.c の _Static_assert が固定する)。 */
long otlp_json_metrics_method_build(char *buf, size_t cap,
                                    const char *service_name, const char *service_version,
                                    const char *scope_name, int part,
                                    uint64_t time_unix_nano, uint64_t start_time_unix_nano,
                                    const otlp_method_metric_t *methods, size_t nmethods);

long otlp_json_traces_build(char *buf, size_t cap,
                            const char *service_name, const char *service_version,
                            const char *scope_name,
                            const otlp_span_t *spans, size_t nspans,
                            const otlp_method_meta_t *metas, size_t nmetas);

long otlp_json_logs_build(char *buf, size_t cap,
                          const char *service_name, const char *service_version,
                          const char *scope_name,
                          const otlp_log_record_t *recs, size_t nrecs);

/* 単一 HTTP server span (kind=SERVER + http.* 属性) を OTLP/JSON で。 */
long otlp_json_http_span_build(char *buf, size_t cap,
                               const char *service_name, const char *service_version,
                               const char *scope_name, const otlp_http_span_t *span);

/* E431: ExponentialHistogram のみ (protobuf 側 otlp_metrics_exphist_build と対)。
 * 汎用 keyed メトリクスの latency 側。かつては Sum と同梱する builder しか無かった。 */
long otlp_json_metrics_exphist_build(char *buf, size_t cap,
                                     const char *svc, const char *ver, const char *scope,
                                     const char *name, const char *unit,
                                     uint64_t t, uint64_t start,
                                     const otlp_series_t *series, size_t n);

/* E400: Sum のみ (record channel の counter)。protobuf 側 otlp_metrics_sum_build と対。 */
long otlp_json_metrics_sum_build(char *buf, size_t cap,
                                 const char *svc, const char *ver, const char *scope,
                                 const char *name, const char *unit,
                                 uint64_t t, uint64_t start,
                                 const otlp_series_t *series, size_t n);

/* 明示バケット Histogram (semconv http.server.request.duration 等) を OTLP/JSON で。 */
long otlp_json_metrics_hist_build(char *buf, size_t cap,
                                  const char *service_name, const char *service_version,
                                  const char *scope_name,
                                  const char *name, const char *unit,
                                  const double *bounds, int nbounds,
                                  uint64_t time_unix_nano, uint64_t start_time_unix_nano,
                                  const otlp_hseries_t *series, size_t nseries);

#ifdef __cplusplus
}
#endif

#endif /* SPNL_OTLP_JSON_H */
