// cmd/bml-precheck/precheck.h — bml-precheck の内部 (E002 — 構造の整理で main.c を分けた)
#ifndef BML_PRECHECK_H
#define BML_PRECHECK_H

#include <stddef.h>

#include "caps/caps.h"
#include "caps/live_caps.h"
#include "caps/recorder.h"
#include "maps/mapdecl.h"
#include "req/check.h"
#include "util/gostr.h"

enum { EXIT_OK_ = 0, EXIT_USAGE = 2, EXIT_REJECTED = 3, EXIT_SCHEMA = 4, EXIT_INVALID = 5, EXIT_PRECHECK = 6, EXIT_MAPS = 7 };

struct out {
	struct bml_buf err;
	int has_err;
	int has_parse_error;
	struct bml_parse_error pe;
	int object_format;
	const struct bml_loader_decl *loader;
	int has_probed_as;
	long long probed_uid;
	char *probed_cap;
	int has_load_as, reprobed; /* bpf-mlir E438 (E037): --caps の load の権限・--caps --live の再 probe */
	long long load_uid;
	char *load_cap;
	struct bml_unmets unmet;
	struct bml_map_problems mp; /* map_mismatch のとき (§12) */
};

struct flags {
	const char *loader, *loader_file, *caps, *schema, *hint, *requirements, *maps, *record, *load_as;
	int live, version, n_binary, n_ext_target;
	const char *binary[256];     /* --binary の値 (Go の flag の順) */
	const char *ext_target[256]; /* --ext-target の値 (bpf-mlir E425 — E036) */
	/* bpf-mlir E557 (E055): --debug-root (既定 /usr/lib/debug — 明示の空は探索しない、set は flag が在ったか) と繰り返しの --debug */
	const char *debug_root;
	int debug_root_set, n_debug;
	const char *debug[256];
	char **args;
	int n_args;
};

char *pc_read_file(const char *path, size_t *len, char **err);
/* 出力の JSON (ebpf-precheck 1) を stdout に書き、code を返す */
int pc_emit(struct out *o, const char *result, int code);
int pc_usage(struct out *o, const char *msg);
/* 2 つの宣言が Go の reflect.DeepEqual で同じか (map は nil と空を区別、中身は集合) */
int pc_decl_equal(const struct bml_loader_decl *a, const struct bml_loader_decl *b);
int pc_parse_flags(int argc, char **argv, struct flags *f, struct bml_buf *err);
int pc_load_loader_file(const char *path, struct bml_loader_decl *d, char **err);
/* 今の process の実効の uid と /proc/self/status の CapEff (Go の self — *cap は malloc) */
void pc_run_as(long long *uid, char **cap);
/* --live: --binary を開き (Go の newLiveCaps)、live の caps を作る。失敗は usage_error の文 (malloc)、成功は NULL */
char *pc_open_live(const struct flags *f, const struct bml_loader_decl *decl, struct bml_live_caps *lc, struct bml_caps *caps);
/* --record: caps.json を書く (Go の json.MarshalIndent + "\n"、0644)。失敗は usage_error の文 (malloc)、成功は NULL */
char *pc_write_record(struct bml_recorder *r, const char *path, long long uid, const char *cap, const struct bml_loader_decl *decl);

#endif
