/* run_own.h — E067 の VM の runner の判定の部品 (実の syscall は ops — 失敗の経路を root なしで試す: test/abi/own_ids_unit.c)。
* - own links / programs are watched only by fixed IDs. Disappearance is only ENOENT from an ID query; other errors are "unobserved" (not turned into an empty set — the bpf-mlir reviewer's local review)
 * - 受信の窓は CLOCK_MONOTONIC の期限まで。timeout (EAGAIN) と EINTR だけ続け、他の読みの誤りは失敗 */
#ifndef BML_TEST_RUN_OWN_H
#define BML_TEST_RUN_OWN_H

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#include <bpf/bpf.h>
#include <linux/bpf.h>

enum own_state { OWN_GONE, OWN_PRESENT, OWN_UNOBSERVED };

struct own_sys {
	int (*link_next)(uint32_t id, uint32_t *next); /* 0 か -errno (終わりは -ENOENT) */
	int (*link_open)(uint32_t id);		       /* fd か -errno */
	int (*link_info)(int fd, struct bpf_link_info *out);
	int (*prog_open)(uint32_t id);
	int (*close_fd)(int fd);
	int64_t (*now_ms)(void);
	void (*sleep_ms)(int ms);
};

static inline int own_close(const struct own_sys *s, int fd, char *err, size_t n)
{
	int c = s->close_fd(fd);
	if (c < 0)
		snprintf(err, n, "close: errno %d", -c);
	return c < 0 ? -1 : 0;
}

/* 固定の program に属する netkit の link の ID を集める。program は同じで pair の違う link は未観測の誤り。0 か -1 (*err に名指し) */
static inline int own_collect_links(const struct own_sys *s, uint32_t prog_id, uint32_t primary, uint32_t peer, uint32_t *ids, struct bpf_link_info *infos,
				    int cap, int *n, char *err, size_t en)
{
	uint32_t id = 0;
	*n = 0;
	for (;;) {
		uint32_t next = 0;
		int rc = s->link_next(id, &next);
		if (rc == -ENOENT)
			return 0;
		if (rc < 0) {
			snprintf(err, en, "link_next after %u: errno %d", id, -rc);
			return -1;
		}
		id = next;
		int fd = s->link_open(id);
		if (fd == -ENOENT)
			continue; /* 歩いている間に消えた link */
		if (fd < 0) {
			snprintf(err, en, "link_open %u: errno %d", id, -fd);
			return -1;
		}
		struct bpf_link_info i;
		memset(&i, 0, sizeof i);
		rc = s->link_info(fd, &i);
		if (own_close(s, fd, err, en))
			return -1;
		if (rc < 0) {
			snprintf(err, en, "link_info %u: errno %d", id, -rc);
			return -1;
		}
		if (i.type != BPF_LINK_TYPE_NETKIT || i.prog_id != prog_id)
			continue;
		if (i.netkit.ifindex != primary && i.netkit.ifindex != peer) {
			snprintf(err, en, "link %u of the own program is on foreign ifindex %u", id, i.netkit.ifindex);
			return -1;
		}
		if (*n >= cap) {
			snprintf(err, en, "more than %d own links", cap);
			return -1;
		}
		ids[*n] = id;
		infos[*n] = i;
		(*n)++;
	}
}

/* 固定の ID が期限までに消えるか。open は link_open か prog_open */
static inline enum own_state own_poll(const struct own_sys *s, int (*open_id)(uint32_t), uint32_t id, int ms, char *err, size_t en)
{
	int64_t end = s->now_ms() + ms;
	do {
		int fd = open_id(id);
		if (fd == -ENOENT)
			return OWN_GONE;
		if (fd < 0) {
			snprintf(err, en, "open %u: errno %d", id, -fd);
			return OWN_UNOBSERVED;
		}
		if (own_close(s, fd, err, en))
			return OWN_UNOBSERVED;
		s->sleep_ms(20);
	} while (s->now_ms() < end);
	return OWN_PRESENT;
}

struct window_ops {
	ssize_t (*read)(void *ctx, uint8_t *b, size_t n, int *outgoing); /* byte 数か -errno */
	int64_t (*now_ms)(void);
	void *ctx;
};

/* 期限まで読み match を数える。-1 は読みの誤り (*err に errno) */
static inline int window_count(const struct window_ops *w, int ms, int (*match)(const uint8_t *, ssize_t, void *), void *arg, int *err)
{
	int64_t end = w->now_ms() + ms;
	int got = 0;
	while (w->now_ms() < end) {
		uint8_t b[256];
		int out = 0;
		ssize_t n = w->read(w->ctx, b, sizeof b, &out);
		if (n == -EAGAIN || n == -EWOULDBLOCK || n == -EINTR)
			continue;
		if (n < 0) {
			*err = (int)-n;
			return -1;
		}
		if (!out && match(b, n, arg))
			got++;
	}
	return got;
}

/* H7: 既知の false の停止 — BML_TARGET_REJECTED (3) かつ Unmet が attach / filter / 向きの 1 件だけ。他の kind・読めない入力は手順の故障 */
static inline int stop_is_expected(int64_t kind, int64_t n_unmet, const char *u_kind, const char *u_prog, const char *u_name, const char *direction)
{
	return kind == 3 && n_unmet == 1 && u_kind && u_prog && u_name && !strcmp(u_kind, "attach") && !strcmp(u_prog, "filter") && !strcmp(u_name, direction);
}

/* sendto の 1 回の結果。PACKET_QDISC_BYPASS の送信は netkit の drop を ENOBUFS で返す (bpf-mlir E650 の実測)。drop の active の段は 8 回とも -1 / ENOBUFS、他の段は全 byte */
static inline int send_outcome_ok(ssize_t rc, int err, size_t want, int expect_drop)
{
	return expect_drop ? rc == -1 && err == ENOBUFS : rc == (ssize_t)want;
}

/* netkit の arm の段の順 (STOP の配線 — own_ids_unit が root なしで試す)。各段の返りは 0 か手順の故障 (値の不一致は段の check が数え、続ける)。
 * 手順の故障か保存の失敗が分かったら後続の attach / phase は 0 回、attach が済んでいれば detach、object の close は必ず。返りは手順の故障の有無 */
enum arm_phase { ARM_NO_LINK, ARM_ATTACHED, ARM_REVERSE, ARM_AFTER };
struct arm_steps {
	void *ctx;
	int (*own_program)(void *);
	int (*phase)(void *, enum arm_phase);
	int (*attach)(void *);
	int (*link_info)(void *);
	int (*detach_poll)(void *);
	int (*close_obj)(void *);
	int (*output_failed)(void *);
};
static inline int arm_bad(const struct arm_steps *s, int rc) { return rc != 0 || s->output_failed(s->ctx) != 0; }
static inline int arm_sequence(const struct arm_steps *s)
{
	int attached = 0, fault = arm_bad(s, s->own_program(s->ctx));
	if (!fault)
		fault = arm_bad(s, s->phase(s->ctx, ARM_NO_LINK));
	if (!fault) {
		int rc = s->attach(s->ctx);
		attached = rc == 0;
		fault = arm_bad(s, rc);
	}
	if (!fault)
		fault = arm_bad(s, s->link_info(s->ctx));
	if (!fault)
		fault = arm_bad(s, s->phase(s->ctx, ARM_ATTACHED));
	if (!fault)
		fault = arm_bad(s, s->phase(s->ctx, ARM_REVERSE));
	if (attached)
		fault |= arm_bad(s, s->detach_poll(s->ctx));
	if (!fault)
		fault = arm_bad(s, s->phase(s->ctx, ARM_AFTER));
	fault |= arm_bad(s, s->close_obj(s->ctx));
	return fault;
}

/* own_program_id.c (runner にだけ link)。0 か -1 (*err に名指し) */
int own_program_id(int64_t obj, const char *prog, uint32_t *id, char *err, size_t en);

/* ---- 実の syscall ---- */
static inline int own_real_link_next(uint32_t id, uint32_t *next) { return bpf_link_get_next_id(id, next) < 0 ? -errno : 0; }
static inline int own_real_link_open(uint32_t id) { int fd = bpf_link_get_fd_by_id(id); return fd < 0 ? -errno : fd; }
static inline int own_real_prog_open(uint32_t id) { int fd = bpf_prog_get_fd_by_id(id); return fd < 0 ? -errno : fd; }
static inline int own_real_link_info(int fd, struct bpf_link_info *o)
{
	__u32 l = sizeof *o;
	return bpf_link_get_info_by_fd(fd, o, &l) < 0 ? -errno : 0;
}
static inline int own_real_close(int fd) { return close(fd) != 0 ? -errno : 0; }
static inline int64_t own_real_now_ms(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
static inline void own_real_sleep_ms(int ms)
{
	struct timespec s = {ms / 1000, (long)(ms % 1000) * 1000000};
	nanosleep(&s, NULL);
}
static const struct own_sys own_real = {own_real_link_next, own_real_link_open, own_real_link_info, own_real_prog_open, own_real_close, own_real_now_ms, own_real_sleep_ms};

/* stdout の保存の失敗を結果に (raw を捨てて rc 0 にしない) */
static int run_out_failed;
static inline void run_flush(void)
{
	if (fflush(stdout) != 0 || ferror(stdout))
		run_out_failed = 1;
}

#endif
