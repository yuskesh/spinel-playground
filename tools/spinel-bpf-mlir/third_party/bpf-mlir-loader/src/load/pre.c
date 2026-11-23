/* load/pre.c — load の前の guard (E005): ELF の形 (bpf-mlir の ELF の狭い形 — R001 Q2 §0・§4.1、673 の ELF の集計) と、
 * libbpf の feature の判断 (feat_supported) の照らし合わせ。 */
#include "load/internal.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "btf/kernel.h"
#include "elf/elf.h"
#include "maps/arena.h"
#include "load/arena_extern.h"
#include "util/mutation.h"

int lb_fail(struct bml_load_result *r, int stage, const char *fmt, ...)
{
	struct bml_buf b = {0};
	char tmp[1024];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(tmp, sizeof tmp, fmt, ap);
	va_end(ap);
	bml_buf_adds(&b, tmp);
	r->stage = stage;
	free(r->msg);
	r->msg = bml_buf_take(&b);
	return -1;
}

const char *lb_feat_name(int f)
{
	switch (f) {
	case LBF_PROG_NAME: return "FEAT_PROG_NAME";
	case LBF_GLOBAL_DATA: return "FEAT_GLOBAL_DATA";
	case LBF_BTF: return "FEAT_BTF";
	case LBF_BTF_FUNC: return "FEAT_BTF_FUNC";
	case LBF_BTF_DATASEC: return "FEAT_BTF_DATASEC";
	case LBF_BTF_GLOBAL_FUNC: return "FEAT_BTF_GLOBAL_FUNC";
	case LBF_ARRAY_MMAP: return "FEAT_ARRAY_MMAP";
	case LBF_EXP_ATTACH_TYPE: return "FEAT_EXP_ATTACH_TYPE";
	case LBF_PROBE_READ_KERN: return "FEAT_PROBE_READ_KERN";
	case LBF_BTF_FLOAT: return "FEAT_BTF_FLOAT";
	case LBF_BTF_DECL_TAG: return "FEAT_BTF_DECL_TAG";
	case LBF_BTF_TYPE_TAG: return "FEAT_BTF_TYPE_TAG";
	case LBF_BTF_ENUM64: return "FEAT_BTF_ENUM64";
	case LBF_BTF_QMARK_DATASEC: return "FEAT_BTF_QMARK_DATASEC";
	}
	return "FEAT_?";
}

/* ---- ELF の形 ---- */

/* bpf-mlir の emitter の program の section の形 (ProgramKinds.def) と kind・test run の族 — guard の ELF の形の検め (E005 / E033) と C ABI の
 * test run の kind の判定 (E034 — 次に kind が増えたらこの表だけを直す) が 1 か所から引く。prefix は "<形>/<target>" (target は空でない) */
static const struct sec_def {
	const char *name;
	int prefix, wave1; /* wave1: E033 の波 1 (変異 load.wave1_sections_reject が外す)、2: E043 の波 2〜4 (変異 load.wave24_sections_reject が外す) */
	const char *kind;
	int family;
} sec_defs[] = {
	{".text", 0, 0, "", BML_RUN_NONE},
	{"xdp", 0, 0, "xdp", BML_RUN_XDP},
	{"tcx/ingress", 0, 0, "sched_cls", BML_RUN_SKB},
	{"tcx/egress", 0, 0, "sched_cls", BML_RUN_SKB},
	{"uprobe", 0, 0, "uprobe", BML_RUN_NONE},
	{"kprobe/", 1, 0, "kprobe", BML_RUN_NONE},
	{"uprobe/", 1, 0, "uprobe", BML_RUN_NONE},
	{"fentry/", 1, 0, "fentry", BML_RUN_TRACING},
	{"fexit/", 1, 0, "fexit", BML_RUN_TRACING},
	{"tp_btf/", 1, 0, "tp_btf", BML_RUN_TRACING},
	/* E033: bpf-mlir P120 の波 1 (libbpf の振る舞いは E033 の背景) */
	{"socket", 0, 1, "socket_filter", BML_RUN_SKB},
	{"action", 0, 1, "sched_act", BML_RUN_SKB},
	{"cgroup_skb/ingress", 0, 1, "cgroup_skb", BML_RUN_SKB},
	{"cgroup_skb/egress", 0, 1, "cgroup_skb", BML_RUN_SKB},
	{"lwt_in", 0, 1, "lwt_in", BML_RUN_SKB},
	{"lwt_out", 0, 1, "lwt_out", BML_RUN_SKB},
	{"lwt_xmit", 0, 1, "lwt_xmit", BML_RUN_SKB},
	{"flow_dissector", 0, 1, "flow_dissector", BML_RUN_FLOW},
	{"sk_lookup", 0, 1, "sk_lookup", BML_RUN_CTX},
	{"netfilter", 0, 1, "netfilter", BML_RUN_NF},
	{"uretprobe", 0, 1, "uretprobe", BML_RUN_NONE},
	{"uretprobe/", 1, 1, "uretprobe", BML_RUN_NONE}, /* E035: tree の uretprobe は uretprobe/<symbol> (E033 は照合で止まる ELF しか見ず書き漏らした) */
	{"syscall", 0, 1, "syscall", BML_RUN_CTX},
	{"raw_tp/", 1, 1, "raw_tp", BML_RUN_CTX},
	{"kretprobe/", 1, 1, "kretprobe", BML_RUN_NONE},
	{"iter/", 1, 1, "iter", BML_RUN_NONE},
	{"fmod_ret/", 1, 1, "fmod_ret", BML_RUN_TRACING},
	/* E040: 波 4 の tracepoint (libbpf の tracepoint+ — SEC_NONE・expected attach type 0、load の時に書き換えない)。attach は bml_attach_tracepoint */
	{"tracepoint/", 1, 0, "tracepoint", BML_RUN_NONE},
	/* E043: 波 2〜4 (bpf-mlir の ProgramAttaches.def の section — libbpf の振る舞いは E043 の背景)。test run の口は開かない (族 NONE)。
	 * freplace (load に target の program の fd が要る) と struct_ops (libbpf の map の作り直しと autoload の変更) は表に無い — 別の E */
	{"lsm/", 1, 2, "lsm", BML_RUN_NONE},
	{"lsm.s/", 1, 2, "lsm_s", BML_RUN_NONE},
	{"cgroup/sock_create", 0, 2, "cgroup_sock", BML_RUN_NONE},
	{"cgroup/sock_release", 0, 2, "cgroup_sock", BML_RUN_NONE},
	{"cgroup/post_bind4", 0, 2, "cgroup_sock", BML_RUN_NONE},
	{"cgroup/post_bind6", 0, 2, "cgroup_sock", BML_RUN_NONE},
	{"cgroup/bind4", 0, 2, "cgroup_sock_addr", BML_RUN_NONE},
	{"cgroup/bind6", 0, 2, "cgroup_sock_addr", BML_RUN_NONE},
	{"cgroup/connect4", 0, 2, "cgroup_sock_addr", BML_RUN_NONE},
	{"cgroup/connect6", 0, 2, "cgroup_sock_addr", BML_RUN_NONE},
	{"cgroup/sendmsg4", 0, 2, "cgroup_sock_addr", BML_RUN_NONE},
	{"cgroup/sendmsg6", 0, 2, "cgroup_sock_addr", BML_RUN_NONE},
	{"cgroup/recvmsg4", 0, 2, "cgroup_sock_addr", BML_RUN_NONE},
	{"cgroup/recvmsg6", 0, 2, "cgroup_sock_addr", BML_RUN_NONE},
	{"cgroup/getpeername4", 0, 2, "cgroup_sock_addr", BML_RUN_NONE},
	{"cgroup/getpeername6", 0, 2, "cgroup_sock_addr", BML_RUN_NONE},
	{"cgroup/getsockname4", 0, 2, "cgroup_sock_addr", BML_RUN_NONE},
	{"cgroup/getsockname6", 0, 2, "cgroup_sock_addr", BML_RUN_NONE},
	{"sockops", 0, 2, "sock_ops", BML_RUN_NONE},
	{"cgroup/dev", 0, 2, "cgroup_device", BML_RUN_NONE},
	{"cgroup/sysctl", 0, 2, "cgroup_sysctl", BML_RUN_NONE},
	{"cgroup/getsockopt", 0, 2, "cgroup_sockopt", BML_RUN_NONE},
	{"cgroup/setsockopt", 0, 2, "cgroup_sockopt", BML_RUN_NONE},
	{"lwt_seg6local", 0, 2, "lwt_seg6local", BML_RUN_NONE},
	{"sk_skb/stream_verdict", 0, 2, "sk_skb", BML_RUN_NONE},
	{"sk_skb/stream_parser", 0, 2, "sk_skb", BML_RUN_NONE},
	{"sk_msg", 0, 2, "sk_msg", BML_RUN_NONE},
	{"sk_reuseport", 0, 2, "sk_reuseport", BML_RUN_NONE},
	{"sk_reuseport/migrate", 0, 2, "sk_reuseport", BML_RUN_NONE},
	{"perf_event", 0, 2, "perf_event", BML_RUN_NONE},
	{"raw_tp.w/", 1, 2, "raw_tp_writable", BML_RUN_NONE},
	{"lirc_mode2", 0, 2, "lirc_mode2", BML_RUN_NONE},
	/* E044: USDT (libbpf の usdt+ — load の時の UPROBE_MULTI の書き換えは load.c の usdt_point_form が外す)。attach は bml_attach_usdt */
	{"usdt", 0, 0, "usdt", BML_RUN_NONE},
	/* E049: ksyscall (libbpf の ksyscall+ — KPROBE・SEC_NONE、load は kprobe と同じ。kretsyscall は bpf-mlir が出さない)。attach は bml_attach_ksyscall */
	{"ksyscall/", 1, 0, "ksyscall", BML_RUN_NONE},
	/* E067: 形式 30〜32 の section (BPF_F_SLEEPABLE の確かめは load.c)。test run の口は開かない。変異 load.target_sections_reject が段 A の停止に戻す */
	{"fentry.s/", 1, 3, "fentry", BML_RUN_NONE},
	{"netkit/primary", 0, 3, "netkit", BML_RUN_NONE},
	{"netkit/peer", 0, 3, "netkit", BML_RUN_NONE},
};

static const struct sec_def *sec_def_of(const char *n)
{
	int skip_w1 = BML_MUT("load.wave1_sections_reject"), skip_w24 = BML_MUT("load.wave24_sections_reject");
	for (size_t i = 0; n && i < sizeof sec_defs / sizeof *sec_defs; i++) {
		const struct sec_def *d = &sec_defs[i];
		if ((d->wave1 == 1 && skip_w1) || (d->wave1 == 2 && skip_w24) || (d->wave1 == 3 && BML_MUT("load.target_sections_reject")))
			continue;
		size_t l = strlen(d->name);
		if (d->prefix ? (strncmp(n, d->name, l) == 0 && n[l]) : strcmp(n, d->name) == 0)
			return d;
	}
	return NULL;
}

const char *bml_load_section_kind(const char *section, int *family)
{
	const struct sec_def *d = sec_def_of(section);
	if (family)
		*family = d ? d->family : BML_RUN_NONE;
	return d ? d->kind : NULL;
}

static int prog_section(const char *n)
{
	return sec_def_of(n) != NULL;
}

/* 中身の section (relocation の先になれる — debug と BTF と eh_frame) */
static int meta_section(const char *n)
{
	return strcmp(n, ".BTF") == 0 || strcmp(n, ".BTF.ext") == 0 || strcmp(n, ".eh_frame") == 0 || strncmp(n, ".debug_", 7) == 0;
}

static int data_section(const char *n)
{
	static const char *const exact[] = {"", ".symtab", ".strtab", ".shstrtab", "license", ".maps", ".rodata", ".bss",
					    ".ebpf_requirements", ".ebpf_records"};
	for (size_t i = 0; i < sizeof exact / sizeof *exact; i++)
		if (strcmp(n, exact[i]) == 0)
			return 1;
	return 0;
}

/* .maps の DATASEC の var の struct の member は libbpf の map の定義の中で bpf-mlir が使う名前だけ (pinning・values・inner map を拒む) */
static int check_maps_defs(const struct bml_elf *e, struct bml_load_result *r)
{
	const struct bml_elf_shdr *s = bml_elf_section(e, ".BTF");
	const uint8_t *p;
	size_t n;
	char *err = NULL;
	if (!s || bml_elf_section_data(e, s, &p, &n, &err) != 0) {
		free(err);
		return lb_fail(r, BML_LOAD_SHAPE, "the ELF has no readable .BTF");
	}
	uint8_t *raw = malloc(n ? n : 1);
	if (!raw)
		return lb_fail(r, BML_LOAD_SHAPE, "out of memory");
	memcpy(raw, p, n);
	struct bml_kbtf kb;
	if (bml_kbtf_from_raw(raw, n, &kb, &err) != 0) {
		int rc = lb_fail(r, BML_LOAD_SHAPE, "the ELF .BTF cannot be read: %s", err ? err : "?");
		free(err);
		return rc;
	}
	static const char *const allowed[] = {"type", "key", "value", "key_size", "value_size", "max_entries", "map_flags"};
	int rc = 0;
	for (uint32_t id = 1; id < kb.n && !rc; id++) {
		struct kbtf_type ds;
		bml_kbtf_type(&kb, id, &ds);
		if (ds.kind != KBTF_DATASEC || strcmp(ds.name, ".maps") != 0)
			continue;
		for (uint32_t i = 0; i < ds.vlen && !rc; i++) {
			struct kbtf_type var, st;
			bml_kbtf_type(&kb, bml_kbtf_u32(&kb, ds.aux + 12 * (size_t)i), &var);
			int cyc;
			bml_kbtf_type(&kb, bml_kbtf_underlying(&kb, var.size_type, &cyc), &st);
			if (var.kind != KBTF_VAR || cyc || st.kind != KBTF_STRUCT) {
				rc = lb_fail(r, BML_LOAD_SHAPE, "a .maps definition is not a struct variable");
				break;
			}
			for (uint32_t j = 0; j < st.vlen; j++) {
				struct kbtf_member m;
				bml_kbtf_member(&kb, &st, j, &m);
				int ok = 0;
				for (size_t k = 0; k < sizeof allowed / sizeof *allowed; k++)
					ok |= strcmp(m.name, allowed[k]) == 0;
				if (!ok && strcmp(m.name, "map_extra") == 0) {
					struct bml_arena_spec spec;
					char *why = NULL;
					ok = bml_arena_elf(e->data, e->len, var.name, &spec, &why) == 0;
					free(why);
				}
				if (!ok) {
					rc = lb_fail(r, BML_LOAD_SHAPE, "map %s has the definition field %s (not in the bpf-mlir ELF form — libbpf would act on it)",
						     var.name, m.name);
					break;
				}
			}
		}
	}
	bml_kbtf_free(&kb);
	return rc;
}

int lb_check_shape(const uint8_t *elf, size_t len, struct bml_load_result *r)
{
	struct bml_elf e;
	char *err = NULL;
	if (bml_elf_open(elf, len, &e, &err) != 0) {
		int rc = lb_fail(r, BML_LOAD_SHAPE, "the ELF cannot be read: %s", err ? err : "?");
		free(err);
		return rc;
	}
	int rc = 0;
	if (!e.is64 || e.big_endian || e.machine != 247 /* EM_BPF */)
		rc = lb_fail(r, BML_LOAD_SHAPE, "not a little-endian 64-bit BPF ELF");
	for (size_t i = 0; i < e.n_sections && !rc; i++) {
		const struct bml_elf_shdr *s = &e.sections[i];
		if (s->type == 4 /* SHT_RELA */) {
			rc = lb_fail(r, BML_LOAD_SHAPE, "section %s is RELA (bpf-mlir emits REL only)", s->name);
			break;
		}
		if (s->type != BML_SHT_REL) {
			if (!prog_section(s->name) && !meta_section(s->name) && !data_section(s->name))
				rc = lb_fail(r, BML_LOAD_SHAPE, "section %s is not in the bpf-mlir ELF form", s->name);
			continue;
		}
		/* relocation: program の section には R_BPF_64_64 (1)・R_BPF_64_32 (10)、BTF / debug には ABS64 (2)・ABS32 (3)・NODYLD32 (4) */
		const char *target = strncmp(s->name, ".rel", 4) == 0 ? s->name + 4 : "";
		int prog = prog_section(target), meta = meta_section(target);
		if (!prog && !meta) {
			rc = lb_fail(r, BML_LOAD_SHAPE, "relocation section %s targets a section outside the form", s->name);
			break;
		}
		const uint8_t *p;
		size_t n;
		if (bml_elf_section_data(&e, s, &p, &n, &err) != 0 || n % 16 != 0) {
			rc = lb_fail(r, BML_LOAD_SHAPE, "relocation section %s cannot be read", s->name);
			break;
		}
		for (size_t k = 0; k < n / 16; k++) {
			uint32_t type = (uint32_t)bml_elf_u64(&e, p + 16 * k + 8);
			int ok = prog ? (type == 1 || type == 10) : (type == 2 || type == 3 || type == 4);
			if (!ok) {
				rc = lb_fail(r, BML_LOAD_SHAPE, "relocation type %u in %s is outside the bpf-mlir ELF form", type, s->name);
				break;
			}
		}
	}
	free(err);
	if (!rc) {
		struct bml_elf_sym *syms = NULL;
		size_t ns = 0;
		err = NULL;
		if (bml_elf_symbols(&e, BML_SHT_SYMTAB, &syms, &ns, &err) != 0)
			rc = lb_fail(r, BML_LOAD_SHAPE, "the ELF has no symbol table");
		for (size_t i = 0; i < ns && !rc; i++) {
			if (syms[i].shndx == BML_SHN_UNDEF) {
				int proof=lb_arena_extern(&e,syms,ns,i,r);
				if(proof<0)rc=-1;
				else if(!proof)rc = lb_fail(r, BML_LOAD_SHAPE, "symbol %s is undefined (extern — libbpf would resolve it)", syms[i].name);
			}
			else if ((syms[i].other & 3) != 0)
				rc = lb_fail(r, BML_LOAD_SHAPE, "symbol %s is not STV_DEFAULT (libbpf would make it static — B5)", syms[i].name);
		}
		free(syms);
		free(err);
	}
	if (!rc)
		rc = check_maps_defs(&e, r);
	bml_elf_close(&e);
	return rc;
}

/* ---- libbpf の feature の判断 ---- */

/* btf の行の機能 → libbpf の feature (1 つの libbpf の feature が 2 つの機能を決める所がある — R001 Q2 §2.3) */
static int feat_of(const char *f)
{
	static const struct {
		const char *name;
		int feat;
	} t[] = {
		{"int", LBF_BTF}, {"ptr", LBF_BTF}, {"const", LBF_BTF}, {"array", LBF_BTF}, {"struct", LBF_BTF},
		{"func", LBF_BTF_FUNC}, {"func_proto", LBF_BTF_FUNC}, {"func_global", LBF_BTF_GLOBAL_FUNC},
		{"var", LBF_BTF_DATASEC}, {"datasec", LBF_BTF_DATASEC}, {"decl_tag", LBF_BTF_DECL_TAG},
		{"type_tag", LBF_BTF_TYPE_TAG}, {"enum", LBF_BTF}, {"enum64", LBF_BTF_ENUM64},
	};
	for (size_t i = 0; i < sizeof t / sizeof *t; i++)
		if (strcmp(t[i].name, f) == 0)
			return t[i].feat;
	return -1;
}

/* ELF の .BTF (libbpf の finalize の前 — sanitize の判断に効く型の kind・linkage・kflag・名前は finalize で変わらない) を libbpf の sanitize の
 * 規則に当てる: 書き換える型が在れば欠けた feature (LBF_*)、無ければ -1、BTF が読めなければ -2 */
int lb_btf_rewrite(const uint8_t *elf, size_t len)
{
	struct bml_elf e;
	char *err = NULL;
	const struct bml_elf_shdr *s;
	const uint8_t *p;
	size_t n;
	if (bml_elf_open(elf, len, &e, &err) != 0) {
		free(err);
		return -2;
	}
	s = bml_elf_section(&e, ".BTF");
	if (!s || bml_elf_section_data(&e, s, &p, &n, &err) != 0) {
		free(err);
		bml_elf_close(&e);
		return -2;
	}
	uint8_t *raw = malloc(n ? n : 1);
	if (!raw) {
		bml_elf_close(&e);
		return -2;
	}
	memcpy(raw, p, n);
	bml_elf_close(&e);
	struct bml_kbtf kb;
	if (bml_kbtf_from_raw(raw, n, &kb, &err) != 0) {
		free(err);
		return -2;
	}
	int has_datasec = feat_supported(NULL, LBF_BTF_DATASEC), has_decl_tag = feat_supported(NULL, LBF_BTF_DECL_TAG),
	    has_qmark = feat_supported(NULL, LBF_BTF_QMARK_DATASEC), has_func = feat_supported(NULL, LBF_BTF_FUNC),
	    has_func_global = feat_supported(NULL, LBF_BTF_GLOBAL_FUNC), has_float = feat_supported(NULL, LBF_BTF_FLOAT),
	    has_type_tag = feat_supported(NULL, LBF_BTF_TYPE_TAG), has_enum64 = feat_supported(NULL, LBF_BTF_ENUM64);
	int out = -1;
	for (uint32_t id = 1; id < kb.n && out < 0; id++) {
		struct kbtf_type t;
		bml_kbtf_type(&kb, id, &t);
		/* libbpf の if / else if の順のまま */
		if ((!has_datasec && t.kind == KBTF_VAR) || (!has_decl_tag && t.kind == KBTF_DECL_TAG))
			out = !has_datasec && t.kind == KBTF_VAR ? LBF_BTF_DATASEC : LBF_BTF_DECL_TAG;
		else if (!has_datasec && t.kind == KBTF_DATASEC)
			out = LBF_BTF_DATASEC;
		else if (!has_qmark && t.kind == KBTF_DATASEC && t.name[0] == '?')
			out = LBF_BTF_QMARK_DATASEC;
		else if (!has_func && (t.kind == KBTF_FUNC_PROTO || t.kind == KBTF_FUNC))
			out = LBF_BTF_FUNC;
		else if (!has_func_global && t.kind == KBTF_FUNC && t.vlen != 0)
			out = LBF_BTF_GLOBAL_FUNC; /* linkage (vlen) が static (0) でなければ static に書く */
		else if (!has_float && t.kind == KBTF_FLOAT)
			out = LBF_BTF_FLOAT;
		else if (!has_type_tag && t.kind == KBTF_TYPE_TAG)
			out = LBF_BTF_TYPE_TAG;
		else if (!has_enum64 && t.kind == KBTF_ENUM && t.kflag)
			out = LBF_BTF_ENUM64; /* kflag を消す — 立っていなければ byte は同じ */
		else if (!has_enum64 && t.kind == KBTF_ENUM64)
			out = LBF_BTF_ENUM64;
	}
	bml_kbtf_free(&kb);
	return out;
}

int lb_check_features(const uint8_t *elf, size_t len, const struct bml_requirements *req, const struct bml_caps *caps,
		      struct bml_load_result *r)
{
	if (BML_MUT("load.no_pre_features")) /* 変異の対照: load の後の guard だけで止まるかを見る */
		return 0;
	/* 1. 予測 (照合の btf_feature の答え) と libbpf の実際の判断の照らし合わせ — 食い違いは Unknown */
	for (size_t i = 0; i < req->n_btf_features && !BML_MUT("load.no_predict"); i++) { /* 変異の対照: sanitize の段を試す */
		const char *f = req->btf_features[i].p;
		int feat = feat_of(f);
		if (feat < 0)
			return lb_fail(r, BML_LOAD_PREDICT, "BTF feature %s has no libbpf feature to cross-check", f);
		int v = 0;
		char *m = NULL;
		int rc = caps && caps->btf_feature ? caps->btf_feature(caps->ctx, f, &v, &m) : BML_Q_UNKNOWN;
		free(m);
		if (rc != BML_Q_OK)
			return lb_fail(r, BML_LOAD_PREDICT, "BTF feature %s: the check has no answer to cross-check libbpf against", f);
		bool lb = feat_supported(NULL, feat);
		if (lb != (v != 0))
			return lb_fail(r, BML_LOAD_PREDICT,
				       "BTF feature %s: the check says %s but libbpf says %s %s — the prediction of the loader's rewrite cannot be trusted",
				       f, v ? "accepted" : "not accepted", lb_feat_name(feat), lb ? "supported" : "missing");
	}
	/* 2. BTF を載せる (B3) と、libbpf の sanitize が ELF の BTF を実際に書き換えるか (bpf_object__sanitize_btf — libbpf.c:3146-3244 の
	 * 型ごとの規則を写す)。sanitize は 8 つの feature のどれかが欠けると走る (btf_needs_sanitization) が、欠けた feature の型が BTF に
	 * 無ければ copy は byte で同じ (6.6 の FEAT_BTF_QMARK_DATASEC — E005)。書き換えの予測で止め、load の後の byte の比べが後ろの守り */
	if (!feat_supported(NULL, LBF_BTF))
		return lb_fail(r, BML_LOAD_SANITIZE, "libbpf says FEAT_BTF is missing — it would not load the BTF (B3)");
	int rw = lb_btf_rewrite(elf, len);
	if (rw >= 0)
		return lb_fail(r, BML_LOAD_SANITIZE, "libbpf says %s is missing and the BTF has types it would rewrite without saying so (B1)",
			       lb_feat_name(rw));
	if (rw == -2)
		return lb_fail(r, BML_LOAD_SANITIZE, "the ELF BTF cannot be read to predict libbpf's rewrite");
	/* 3. program と map の書き換え (P2〜P5) と helper の置き換え (P1 — probe_read_{kernel,user}[_str] を使う program があるとき) */
	static const int attr_feats[] = {LBF_PROG_NAME, LBF_GLOBAL_DATA, LBF_ARRAY_MMAP};
	for (size_t i = 0; i < sizeof attr_feats / sizeof *attr_feats; i++)
		if (!feat_supported(NULL, attr_feats[i]))
			return lb_fail(r, BML_LOAD_REWRITE, "libbpf says %s is missing — it would change the programs or maps without saying so",
				       lb_feat_name(attr_feats[i]));
	/* E019: FEAT_EXP_ATTACH_TYPE の欠けで libbpf が書き換えるのは SEC_EXP_ATTACH_OPT の定義の section の program だけ (expected_attach_type を 0 に)。
	 * libbpf の probe (cgroup_sock の load) は CAP_NET_ADMIN の無い権限で EPERM になり「欠け」と読む — ELF に関係なく止めると {bpf, perfmon} の
	 * fentry を止める (mojo E093)。当たる section が在る時だけ止める (ELF を読めなければ止める — fail closed) */
	if (!feat_supported(NULL, LBF_EXP_ATTACH_TYPE)) {
		const char *hit = NULL;
		struct bml_elf e;
		char *err = NULL;
		int open_ok = bml_elf_open(elf, len, &e, &err) == 0;
		free(err);
		for (size_t i = 0; open_ok && !hit && i < e.n_sections; i++)
			if ((e.sections[i].flags & BML_SHF_EXECINSTR) && lb_sec_exp_attach_opt(e.sections[i].name))
				hit = e.sections[i].name;
		char name[128] = "";
		if (hit)
			snprintf(name, sizeof name, "%s", hit);
		if (open_ok)
			bml_elf_close(&e);
		if (!open_ok || hit)
			return lb_fail(r, BML_LOAD_REWRITE,
				       "libbpf says FEAT_EXP_ATTACH_TYPE is missing — it would clear the expected attach type of the program in section %s without saying so",
				       open_ok ? name : "(the ELF cannot be read)");
	}
	for (size_t i = 0; i < req->n_programs; i++)
		for (size_t j = 0; j < req->programs[i].n_helpers; j++) {
			int64_t h = req->programs[i].helpers[j].id;
			if (h >= 112 && h <= 115 && !feat_supported(NULL, LBF_PROBE_READ_KERN))
				return lb_fail(r, BML_LOAD_REWRITE,
					       "program %s calls helper %lld but libbpf says FEAT_PROBE_READ_KERN is missing — it would replace the helper (P1)",
					       req->programs[i].symbol.p, (long long)h);
		}
	return 0;
}

const char *lb_errno(int e)
{
	static __thread char buf[256];
	char *s = bml_go_errno_str(e);
	snprintf(buf, sizeof buf, "%s", s ? s : "unknown error");
	free(s);
	return buf;
}
