/*
 * o11y_gzip.c — gzip (RFC 1952) inflate の C shim (E452)
 *
 * gRPC の compressed frame (flag=1, grpc-encoding: gzip) と HTTP の
 * Content-Encoding: gzip の両方から使う。zlib の状態機械はここに閉じる。
 *
 * Ruby:
 *   out = GZ.o11y_gunzip(data, len)    # :binstr (伸長結果)
 *   GZ.o11y_gunzip_err                 # 0 = 成功。非 0 = zlib エラーコード (負) or 独自 (正)
 *
 * 失敗時は空 :binstr + err 非 0。空入力の正当な伸長 (空) と区別するため必ず err を見る。
 * 伸長サイズは MAX_OUT で制限 (zip bomb 対策 — 超過は err=1 で loud に落とす)。
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

extern int sp_ffi_bin_len;   /* :binstr 契約 (lib/sp_alloc.h) */

#define MAX_OUT (64 * 1024 * 1024)   /* 64MB: OTLP バッチとして十分、bomb は拒否 */

static uint8_t *g_buf = NULL;
static size_t g_cap = 0;
static int g_err = 0;

int o11y_gunzip_err(void) { return g_err; }

const char *o11y_gunzip(const char *data, int len) {
    static const char empty[1] = "";
    g_err = 0;
    sp_ffi_bin_len = 0;
    if (len < 0) { g_err = 2; return empty; }

    z_stream zs;
    memset(&zs, 0, sizeof zs);
    /* windowBits 15+16: gzip ヘッダ必須 (生 deflate は受けない — gRPC/HTTP とも gzip) */
    if (inflateInit2(&zs, 15 + 16) != Z_OK) { g_err = 3; return empty; }

    zs.next_in = (Bytef *)data;
    zs.avail_in = (uInt)len;
    size_t total = 0;
    int rc = Z_OK;
    while (rc != Z_STREAM_END) {
        if (total + 65536 > g_cap) {
            size_t ncap = g_cap ? g_cap * 2 : 262144;
            while (ncap < total + 65536) ncap *= 2;
            if (ncap > MAX_OUT) { g_err = 1; inflateEnd(&zs); return empty; }
            uint8_t *nb = (uint8_t *)realloc(g_buf, ncap);
            if (!nb) { g_err = 4; inflateEnd(&zs); return empty; }
            g_buf = nb;
            g_cap = ncap;
        }
        zs.next_out = g_buf + total;
        zs.avail_out = (uInt)(g_cap - total);
        rc = inflate(&zs, Z_NO_FLUSH);
        total = zs.total_out;
        if (rc == Z_STREAM_END) break;
        if (rc != Z_OK) { g_err = rc; inflateEnd(&zs); return empty; }
        if (zs.avail_in == 0 && rc == Z_OK) { g_err = 5; inflateEnd(&zs); return empty; } /* truncated */
    }
    inflateEnd(&zs);
    sp_ffi_bin_len = (int)total;
    return g_buf ? (const char *)g_buf : empty;
}
