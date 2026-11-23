// SPDX-License-Identifier: GPL-2.0
//
// spnl_event_seq_probe — .bpf.o を kernel で N 回実行し、ring buffer へ出た
// **イベント列**を読み上げる (E155 のイベント列差動)。
//
// 現行 backend の object と MLIR backend の object をこの probe に別々にかけ、
// 出力行を突き合わせる (tests/runtime/run_mlir_event_seq.sh)。timestamp は
// 走行ごとに変わるので出力しない — 比べるのは type / version / a / b の列。
//
// 使い方: spnl_event_seq_probe <program.bpf.o> <prog_name> <ringbuf_map> [runs]
//
// 出力:
//   RETVALS=2,2,2
//   EVT type=0x0102 version=1 a=7 b=9   (イベントごとに 1 行、到着順)
//   COUNT=3
//
// exit 0 = 測れた / 1 = load か run が失敗。
//
// Build: cc -O2 tools/spnl_event_seq_probe.c -lbpf -lelf -lz

#include <bpf/bpf.h>
#include <bpf/libbpf.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct evt_hdr { unsigned short type, version; unsigned int reserved; unsigned long long timestamp; };

static int g_count;

static int on_event(void *ctx, void *data, size_t size)
{
    (void)ctx;
    if (size < sizeof(struct evt_hdr) + 16) {
        printf("EVT short size=%zu\n", size);
        g_count++;
        return 0;
    }
    const struct evt_hdr *h = data;
    const long long *p = (const long long *)((const char *)data + sizeof(*h));
    /* timestamp は意味比較の対象外 (走行ごとに変わる)。 */
    printf("EVT type=0x%04x version=%u a=%lld b=%lld\n",
           (unsigned)h->type, (unsigned)h->version, p[0], p[1]);
    g_count++;
    return 0;
}

static int quiet_cb(enum libbpf_print_level level, const char *fmt, va_list ap)
{
    if (level == LIBBPF_DEBUG)
        return 0;
    return vfprintf(stderr, fmt, ap);
}

int main(int argc, char **argv)
{
    if (argc < 4 || argc > 5) {
        fprintf(stderr, "usage: %s <program.bpf.o> <prog_name> <ringbuf_map> [runs]\n", argv[0]);
        return 2;
    }
    int runs = argc == 5 ? atoi(argv[4]) : 3;
    libbpf_set_print(quiet_cb);

    struct bpf_object *obj = bpf_object__open_file(argv[1], NULL);
    if (!obj || bpf_object__load(obj)) {
        fprintf(stderr, "LOAD_FAIL %s\n", argv[1]);
        return 1;
    }
    struct bpf_program *prog = bpf_object__find_program_by_name(obj, argv[2]);
    struct bpf_map *map = bpf_object__find_map_by_name(obj, argv[3]);
    if (!prog || !map) {
        fprintf(stderr, "MISSING prog=%p map=%p\n", (void *)prog, (void *)map);
        return 1;
    }
    struct ring_buffer *rb = ring_buffer__new(bpf_map__fd(map), on_event, NULL, NULL);
    if (!rb) {
        fprintf(stderr, "RINGBUF_FAIL\n");
        return 1;
    }

    char data_in[64] = {0};
    char data_out[256];
    printf("RETVALS=");
    for (int i = 0; i < runs; i++) {
        LIBBPF_OPTS(bpf_test_run_opts, opts,
                    .data_in = data_in, .data_size_in = sizeof data_in,
                    .data_out = data_out, .data_size_out = sizeof data_out,
                    .repeat = 1);
        if (bpf_prog_test_run_opts(bpf_program__fd(prog), &opts)) {
            fprintf(stderr, "RUN_FAIL at %d\n", i);
            return 1;
        }
        printf("%s%d", i ? "," : "", opts.retval);
    }
    printf("\n");

    ring_buffer__poll(rb, 200 /* ms */);
    printf("COUNT=%d\n", g_count);

    ring_buffer__free(rb);
    bpf_object__close(obj);
    return 0;
}
