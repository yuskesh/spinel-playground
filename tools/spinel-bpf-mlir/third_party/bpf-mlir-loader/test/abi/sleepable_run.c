/* sleepable_run — E067 H6: fentry.s の実 load / attach (VM の root — 試験の build だけ)。
 *
 *   sleepable_run <copy.bpf.o> <schema の sha256>
 *
 * job ごとに load → attach → 同じ thread の getpgid(0) 1 回 → ringbuf の event を読む → detach → close。want は bpf-mlir E661 の実測と同じ値。
 * 各 check は "<id>: … — ok|FAIL" の 1 行、終わりに "sleepable_run: FAIL <n>"。手順の故障 (読み・detach・close・消失の未観測) の後の job は走らせない。 */
#define _GNU_SOURCE
#include <inttypes.h>
#include <stdarg.h>
#include <stdlib.h>
#include <sys/mman.h>

#include "bml/bml.h"
#include "run_own.h"
#include "tcx_fixture.h"

#define GONE_MS 15000 /* own の program の消失の期限 */
#define READ_MS 2000  /* 最初の event を待つ窓 */
#define EXTRA_MS 200  /* 余りの event を見る有限の窓 (1 回) */

#define D_EVENTS "{\"name\":\"events\",\"kind\":\"ringbuf\",\"key\":\"-\",\"value\":\"record:ev\",\"max_entries\":4096}"
#define R_EV "{\"ev\":{\"size\":24,\"members\":[{\"name\":\"status\",\"offset\":0,\"type\":\"i64\"},{\"name\":\"d\",\"offset\":8,\"type\":\"[16]u8\"}]}}"
#define MAPS "{\"records\":" R_EV ",\"globals\":[{\"name\":\"uaddr\",\"section\":\"rodata\",\"type\":\"u64\"}],\"maps\":[" D_EVENTS "]}"

static const uint8_t pattern[16] = {0x45, 0x36, 0x36, 0x31, 0xa5, 0x5a, 0xc3, 0x3c, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef};

static int fails;
static void check(const char *id, int good, const char *fmt, ...) __attribute__((format(printf, 3, 4)));
static void check(const char *id, int good, const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	printf("%s: ", id);
	vprintf(fmt, ap);
	printf(" — %s\n", good ? "ok" : "FAIL");
	va_end(ap);
	run_flush();
	fails += !good;
}

/* 0 は event を読んだ、1 は timeout の間に無い、-1 は読みの誤り */
static int read_one(int64_t reader, int ms, uint8_t *dst, int64_t *kind)
{
	int64_t r = bml_ringbuf_read(reader, ms, dst, 24);
	*kind = bml_result_kind(r);
	int64_t v = bml_result_value(r);
	bml_result_free(r);
	return *kind != 0 ? -1 : v == 1 ? 0 : 1;
}

static int result_kind_free(int64_t r)
{
	int k = (int)bml_result_kind(r);
	bml_result_free(r);
	return k;
}

/* 手順の故障なら 1 */
static int job(const char *j, const uint8_t *elf, int64_t n, const char *sha, uint64_t addr, int64_t want_status, const uint8_t *want_data)
{
	char id[64], cfg[128], msg[1024] = "", u[256] = "", err[128] = "";
	int fault = 0;
	snprintf(cfg, sizeof cfg, "{\"set\":{\"uaddr\":%" PRIu64 "}}", addr);
	int64_t r = bml_load_checked_config(elf, n, S(sha), S(MAPS), S(cfg), 0);
	int64_t kind = bml_result_kind(r), obj = bml_result_value(r), un = bml_result_unmet_count(r), ml = 0;
	const char *m = bml_result_message(r, &ml);
	snprintf(msg, sizeof msg, "%.*s", (int)ml, m ? m : "");
	if (un == 1) {
		const char *k = bml_result_unmet_field(r, 0, 0, NULL), *nm = bml_result_unmet_field(r, 0, 2, NULL);
		snprintf(u, sizeof u, "%s:%s", k ? k : "", nm ? nm : "");
	}
	bml_result_free(r);
	snprintf(id, sizeof id, "%s-load", j);
	check(id, kind == 0, "kind %" PRId64 " \"%s\", Unmet %" PRId64 " entries", kind, msg, un);
	snprintf(id, sizeof id, "%s-unmet", j);
	check(id, un == 1 && !strcmp(u, "helper_unknown:copy_from_user"), "\"%s\"", u);
	if (kind != 0)
		return 1;
	uint32_t pid = 0;
	if (own_program_id(obj, "prog", &pid, err, sizeof err))
		pid = 0;
	snprintf(id, sizeof id, "%s-own-id", j);
	check(id, pid != 0, "program ID %u (%s)", pid, err);
	err[0] = 0;
	fault |= pid == 0 || run_out_failed;

	int64_t rh = bml_ringbuf_open(obj, S(D_EVENTS), S(R_EV), 24);
	int rok = bml_result_kind(rh) == 0;
	int64_t reader = bml_result_value(rh);
	bml_result_free(rh);
	/* 手順の故障の後は attach を 0 回に (cleanup へ) */
	int64_t ak = -1, link = 0;
	snprintf(id, sizeof id, "%s-attach", j);
	if (rok && !fault) {
		int64_t a = bml_attach_fentry(obj, S("prog")), aml = 0;
		ak = bml_result_kind(a), link = bml_result_value(a);
		const char *am = bml_result_message(a, &aml);
		check(id, ak == 0, "attach kind %" PRId64 " \"%.*s\"", ak, (int)aml, am ? am : "");
		bml_result_free(a);
	} else {
		check(id, 0, "reader %d, procedure failure %d; attach not run", rok, fault);
	}
	fault |= !rok || ak != 0 || run_out_failed;

	uint8_t ev[24] = {0}, extra[24];
	int got = 0, more = 0, rd_err = 0;
	if (rok && ak == 0 && !fault) {
		(void)getpgid(0);
		int64_t rk = 0;
		int e = read_one(reader, READ_MS, ev, &rk);
		got = e == 0;
		rd_err |= e < 0;
		int64_t end = own_real_now_ms() + EXTRA_MS;
		while (!rd_err && own_real_now_ms() < end) {
			e = read_one(reader, EXTRA_MS, extra, &rk);
			rd_err |= e < 0;
			more += e == 0;
			if (e == 1)
				break;
		}
	}
	int64_t status = 0;
	memcpy(&status, ev, sizeof status);
	snprintf(id, sizeof id, "%s-event", j);
	check(id, !rd_err && got && more == 0 && status == want_status && !memcmp(ev + 8, want_data, 16),
	      "read errors %d, events %d (remainder %d), status %" PRId64 " (want %" PRId64 "), data %s", rd_err, got, more, status, want_status,
	      !memcmp(ev + 8, want_data, 16) ? "match" : "mismatch");
	fault |= rd_err;

	/* 主因があっても detach と reader / object の close へ必ず進む */
	int dk = ak == 0 ? result_kind_free(bml_detach(link)) : 0;
	int rc = rok ? result_kind_free(bml_ringbuf_close(reader)) : 0;
	int ck = result_kind_free(bml_close(obj));
	snprintf(id, sizeof id, "%s-close", j);
	check(id, dk == 0 && rc == 0 && ck == 0, "detach %d, reader %d, object %d", dk, rc, ck);
	fault |= dk || rc || ck;
	enum own_state st = pid ? own_poll(&own_real, own_real_prog_open, pid, GONE_MS, err, sizeof err) : OWN_UNOBSERVED;
	snprintf(id, sizeof id, "%s-gone", j);
	check(id, st == OWN_GONE, "own program %u state %d (%s)", pid, st, err);
	fault |= st != OWN_GONE;
	return fault || run_out_failed;
}

int main(int argc, char **argv)
{
	if (argc != 3) {
		fprintf(stderr, "sleepable_run <copy.bpf.o> <sha>\n");
		return 2;
	}
	int64_t n = 0;
	uint8_t *elf = slurp(argv[1], &n);
	if (!elf) {
		fprintf(stderr, "sleepable_run: cannot read %s\n", argv[1]);
		return 2;
	}
	uint8_t *good = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	uint8_t *bad = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (good == MAP_FAILED || bad == MAP_FAILED || mprotect(bad, 4096, PROT_NONE) != 0) {
		perror("sleepable_run: mmap");
		return 2;
	}
	memcpy(good, pattern, sizeof pattern);
	static const uint8_t zero[16];
	int stop = job("ok", elf, n, argv[2], (uint64_t)(uintptr_t)good, 0, pattern);
	if (!stop)
		job("efault", elf, n, argv[2], (uint64_t)(uintptr_t)bad, -14, zero);
	else
		check("efault-skipped", 0, "not run because of a procedure failure in the previous job");
	free(elf);
	printf("sleepable_run: FAIL %d\n", fails);
	run_flush();
	return fails || run_out_failed ? 1 : 0;
}
