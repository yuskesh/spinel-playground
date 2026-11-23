/* bml_testonly.h — 試験の build だけの口 (E017 — -DBML_TEST_CAPS で build した library にだけ在る。製品の libbml.a に bml_testonly_ の symbol が
 * 無いことを gate が nm で確かめる)。mojo-bpf-mlir docs/loader_cabi.md の「試験の口」の着地 — 下流の試験 (照合しない load の対照・凍結・故意の
 * fault・uprobe の attach の変異) が使う。製品の code から呼ばないこと。 */
#ifndef BML_BML_TESTONLY_H
#define BML_BML_TESTONLY_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 照合しない load (段 3 の target の requirements の照合を飛ばす — schema・map の宣言・設定値・target の読みと guard 付きの load はする、
 * caps は live)。targets は bml_load_checked_targets と同じ (空は無し) */
int64_t bml_testonly_load_unchecked_targets(const uint8_t *elf, int64_t n, const char *sha, int64_t sha_len, const char *maps, int64_t maps_len,
					    const char *config, int64_t config_len, const char *targets, int64_t targets_len);
/* load の後の global への直の書き込み — OK で message に "libbpf=<誤り|nil> kernel=<誤り|nil>" (.rodata は凍結で kernel が拒否する見込み) */
int64_t bml_testonly_global_set_raw(int64_t obj, const char *name, int64_t len, int64_t bits);
/* map を freeze する (BPF_MAP_FREEZE) */
int64_t bml_testonly_freeze_map(int64_t obj, const char *name, int64_t len);
/* ring buffer の写像を munmap の後に読む故意の fault — 戻らない (SIGSEGV で process が落ちる) */
int64_t bml_testonly_ringbuf_fault(int64_t obj, const char *name, int64_t len);
/* uprobe の attach の変異: program の attach の file offset を別の symbol から計算する (sym が空なら戻す) */
int64_t bml_testonly_uprobe_symbol(const char *prog, int64_t prog_len, const char *sym, int64_t sym_len);
/* uprobe の file offset の計算の変異: "" (正しい — st_value − p_vaddr + p_offset)・"no_p_offset" (st_value − p_vaddr)・"vaddr" (st_value)。他は BML_OTHER */
int64_t bml_testonly_uprobe_offset_mode(const char *mode, int64_t mode_len);
/* tp_btf の attach の照らしの対照 (E024): 宣言の tracepoint の名前をこの名前に差し替える (len 0 で戻す)。127 byte を超えると BML_VALUE_RANGE */
int64_t bml_testonly_tpbtf_declared(const char *tp, int64_t len);
/* USDT の load と attach の形 (E044): "" (製品 — expected_attach_type 0 で load し点ごとの uprobe)・"multi" (libbpf の SEC_USDT の
 * BPF_TRACE_UPROBE_MULTI の書き換えを残し、uprobe_multi の 1 つの link)・"multi_perf" (書き換えを残し点ごとの uprobe — kernel の拒否の観測)。
 * 次の load から効く。他は BML_OTHER */
int64_t bml_testonly_usdt_mode(const char *mode, int64_t len);

#ifdef __cplusplus
}
#endif

#endif /* BML_BML_TESTONLY_H */
