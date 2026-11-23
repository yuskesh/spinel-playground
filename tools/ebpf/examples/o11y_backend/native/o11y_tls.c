/*
 * o11y_tls.c — mbedTLS による server 側 TLS 終端 (E453)
 *
 * ADR-013 の vendored mbedTLS (client 側 otlp_tls.c と同じ静的ライブラリ) を server 用に。
 * ポートごとに ALPN を固定した 2 つの config を持つ:
 *   mode 0 (OTLP/HTTPS 4318): ALPN http/1.1 — curl 等が h2 を優先提案しても 1.1 に固定
 *   mode 1 (OTLP/grpcs 4317): ALPN h2
 * o11y_h2.c は otls_is(fd) を見て I/O をこの TU 経由に切り替える (h2-over-TLS)。
 * HTTP/1.1 側には sp_net の rl_* と同じ意味論の line-buffered reader を提供する
 * (drain-first — E187 の教訓は TLS でも同じ)。
 */
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <mbedtls/ssl.h>
#include <mbedtls/entropy.h>
#include <mbedtls/ctr_drbg.h>
#include <mbedtls/x509_crt.h>
#include <mbedtls/pk.h>
#include <mbedtls/net_sockets.h>   /* MBEDTLS_ERR_NET_* */
#include <psa/crypto.h>

extern int sp_ffi_bin_len;   /* :binstr 契約 */

#define OTLS_MAX_FD 4096
#define RBUF_CAP 65536

typedef struct {
    mbedtls_ssl_context ssl;
    int fd;
    uint8_t rbuf[RBUF_CAP];      /* line-buffered reader (HTTP/1.1 経路のみ使用) */
    size_t rlen, roff;
    char line[8192];
} otls_conn;

static mbedtls_entropy_context g_entropy;
static mbedtls_ctr_drbg_context g_drbg;
static mbedtls_x509_crt g_cert;
static mbedtls_pk_context g_key;
static mbedtls_ssl_config g_conf_http, g_conf_h2;
static const char *ALPN_HTTP[] = { "http/1.1", NULL };
static const char *ALPN_H2[]   = { "h2", NULL };
static otls_conn *g_tconn[OTLS_MAX_FD];
static int g_ready = 0;

/* EAGAIN は SO_RCVTIMEO/SNDTIMEO (otls_accept で 5s を設定) の満了 = デッドライン超過
 * として fatal に扱う。WANT_* に写像すると「平文を TLS ポートに送る client」や
 * slow client の handshake が worker を永久に専有する (E453 の負の対照が実測した hang)。 */
static int bio_send(void *ctx, const unsigned char *buf, size_t len) {
    int fd = ((otls_conn *)ctx)->fd;
    ssize_t n = write(fd, buf, len);
    if (n < 0) {
        if (errno == EINTR) return MBEDTLS_ERR_SSL_WANT_WRITE;
        return MBEDTLS_ERR_NET_SEND_FAILED;
    }
    return (int)n;
}

static int bio_recv(void *ctx, unsigned char *buf, size_t len) {
    int fd = ((otls_conn *)ctx)->fd;
    ssize_t n = read(fd, buf, len);
    if (n < 0) {
        if (errno == EINTR) return MBEDTLS_ERR_SSL_WANT_READ;
        return MBEDTLS_ERR_NET_RECV_FAILED;   /* EAGAIN (timeout) 含む */
    }
    return (int)n;
}

static int conf_setup(mbedtls_ssl_config *conf, const char **alpn) {
    mbedtls_ssl_config_init(conf);
    if (mbedtls_ssl_config_defaults(conf, MBEDTLS_SSL_IS_SERVER,
                                    MBEDTLS_SSL_TRANSPORT_STREAM,
                                    MBEDTLS_SSL_PRESET_DEFAULT) != 0) return -1;
    mbedtls_ssl_conf_rng(conf, mbedtls_ctr_drbg_random, &g_drbg);
    if (mbedtls_ssl_conf_own_cert(conf, &g_cert, &g_key) != 0) return -1;
    if (mbedtls_ssl_conf_alpn_protocols(conf, alpn) != 0) return -1;
    return 0;
}

/* cert/key を読み 2 config を用意。0 = 成功。 */
int otls_init(const char *cert_path, const char *key_path) {
    if (g_ready) return 0;
    psa_crypto_init();
    mbedtls_entropy_init(&g_entropy);
    mbedtls_ctr_drbg_init(&g_drbg);
    mbedtls_x509_crt_init(&g_cert);
    mbedtls_pk_init(&g_key);
    if (mbedtls_ctr_drbg_seed(&g_drbg, mbedtls_entropy_func, &g_entropy,
                              (const unsigned char *)"o11y_tls", 8) != 0) return -1;
    if (mbedtls_x509_crt_parse_file(&g_cert, cert_path) != 0) return -2;
    if (mbedtls_pk_parse_keyfile(&g_key, key_path, NULL,
                                 mbedtls_ctr_drbg_random, &g_drbg) != 0) return -3;
    if (conf_setup(&g_conf_http, ALPN_HTTP) != 0) return -4;
    if (conf_setup(&g_conf_h2, ALPN_H2) != 0) return -4;
    g_ready = 1;
    return 0;
}

int otls_is(int fd) {
    return (fd >= 0 && fd < OTLS_MAX_FD && g_tconn[fd]) ? 1 : 0;
}

/* accept 直後に呼ぶ。mode: 0 = http/1.1, 1 = h2。handshake 完了まで回す (blocking fd)。 */
int otls_accept(int fd, int mode) {
    if (!g_ready || fd < 0 || fd >= OTLS_MAX_FD || g_tconn[fd]) return -1;
    otls_conn *c = (otls_conn *)calloc(1, sizeof *c);
    if (!c) return -1;
    c->fd = fd;
    struct timeval tv = { 5, 0 };   /* TLS 接続の I/O デッドライン (handshake 含む) */
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
    mbedtls_ssl_init(&c->ssl);
    if (mbedtls_ssl_setup(&c->ssl, mode ? &g_conf_h2 : &g_conf_http) != 0) {
        free(c);
        return -1;
    }
    mbedtls_ssl_set_bio(&c->ssl, c, bio_send, bio_recv, NULL);
    int ret;
    while ((ret = mbedtls_ssl_handshake(&c->ssl)) != 0) {
        if (ret == MBEDTLS_ERR_SSL_WANT_READ || ret == MBEDTLS_ERR_SSL_WANT_WRITE) continue;
        mbedtls_ssl_free(&c->ssl);
        free(c);
        return -2;   /* handshake 失敗 (平文が来た等)。呼び手は close */
    }
    g_tconn[fd] = c;
    return 0;
}

const char *otls_alpn(int fd) {
    if (!otls_is(fd)) return "";
    const char *p = mbedtls_ssl_get_alpn_protocol(&g_tconn[fd]->ssl);
    return p ? p : "";
}

void otls_close(int fd) {
    if (!otls_is(fd)) return;
    otls_conn *c = g_tconn[fd];
    g_tconn[fd] = NULL;
    mbedtls_ssl_close_notify(&c->ssl);   /* best effort */
    mbedtls_ssl_free(&c->ssl);
    close(c->fd);
    free(c);
}

/* ---- raw 読み書き (o11y_h2.c が h2-over-TLS で使う) ---- */

/* >0 = 読めたバイト数, 0 = いまは無い (WANT_READ), -1 = 終了/エラー */
int otls_read_raw(int fd, uint8_t *buf, int cap) {
    if (!otls_is(fd)) return -1;
    int n = mbedtls_ssl_read(&g_tconn[fd]->ssl, buf, (size_t)cap);
    if (n > 0) return n;
    if (n == MBEDTLS_ERR_SSL_WANT_READ || n == MBEDTLS_ERR_SSL_WANT_WRITE) return 0;
    return -1;   /* close_notify 含む */
}

/* mbedtls の内部 buffer に処理待ちの record/bytes が残っているか (E453)。
 * h2 の drain ループはこれが真の間だけ追加で read する — socket が空のときに
 * ssl_read を呼ぶと blocking read → デッドライン発火で健全な接続を切ってしまう。 */
int otls_pending(int fd) {
    if (!otls_is(fd)) return 0;
    mbedtls_ssl_context *ssl = &g_tconn[fd]->ssl;
    return (mbedtls_ssl_check_pending(ssl) || mbedtls_ssl_get_bytes_avail(ssl) > 0) ? 1 : 0;
}

int otls_write_all(int fd, const uint8_t *buf, size_t len) {
    if (!otls_is(fd)) return -1;
    size_t off = 0;
    while (off < len) {
        int n = mbedtls_ssl_write(&g_tconn[fd]->ssl, buf + off, len - off);
        if (n > 0) { off += (size_t)n; continue; }
        if (n == MBEDTLS_ERR_SSL_WANT_READ || n == MBEDTLS_ERR_SSL_WANT_WRITE) continue;
        return -1;
    }
    return 0;
}

/* ---- HTTP/1.1 用 line-buffered reader (sp_net rl_* の TLS 版) ---- */

static int fill_rbuf(otls_conn *c) {
    if (c->roff < c->rlen) return 1;
    c->roff = c->rlen = 0;
    while (1) {
        int n = mbedtls_ssl_read(&c->ssl, c->rbuf, RBUF_CAP);
        if (n > 0) { c->rlen = (size_t)n; return 1; }
        if (n == MBEDTLS_ERR_SSL_WANT_READ || n == MBEDTLS_ERR_SSL_WANT_WRITE) continue;
        return 0;   /* EOF/エラー */
    }
}

/* CRLF を剥いだ 1 行。EOF は "" (既存 sp_net_read_line と同じ意味論)。 */
const char *otls_read_line(int fd) {
    if (!otls_is(fd)) return "";
    otls_conn *c = g_tconn[fd];
    size_t w = 0;
    while (w < sizeof c->line - 1) {
        if (c->roff >= c->rlen && !fill_rbuf(c)) { c->line[0] = '\0'; return c->line; }
        uint8_t b = c->rbuf[c->roff++];
        if (b == '\n') break;
        c->line[w++] = (char)b;
    }
    if (w > 0 && c->line[w - 1] == '\r') w--;
    c->line[w] = '\0';
    return c->line;
}

/* buffer を drain してから読む (E187 と同じ規律)。 */
const char *otls_recv_some(int fd, int want) {
    static const char empty[1] = "";
    sp_ffi_bin_len = 0;
    if (!otls_is(fd) || want <= 0) return empty;
    otls_conn *c = g_tconn[fd];
    if (c->roff < c->rlen) {
        size_t have = c->rlen - c->roff;
        size_t n = (size_t)want < have ? (size_t)want : have;
        const char *p = (const char *)(c->rbuf + c->roff);
        c->roff += n;
        sp_ffi_bin_len = (int)n;
        return p;
    }
    static uint8_t tmp[RBUF_CAP];
    int cap = want < (int)sizeof tmp ? want : (int)sizeof tmp;
    while (1) {
        int n = mbedtls_ssl_read(&c->ssl, tmp, (size_t)cap);
        if (n > 0) { sp_ffi_bin_len = n; return (const char *)tmp; }
        if (n == MBEDTLS_ERR_SSL_WANT_READ || n == MBEDTLS_ERR_SSL_WANT_WRITE) continue;
        return empty;
    }
}

int otls_write_bytes(int fd, const char *data, int len) {
    return otls_write_all(fd, (const uint8_t *)data, (size_t)(len < 0 ? 0 : len));
}
