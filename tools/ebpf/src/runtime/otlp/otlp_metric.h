/*
 * otlp_metric.h — 汎用 keyed メトリクスの OTLP export (--instrument 非依存)
 *
 * 任意のプローブ (kprobe/uprobe で既存プロセスを観察する DSL 含む) が `hist_observe_by(key, val)`
 * で per-key の log2-latency hist を貯め、各 key に任意ラベル (function/pid/comm 等) を付けて
 * OTLP metrics (Sum=rate + ExponentialHistogram=latency) として送る。otlp_agent.c の自己計装
 * メソッドレジストリに依存しない。bpf map を読むため libbpf 依存 (eBPF プログラム専用)。
 */
#ifndef SPNL_OTLP_METRIC_H
#define SPNL_OTLP_METRIC_H

#include <stdint.h>

struct bpf_object;

#ifdef __cplusplus
extern "C" {
#endif

/* series (hist key) にラベルを 1 つ登録 (同一 key に複数呼べる)。成功 0 / 失敗 -1。 */
int spnl_otlp_series_label(uint64_t key, const char *label_key, const char *label_val);

/* 登録済 series を hist_map (bpf_hist_keyed) から読み、metric_name(Sum) +
 * "<metric_name>_latency_ns"(ExponentialHistogram) で endpoint に push。HTTP status / -1。 */
int spnl_otlp_metric_push_obj(struct bpf_object *obj, const char *hist_map,
                              const char *metric_name, const char *endpoint);

#ifdef __cplusplus
}
#endif

#endif /* SPNL_OTLP_METRIC_H */
