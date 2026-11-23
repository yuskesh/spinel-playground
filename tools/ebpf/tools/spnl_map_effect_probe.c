// SPDX-License-Identifier: GPL-2.0
//
// spnl_map_effect_probe — .bpf.o を kernel で 1 回実行し、map への効果を測る
// (E154 checkpoint 3 の実行時差動)。
//
// 静的な object 差動 (bpf_object.rb) は helper 呼び出し列と map 参照までしか
// 主張しない。「実行すると counter が本当に増えるか」は kernel に聞くのが正で、
// current backend の object と MLIR backend の object をこの probe に別々に
// かけて出力行を突き合わせる (tests/runtime/run_mlir_object_effect.sh)。
//
// 使い方: spnl_map_effect_probe <program.bpf.o> <prog_name> <map_symbol>
//
//   1. bpf_object__open_file + load (spnl_load_check と同じ、ADR-011 の載せ方)
//   2. key=0 の値を読む (未作成なら "absent")
//   3. BPF_PROG_TEST_RUN で 64 byte のゼロ詰め packet を 1 回流す
//   4. key=0 の値をもう一度読む
//
// 出力 (1 行、比較器はこれを文字列比較する):
//   RETVAL=<n> BEFORE=<v|absent> AFTER=<v|absent>
//
// exit 0 = 測れた / 1 = load か run が失敗 / 2 = usage。
// **測れなかったことを成功扱いにしない** — 出力行はエラー時に出さない。
//
// Build: cc -O2 tools/spnl_map_effect_probe.c -lbpf -lelf -lz

#include <bpf/bpf.h>
#include <bpf/libbpf.h>
#include <stdio.h>
#include <string.h>

static int quiet_cb(enum libbpf_print_level level, const char *fmt, va_list ap)
{
    if (level == LIBBPF_DEBUG)
        return 0;
    return vfprintf(stderr, fmt, ap);
}

int main(int argc, char **argv)
{
    if (argc != 4) {
        fprintf(stderr, "usage: %s <program.bpf.o> <prog_name> <map_symbol>\n", argv[0]);
        return 2;
    }
    libbpf_set_print(quiet_cb);

    struct bpf_object *obj = bpf_object__open_file(argv[1], NULL);
    if (!obj) {
        fprintf(stderr, "OPEN_FAIL %s\n", argv[1]);
        return 1;
    }
    if (bpf_object__load(obj)) {
        fprintf(stderr, "LOAD_FAIL %s\n", argv[1]);
        bpf_object__close(obj);
        return 1;
    }

    struct bpf_program *prog = bpf_object__find_program_by_name(obj, argv[2]);
    struct bpf_map *map = bpf_object__find_map_by_name(obj, argv[3]);
    if (!prog || !map) {
        fprintf(stderr, "MISSING %s: prog=%p map=%p\n", argv[2], (void *)prog, (void *)map);
        bpf_object__close(obj);
        return 1;
    }

    __u32 key = 0;
    long long before = 0, after = 0;
    int have_before = bpf_map__lookup_elem(map, &key, sizeof key,
                                           &before, sizeof before, 0) == 0;

    char data_in[64] = {0};   /* XDP の test_run は >= ETH_HLEN の frame を要る */
    char data_out[256];
    LIBBPF_OPTS(bpf_test_run_opts, opts,
                .data_in = data_in, .data_size_in = sizeof data_in,
                .data_out = data_out, .data_size_out = sizeof data_out,
                .repeat = 1);
    if (bpf_prog_test_run_opts(bpf_program__fd(prog), &opts)) {
        fprintf(stderr, "RUN_FAIL %s\n", argv[2]);
        bpf_object__close(obj);
        return 1;
    }

    int have_after = bpf_map__lookup_elem(map, &key, sizeof key,
                                          &after, sizeof after, 0) == 0;

    printf("RETVAL=%d BEFORE=", opts.retval);
    if (have_before) printf("%lld", before); else printf("absent");
    printf(" AFTER=");
    if (have_after) printf("%lld", after); else printf("absent");
    printf("\n");

    bpf_object__close(obj);
    return 0;
}
