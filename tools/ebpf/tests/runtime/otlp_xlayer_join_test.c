/*
 * otlp_xlayer_join_test.c — E274: L2–L8 横断相関の「4-tuple join」を map レベルで実証する。
 *
 * 本 Apple-container VM では BPF program の *attach* (perf_event_open) が hypervisor 下でハングする
 * ため、live な tracepoint 発火での E2E は取れない (kprobe/tracepoint とも、E271 probe_metrics も同様)。
 * そこで attach を使わずに join を実証する:
 *
 *   1. 生成 skeleton を open_and_load (=bpf map/prog を kernel に load。attach しない → ハングしない)。
 *   2. loopback で 1 本 TCP を張り accept 済み server fd を得る。
 *   3. その fd の 4-tuple から、DSL(.bpf.c) の tracepoint と **byte 一致の算術**でキーを作り、
 *      本物の bpf_hist_keyed map に established/state_changes を書く (tracepoint の書込を模す)。
 *   4. **本番の lookup FFI** spnl_otlp_xlayer_l34_count_obj(obj, "bpf_hist_keyed", fd, metric_id) が、
 *      fd だけからキーを再導出して当該値を引けることを確認 → userspace 結合 (join) の成立。
 *   5. **本番の span FFI** spnl_otlp_http_span_fd_x で 1 span = L3/L4+L7+L8 を組んで endpoint に送る。
 *
 * 使い方: otlp_xlayer_join_test <skeleton-obj-loaded-internally> <endpoint> [traceparent] [tenant]
 * ここで DSL の書込式と本テストの書込式が同一であることは、生成 .bpf.c を Edoc に併記して示す。
 */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#include <bpf/libbpf.h>
#include <bpf/bpf.h>

#include "xlayer_correlate.skel.h"   /* 生成 skeleton (build dir を -I で渡す) */
#include "otlp_httpspan.h"

/* 本番 lookup FFI (otlp_xlayer.c)。 */
extern long spnl_otlp_xlayer_l34_count_obj(struct bpf_object *obj, const char *map_name,
                                           int fd, unsigned long long metric_id);
extern int  spnl_otlp_xlayer_key_from_fd(int fd, unsigned long long metric_id,
                                          unsigned long long *key_out);

/* 127.0.0.1 に自己接続して server 側 accept fd を返す (client fd は *client_out)。失敗で -1。 */
static int self_connect(int *client_out) {
    int ln = socket(AF_INET, SOCK_STREAM, 0);
    if (ln < 0) return -1;
    struct sockaddr_in a;
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    a.sin_port = 0;
    if (bind(ln, (struct sockaddr *)&a, sizeof a) != 0) { close(ln); return -1; }
    if (listen(ln, 1) != 0) { close(ln); return -1; }
    socklen_t sl = sizeof a;
    if (getsockname(ln, (struct sockaddr *)&a, &sl) != 0) { close(ln); return -1; }
    int cl = socket(AF_INET, SOCK_STREAM, 0);
    if (cl < 0) { close(ln); return -1; }
    if (connect(cl, (struct sockaddr *)&a, sizeof a) != 0) { close(ln); close(cl); return -1; }
    int sv = accept(ln, NULL, NULL);
    close(ln);
    if (sv < 0) { close(cl); return -1; }
    *client_out = cl;
    return sv;
}

/* bpf_hist_keyed の value = struct { __u64 buckets[64]; } (512B)。slot 0 に count を置く。 */
struct hist_val { uint64_t buckets[64]; };

int main(int argc, char **argv) {
    const char *ep = (argc > 1) ? argv[1] : "http://127.0.0.1:4318";
    const char *tp = (argc > 2) ? argv[2]
        : "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01";
    const char *tenant = (argc > 3) ? argv[3] : "acme";

    int cl = -1;
    int sv = self_connect(&cl);
    if (sv < 0) { fprintf(stderr, "[join] self_connect failed\n"); return 2; }

    /* (1) skeleton を open_and_load。attach しない (この VM では attach がハングするため)。 */
    struct xlayer_correlate *skel = xlayer_correlate__open_and_load();
    if (!skel) { fprintf(stderr, "[join] open_and_load failed\n"); close(sv); close(cl); return 2; }

    struct bpf_map *m = bpf_object__find_map_by_name(skel->obj, "bpf_hist_keyed");
    if (!m) { fprintf(stderr, "[join] bpf_hist_keyed not found\n"); return 2; }
    int mapfd = bpf_map__fd(m);

    /* (3) fd の 4-tuple → キー (DSL/C と同一算術) を lookup と同一の導出で取得し、そこに書く。
     *     established(mid=2)=1, state_changes(mid=1)=3 を tracepoint の書込として模す。 */
    unsigned long long k_est = 0, k_chg = 0;
    if (!spnl_otlp_xlayer_key_from_fd(sv, 2, &k_est) ||
        !spnl_otlp_xlayer_key_from_fd(sv, 1, &k_chg)) {
        fprintf(stderr, "[join] key_from_fd failed (non-inet?)\n"); return 2;
    }
    struct hist_val v_est, v_chg;
    memset(&v_est, 0, sizeof v_est); v_est.buckets[0] = 1;  /* established = 1 */
    memset(&v_chg, 0, sizeof v_chg); v_chg.buckets[0] = 3;  /* state_changes = 3 */
    if (bpf_map_update_elem(mapfd, &k_est, &v_est, BPF_ANY) != 0 ||
        bpf_map_update_elem(mapfd, &k_chg, &v_chg, BPF_ANY) != 0) {
        fprintf(stderr, "[join] map_update failed\n"); return 2;
    }

    /* (4) 本番 lookup FFI が fd だけからキーを再導出して当てられることを確認 = join 成立。 */
    long est = spnl_otlp_xlayer_l34_count_obj(skel->obj, "bpf_hist_keyed", sv, 2);
    long chg = spnl_otlp_xlayer_l34_count_obj(skel->obj, "bpf_hist_keyed", sv, 1);
    /* miss を区別する証拠として、故意にズラした fd (client 側 cl) は別 4-tuple の向き = miss。 */
    long est_wrong = spnl_otlp_xlayer_l34_count_obj(skel->obj, "bpf_hist_keyed", cl, 2);

    struct sockaddr_in la, pa; socklen_t ll = sizeof la, pl = sizeof pa;
    getsockname(sv, (struct sockaddr *)&la, &ll);
    getpeername(sv, (struct sockaddr *)&pa, &pl);
    char sbuf[32], cbuf[32];
    inet_ntop(AF_INET, &la.sin_addr, sbuf, sizeof sbuf);
    inet_ntop(AF_INET, &pa.sin_addr, cbuf, sizeof cbuf);
    fprintf(stderr, "[join] server=%s:%d client=%s:%d  key_est=%llu key_chg=%llu\n",
            sbuf, ntohs(la.sin_port), cbuf, ntohs(pa.sin_port), k_est, k_chg);
    fprintf(stderr, "[join] lookup(sv): established=%ld state_changes=%ld  | lookup(cl,est)=%ld (miss expected)\n",
            est, chg, est_wrong);

    /* (5) 1 span = L3/L4 (client.address/server.port + established/state_changes) + L7 + L8(tenant) */
    uint64_t t0 = spnl_otlp_now_unix_ns();
    uint64_t t1 = t0 + 1234567;  /* ~1.2ms latency */
    int st = spnl_otlp_http_span_fd_x(sv, tp, "GET", "/hello", "/hello", 200,
                                      t0, t1, tenant, est, chg, ep);
    fprintf(stderr, "[join] span (all layers) -> otlp %d\n", st);

    xlayer_correlate__destroy(skel);
    close(sv); close(cl);
    /* 成功条件: join が当たり (est==1, chg==3)、別向き fd は miss(-1)、span 送信 200。 */
    return (est == 1 && chg == 3 && est_wrong == -1 && st == 200) ? 0 : 1;
}
