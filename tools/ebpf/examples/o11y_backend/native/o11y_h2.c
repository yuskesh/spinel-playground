/*
 * o11y_h2.c — h2c (平文 HTTP/2) server + gRPC unary 受信の C shim (E451)
 *
 * 設計 27 章 / E445 追記の作法どおり、「一筋縄でいかない境界」を C 側に閉じ込める:
 * nghttp2 の callback 群・HPACK・flow control・stream 状態機械はすべてこの TU の中。
 * Ruby には「完成したリクエストを取り出す / 応答を返す」だけを見せる:
 *
 *   H2.h2_open(fd)                        accept 直後に呼ぶ (server preface 送出)
 *   H2.h2_feed(fd)     -> <0 = 接続終了   epoll が readable と言うたびに呼ぶ
 *   H2.h2_next_stream(fd) -> id | -1      完成リクエスト queue の先頭
 *   H2.h2_req_path(fd) / h2_req_body(fd)  先頭の :path / body (:binstr、gRPC prefix 込み)
 *   H2.h2_req_pop(fd)                     先頭を捨てて次へ
 *   H2.h2_respond_grpc(fd, stream, grpc_status, msg)   200 + 空 Export 応答 + trailer
 *   H2.h2_close(fd)                       session 破棄 + close(fd)
 *
 * flow control は nghttp2 の自動 WINDOW_UPDATE (既定) に任せる。E452 の負の対照
 * (64KB 超の連続バッチ) がこの選択を実測で検証する。
 */
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <nghttp2/nghttp2.h>

extern int sp_ffi_bin_len;   /* :binstr 契約 (lib/sp_alloc.h) */

/* E453: TLS 終端 (o11y_tls.c)。otls_is(fd) の接続は I/O を TLS 経由に切り替える */
extern int otls_is(int fd);
extern int otls_read_raw(int fd, uint8_t *buf, int cap);
extern int otls_write_all(int fd, const uint8_t *buf, size_t len);
extern void otls_close(int fd);
extern int otls_pending(int fd);

#define H2_MAX_FD 4096

/* 完成したリクエスト 1 件 (END_STREAM まで受けたもの) */
typedef struct h2_req {
    int32_t stream_id;
    char *path;
    char *encoding;                 /* grpc-encoding ヘッダ (無ければ NULL)、E452 */
    uint8_t *body;
    size_t body_len;
    struct h2_req *next;
} h2_req;

/* 受信中 stream の作業領域 (nghttp2 の stream_user_data) */
typedef struct {
    char *path;
    char *encoding;
    uint8_t *body;
    size_t body_len, body_cap;
} h2_stream;

/* 応答 body の data provider 用 (trailer は EOF 時に submit) */
typedef struct {
    uint8_t buf[16];
    size_t len, off;
    char grpc_status[16];
    char grpc_message[256];
} h2_resp;

typedef struct {
    nghttp2_session *sess;
    int fd;
    h2_req *q_head, *q_tail;   /* 完成リクエストの FIFO */
} h2_conn;

static h2_conn *g_conn[H2_MAX_FD];

/* ---------- 小物 ---------- */

static int write_all(int fd, const uint8_t *p, size_t n) {
    size_t off = 0;
    while (off < n) {
        ssize_t w = write(fd, p + off, n - off);
        if (w < 0) { if (errno == EINTR) continue; return -1; }
        off += (size_t)w;
    }
    return 0;
}

static void stream_free(h2_stream *st) {
    if (!st) return;
    free(st->path);
    free(st->encoding);
    free(st->body);
    free(st);
}

static void req_push(h2_conn *c, h2_stream *st, int32_t stream_id) {
    h2_req *r = (h2_req *)calloc(1, sizeof *r);
    if (!r) return;
    r->stream_id = stream_id;
    r->path = st->path;         st->path = NULL;   /* 所有権を queue へ */
    r->encoding = st->encoding; st->encoding = NULL;
    r->body = st->body;         st->body = NULL;
    r->body_len = st->body_len;
    if (c->q_tail) c->q_tail->next = r; else c->q_head = r;
    c->q_tail = r;
}

static void req_pop(h2_conn *c) {
    h2_req *r = c->q_head;
    if (!r) return;
    c->q_head = r->next;
    if (!c->q_head) c->q_tail = NULL;
    free(r->path);
    free(r->encoding);
    free(r->body);
    free(r);
}

/* ---------- nghttp2 callbacks ---------- */

static ssize_t cb_send(nghttp2_session *sess, const uint8_t *data, size_t length,
                       int flags, void *user_data) {
    h2_conn *c = (h2_conn *)user_data;
    (void)sess; (void)flags;
    int rc = otls_is(c->fd) ? otls_write_all(c->fd, data, length)
                            : write_all(c->fd, data, length);
    if (rc != 0) return NGHTTP2_ERR_CALLBACK_FAILURE;
    return (ssize_t)length;
}

static int cb_begin_headers(nghttp2_session *sess, const nghttp2_frame *frame,
                            void *user_data) {
    (void)user_data;
    if (frame->hd.type != NGHTTP2_HEADERS ||
        frame->headers.cat != NGHTTP2_HCAT_REQUEST) return 0;
    h2_stream *st = (h2_stream *)calloc(1, sizeof *st);
    if (!st) return NGHTTP2_ERR_CALLBACK_FAILURE;
    nghttp2_session_set_stream_user_data(sess, frame->hd.stream_id, st);
    return 0;
}

static int cb_header(nghttp2_session *sess, const nghttp2_frame *frame,
                     const uint8_t *name, size_t namelen,
                     const uint8_t *value, size_t valuelen,
                     uint8_t flags, void *user_data) {
    (void)flags; (void)user_data;
    if (frame->hd.type != NGHTTP2_HEADERS) return 0;
    h2_stream *st = (h2_stream *)nghttp2_session_get_stream_user_data(sess, frame->hd.stream_id);
    if (!st) return 0;
    if (namelen == 5 && memcmp(name, ":path", 5) == 0 && !st->path) {
        st->path = (char *)malloc(valuelen + 1);
        if (!st->path) return NGHTTP2_ERR_CALLBACK_FAILURE;
        memcpy(st->path, value, valuelen);
        st->path[valuelen] = '\0';
    }
    if (namelen == 13 && memcmp(name, "grpc-encoding", 13) == 0 && !st->encoding) {
        st->encoding = (char *)malloc(valuelen + 1);
        if (!st->encoding) return NGHTTP2_ERR_CALLBACK_FAILURE;
        memcpy(st->encoding, value, valuelen);
        st->encoding[valuelen] = '\0';
    }
    return 0;
}

static int cb_data_chunk(nghttp2_session *sess, uint8_t flags, int32_t stream_id,
                         const uint8_t *data, size_t len, void *user_data) {
    (void)flags; (void)user_data;
    h2_stream *st = (h2_stream *)nghttp2_session_get_stream_user_data(sess, stream_id);
    if (!st) return 0;
    if (st->body_len + len > st->body_cap) {
        size_t ncap = st->body_cap ? st->body_cap : 16384;
        while (ncap < st->body_len + len) ncap *= 2;
        uint8_t *nb = (uint8_t *)realloc(st->body, ncap);
        if (!nb) return NGHTTP2_ERR_CALLBACK_FAILURE;
        st->body = nb;
        st->body_cap = ncap;
    }
    memcpy(st->body + st->body_len, data, len);
    st->body_len += len;
    return 0;
}

static int cb_frame_recv(nghttp2_session *sess, const nghttp2_frame *frame,
                         void *user_data) {
    h2_conn *c = (h2_conn *)user_data;
    if ((frame->hd.type == NGHTTP2_DATA || frame->hd.type == NGHTTP2_HEADERS) &&
        (frame->hd.flags & NGHTTP2_FLAG_END_STREAM)) {
        h2_stream *st = (h2_stream *)nghttp2_session_get_stream_user_data(sess, frame->hd.stream_id);
        if (st) req_push(c, st, frame->hd.stream_id);
        /* st の中身は queue に移した。器は stream_close で解放 */
    }
    return 0;
}

static int cb_stream_close(nghttp2_session *sess, int32_t stream_id,
                           uint32_t error_code, void *user_data) {
    (void)error_code; (void)user_data;
    h2_stream *st = (h2_stream *)nghttp2_session_get_stream_user_data(sess, stream_id);
    stream_free(st);
    nghttp2_session_set_stream_user_data(sess, stream_id, NULL);
    return 0;
}

/* 応答 body: h2_resp の buf を出し切ったら EOF (+NO_END_STREAM) にして trailer を積む */
static ssize_t cb_resp_read(nghttp2_session *sess, int32_t stream_id, uint8_t *buf,
                            size_t length, uint32_t *data_flags,
                            nghttp2_data_source *source, void *user_data) {
    (void)user_data;
    h2_resp *r = (h2_resp *)source->ptr;
    size_t left = r->len - r->off;
    size_t n = left < length ? left : length;
    memcpy(buf, r->buf + r->off, n);
    r->off += n;
    if (r->off == r->len) {
        *data_flags |= NGHTTP2_DATA_FLAG_EOF | NGHTTP2_DATA_FLAG_NO_END_STREAM;
        nghttp2_nv tr[2];
        int ntr = 0;
        tr[ntr].name = (uint8_t *)"grpc-status";
        tr[ntr].value = (uint8_t *)r->grpc_status;
        tr[ntr].namelen = 11;
        tr[ntr].valuelen = strlen(r->grpc_status);
        tr[ntr].flags = NGHTTP2_NV_FLAG_NONE;
        ntr++;
        if (r->grpc_message[0]) {
            tr[ntr].name = (uint8_t *)"grpc-message";
            tr[ntr].value = (uint8_t *)r->grpc_message;
            tr[ntr].namelen = 12;
            tr[ntr].valuelen = strlen(r->grpc_message);
            tr[ntr].flags = NGHTTP2_NV_FLAG_NONE;
            ntr++;
        }
        if (nghttp2_submit_trailer(sess, stream_id, tr, ntr) != 0)
            return NGHTTP2_ERR_CALLBACK_FAILURE;
        /* r は trailer 送出後に不要。stream close 側で free できないので即時 free は
           read の再入が無い EOF 確定後のここで行う (source->ptr は以後読まれない)。 */
        free(r);
    }
    return (ssize_t)n;
}

/* ---------- Ruby から呼ぶ面 ---------- */

int h2_is_open(int fd) {
    return (fd >= 0 && fd < H2_MAX_FD && g_conn[fd]) ? 1 : 0;
}

int h2_open(int fd) {
    if (fd < 0 || fd >= H2_MAX_FD || g_conn[fd]) return -1;
    h2_conn *c = (h2_conn *)calloc(1, sizeof *c);
    if (!c) return -1;
    c->fd = fd;
    nghttp2_session_callbacks *cbs;
    if (nghttp2_session_callbacks_new(&cbs) != 0) { free(c); return -1; }
    nghttp2_session_callbacks_set_send_callback(cbs, cb_send);
    nghttp2_session_callbacks_set_on_begin_headers_callback(cbs, cb_begin_headers);
    nghttp2_session_callbacks_set_on_header_callback(cbs, cb_header);
    nghttp2_session_callbacks_set_on_data_chunk_recv_callback(cbs, cb_data_chunk);
    nghttp2_session_callbacks_set_on_frame_recv_callback(cbs, cb_frame_recv);
    nghttp2_session_callbacks_set_on_stream_close_callback(cbs, cb_stream_close);
    int rc = nghttp2_session_server_new(&c->sess, cbs, c);
    nghttp2_session_callbacks_del(cbs);
    if (rc != 0) { free(c); return -1; }
    if (nghttp2_submit_settings(c->sess, NGHTTP2_FLAG_NONE, NULL, 0) != 0 ||
        nghttp2_session_send(c->sess) != 0) {
        nghttp2_session_del(c->sess);
        free(c);
        return -1;
    }
    g_conn[fd] = c;
    return 0;
}

void h2_close(int fd) {
    if (!h2_is_open(fd)) return;
    h2_conn *c = g_conn[fd];
    g_conn[fd] = NULL;
    while (c->q_head) req_pop(c);
    nghttp2_session_del(c->sess);
    if (otls_is(c->fd)) otls_close(c->fd);   /* TLS: session 解放 + close は TLS 側で (二重 close 回避) */
    else close(c->fd);
    free(c);
}

/* readable になった fd から 1 回 recv して session に食わせる。
 * 戻り: 0 = 継続, -1 = 接続終了 (呼び手は epoll から外し h2_close する) */
int h2_feed(int fd) {
    if (!h2_is_open(fd)) return -1;
    h2_conn *c = g_conn[fd];
    static uint8_t buf[65536];
    if (otls_is(fd)) {
        /* TLS: epoll が readable と言った socket 分を 1 回読み、その後は mbedtls の
           内部 buffer に残った record (otls_pending) だけを drain する。socket が
           空の状態で ssl_read を呼ぶと blocking read → 5s デッドラインで健全な
           接続を fatal にしてしまう (E453 で実測した grpcs 全損の原因)。 */
        do {
            int n = otls_read_raw(fd, buf, (int)sizeof buf);
            if (n < 0) return -1;
            if (n == 0) break;
            ssize_t used = nghttp2_session_mem_recv(c->sess, buf, (size_t)n);
            if (used < 0 || used != n) return -1;
        } while (otls_pending(fd));
    } else {
        ssize_t n = recv(fd, buf, sizeof buf, 0);
        if (n == 0) return -1;                   /* peer closed */
        if (n < 0) return (errno == EINTR || errno == EAGAIN) ? 0 : -1;
        ssize_t used = nghttp2_session_mem_recv(c->sess, buf, (size_t)n);
        if (used < 0 || used != n) return -1;
    }
    if (nghttp2_session_send(c->sess) != 0) return -1;
    if (!nghttp2_session_want_read(c->sess) && !nghttp2_session_want_write(c->sess))
        return -1;
    return 0;
}

int h2_next_stream(int fd) {
    if (!h2_is_open(fd) || !g_conn[fd]->q_head) return -1;
    return (int)g_conn[fd]->q_head->stream_id;
}

const char *h2_req_path(int fd) {
    if (!h2_is_open(fd) || !g_conn[fd]->q_head) return "";
    const char *p = g_conn[fd]->q_head->path;
    return p ? p : "";
}

const char *h2_req_encoding(int fd) {
    if (!h2_is_open(fd) || !g_conn[fd]->q_head) return "";
    const char *e = g_conn[fd]->q_head->encoding;
    return e ? e : "";
}

const char *h2_req_body(int fd) {
    static const char empty[1] = "";
    if (!h2_is_open(fd) || !g_conn[fd]->q_head) { sp_ffi_bin_len = 0; return empty; }
    h2_req *r = g_conn[fd]->q_head;
    sp_ffi_bin_len = (int)r->body_len;
    return r->body ? (const char *)r->body : empty;
}

void h2_req_pop(int fd) {
    if (h2_is_open(fd)) req_pop(g_conn[fd]);
}

/* gRPC unary 応答: :status 200 + application/grpc、body = 5-byte prefix の空メッセージ、
 * trailer に grpc-status (+ message)。logs Export の応答メッセージは空で足りる。 */
int h2_respond_grpc(int fd, int stream_id, int grpc_status, const char *grpc_message) {
    if (!h2_is_open(fd)) return -1;
    h2_conn *c = g_conn[fd];
    h2_resp *r = (h2_resp *)calloc(1, sizeof *r);
    if (!r) return -1;
    memset(r->buf, 0, 5);                        /* flag=0, len=0: 空メッセージ */
    r->len = 5;
    snprintf(r->grpc_status, sizeof r->grpc_status, "%d", grpc_status);
    if (grpc_message && grpc_message[0])
        snprintf(r->grpc_message, sizeof r->grpc_message, "%s", grpc_message);
    nghttp2_nv hdrs[2] = {
        { (uint8_t *)":status", (uint8_t *)"200", 7, 3, NGHTTP2_NV_FLAG_NONE },
        { (uint8_t *)"content-type", (uint8_t *)"application/grpc", 12, 16, NGHTTP2_NV_FLAG_NONE },
    };
    nghttp2_data_provider prd;
    prd.source.ptr = r;
    prd.read_callback = cb_resp_read;
    if (nghttp2_submit_response(c->sess, stream_id, hdrs, 2, &prd) != 0) {
        free(r);
        return -1;
    }
    return nghttp2_session_send(c->sess) == 0 ? 0 : -1;
}
