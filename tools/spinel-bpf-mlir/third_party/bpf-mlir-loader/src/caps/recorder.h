/* caps/recorder.h — 問い合わせの答えを記録する caps (bpf-mlir の go/requirements/recorder.go の Recorder の写し — E004)。
 *
 * 下の caps に問い、答えを (問い合わせ, 鍵) ごとに記録する (同じ鍵は後の答え)。kfields は kfield ごとに下の caps に問う (記録の鍵が
 * kfield ごと — 食い違いの文は kfield の並びで繋ぐ)。記録は caps.json (ebpf-caps 3 — E009) として Go の json.MarshalIndent と同じ byte で書く
 * (map の鍵の byte の順・HTML の escape・2 空白の字下げ・末尾の改行)。 */
#ifndef BML_CAPS_RECORDER_H
#define BML_CAPS_RECORDER_H

#include "caps/caps.h"

struct bml_recorder;

/* under は recorder より長く生きること */
struct bml_recorder *bml_recorder_new(const struct bml_caps *under);
void bml_recorder_free(struct bml_recorder *r);
/* 記録の caps (r が生きている間有効) */
void bml_recorder_caps(struct bml_recorder *r, struct bml_caps *out);
/* uprobe の binary の記録の path (Go の SetBinaryPath) */
int bml_recorder_set_binary(struct bml_recorder *r, const char *program, const char *path);
/* caps.json の byte (malloc)。loader は宣言された loader (--loader / --loader-file) */
char *bml_recorder_json(const struct bml_recorder *r, long long uid, const char *cap_eff, const struct bml_loader_decl *loader,
			size_t *len);

#endif
