// SPDX-License-Identifier: GPL-2.0
//
// spnl_pair_otlp_json.h — pair record 列 -> OTLP/JSON 3 文書 (logs / Sum /
// ExponentialHistogram) の共有 intake (E156)。
//
// spnl_otlp_model_probe.c (host の意味差動、checkpoint 2) と
// spnl_otlp_e2e_probe.c (kernel E2E + OTLP 送信、checkpoint 3) が **同じ写像**
// を使うための static 実装。片方だけ直すと 2 つの probe が別の意味を主張する
// ので、intake はここ 1 箇所に置く。
//
// temporality / monotonic / scale / offset の意味は otlp_json builder 側が
// 持つ — ここは intake (値と時刻) だけを供給する。
//
// 拒否 (黙って落とさない):
//   - 観測値 b < 1 (zero_count / 負 bucket / bucket index -1 は現行 builder の
//     series が表現できない — 表現できないものを 0 に丸めない)
// hdr.type の検査 (SPNL_EVT_TYPE_OK) は呼び手の責務 — model probe は拒否し、
// e2e probe は数えて捨てる (どちらも黙らない)。

#ifndef SPNL_PAIR_OTLP_JSON_H
#define SPNL_PAIR_OTLP_JSON_H

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "otlp_json.h"
#include "otlp_logs.h"
#include "otlp_metrics.h"

struct pair_rec {
    struct spnl_event_hdr hdr;
    long long a;
    long long b;
};
_Static_assert(sizeof(struct pair_rec) == 32, "pair record layout is 32 bytes");

// otlp_lower_exclusive (schema の bucket_rule): 2^i < v <= 2^(i+1) の i。
// v >= 2 のみ (v == 1 は i = -1 で slot 配列に置けないため呼び手が先に拒否する)。
static int pair_bucket_index(unsigned long long v) {
    return 63 - __builtin_clzll(v - 1ULL);
}

/* recs[0..n) から 3 文書を組む。成功 0 / 表現できない入力 -1 (msg に理由)。 */
static int pair_build_otlp_json(const struct pair_rec *recs, size_t n,
                                long long wall_off,
                                const char *sum_name, const char *sum_unit,
                                const char *hist_name, const char *hist_unit,
                                char *lbuf, size_t lcap, long *llen,
                                char *sbuf, size_t scap, long *slen,
                                char *hbuf, size_t hcap, long *hlen,
                                char *msg, size_t msglen) {
    otlp_log_record_t *logs = calloc(n ? n : 1, sizeof(*logs));
    if (!logs) {
        snprintf(msg, msglen, "out of memory");
        return -1;
    }
    otlp_series_t sum_series = {0};
    otlp_series_t hist_series = {0};
    unsigned long long asum = 0;
    double bsum = 0.0;
    long long tmin = 0, tmax = 0;

    for (size_t i = 0; i < n; i++) {
        const struct pair_rec *r = &recs[i];
        long long wall = (long long)r->hdr.timestamp + wall_off;
        if (i == 0 || wall < tmin) tmin = wall;
        if (i == 0 || wall > tmax) tmax = wall;

        logs[i].time_unix_ns = (uint64_t)wall;
        logs[i].body_int = r->a;
        asum += (unsigned long long)r->a;

        if (r->b < 1) {
            snprintf(msg, msglen,
                     "record %zu has b=%lld — the current series intake cannot "
                     "express zero_count / negative buckets", i, r->b);
            free(logs);
            return -1;
        }
        if (r->b == 1) {
            snprintf(msg, msglen,
                     "record %zu has b=1 — bucket index -1 does not fit the "
                     "slot array of the current intake", i);
            free(logs);
            return -1;
        }
        hist_series.buckets[pair_bucket_index((unsigned long long)r->b)]++;
        bsum += (double)r->b;
    }

    sum_series.count = asum;  /* Sum data point の値 (enc_series_calls) */
    hist_series.count = n;    /* rate。0 だと series ごと出力されない */
    hist_series.has_sum = 1;  /* 生値を観測したので正確な合計 (E156) */
    hist_series.sum = bsum;

    *llen = otlp_json_logs_build(lbuf, lcap,
                                 "spnl-probe", "", "spinel-ebpf", logs, n);
    *slen = otlp_json_metrics_sum_build(sbuf, scap,
                                        "spnl-probe", "", "spinel-ebpf",
                                        sum_name, sum_unit,
                                        (uint64_t)tmax, (uint64_t)tmin,
                                        &sum_series, 1);
    *hlen = otlp_json_metrics_exphist_build(hbuf, hcap,
                                            "spnl-probe", "", "spinel-ebpf",
                                            hist_name, hist_unit,
                                            (uint64_t)tmax, (uint64_t)tmin,
                                            &hist_series, 1);
    free(logs);
    if (*llen < 0 || *slen < 0 || *hlen < 0) {
        snprintf(msg, msglen, "builder failed (logs=%ld sum=%ld hist=%ld)",
                 *llen, *slen, *hlen);
        return -1;
    }
    return 0;
}

#endif /* SPNL_PAIR_OTLP_JSON_H */
