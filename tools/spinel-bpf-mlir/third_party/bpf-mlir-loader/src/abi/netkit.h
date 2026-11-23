/* abi/netkit.h — netkit の attach の後の照合 (E067)。kernel に触れる操作は ops で渡し、失敗の経路を root なしで試す (test/abi/netkit_finish_unit.c)。 */
#ifndef BML_ABI_NETKIT_H
#define BML_ABI_NETKIT_H

#include <stdint.h>

#include <linux/bpf.h>

struct abi_nk_peer {
	uint32_t ifindex;
	int other_netns; /* 応答に IFLA_LINK_NETNSID が在る — ifindex の空間が primary と別 */
};

struct abi_nk_ops {
	void *ctx;
	/* 0: *out を埋めた、1: 応答に IFLA_LINK が無い、負: -errno */
	int (*peer)(void *ctx, uint32_t primary, struct abi_nk_peer *out);
	int (*info)(void *ctx, struct bpf_link_info *out); /* 0 か -errno */
	int (*close_link)(void *ctx);			   /* 0 か -errno */
};

/* attach に成功した link を照らす。0: 全て一致 (link は開いたまま)。-1: link を close し、*msg (malloc) に主因と close の誤りの両方を書いた */
int abi_netkit_finish(const char *name, uint32_t want_attach, uint32_t primary, uint32_t prog_id, const struct abi_nk_ops *ops, char **msg);

/* 呼び手の netns の RTM_GETLINK (ifindex で) の IFLA_LINK / IFLA_LINK_NETNSID。戻り値は abi_nk_ops の peer と同じ */
int abi_netkit_query_peer(uint32_t primary, struct abi_nk_peer *out);

#endif
