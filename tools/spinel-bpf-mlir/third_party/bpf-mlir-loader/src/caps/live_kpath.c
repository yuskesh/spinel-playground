/* caps/live_kpath.c — kernel/core の findMember と、kfield の埋め込みの経路 a.b(.c) の段ごとの探索と型 struct:T の照らし (bpf-mlir E553 の
 * CheckKFields の写し — E054)。find_member は live_btf.c から移した (E009 / E018 の写しのまま — live_btf.c の行の上限) */
#include "caps/live_internal.h"

#include <stdlib.h>
#include <string.h>

#include "btf/kernel.h"
#include "util/gostr.h"
#include "util/mutation.h"

/* core の findMember (bpf-mlir v0.17.0 E315): 幅優先で最初の一致 — 直の member を先に見て、名前の無い member の型 (typedef と修飾を
 * 剥がした struct / union) の member の列を後ろに並べる。1 は見つけた (*out)、0 は無い、-1 は oom、-2 は訪れる列が BTF の型の数を超えた
 * (循環した anonymous の struct — Go の findMember は訪れた集合も上限も持たず終わらない。C は止める — E009 H4 の意図した違い)。
 * 変異 live.kfields_direct_only は直の member だけを見る (H3 の対照) */
/* v0.19.0 E326 (kernel/core の findMember): 訪れた anonymous な複合の型 (根の struct を含む) は 2 回目を積まない — 循環する BTF でも終わり、
 * 2 回目に出会ったかを *twice に (見つからない時の文の注)。1 は見つかった・0 は無い・-1 は memory の不足 */
static int find_member(const struct bml_kbtf *kb, uint32_t struct_id, const char *name, struct kbtf_member *out, int *twice)
{
	uint32_t *q = malloc(sizeof *q * 16);
	uint8_t *seen = calloc((size_t)kb->n + 2, 1);
	size_t head = 0, tail = 0, cap = 16;
	*twice = 0;
	if (!q || !seen) {
		free(q);
		free(seen);
		return -1;
	}
	if (struct_id <= kb->n)
		seen[struct_id] = 1;
	q[tail++] = struct_id;
	int rc = 0;
	while (head < tail && !rc) {
		struct kbtf_type t;
		bml_kbtf_type(kb, q[head++], &t);
		for (uint32_t j = 0; j < t.vlen && !rc; j++) {
			struct kbtf_member m;
			bml_kbtf_member(kb, &t, j, &m);
			if (strcmp(m.name, name) == 0) {
				*out = m;
				rc = 1;
				break;
			}
			if (m.name[0] || BML_MUT("live.kfields_direct_only"))
				continue;
			int cyc;
			uint32_t u = bml_kbtf_underlying(kb, m.type, &cyc);
			struct kbtf_type ut;
			bml_kbtf_type(kb, u, &ut);
			if (cyc || (ut.kind != KBTF_STRUCT && ut.kind != KBTF_UNION))
				continue; /* anonymous の複合でないもの — 黙って飛ばす (Go と同じ) */
			if (u <= kb->n && seen[u] && !BML_MUT("live.no_member_seen")) {
				*twice = 1;
				continue;
			}
			if (u <= kb->n)
				seen[u] = 1;
			if (tail == cap) {
				uint32_t *nq = realloc(q, sizeof *q * (cap *= 2));
				if (!nq) {
					rc = -1;
					break;
				}
				q = nq;
			}
			q[tail++] = u;
		}
	}
	free(q);
	free(seen);
	return rc;
}

/* CheckKFields の経路 (bpf-mlir E553): strings.Split(field, ".") の段ごとに findMember、twice は段の OR。途中の段の UnderlyingType が struct で
 * なければ無い (0)。変異 caps.kpath_leaf_only は途中の段を飛ばし、最後の段を根の struct で探す (H3 の対照 — 平らな答えの代用) */
int lv_find_member_path(const struct bml_kbtf *kb, uint32_t struct_id, const char *path, struct kbtf_member *out, int *twice)
{
	*twice = 0;
	if (BML_MUT("caps.kpath_leaf_only") && strrchr(path, '.'))
		path = strrchr(path, '.') + 1;
	uint32_t st = struct_id;
	for (const char *p = path;;) {
		const char *dot = strchr(p, '.');
		size_t n = dot ? (size_t)(dot - p) : strlen(p);
		char *part = strndup(p, n);
		if (!part)
			return -1;
		int seen = 0, rc = find_member(kb, st, part, out, &seen);
		free(part);
		*twice |= seen;
		if (rc <= 0 || !dot)
			return rc;
		int cyc;
		uint32_t u = bml_kbtf_underlying(kb, out->type, &cyc);
		struct kbtf_type ut;
		bml_kbtf_type(kb, u, &ut);
		if (cyc || ut.kind != KBTF_STRUCT)
			return 0;
		st = u;
		p = dot + 1;
	}
}

/* kfield の型 struct:T (bpf-mlir E553): 値の埋め込みの struct・名前 T・bitfield でない。0 は合う、1 は食い違い (文を b に) */
int lv_kfield_embedded(const struct bml_kbtf *kb, const struct kbtf_member *mb, const char *name, struct bml_buf *b)
{
	int cyc;
	struct kbtf_type t;
	bml_kbtf_type(kb, bml_kbtf_underlying(kb, mb->type, &cyc), &t);
	if (!cyc && t.kind == KBTF_STRUCT && !strcmp(t.name, name) && mb->bitfield_size == 0)
		return 0;
	bml_buf_adds(b, "the target field is ");
	bml_kbtf_format(kb, b, mb->type, 0, 's');
	bml_buf_addf(b, ", not embedded struct %s", name);
	return 1;
}
