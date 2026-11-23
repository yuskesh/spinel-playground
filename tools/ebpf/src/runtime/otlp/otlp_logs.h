/*
 * otlp_logs.h — emit イベントを OTLP logs (LogRecord) に変換 (ADR-012 / P003 S4)
 *
 * spinel-ebpf の emit リングバッファ (spnl_emit -> <unit>_events / spnl_emit_str ->
 * <unit>_str_events) の各イベントを 1 件 = 1 LogRecord にする。body は int か string。
 * 組み立て (encode) は libbpf 非依存で host 単体検証できる。drain は otlp_agent が行う。
 */
#ifndef SPNL_OTLP_LOGS_H
#define SPNL_OTLP_LOGS_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint64_t    time_unix_ns;  /* wall-clock (ktime + offset) */
    int32_t     severity;      /* OTLP SeverityNumber、0 は INFO(9) 既定 */
    bool        body_is_str;
    const char *body_str;      /* body_is_str のとき */
    int64_t     body_int;      /* それ以外 */
    const char *event_name;    /* NULL なら省略 */
} otlp_log_record_t;

/* records から OTLP ExportLogsServiceRequest を組む。成功でバイト数、失敗で -1。 */
long otlp_logs_build(uint8_t *buf, size_t cap,
                     const char *service_name, const char *service_version,
                     const char *scope_name,
                     const otlp_log_record_t *recs, size_t nrecs);

#ifdef __cplusplus
}
#endif

#endif /* SPNL_OTLP_LOGS_H */
