/* caps/live_caps.h — live の caps (target の kernel に問う — E004) を照合の caps の形に。ebpf-precheck の `--live` と `--binary` の写し。 */
#ifndef BML_CAPS_LIVE_CAPS_H
#define BML_CAPS_LIVE_CAPS_H

#include "caps/caps.h"
#include "caps/live.h"

struct bml_live_bin {
	char *program, *path;
	int fd;
};

/* `--ext-target program=target` (bpf-mlir E425 — E036): 読めた BTF か読めなかった文 (照合で ext_target_unknown) */
struct bml_live_ext {
	char *program;
	int ok;
	struct bml_kbtf kb;
	char *err;
};

struct bml_live_caps {
	struct bml_live live;
	struct bml_live_bin *bins; /* `--binary program=path` (開いた fd — 照合の間持つ) */
	size_t n_bins;
	struct bml_live_ext *exts; /* 在るときだけ問い合わせ ext_targets を持つ (C ABI の live の caps は持たない) */
	size_t n_exts;
	const struct bml_loader_decl *decl; /* 宣言された loader (ebpf-precheck の liveCaps.Loader — NULL は Cilium022) */
	/* bpf-mlir E557 (E055): 分けた DWARF — debug_root が NULL は /usr/lib/debug、"" は探索しない (LiveCaps.UprobeDebugRoot)。debugs は
	 * program ごとの override (UprobeDebugPaths — 優先、失敗しても root に戻らない) */
	char *debug_root;
	struct bml_live_debug {
		char *program, *path;
	} *debugs;
	size_t n_debugs;
};

/* CONTRACT: caps valid while c is alive (the loader declaration is c->decl; NULL means Cilium022) */
void bml_live_caps(struct bml_live_caps *c, struct bml_caps *out);
void bml_live_caps_free(struct bml_live_caps *c);

#endif
