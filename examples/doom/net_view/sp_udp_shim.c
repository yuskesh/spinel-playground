/* examples/doom/net_view/sp_udp_shim.c -- the UDP socket net_view.rb receives
 * the board's frames on (decision 0024), and sends the keys from (decision
 * 0025).
 *
 * It matches net_view.rb's `ffi_func` declarations one to one, in the form of
 * ../native/sp_sdl_shim.c:
 *
 *   - the socket is an int64 handle; Ruby holds no pointer and no fd
 *   - a failure is the return value (0 for a handle, negative otherwise), and
 *     its text is fetched afterwards with sp_udp_error()
 *   - sp_udp_recv returns the datagram's bytes for the `:binstr` return mode:
 *     the pinned runtime builds the String from the count this file publishes
 *     in sp_ffi_bin_len, so a datagram's NUL bytes survive. An empty String
 *     is "nothing yet" or a failure; sp_udp_status() tells them apart.
 *   - sp_udp_send takes the message's length as an argument: a `:str`
 *     argument is a `const char *` with no length, and the key message has
 *     0 bytes in it.
 */

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

/* the runtime's byte count for `:binstr` (vendor/spinel/lib/sp_alloc.h); the
 * viewer is single-threaded, so it is a plain int here */
extern int sp_ffi_bin_len;

#define SP_UDP_MAXSOCK 4
/* the largest datagram kept whole: more than a frame channel message (1 + 768
 * or 9 + 1280 bytes) ever is; a longer one arrives cut and is a bad datagram */
#define SP_UDP_MAX 65536

typedef struct {
    int used;
    int fd;
    int status;     /* the last recv: 1 a datagram, 0 none in time, -1 failed */
    int rcvbuf;     /* the receive buffer the kernel granted */
    char from[INET_ADDRSTRLEN];  /* the last datagram's source address */
} SpUdpSock;

static SpUdpSock s_sock[SP_UDP_MAXSOCK];
static char s_err[256];
static char s_buf[SP_UDP_MAX];

static void seterr(const char *what) {
    snprintf(s_err, sizeof s_err, "%s: %s", what, strerror(errno));
}

const char *sp_udp_error(void) { return s_err; }

static SpUdpSock *get(int64_t h) {
    if (h < 1 || h > SP_UDP_MAXSOCK) return NULL;
    SpUdpSock *s = &s_sock[h - 1];
    return s->used ? s : NULL;
}

/* A UDP socket bound to addr (dotted IPv4, "0.0.0.0" for any) and port, with
 * an 8 MB receive buffer asked for, so that a viewer busy presenting does not
 * leave the kernel to drop what the board sent. */
int64_t sp_udp_open(const char *addr, int port) {
    int slot = -1;
    for (int i = 0; i < SP_UDP_MAXSOCK; i++) if (!s_sock[i].used) { slot = i; break; }
    if (slot < 0) { snprintf(s_err, sizeof s_err, "no free socket slot"); return 0; }
    if (port <= 0 || port > 65535) { snprintf(s_err, sizeof s_err, "bad port %d", port); return 0; }
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof sa);
    sa.sin_family = AF_INET;
    sa.sin_port = htons((uint16_t)port);
    if (!addr || inet_pton(AF_INET, addr, &sa.sin_addr) != 1) {
        snprintf(s_err, sizeof s_err, "bad IPv4 address '%s'", addr ? addr : "");
        return 0;
    }
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) { seterr("socket"); return 0; }
    int want = 8 << 20;
    /* macOS refuses a size over kern.ipc.maxsockbuf outright; halve until it takes */
    while (want >= 65536 && setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &want, sizeof want) != 0) want /= 2;
    if (bind(fd, (struct sockaddr *)&sa, sizeof sa) != 0) { seterr("bind"); close(fd); return 0; }
    int got = 0;
    socklen_t len = sizeof got;
    if (getsockopt(fd, SOL_SOCKET, SO_RCVBUF, &got, &len) != 0) got = 0;
    SpUdpSock *s = &s_sock[slot];
    memset(s, 0, sizeof *s);
    s->used = 1;
    s->fd = fd;
    s->rcvbuf = got;
    s_err[0] = '\0';
    return slot + 1;
}

/* the receive buffer the kernel granted, in bytes (0 if unknown) */
int sp_udp_rcvbuf(int64_t h) {
    SpUdpSock *s = get(h);
    return s ? s->rcvbuf : -1;
}

/* One datagram, waiting at most timeout_ms (0: only what is already there). */
const char *sp_udp_recv(int64_t h, int timeout_ms) {
    sp_ffi_bin_len = 0;
    SpUdpSock *s = get(h);
    if (!s) { snprintf(s_err, sizeof s_err, "bad handle"); return s_buf; }
    struct pollfd p = { s->fd, POLLIN, 0 };
    int r = poll(&p, 1, timeout_ms < 0 ? 0 : timeout_ms);
    if (r < 0) {
        if (errno == EINTR) { s->status = 0; return s_buf; }
        seterr("poll"); s->status = -1; return s_buf;
    }
    if (r == 0) { s->status = 0; return s_buf; }
    struct sockaddr_in src;
    socklen_t slen = sizeof src;
    memset(&src, 0, sizeof src);
    ssize_t n = recvfrom(s->fd, s_buf, sizeof s_buf, 0, (struct sockaddr *)&src, &slen);
    if (n < 0) {
        if (errno == EAGAIN || errno == EINTR) { s->status = 0; return s_buf; }
        seterr("recvfrom"); s->status = -1; return s_buf;
    }
    if (src.sin_family != AF_INET || !inet_ntop(AF_INET, &src.sin_addr, s->from, sizeof s->from))
        s->from[0] = '\0';
    s->status = 1;
    sp_ffi_bin_len = (int)n;
    return s_buf;
}

/* One datagram of len bytes to addr (dotted IPv4) and port, from the socket's
 * own bound port. It does not wait for room in the send buffer: a send that
 * would wait fails, as any other does. Returns len, or -1. */
int sp_udp_send(int64_t h, const char *addr, int port, const char *data, int len) {
    SpUdpSock *s = get(h);
    if (!s) { snprintf(s_err, sizeof s_err, "bad handle"); return -1; }
    if (port <= 0 || port > 65535) { snprintf(s_err, sizeof s_err, "bad port %d", port); return -1; }
    if (len < 0 || len > SP_UDP_MAX) { snprintf(s_err, sizeof s_err, "bad length %d", len); return -1; }
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof sa);
    sa.sin_family = AF_INET;
    sa.sin_port = htons((uint16_t)port);
    if (!addr || inet_pton(AF_INET, addr, &sa.sin_addr) != 1) {
        snprintf(s_err, sizeof s_err, "bad IPv4 address '%s'", addr ? addr : "");
        return -1;
    }
    ssize_t n = sendto(s->fd, data, (size_t)len, MSG_DONTWAIT, (struct sockaddr *)&sa, sizeof sa);
    if (n < 0) { seterr("sendto"); return -1; }
    if (n != len) { snprintf(s_err, sizeof s_err, "sendto: %zd of %d bytes", n, len); return -1; }
    return len;
}

/* the source address of the last datagram sp_udp_recv returned, dotted IPv4
 * ("" before the first, or when it was not IPv4) */
const char *sp_udp_from(int64_t h) {
    SpUdpSock *s = get(h);
    return s ? s->from : "";
}

/* the last sp_udp_recv: 1 a datagram (possibly empty), 0 none in time, -1 failed */
int sp_udp_status(int64_t h) {
    SpUdpSock *s = get(h);
    return s ? s->status : -1;
}

void sp_udp_close(int64_t h) {
    SpUdpSock *s = get(h);
    if (!s) return;
    close(s->fd);
    memset(s, 0, sizeof *s);
}
