/* spinel_diff — E007 の差動の driver: 操作の列 (stdin — tab 区切り) を spinelbpf_* の 25 export だけで走らせ、正規化した結果を 1 行ずつ出す。
 * 同じ source を spinel の Go の試験 archive と shim (libbml_spinel.a + libbml) に別々に link し、scripts/spinel-diff.sh が出力を比べる。
 *
 * 操作 (先頭の `~` は value と bytes を比べない — kind だけ。ktime 等の非決定の値を含みうる test run の後の読み):
 *   load <ELF> <sha> <maps.json の file> <caps>   close   unmet
 *   get <decl> <key>   put <decl> <key> <値>   getb <decl> <key> <n>   putb <decl> <key> <n> <seed|bad>
 *   hget <decl> <klen> <vlen> <kseed>   hput <decl> <klen> <vlen> <kseed> <vseed|bad>   hdel <decl> <klen> <kseed>   hkeys <decl> <klen> <cap>
 *   ropen <名前>   rread <timeout> <n>   rclose   run <prog> <回数>   runp <prog> <n> <udp|seed|bad>   attach <prog> <if>   detach
 * 出力: `<番号>\t<操作>\tkind=K\tvalue=V\tbytes=<hex|->\tmsg=<文の最初の行>` (handle の value は H に)。 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "shim/spinel/spinelbpf.h"

static int64_t obj = -1, rd = -1, lnk = -1;

static uint8_t *slurp(const char *path, int64_t *n)
{
	FILE *f = fopen(path, "rb");
	if (!f)
		return NULL;
	fseek(f, 0, SEEK_END);
	long l = ftell(f);
	fseek(f, 0, SEEK_SET);
	uint8_t *p = malloc((size_t)l + 1);
	if (p && fread(p, 1, (size_t)l, f) != (size_t)l) {
		free(p);
		p = NULL;
	}
	if (p)
		p[l] = 0;
	fclose(f);
	*n = l;
	return p;
}

static void fill(int64_t *a, int64_t n, const char *seed)
{
	long s = strtol(seed, NULL, 10);
	for (int64_t i = 0; i < n; i++)
		a[i] = (s * 31 + i * 7) & 0xff;
	if (!strcmp(seed, "bad") && n > 0)
		a[n - 1] = 300;
}

/* UDP の frame (Ethernet + IPv4 + UDP — 42 byte、abi_fixture.h と同じ) */
static const uint8_t udp[42] = {0x02, 0, 0, 0, 0, 0x02, 0x02, 0, 0, 0, 0, 0x01, 0x08, 0x00, 0x45, 0, 0x00, 0x1c, 0, 1, 0x00, 0x00, 64, 17,
				0,    0, 10, 0, 0, 1,    10,   0, 0, 2, 0x04, 0xd2, 0x00, 0x50, 0x00, 0x08, 0,    0};

static size_t g_klen;
static int cmp_keys(const void *a, const void *b)
{
	return memcmp(a, b, g_klen);
}

static void hex(const int64_t *a, int64_t n)
{
	for (int64_t i = 0; i < n; i++)
		printf("%02x", (unsigned)(a[i] & 0xff));
}

static void report(int idx, const char *op, int64_t r, int handle, const int64_t *bytes, int64_t n, int nd)
{
	int64_t k = spinelbpf_result_kind(r), v = spinelbpf_result_value(r);
	printf("%d\t%s\tkind=%lld\tvalue=", idx, op, (long long)k);
	if ((handle || nd) && k == 0)
		printf(nd ? "*" : "H");
	else
		printf("%lld", (long long)v);
	printf("\tbytes=");
	if (nd && k == 0 && bytes)
		printf("*");
	else if (k == 0 && bytes && n > 0)
		hex(bytes, n);
	else
		printf("-");
	const char *m = spinelbpf_result_message(r);
	printf("\tmsg=");
	for (const char *p = m ? m : ""; *p && *p != '\n'; p++)
		putchar(*p == '\t' ? ' ' : *p);
	printf("\n");
	fflush(stdout);
}

int main(void)
{
	char line[65536];
	int idx = 0;
	static int64_t buf[1 << 20], kb[1 << 16], vb[1 << 16];
	while (fgets(line, sizeof line, stdin)) {
		line[strcspn(line, "\n")] = 0;
		if (!line[0] || line[0] == '#')
			continue;
		char *f[8] = {0};
		int nf = 0;
		for (char *s = line, *t; nf < 8 && (t = strsep(&s, "\t"));)
			f[nf++] = t;
		int nd = f[0][0] == '~';
		const char *op = f[0] + nd;
		idx++;
		int64_t r = -1, n = 0;
		int handle = 0;
		const int64_t *bytes = NULL;
		if (!strcmp(op, "load")) {
			int64_t el = 0, ml = 0;
			uint8_t *elf = slurp(f[1], &el), *maps = slurp(f[3], &ml);
			r = spinelbpf_load_checked(elf, el, f[2], (char *)(maps ? maps : (uint8_t *)""), strtoll(f[4], NULL, 10));
			if (spinelbpf_result_kind(r) == 0)
				obj = spinelbpf_result_value(r);
			handle = 1;
			free(elf);
			free(maps);
			/* Unmet も比べる (行の列) */
			int64_t nu = spinelbpf_result_unmet_count(r);
			for (int64_t i = 0; i < nu; i++)
				printf("%d\tunmet\t%s\n", idx, spinelbpf_result_unmet(r, i));
		} else if (!strcmp(op, "close"))
			r = spinelbpf_close(obj);
		else if (!strcmp(op, "unmet")) {
			r = spinelbpf_object_unmet(obj);
			int64_t nu = spinelbpf_result_unmet_count(r);
			for (int64_t i = 0; i < nu; i++)
				printf("%d\tunmet\t%s\n", idx, spinelbpf_result_unmet(r, i));
		} else if (!strcmp(op, "get"))
			r = spinelbpf_map_get(obj, f[1], strtoll(f[2], NULL, 10));
		else if (!strcmp(op, "put"))
			r = spinelbpf_map_put(obj, f[1], strtoll(f[2], NULL, 10), strtoll(f[3], NULL, 10));
		else if (!strcmp(op, "getb")) {
			n = strtoll(f[3], NULL, 10);
			memset(buf, 0, sizeof(int64_t) * (size_t)(n > 0 && n < (1 << 20) ? n : 0));
			r = spinelbpf_map_get_bytes(obj, f[1], strtoll(f[2], NULL, 10), buf, n);
			bytes = buf;
		} else if (!strcmp(op, "putb")) {
			n = strtoll(f[3], NULL, 10);
			fill(buf, n > 0 && n < (1 << 20) ? n : 0, f[4]);
			r = spinelbpf_map_put_bytes(obj, f[1], strtoll(f[2], NULL, 10), buf, n);
		} else if (!strcmp(op, "hget")) {
			int64_t kl = strtoll(f[2], NULL, 10);
			n = strtoll(f[3], NULL, 10);
			fill(kb, kl > 0 && kl < (1 << 16) ? kl : 0, f[4]);
			memset(vb, 0, sizeof vb);
			r = spinelbpf_hash_get(obj, f[1], kb, kl, vb, n);
			bytes = vb;
		} else if (!strcmp(op, "hput")) {
			int64_t kl = strtoll(f[2], NULL, 10), vl = strtoll(f[3], NULL, 10);
			fill(kb, kl > 0 && kl < (1 << 16) ? kl : 0, f[4]);
			fill(vb, vl > 0 && vl < (1 << 16) ? vl : 0, f[5]);
			r = spinelbpf_hash_put(obj, f[1], kb, kl, vb, vl);
		} else if (!strcmp(op, "hdel")) {
			int64_t kl = strtoll(f[2], NULL, 10);
			fill(kb, kl > 0 && kl < (1 << 16) ? kl : 0, f[3]);
			r = spinelbpf_hash_delete(obj, f[1], kb, kl);
		} else if (!strcmp(op, "hkeys")) {
			int64_t kl = strtoll(f[2], NULL, 10), cap = strtoll(f[3], NULL, 10);
			memset(buf, 0, sizeof buf);
			r = spinelbpf_hash_keys(obj, f[1], kl, buf, cap);
			if (spinelbpf_result_kind(r) == 0 && kl > 0) { /* 列挙の順は hash の種で変わる — key を並べて比べる */
				int64_t cnt = spinelbpf_result_value(r);
				static uint8_t ks[1 << 20];
				for (int64_t i = 0; i < cnt * kl && i < (1 << 20); i++)
					ks[i] = (uint8_t)buf[i];
				g_klen = (size_t)kl;
				qsort(ks, (size_t)cnt, (size_t)kl, cmp_keys);
				for (int64_t i = 0; i < cnt * kl && i < (1 << 20); i++)
					buf[i] = ks[i];
				n = cnt * kl;
				bytes = buf;
			}
		} else if (!strcmp(op, "possible")) {
			r = spinelbpf_possible_cpus();
		} else if (!strcmp(op, "pget") || !strcmp(op, "pput")) {
			/* pget <decl> <klen> <vlen> <kseed|z> <delta>・pput <decl> <klen> <vlen> <kseed|z> <vseed|bad> <delta> — n は possible CPU の数から
			 * (get: P × round_up(vlen, 8)、put: P × vlen) に delta を足す (host と VM で P が違う) */
			int64_t pr = spinelbpf_possible_cpus(), P = spinelbpf_result_value(pr);
			spinelbpf_result_free(pr);
			int64_t kl = strtoll(f[2], NULL, 10), vl = strtoll(f[3], NULL, 10);
			if (!strcmp(f[4], "z"))
				memset(kb, 0, sizeof(int64_t) * (size_t)(kl > 0 && kl < (1 << 16) ? kl : 0));
			else
				fill(kb, kl > 0 && kl < (1 << 16) ? kl : 0, f[4]);
			if (!strcmp(op, "pget")) {
				n = P * ((vl + 7) / 8 * 8) + strtoll(f[5], NULL, 10);
				memset(buf, 0, sizeof(int64_t) * (size_t)(n > 0 && n < (1 << 20) ? n : 0));
				r = spinelbpf_percpu_get(obj, f[1], kb, kl, buf, n);
				bytes = buf;
			} else {
				int64_t pn = P * vl + strtoll(f[6], NULL, 10);
				fill(buf, pn > 0 && pn < (1 << 20) ? pn : 0, f[5]);
				r = spinelbpf_percpu_put(obj, f[1], kb, kl, buf, pn);
			}
		} else if (!strcmp(op, "ropen")) {
			r = spinelbpf_ringbuf_open(obj, f[1]);
			if (spinelbpf_result_kind(r) == 0)
				rd = spinelbpf_result_value(r);
			handle = 1;
		} else if (!strcmp(op, "rread")) {
			n = strtoll(f[2], NULL, 10);
			memset(buf, 0, sizeof(int64_t) * (size_t)(n > 0 && n < (1 << 20) ? n : 0));
			r = spinelbpf_ringbuf_read(rd, strtoll(f[1], NULL, 10), buf, n);
			bytes = buf;
		} else if (!strcmp(op, "rclose"))
			r = spinelbpf_ringbuf_close(rd);
		else if (!strcmp(op, "run"))
			r = spinelbpf_test_run_xdp(obj, f[1], strtoll(f[2], NULL, 10));
		else if (!strcmp(op, "runp")) {
			n = strtoll(f[2], NULL, 10);
			if (!strcmp(f[3], "udp"))
				for (int64_t i = 0; i < n; i++)
					buf[i] = i < 42 ? udp[i] : 0;
			else
				fill(buf, n > 0 && n < (1 << 20) ? n : 0, f[3]);
			r = spinelbpf_test_run_xdp_packet(obj, f[1], buf, n);
			n = 0;
		} else if (!strcmp(op, "attach")) {
			r = spinelbpf_attach_xdp(obj, f[1], f[2]);
			if (spinelbpf_result_kind(r) == 0)
				lnk = spinelbpf_result_value(r);
			handle = 1;
		} else if (!strcmp(op, "detach"))
			r = spinelbpf_detach(lnk);
		else {
			printf("%d\t%s\tUNKNOWN-OP\n", idx, op);
			continue;
		}
		report(idx, f[0], r, handle, bytes, n, nd);
		spinelbpf_result_free(r);
	}
	return 0;
}
