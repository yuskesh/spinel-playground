/* caps/live_sockmap.c — sk_skb / sk_msg の attach_types の sockmap の link の probe (bpf-mlir E440 の kernel/internal/kload/attachctx.go の
 * sockmapLinkProbe の写し — E037、live_attach.c から呼ぶ): `r0 = 0; exit` を expected attach type で load し、受理なら空の小さな sockmap を作り
 * BPF_LINK_CREATE (cilium の link.AttachRawLink — fallback の無い生の link) で付けて**直ぐ閉じる** (map は空 — socket に効かない)。作れたら真、
 * EINVAL (6.10 より前の link_create は SK_SKB / SK_MSG を持たない) は偽、他は Unknown。PROG_ATTACH は使わない。 */
#define _GNU_SOURCE
#include "caps/live_internal.h"

#include <errno.h>
#include <linux/bpf.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "util/gostr.h"
#include "util/mutation.h"

#define UNK ": cannot be determined on this target" /* ErrUnknown の文 (unknownf の %w) */

static const uint8_t ret_zero[16] = {0xb7, 0, 0, 0, 0, 0, 0, 0, 0x95, 0, 0, 0, 0, 0, 0, 0};

int lv_sockmap_link_probe(struct bml_live *l, const char *pt_name, uint32_t pt, const char *at_name, uint32_t at, int *val, char **why)
{
	*val = 0;
	struct lv_prog p = {0};
	struct lv_res r;
	p.type = pt;
	p.attach_type = at;
	p.insns = ret_zero;
	p.n_insns = 2;
	p.license = "GPL";
	p.name = "ebpf_probe";
	p.log_mode = LV_LOG_0;
	if (lv_prog_load(l, &p, &r) != 0) {
		lv_res_free(&r);
		return -2; /* load の拒否は今の対の load の判定 (呼び手) */
	}
	int pfd = r.fd;
	/* cilium の NewMap (SockMap — key 4・value 4・1 個・名前 ebpf_probe) */
	union bpf_attr a;
	memset(&a, 0, sizeof a);
	a.map_type = BPF_MAP_TYPE_SOCKMAP;
	a.key_size = 4;
	a.value_size = 4;
	a.max_entries = 1;
	char nm[16];
	lv_obj_name(l, "ebpf_probe", nm);
	memcpy(a.map_name, nm, sizeof a.map_name);
	int mfd = lv_bpf(BPF_MAP_CREATE, &a, sizeof a);
	if (mfd < 0) {
		char *es = bml_go_errno_str(-mfd);
		if (asprintf(why, "%s with expected attach type %s loads, but creating a sockmap for the link probe failed (map create: %s%s)" UNK, pt_name, at_name,
			     es ? es : "", mfd == -EPERM ? " (MEMLOCK may be too low, consider rlimit.RemoveMemlock)" : "") < 0)
			*why = NULL;
		free(es);
		lv_close(pfd);
		return BML_Q_UNKNOWN;
	}
	memset(&a, 0, sizeof a);
	a.link_create.prog_fd = (uint32_t)pfd;
	a.link_create.target_fd = (uint32_t)mfd;
	a.link_create.attach_type = at;
	int lfd = BML_MUT("live.sockmap_link_einval") ? -EINVAL : lv_bpf(BPF_LINK_CREATE, &a, sizeof a);
	int rc = BML_Q_OK;
	if (lfd >= 0) {
		lv_close(lfd);
		*val = 1;
	} else if (lfd != -EINVAL) { /* EINVAL は sockmap の BPF_LINK_CREATE が無い (6.10 より前) — 偽 */
		char *es = bml_go_errno_str(-lfd);
		if (asprintf(why, "%s with expected attach type %s loads, but the sockmap link probe failed (create link: %s)" UNK, pt_name, at_name, es ? es : "") < 0)
			*why = NULL;
		free(es);
		rc = BML_Q_UNKNOWN;
	}
	lv_close(mfd);
	lv_close(pfd);
	return rc;
}
