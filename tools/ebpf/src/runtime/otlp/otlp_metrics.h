/*
 * otlp_metrics.h — `--instrument` の per-method RED を OTLP metrics に変換 (ADR-012 / P003 S2)
 *
 * 1 メソッド = {method, file, line, calls, buckets[64]} を受け、ExportMetricsServiceRequest を組む:
 *   - spnl_method_calls_total : Sum (monotonic, CUMULATIVE)、N data points
 *   - spnl_method_latency_ns  : ExponentialHistogram (scale=0)、N data points
 * 各 data point 属性は symbol-map 由来の code.function / code.filepath / code.lineno。
 *
 * buckets[s] は spnl_hist_log2 = floor(log2(ns)) のヒストグラム (codegen の bpf_hist_keyed)。
 * OTLP ExponentialHistogram(scale=0、bucket index i = (2^i, 2^(i+1)])へは slot s -> 正 bucket s で
 * 対応させる(境界の閉/開差は ns レイテンシでは無視可)。sum は Σ count_s * 1.5*2^s の userspace 近似
 * (kernel は sum を保持しないため。ADR-012 の「kernel 不変」を維持)。
 */
#ifndef SPNL_OTLP_METRICS_H
#define SPNL_OTLP_METRICS_H

#include <stddef.h>
#include <stdint.h>
#include "otlp_http.h"  /* otlp_kv_t (汎用ラベル) */

/* E431: 明示バケット Histogram の境界は DECLARED (record_schema.h の bounds set
 * `log2_ns_31`)。ここで読むのは **マクロだけ** — 生成 mirror の残りは kernel 型を
 * 要し、このヘッダは libbpf 非依存の TU (otlp_json.c 等) にも届くため。
 *
 * MACROS_ONLY を **自分で立てたときだけ倒す**: 生成ヘッダは境界ブロックに独自の
 * include guard を持ち、残りは「include 時に MACROS_ONLY が立っていないこと」で
 * 守られている。立てっぱなしにすると、後から本体を include する TU
 * (otlp_agent.c の SPNL_REC_CONSUME_IMPL) が accessor 定義を丸ごと落とす。 */
#ifdef SPNL_RECORD_MIRROR_MACROS_ONLY
#  include "record_mirror_gen.h"
#else
#  define SPNL_RECORD_MIRROR_MACROS_ONLY 1
#  include "record_mirror_gen.h"
#  undef SPNL_RECORD_MIRROR_MACROS_ONLY
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define OTLP_HIST_SLOTS 64

typedef struct {
    const char *method;   /* ruby 名 -> code.function */
    const char *file;     /* -> code.filepath ("" 可) */
    int32_t     line;     /* -> code.lineno (<=0 は省略) */
    uint64_t    calls;    /* counter (calls==0 のメソッドは出力しない) */
    uint64_t    buckets[OTLP_HIST_SLOTS]; /* log2 latency hist (floor(log2(ns))) */
} otlp_method_metric_t;

/* 汎用シリーズ (任意キー + 任意ラベル)。--instrument 非依存の外部プローブ計測用。
 *
 * sum (E156): kernel の log2 slot しか無い intake は正確な合計を持てないので、
 * ExponentialHistogram の sum は slot 中点で近似してきた。record 由来の intake は
 * userspace で生値を観測できる — has_sum=1 で正確な合計を渡すと encoder (pb/JSON
 * 両方) がそれを使う。has_sum=0 (既存呼び手のゼロ初期化) は従来どおり中点近似 —
 * 近似は「生値を持たない intake の宣言済み限界」であって既定値ではない。 */
typedef struct {
    uint64_t         count;                    /* rate (count==0 は出力しない) */
    uint64_t         buckets[OTLP_HIST_SLOTS]; /* log2 latency hist */
    const otlp_kv_t *labels;                   /* 任意ラベル (function/pid/comm 等) */
    int              nlabels;
    int              has_sum;                  /* 1 = sum が正確な合計 */
    double           sum;                      /* has_sum=1 のときの Σ観測値 */
} otlp_series_t;

/* ---- 1 リクエスト = 1 metric (E431) ----------------------------------------
 *
 * かつて汎用 keyed メトリクスは `otlp_metrics_series_build` が Sum と
 * ExponentialHistogram を **1 リクエストに同梱**していた。OTLP の 1 リクエストは
 * 全体で 1 ステータスなので、**片方が拒否されるともう片方も道連れになる** — E291 で
 * counter が 1 つも着弾しなかった理由がこれで、Splunk は Sum を 200 で受けるのに
 * ExponentialHistogram に 500 を返す (E429 実測)。同梱する builder は撤去した。
 * 呼び手は metric ごとに build して metric ごとに送る (E400 の record metric が
 * 最初からそうしていた形。`otlp_recmetric.c` の push_one を参照)。 */

/* 明示バケット Histogram に使う log2 ruler。写しは持たず、上で読んだ宣言そのもの。 */
#define OTLP_LOG2_NBOUNDS  SPNL_BOUNDS_LOG2_NS_31_N
#define OTLP_LOG2_NBUCKETS (OTLP_LOG2_NBOUNDS + 1)

static inline const double *otlp_log2_ns_bounds(void) {
    static const double b[OTLP_LOG2_NBOUNDS] = SPNL_BOUNDS_LOG2_NS_31_INIT;
    return b;
}

/* 64 slot の log2 hist を上の ruler の bucket_counts に畳む。
 *
 * log2 slot s は整数 ns の [2^s, 2^(s+1)-1] を数え (slot 0 は v<=1)、OTLP の明示
 * バケット j は (bounds[j-1], bounds[j]] を数える。境界が全部 2^m - 1 なので
 * **slot は必ずどれか 1 つの bucket に丸ごと入る** = 件数は 1 つも割れない
 * (E431 D1: 3 分布 60 万標本で slot 別カウントと bucket 別カウントの不一致 0)。
 * sum は kernel が持たないので slot 代表値の近似 — ExponentialHistogram 経路と
 * 同じ規約なので、**表現を替えても sum は動かない**。
 *
 * header に置いてあるのは、protobuf 側 (nanopb 有) と JSON 側 (nanopb 無) の
 * 両方から呼ばれるから。畳み方が 2 つになると 2 つの経路が別の histogram を出す。 */
static inline void otlp_log2_fold(const uint64_t slots[OTLP_HIST_SLOTS],
                                  uint64_t out_buckets[OTLP_LOG2_NBUCKETS],
                                  uint64_t *count_out, double *sum_out) {
    const double *bounds = otlp_log2_ns_bounds();
    uint64_t total = 0;
    double sum = 0.0;
    for (int j = 0; j < OTLP_LOG2_NBUCKETS; j++) out_buckets[j] = 0;
    for (int s = 0; s < OTLP_HIST_SLOTS; s++) {
        uint64_t c = slots[s];
        if (c == 0) continue;
        /* 2^64-1 は uint64 に収まらないので上端を double で作る (s=63 でも安全)。 */
        double edge = (double)((uint64_t)1 << s) * 2.0 - 1.0;
        int j = OTLP_LOG2_NBOUNDS;                     /* 既定 = overflow バケット */
        for (int k = 0; k < OTLP_LOG2_NBOUNDS; k++)
            if (bounds[k] >= edge) { j = k; break; }
        out_buckets[j] += c;
        total += c;
        sum += (double)c * (s <= 0 ? 1.0 : 1.5 * (double)((uint64_t)1 << s));
    }
    if (count_out) *count_out = total;
    if (sum_out)   *sum_out   = sum;
}

/* latency をどちらの histogram 型で出すか。OTel 仕様の
 * OTEL_EXPORTER_OTLP_METRICS_DEFAULT_HISTOGRAM_AGGREGATION を読む
 * (`explicit_bucket_histogram` = 仕様の既定 / `base2_exponential_bucket_histogram`)。
 * **送り先を見て切り替えるのではない** — 操作者が宣言する。未知の綴りは loud に落とす。 */
typedef enum {
    OTLP_HIST_AGG_EXPLICIT    = 0,  /* explicit_bucket_histogram (既定) */
    OTLP_HIST_AGG_EXPONENTIAL = 1,  /* base2_exponential_bucket_histogram */
} otlp_hist_agg_t;
otlp_hist_agg_t otlp_hist_aggregation(void);

/* monotonic Sum のみ (E400)。値を持たない record channel の counter 用 —
 * series_build と違い ExponentialHistogram を伴わない。series の buckets は読まない。
 * 成功でバイト数、失敗で -1。 */
long otlp_metrics_sum_build(uint8_t *buf, size_t cap,
                            const char *service_name, const char *service_version,
                            const char *scope_name,
                            const char *name, const char *unit,
                            uint64_t time_unix_nano, uint64_t start_time_unix_nano,
                            const otlp_series_t *series, size_t nseries);

/* Gauge のみ (E429)。値は series の count をそのまま非単調な瞬時値として出す。
 * 型ごとの受理を切り分けるために「1 payload = 1 metric 型」を作れる必要があった。
 * 成功でバイト数、失敗で -1。 */
long otlp_metrics_gauge_build(uint8_t *buf, size_t cap,
                              const char *service_name, const char *service_version,
                              const char *scope_name,
                              const char *name, const char *unit,
                              uint64_t time_unix_nano, uint64_t start_time_unix_nano,
                              const otlp_series_t *series, size_t nseries);

/* ExponentialHistogram のみ (E429)。series_build の latency 側だけを単独で出す。
 * 成功でバイト数、失敗で -1。 */
long otlp_metrics_exphist_build(uint8_t *buf, size_t cap,
                                const char *service_name, const char *service_version,
                                const char *scope_name,
                                const char *name, const char *unit,
                                uint64_t time_unix_nano, uint64_t start_time_unix_nano,
                                const otlp_series_t *series, size_t nseries);

/* 明示バケット Histogram の 1 series (semconv http.server.request.duration 等、E272)。
 * bounds は全 series 共通なので build 関数側が持ち、series は bucket_counts (長さ nbounds+1) +
 * sum + count + 任意ラベルだけを持つ。 */
typedef struct {
    const otlp_kv_t *labels;
    int              nlabels;
    uint64_t         count;
    double           sum;
    const uint64_t  *bucket_counts; /* 長さ = nbounds + 1 */
} otlp_hseries_t;

/* explicit-bounds Histogram (name/unit、CUMULATIVE) を組む。bounds は昇順・全 series 共通。
 * 成功でバイト数、失敗で -1。 */
long otlp_metrics_hist_build(uint8_t *buf, size_t cap,
                             const char *service_name, const char *service_version,
                             const char *scope_name,
                             const char *name, const char *unit,
                             const double *bounds, int nbounds,
                             uint64_t time_unix_nano, uint64_t start_time_unix_nano,
                             const otlp_hseries_t *series, size_t nseries);

/* `--instrument` の per-method RED を **1 リクエスト 1 metric** で encode (E431)。
 * かつての otlp_metrics_build は calls(Sum) と latency(ExponentialHistogram) を
 * 同梱していたので、Splunk が latency に返す 500 が rate を道連れにしていた。
 * どの part を出すかは呼び手が決める (latency の型は otlp_hist_aggregation() が既定を
 * 返すが、test が両方を作れるようにここでは選ばせる)。成功でバイト数、失敗で -1。 */
typedef enum {
    OTLP_MPART_CALLS        = 0,  /* spnl_method_calls_total (Sum) */
    OTLP_MPART_LATENCY_EXP  = 1,  /* spnl_method_latency_ns (ExponentialHistogram) */
    OTLP_MPART_LATENCY_HIST = 2,  /* spnl_method_latency_ns (explicit-bucket Histogram) */
} otlp_method_part_t;

long otlp_metrics_method_build(uint8_t *buf, size_t cap,
                               const char *service_name, const char *service_version,
                               const char *scope_name, otlp_method_part_t part,
                               uint64_t time_unix_nano, uint64_t start_time_unix_nano,
                               const otlp_method_metric_t *methods, size_t nmethods);

/* build + OTLP/HTTP POST。endpoint は "http://host:port"。HTTP 200 で 0。 */
int otlp_metrics_export(const char *endpoint,
                        const char *service_name, const char *service_version,
                        const char *scope_name,
                        uint64_t time_unix_nano, uint64_t start_time_unix_nano,
                        const otlp_method_metric_t *methods, size_t nmethods,
                        int *http_status, char *err, size_t errlen);

#ifdef __cplusplus
}
#endif

#endif /* SPNL_OTLP_METRICS_H */
