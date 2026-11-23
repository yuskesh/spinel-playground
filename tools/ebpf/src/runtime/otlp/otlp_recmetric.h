/*
 * otlp_recmetric.h — record channel から OTLP metrics へ (E400)
 *
 * ringbuf の record は 1 件 = 1 span (CcEgressSpan) という読み方をずっとしてきた。
 * span は「1 回何が起きたか」の形であって「どれくらいの頻度で、どれくらい時間が
 * かかったか」の形ではない。後者は metric で、その宣言が
 * src/codegen_c/record_schema.h の CcRecMetric。
 *
 * ここはその宣言の**実行時側**:
 *   - spnl_recmetric_observe()  … drain した record 1 件を集計に入れる
 *                                 (生成された spnl_recmetric_observe_<ch>() が呼ぶ)
 *   - spnl_otlp_record_metrics_push() … 集計を OTLP metrics として送る (Ruby から FFI)
 *
 * **series 数は宣言で証明済み**。生成器が全 metric の series bound を掛けて足し、
 * SPNL_RECMETRIC_MAX_SERIES を超える宣言は**コンパイルさせない**ので、下の配列は
 * 溢れない。otlp_httpspan.c の手書き集計 (cap 64、65 本目を警告して捨てる) と違い、
 * 「入りきらない series をどうするか」を実行時に決める必要がそもそも無い。
 */
#ifndef SPNL_OTLP_RECMETRIC_H
#define SPNL_OTLP_RECMETRIC_H

#ifdef __cplusplus
extern "C" {
#endif

/* 生成された intake が呼ぶ。`metric` は生成テーブル spnl_recmetrics[] の index
 * (SPNL_RECMETRIC_<CH>_<ID> マクロ)。label_values は宣言順の**生の**レンダリング —
 * 宣言された集合への射影 (集合外 -> fallback) はここで 1 箇所だけ行う。 */
void spnl_recmetric_observe(int metric, const char *const *label_values,
                            int nlabels, int has_value, double value);

/* 集計を OTLP/HTTP (または gRPC / JSON) で送る。metric ごとに 1 POST。
 * 戻りは最後の POST の HTTP status、1 件も無ければ 0、失敗で -1。 */
int spnl_otlp_record_metrics_push(const char *endpoint);

/* いま何本の time series を持っているか (テスト・診断用)。 */
int spnl_recmetric_series_count(void);

#ifdef __cplusplus
}
#endif

#endif /* SPNL_OTLP_RECMETRIC_H */
