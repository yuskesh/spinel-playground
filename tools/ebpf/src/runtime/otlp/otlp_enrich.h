/*
 * otlp_enrich.h — 層 2 (ADR-014) の enricher レジストリ (E313)。
 *
 * span push funnel (otlp_agent.c) は record ごとに attrs を組んだあと、ここの
 * otlp_enrich_run() を **1 回**呼ぶだけで、登録済みの全 enricher (k8s / peer / …) を
 * 順に適用する。各 enricher は「適用条件を満たせば属性を付与、満たさなければ 0
 * (no-op)」という共通形 (E304 で確立、ADR-014 層 2 の no-op エンリッチャ・パターン)。
 *
 *   otlp_k8s  (E304): cgroup_id -> k8s.*                     (全 signal に適用)
 *   otlp_cri  (E315): cgroup_id -> k8s.container.name=実名   (全 signal に適用、k8s の id を上書き)
 *   otlp_peer (E310): network.peer.address -> peer.k8s.* /   (conn signal のみに適用
 *                     network.peer.external                    = 宛先アドレスを持つ経路)
 *
 * **per-signal 適用可否は registry entry の signal_mask で宣言する** — どの record 型に
 * 適用されるかが enricher ごとに違う (k8s/cri=全経路、peer=conn のみ)。funnel は
 * ctx->signal を mask と突き合わせてから enricher を呼ぶ。
 *
 * **funnel は last-writer-wins** (E315): enricher が既存 key を再度出したら **後勝ちで置換**
 * (index 不変 = 順序保持)、新規 key は末尾 append。これで otlp_cri が otlp_k8s の
 * k8s.container.name=<id> を実 container 名で上書きできる。**key が衝突しない限り
 * 単純 append と byte-identical** (E304/E310 の後方互換は不変)。
 *
 * **出力順は g_enrichers[] の並び順 (k8s -> cri -> peer)。span byte を変えないため不変に保つ**
 * (属性の順序が変わると wire/golden が変わる。cri は既存 key の上書きなので新スロットを増やさない)。
 *
 * 将来の enricher #4 (cloud metadata 等) は otlp_enrich.c の g_enrichers[] に **1 行足すだけ**で
 * 全 (対象 signal の) span 経路に効く (E315 で cri を 1 行追加して実証)。
 *
 * libbpf 非依存・pure C (host 単体テスト可、tests/runtime/otlp_enrich_test.c)。
 */
#ifndef SPNL_OTLP_ENRICH_H
#define SPNL_OTLP_ENRICH_H

#include <stdint.h>
#include "otlp_http.h"   /* otlp_kv_t */

#ifdef __cplusplus
extern "C" {
#endif

/* span push 経路 (record の種別)。enricher の per-signal 適用可否に使う。 */
typedef enum {
    OTLP_SIGNAL_CONN   = 0,   /* E294/E296/E306 network connect span */
    OTLP_SIGNAL_DNS    = 1,   /* E295/E311 DNS query span */
    OTLP_SIGNAL_L7     = 2,   /* E297 L7 request/response span */
    OTLP_SIGNAL_HTTP   = 3,   /* E298/E299 HTTP L7 RED span */
    OTLP_SIGNAL_OFFCPU = 4,   /* E300/E312 off-CPU / request-tree parent span */
    OTLP_SIGNAL__COUNT = 5,
} otlp_signal_t;

/* enricher に渡す共通 context (record から必要な入力だけを運ぶ)。 */
typedef struct {
    otlp_signal_t signal;      /* どの span 経路か */
    uint64_t      cgid;        /* cgroup_id (0 = 無し、k8s enricher の入力) */
    const char   *peer_addr;   /* network.peer.address 文字列 (NULL = 無し、peer enricher の入力) */
} otlp_enrich_ctx_t;

/* enricher 1 個の実体。out[0..cap) に属性を詰め、詰めた件数を返す
 * (非適用 / no-op は 0)。 */
typedef int (*otlp_enrich_fn)(const otlp_enrich_ctx_t *ctx, otlp_kv_t *out, int cap);

typedef struct {
    const char    *name;         /* "k8s" / "peer" / … (introspection・デバッグ用) */
    uint32_t       signal_mask;  /* 適用する signal のビットマスク (OTLP_SIG_BIT) */
    otlp_enrich_fn enrich;
} otlp_enricher_t;

#define OTLP_SIG_BIT(s) (1u << (unsigned)(s))
#define OTLP_SIG_ALL    0xFFFFFFFFu

/* ctx に対して登録済みの全 enricher を signal_mask で判定しつつ順に適用し、
 * out[0..cap) に属性を追記する。詰めた総数を返す。 */
int otlp_enrich_run(const otlp_enrich_ctx_t *ctx, otlp_kv_t *out, int cap);

/* introspection (単体テスト用): 登録数 / i 番目の enricher (範囲外は NULL)。 */
int                    otlp_enrich_count(void);
const otlp_enricher_t *otlp_enrich_at(int i);

#ifdef __cplusplus
}
#endif
#endif /* SPNL_OTLP_ENRICH_H */
