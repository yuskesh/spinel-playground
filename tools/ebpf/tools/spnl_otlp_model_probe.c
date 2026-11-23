// SPDX-License-Identifier: GPL-2.0
//
// spnl_otlp_model_probe — E156 (P013 Task 9): **Spinel current backend の入力境界**。
//
// 固定 pair record bytes を既存の OTLP/JSON builder (otlp_json.c — protobuf 版と
// 同じ入力構造体・同じ意味の対) に通し、LogRecord / Sum / ExponentialHistogram の
// OTLP/JSON 3 文書を 1 つの JSON にまとめて印字する。intake は
// spnl_pair_otlp_json.h (checkpoint 3 の e2e probe と共有) — temporality /
// monotonic / scale / offset の意味は builder の側が持つ。
//
// 使い方:
//   spnl_otlp_model_probe <records.bin> <wall_offset_ns>
//                         <sum_name> <sum_unit> <hist_name> <hist_unit>
//
// records.bin は 32B pair record (spnl_event_hdr + __s64 a + __s64 b) の連結。
// 名前と unit は schema の telemetry 宣言から呼び手が渡す (この probe は schema を
// parse しない — C 側に JSON parser を持ち込まないため)。
//
// 拒否 (黙って落とさない):
//   - ファイル長が record size の倍数でない (length mismatch)
//   - hdr.type が SPNL_EVT_TYPE_OK を満たさない (未知 record ID)
//   - 表現できない観測値 (spnl_pair_otlp_json.h 参照)
//
// Build (clang — run_otlp_json.sh と同じ):
//   clang -O2 -I include -I src/runtime/otlp
//         tools/spnl_otlp_model_probe.c src/runtime/otlp/otlp_json.c

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* checkpoint 2 は kernel を使わない意味差動なので、probe は host-portable に
 * する (Mac 検収 2026-08-26)。types.h が要る Linux 型だけを非 Linux で定義し、
 * Linux runtime 全体の Mac 対応には広げない。 */
#ifdef __linux__
#include <linux/types.h>
#else
typedef uint8_t  __u8;
typedef uint16_t __u16;
typedef uint32_t __u32;
typedef uint64_t __u64;
typedef int8_t   __s8;
typedef int16_t  __s16;
typedef int32_t  __s32;
typedef int64_t  __s64;
#endif

#include "spnl/types.h"
#include "spnl_pair_otlp_json.h"

int main(int argc, char **argv) {
    if (argc != 7) {
        fprintf(stderr, "usage: %s <records.bin> <wall_offset_ns> "
                        "<sum_name> <sum_unit> <hist_name> <hist_unit>\n", argv[0]);
        return 2;
    }
    const char *path = argv[1];
    long long off = strtoll(argv[2], NULL, 10);

    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "FAIL: cannot open %s\n", path); return 1; }
    fseek(f, 0, SEEK_END);
    long fsz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (fsz <= 0 || (fsz % (long)sizeof(struct pair_rec)) != 0) {
        fprintf(stderr, "FAIL: length mismatch (%ld bytes, record size %zu)\n",
                fsz, sizeof(struct pair_rec));
        fclose(f);
        return 1;
    }
    size_t n = (size_t)fsz / sizeof(struct pair_rec);
    struct pair_rec *recs = calloc(n, sizeof(*recs));
    if (!recs || fread(recs, sizeof(*recs), n, f) != n) {
        fprintf(stderr, "FAIL: short read\n");
        fclose(f);
        return 1;
    }
    fclose(f);

    for (size_t i = 0; i < n; i++) {
        if (!SPNL_EVT_TYPE_OK(recs[i].hdr.type, SPNL_EVT_EMIT_PAIR)) {
            fprintf(stderr, "FAIL: record %zu has unknown id 0x%04x "
                            "(want 0x%04x or legacy 0x%04x)\n",
                    i, recs[i].hdr.type, SPNL_EVT_EMIT_PAIR, SPNL_EVT_USER_BASE);
            return 1;
        }
    }

    static char lbuf[65536], sbuf[65536], hbuf[65536];
    long ln, sn, hn;
    char msg[256];
    if (pair_build_otlp_json(recs, n, off, argv[3], argv[4], argv[5], argv[6],
                             lbuf, sizeof lbuf, &ln, sbuf, sizeof sbuf, &sn,
                             hbuf, sizeof hbuf, &hn, msg, sizeof msg) != 0) {
        fprintf(stderr, "FAIL: %s\n", msg);
        return 1;
    }
    printf("{\"logs\":%.*s,\"sum\":%.*s,\"exphist\":%.*s}\n",
           (int)ln, lbuf, (int)sn, sbuf, (int)hn, hbuf);
    free(recs);
    return 0;
}
