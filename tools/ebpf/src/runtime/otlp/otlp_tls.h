/*
 * otlp_tls.h — OTLP egress 用 TLS クライアント (ADR-013、mbedTLS)
 *
 * connected な socket fd の上に TLS を被せる薄い層 (upstream spinel の `sp_net_tls` 構想
 * = 「fd の上に layer」に整合)。TLS クライアントのみ。https:// / grpcs:// の OTLP 直送に使う。
 *
 * 証明書検証 (env):
 *   OTEL_EXPORTER_OTLP_CERTIFICATE         — カスタム CA file (PEM)。未指定なら system CA bundle。
 *   OTEL_EXPORTER_OTLP_INSECURE_SKIP_VERIFY=1 — 検証を無効化 (dev only、既定は検証 ON)。
 */
#ifndef SPNL_OTLP_TLS_H
#define SPNL_OTLP_TLS_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct otlp_tls otlp_tls_t;

/* connected fd を TLS client で wrap し handshake する。SNI/検証 hostname に hostname を使う。
 * alpn != NULL のとき ALPN で 1 プロトコルを提示 (gRPC-over-TLS は "h2" 必須、HTTP/1.1 は NULL)。
 * 成功で handle、失敗で NULL (err にメッセージ)。fd の所有権は移らない (呼び出し側が close)。 */
otlp_tls_t *otlp_tls_connect(int fd, const char *hostname, const char *alpn, char *err, size_t errlen);

/* len バイトを全部 TLS 送信。成功 0 / 失敗 -1。 */
int otlp_tls_write(otlp_tls_t *t, const void *buf, size_t len);

/* TLS 受信。読めたバイト数 / 0 = close_notify / -1 = エラー。 */
int otlp_tls_read(otlp_tls_t *t, void *buf, size_t len);

/* close_notify + 解放 (fd は閉じない)。 */
void otlp_tls_free(otlp_tls_t *t);

#ifdef __cplusplus
}
#endif

#endif /* SPNL_OTLP_TLS_H */
