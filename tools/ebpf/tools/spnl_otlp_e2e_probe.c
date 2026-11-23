// SPDX-License-Identifier: GPL-2.0
//
// spnl_otlp_e2e_probe — E156 checkpoint 3 (P013 Task 9): **kernel record 取得と
// OTLP 送信・障害分離の一体 probe**。
//
//   .bpf.o を load -> BPF_PROG_TEST_RUN xN -> ring buffer から pair record 列を
//   取得 -> (任意) 有界 queue -> OTLP/JSON 3 文書 (共有 intake
//   spnl_pair_otlp_json.h) -> (任意) endpoint へ POST。
//
// 分離の設計: **送信の成否は exit code に影響しない。** kernel 側 (load /
// test_run / drain) が健全なら 0 で返り、送信の失敗・retry・拒否は
// self-metrics (otlp_http_stats) と SEND 行で観測する — exporter 障害が
// 計測を止めない、の probe 版。
//
// 使い方:
//   spnl_otlp_e2e_probe <obj.bpf.o> <prog> <ringbuf_map> <runs> <wall_offset_ns>
//                       <sum_name> <sum_unit> <hist_name> <hist_unit>
//                       [--dump FILE] [--endpoint URL] [--queue N] [--retries R]
//
// 出力 (1 行 1 事実):
//   RUNS=<n> RETVALS_UNIQ=<カンマ区切りの実測 verdict 集合>
//   COUNT=<drain した record 数> BADTYPE=<未知 ID で捨てた数>
//   QUEUED=<送る record 数> QDROP=<queue 満杯で捨てた数 (drop-newest)>
//   LOST=<kernel ringbuf の lost counter (percpu 合計)>
//   SEND <logs|sum|exphist> rc=<0|-1> status=<HTTP>   (--endpoint 時のみ)
//   spnl.otlp attempts=.. retries=.. failures=.. rejected=..
//
// queue の方針は **drop-newest** (満杯なら新しい record を数えて捨てる)。
// 黙って捨てない — QDROP に出る。
//
// Build: clang -O2 -I include -I src/runtime/otlp tools/spnl_otlp_e2e_probe.c
//        src/runtime/otlp/otlp_json.c src/runtime/otlp/otlp_http.c
//        -lbpf -lelf -lz

#include <bpf/bpf.h>
#include <bpf/libbpf.h>
#include <linux/types.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "spnl/types.h"
#include "otlp_http.h"
#include "spnl_pair_otlp_json.h"

#define MAX_RECS 65536

static struct pair_rec g_recs[MAX_RECS];
static size_t g_count;    /* drain した総数 (badtype 除く) */
static size_t g_badtype;  /* 未知 ID で捨てた数 */
static size_t g_queued;   /* 送る数 (queue 反映後) */
static size_t g_qdrop;    /* queue 満杯で捨てた数 */
static size_t g_queue_cap;

static int on_event(void *ctx, void *data, size_t size)
{
    (void)ctx;
    if (size != sizeof(struct pair_rec)) {
        /* length mismatch は record として数えない — 捨てた事実だけ数える */
        g_badtype++;
        return 0;
    }
    const struct pair_rec *r = data;
    if (!SPNL_EVT_TYPE_OK(r->hdr.type, SPNL_EVT_EMIT_PAIR)) {
        g_badtype++;
        return 0;
    }
    g_count++;
    if (g_queue_cap && g_queued >= g_queue_cap) {
        g_qdrop++;              /* drop-newest: 満杯なら新着を数えて捨てる */
        return 0;
    }
    if (g_queued < MAX_RECS)
        g_recs[g_queued++] = *r;
    return 0;
}

static int quiet_cb(enum libbpf_print_level level, const char *fmt, va_list ap)
{
    if (level == LIBBPF_DEBUG)
        return 0;
    return vfprintf(stderr, fmt, ap);
}

/* ringbuf map 名から lost counter (percpu_array) 名を導く。規則は
 * spbpf_schema.rb の lost_sym と同じ: "_pair_events" -> "_lost"。 */
static int lost_sum(struct bpf_object *obj, const char *ringname, long long *out)
{
    char lost[256];
    const char *suf = strstr(ringname, "_pair_events");
    if (!suf) return -1;
    snprintf(lost, sizeof lost, "%.*s_lost", (int)(suf - ringname), ringname);
    struct bpf_map *m = bpf_object__find_map_by_name(obj, lost);
    if (!m) return -1;
    int ncpu = libbpf_num_possible_cpus();
    if (ncpu <= 0) return -1;
    unsigned long long *vals = calloc((size_t)ncpu, sizeof(*vals));
    if (!vals) return -1;
    unsigned int key = 0;
    if (bpf_map_lookup_elem(bpf_map__fd(m), &key, vals) != 0) {
        free(vals);
        return -1;
    }
    long long sum = 0;
    for (int i = 0; i < ncpu; i++) sum += (long long)vals[i];
    free(vals);
    *out = sum;
    return 0;
}

static void post_doc(const char *host, const char *port, const char *path,
                     const char *what, const char *buf, long len, int retries)
{
    int status = 0;
    char err[256] = "";
    int rc = otlp_http_post(host, port, path, "application/json",
                            (const uint8_t *)buf, (size_t)len,
                            0, retries, &status, err, sizeof err);
    printf("SEND %s rc=%d status=%d%s%s\n", what, rc, status,
           rc != 0 ? " err=" : "", rc != 0 ? err : "");
}

int main(int argc, char **argv)
{
    if (argc < 10) {
        fprintf(stderr,
                "usage: %s <obj.bpf.o> <prog> <ringbuf_map> <runs> <wall_offset_ns>\n"
                "          <sum_name> <sum_unit> <hist_name> <hist_unit>\n"
                "          [--dump FILE] [--endpoint URL] [--queue N] [--retries R]\n",
                argv[0]);
        return 2;
    }
    const char *objpath = argv[1], *progname = argv[2], *ringname = argv[3];
    int runs = atoi(argv[4]);
    long long wall_off = strtoll(argv[5], NULL, 10);
    const char *sum_name = argv[6], *sum_unit = argv[7];
    const char *hist_name = argv[8], *hist_unit = argv[9];
    const char *dump = NULL, *endpoint = NULL;
    int retries = 2;
    for (int i = 10; i < argc; i++) {
        if (!strcmp(argv[i], "--dump") && i + 1 < argc) dump = argv[++i];
        else if (!strcmp(argv[i], "--endpoint") && i + 1 < argc) endpoint = argv[++i];
        else if (!strcmp(argv[i], "--queue") && i + 1 < argc) g_queue_cap = (size_t)atoll(argv[++i]);
        else if (!strcmp(argv[i], "--retries") && i + 1 < argc) retries = atoi(argv[++i]);
        else { fprintf(stderr, "unknown arg: %s\n", argv[i]); return 2; }
    }

    libbpf_set_print(quiet_cb);
    struct bpf_object *obj = bpf_object__open_file(objpath, NULL);
    if (!obj || bpf_object__load(obj)) {
        fprintf(stderr, "LOAD_FAIL %s\n", objpath);
        return 1;
    }
    struct bpf_program *prog = bpf_object__find_program_by_name(obj, progname);
    struct bpf_map *map = bpf_object__find_map_by_name(obj, ringname);
    if (!prog || !map) {
        fprintf(stderr, "MISSING prog=%p map=%p\n", (void *)prog, (void *)map);
        return 1;
    }
    struct ring_buffer *rb = ring_buffer__new(bpf_map__fd(map), on_event, NULL, NULL);
    if (!rb) {
        fprintf(stderr, "RINGBUF_FAIL\n");
        return 1;
    }

    /* kernel 実行。drain は最後に 1 回 — ring が先に満ちれば producer 側の
     * reserve が落ち、lost counter に出る (ringbuf drop 注入はこの性質を使う)。 */
    char data_in[64] = {0};
    char data_out[256];
    int uniq[8];
    int nuniq = 0;
    for (int i = 0; i < runs; i++) {
        LIBBPF_OPTS(bpf_test_run_opts, opts,
                    .data_in = data_in, .data_size_in = sizeof data_in,
                    .data_out = data_out, .data_size_out = sizeof data_out,
                    .repeat = 1);
        if (bpf_prog_test_run_opts(bpf_program__fd(prog), &opts)) {
            fprintf(stderr, "RUN_FAIL at %d\n", i);
            return 1;
        }
        int seen = 0;
        for (int j = 0; j < nuniq; j++) seen |= (uniq[j] == (int)opts.retval);
        if (!seen && nuniq < 8) uniq[nuniq++] = (int)opts.retval;
    }
    while (ring_buffer__poll(rb, 100 /* ms */) > 0)
        ;

    printf("RUNS=%d RETVALS_UNIQ=", runs);
    for (int j = 0; j < nuniq; j++) printf("%s%d", j ? "," : "", uniq[j]);
    printf("\n");
    printf("COUNT=%zu BADTYPE=%zu\nQUEUED=%zu QDROP=%zu\n",
           g_count, g_badtype, g_queued, g_qdrop);

    long long lost = -1;
    if (lost_sum(obj, ringname, &lost) != 0) {
        fprintf(stderr, "LOST_MAP_MISSING (%s)\n", ringname);
        return 1;
    }
    printf("LOST=%lld\n", lost);

    if (dump) {
        FILE *df = fopen(dump, "wb");
        if (!df || fwrite(g_recs, sizeof(struct pair_rec), g_queued, df) != g_queued) {
            fprintf(stderr, "DUMP_FAIL %s\n", dump);
            return 1;
        }
        fclose(df);
    }

    if (endpoint && g_queued > 0) {
        static char lbuf[1 << 22], sbuf[65536], hbuf[65536];
        long ln, sn, hn;
        char msg[256];
        if (pair_build_otlp_json(g_recs, g_queued, wall_off,
                                 sum_name, sum_unit, hist_name, hist_unit,
                                 lbuf, sizeof lbuf, &ln, sbuf, sizeof sbuf, &sn,
                                 hbuf, sizeof hbuf, &hn, msg, sizeof msg) != 0) {
            fprintf(stderr, "BUILD_FAIL: %s\n", msg);
            return 1;
        }
        char host[256], port[16];
        if (otlp_http_parse_endpoint(endpoint, host, sizeof host, port, sizeof port) != 0) {
            fprintf(stderr, "BAD_ENDPOINT %s\n", endpoint);
            return 1;
        }
        /* per-signal path (OTLP/HTTP の既定)。1 リクエスト 1 metric (E431)。 */
        post_doc(host, port, "/v1/logs", "logs", lbuf, ln, retries);
        post_doc(host, port, "/v1/metrics", "sum", sbuf, sn, retries);
        post_doc(host, port, "/v1/metrics", "exphist", hbuf, hn, retries);
    }
    otlp_http_stats_report(stdout);

    ring_buffer__free(rb);
    bpf_object__close(obj);
    return 0;
}
