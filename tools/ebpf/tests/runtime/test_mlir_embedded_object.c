// SPDX-License-Identifier: GPL-2.0
//
// test_mlir_embedded_object — E155: **埋め込まれた** eBPF object の実行検査。
//
// `bin/spinel-ebpf compile --build` は bpftool gen skeleton の C 配列として
// .bpf.o をバイナリへ埋め込み、実行時は memory から load する (隣接ファイルは
// 見ない)。この TU は生成された 24_xdp_counter.skel.h を include して同じ
// 経路 (__open_and_load) を通し、次を測る:
//
//   1. 隣接 .bpf.o が無い状態で load できる (呼び手の script が先に消す)
//   2. XDP program を BPF_PROG_TEST_RUN で N 回流し、retval と counter を読む
//
// 出力 (1 行、current 版と MLIR 版の 2 バイナリで文字列比較される):
//   EMBED_LOAD=ok RETVALS=2,2,2 COUNT=3
//
// exit 0 = 測れた / 1 = load か run が失敗。**測れなかったことを成功扱いに
// しない** — 出力行はエラー時に出さない。
//
// Build (どちらの skel.h を埋め込むかは -I で選ぶ):
//   cc -O2 -I <dir-with-skel.h> tests/runtime/test_mlir_embedded_object.c
//      -lbpf -lelf -lz -o probe

#include <bpf/bpf.h>
#include <bpf/libbpf.h>
#include <stdio.h>
#include <string.h>

#include "24_xdp_counter.skel.h"

#define RUNS 3

static int quiet_cb(enum libbpf_print_level level, const char *fmt, va_list ap)
{
    if (level == LIBBPF_DEBUG)
        return 0;
    return vfprintf(stderr, fmt, ap);
}

int main(void)
{
    libbpf_set_print(quiet_cb);

    /* 埋め込み経路そのもの: skeleton の C 配列から open + load。 */
    struct u_24_xdp_counter *skel = u_24_xdp_counter__open_and_load();
    if (!skel) {
        fprintf(stderr, "EMBED_LOAD_FAIL\n");
        return 1;
    }

    struct bpf_map *map =
        bpf_object__find_map_by_name(skel->obj, "u_24_xdp_counter_top_rx_pkts");
    if (!map) {
        fprintf(stderr, "MAP_MISSING u_24_xdp_counter_top_rx_pkts\n");
        u_24_xdp_counter__destroy(skel);
        return 1;
    }

    __u32 key = 0;
    long long before = 0;
    if (bpf_map__lookup_elem(map, &key, sizeof key, &before, sizeof before, 0) == 0) {
        /* 新しく load した object の counter が既に居るのはおかしい。 */
        fprintf(stderr, "COUNTER_PREPOPULATED %lld\n", before);
        u_24_xdp_counter__destroy(skel);
        return 1;
    }

    char data_in[64] = {0};   /* XDP の test_run は >= ETH_HLEN の frame を要る */
    char data_out[256];
    int retvals[RUNS];
    for (int i = 0; i < RUNS; i++) {
        LIBBPF_OPTS(bpf_test_run_opts, opts,
                    .data_in = data_in, .data_size_in = sizeof data_in,
                    .data_out = data_out, .data_size_out = sizeof data_out,
                    .repeat = 1);
        if (bpf_prog_test_run_opts(bpf_program__fd(skel->progs.xdp__main), &opts)) {
            fprintf(stderr, "RUN_FAIL at %d\n", i);
            u_24_xdp_counter__destroy(skel);
            return 1;
        }
        retvals[i] = opts.retval;
    }

    long long count = -1;
    if (bpf_map__lookup_elem(map, &key, sizeof key, &count, sizeof count, 0) != 0) {
        fprintf(stderr, "COUNTER_UNREADABLE\n");
        u_24_xdp_counter__destroy(skel);
        return 1;
    }

    printf("EMBED_LOAD=ok RETVALS=");
    for (int i = 0; i < RUNS; i++)
        printf("%s%d", i ? "," : "", retvals[i]);
    printf(" COUNT=%lld\n", count);

    u_24_xdp_counter__destroy(skel);
    return 0;
}
