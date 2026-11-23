/* E066: 3 つの live の probe の Close の失敗 (link の --wrap で syscall を置き換える — kernel・root に触れない)。
 * Go の netkit.go・sleepable.go・helper_target.go の Close の扱い: netkit と sleepable は Unknown に戻す、helper_target は誤り。 */
#include "caps/live_internal.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* 台本: load は順に loads[] を返す (fd >= 0 は成功、-1 は失敗)。close は fail_fds の fd だけ -EIO */
static struct { int fd, err, verifier; const char *line; } loads[4];
static int n_loads, next_load, link_rc, closes, fail_a, fail_b;

int __wrap_lv_prog_load(struct bml_live *l, const struct lv_prog *p, struct lv_res *r)
{
	(void)l, (void)p;
	memset(r, 0, sizeof *r);
	if (next_load >= n_loads)
		abort();
	int i = next_load++;
	r->fd = loads[i].fd;
	if (loads[i].fd >= 0)
		return 0;
	r->err = loads[i].err;
	r->verifier = loads[i].verifier;
	if (loads[i].line) {
		r->lines = calloc(1, sizeof *r->lines);
		if (!r->lines || !(r->lines[0] = strdup(loads[i].line)))
			abort();
		r->n_lines = 1;
	}
	return -1;
}

int __wrap_lv_bpf(int cmd, void *attr, unsigned size)
{
	(void)cmd, (void)attr, (void)size;
	return link_rc;
}

int __wrap_lv_close_checked(int fd)
{
	closes++;
	return fd == fail_a || fd == fail_b ? -EIO : 0;
}

int __wrap_bml_live_func_args(struct bml_live *l, const char *name, const struct bml_str *args, size_t n, struct bml_strs *out, char **msg)
{
	(void)l, (void)name, (void)args, (void)n, (void)out, (void)msg;
	return BML_Q_OK;
}

static int fails;

static void script(int fa, int fb)
{
	n_loads = next_load = closes = 0;
	fail_a = fa, fail_b = fb;
}

static void load_ok(int fd) { loads[n_loads].fd = fd, loads[n_loads].err = 0, loads[n_loads].verifier = 0, loads[n_loads].line = NULL, n_loads++; }
static void load_bad(int err, int verifier, const char *line) { loads[n_loads].fd = -1, loads[n_loads].err = err, loads[n_loads].verifier = verifier, loads[n_loads].line = line, n_loads++; }

static void verdict(const char *name, int ok, char *msg)
{
	printf("%s: %s\n", name, ok ? "PASS" : "FAIL");
	if (!ok)
		fails++, printf("  msg=%s\n", msg ? msg : "(null)");
	free(msg);
}

#define HAS(m, s) ((m) && strstr((m), (s)))

static void netkit(const char *name, int rc, int fa, int fb, int want_st, int want_out, const char *want_text, int want_closes)
{
	struct bml_live l = {0};
	int out = 0;
	char *msg = NULL;
	script(fa, fb);
	load_ok(5);
	link_rc = rc;
	int st = bml_live_netkit(&l, "primary", &out, &msg);
	verdict(name, st == want_st && out == want_out && closes == want_closes && (!want_text || HAS(msg, want_text)), msg);
}

static void sleepable(const char *name, int want_st, int want_out, const char *want_text)
{
	struct bml_live l = {0};
	int out = 0;
	char *msg = NULL;
	int st = bml_live_sleepable(&l, "tracing", "trace_fentry", &out, &msg);
	verdict(name, st == want_st && out == want_out && (!want_text || HAS(msg, want_text)), msg);
}

static void helper_target(const char *name, int want_st, const char *want_text, size_t want_diffs)
{
	struct bml_live l = {0};
	struct bml_helper_target h = {0};
	struct bml_strs out = {0};
	char *msg = NULL;
	h.helper = (struct bml_str){(char *)"d_path", 6};
	h.attach_type = (struct bml_str){(char *)"trace_fentry", 12};
	h.target = (struct bml_str){(char *)"vfs_getattr", 11};
	h.arg_type = (struct bml_str){(char *)"path", 4};
	h.helper_id = 147;
	int st = bml_live_helper_target(&l, "tracing", 26, &h, &out, &msg);
	verdict(name, st == want_st && out.n == want_diffs && (!want_text || HAS(msg, want_text)), msg);
	bml_strs_free(&out);
}

int main(void)
{
	const char *close_prog = "close netkit probe program";

	netkit("nk-enodev-close-ok", -ENODEV, -9, -9, BML_Q_OK, 1, NULL, 1);
	netkit("nk-enodev-close-fail", -ENODEV, 5, -9, BML_Q_UNKNOWN, 0, close_prog, 1);
	netkit("nk-einval-close-fail", -EINVAL, 5, -9, BML_Q_UNKNOWN, 0, close_prog, 1);
	netkit("nk-eperm-close-fail", -EPERM, 5, -9, BML_Q_UNKNOWN, 0, close_prog, 1);
	netkit("nk-link-created-close-ok", 7, -9, -9, BML_Q_UNKNOWN, 0, "succeeded unexpectedly", 2);
	netkit("nk-link-close-fail", 7, 7, -9, BML_Q_UNKNOWN, 0, "close unexpected netkit link", 2);
	netkit("nk-link-and-prog-close-fail", 7, 7, 5, BML_Q_UNKNOWN, 0, close_prog, 2);

	script(-9, -9), load_ok(5);
	sleepable("sl-accept-close-ok", BML_Q_OK, 1, NULL);
	script(5, -9), load_ok(5);
	sleepable("sl-accept-close-fail", BML_Q_UNKNOWN, 0, "close the accepted sleepable probe program");
	script(-9, -9), load_bad(EINVAL, 1, "Program of this type cannot be sleepable"), load_ok(6);
	sleepable("sl-refused-close-ok", BML_Q_OK, 0, NULL);
	script(6, -9), load_bad(EINVAL, 1, "Program of this type cannot be sleepable"), load_ok(6);
	sleepable("sl-control-close-fail", BML_Q_UNKNOWN, 0, "close the control sleepable probe program");
	script(-9, -9), load_bad(EINVAL, 1, "x"), load_bad(EPERM, 0, NULL);
	sleepable("sl-both-load-fail", BML_Q_UNKNOWN, 0, "so did the control load");

	script(-9, -9), load_ok(5);
	helper_target("ht-accept-close-ok", BML_Q_OK, NULL, 0);
	script(5, -9), load_ok(5);
	helper_target("ht-accept-close-fail", BML_Q_ERROR, "helper_target close", 0);
	script(-9, -9), load_bad(EINVAL, 1, "helper call is not allowed in probe");
	helper_target("ht-denied-no-close", BML_Q_OK, NULL, 1);
	return fails != 0;
}
