/*
 * otlp_cri.h — cgroup_id -> CRI container 名の解決 enricher (E315、ADR-014 層 2、第 3 号)。
 *
 * otlp_k8s (E304) は cgid を pod に解決するが、`k8s.container.name` には CRI 名解決の
 * 手段が無いため **container-id (hex)** をそのまま載せていた (E304/E310 の明示的な残課題)。
 * ここは静的スナップショット (SPNL_K8S_CRIMAP、run 開始時に crictl 由来で採取) で
 * cgid -> 実 container 名 (coredns / local-path-provisioner 等) を引き、`k8s.container.name`
 * を **実名**にする。funnel は last-writer-wins なので otlp_k8s の id 出力を後勝ちで上書きする。
 *
 * (A) userspace 結合 (codegen 無改変・record layout 不変)。probe は 1 文字も変えない。
 * 適用条件を満たさなければ (SPNL_K8S_CRIMAP 未設定 = 非 k8s / マップ無し、または cgid が
 * マップに無い) 完全 no-op で `k8s.container.name` は otlp_k8s の container-id のまま
 * = **E304/E310 と byte 同一** (E304 otlp_k8s / E310 otlp_peer と同じ no-op エンリッチャ・パターン)。
 *
 * 設定 (env、静的スナップショット。run 開始時に crictl 由来で採取):
 *   SPNL_K8S_CRIMAP  "<cgid> <container_name>" 行 (cgid = leaf cgroup inode、10 進)。
 *                    これが解決の gate。uidmap/ipmap と同型 (E304/E310)。
 *
 * 全 signal に適用 (process ctx の cgid を持ち得る経路すべて。registry の signal_mask で宣言)。
 * libbpf 非依存・pure C (host 単体テスト可、tests/runtime)。
 */
#ifndef SPNL_OTLP_CRI_H
#define SPNL_OTLP_CRI_H

#include <stdint.h>
#include "otlp_http.h"   /* otlp_kv_t */

#ifdef __cplusplus
extern "C" {
#endif

/* cgid を CRIMAP で container 名に解決。見つかれば name_out に詰めて 1、無ければ 0。
 * SPNL_K8S_CRIMAP 未設定なら常に 0 (完全 no-op)。 */
int spnl_cri_lookup(uint64_t cgid, char *name_out, int cap);

/* 便宜: cgid 1 個から attrs (k8s.container.name = 実 container 名) を詰める。詰めた件数 (0/1) を返す。
 * SPNL_K8S_CRIMAP 未設定 / cgid=0 / マップに無い / cap<=0 なら 0 (span byte 不変)。 */
int spnl_cri_enrich_attrs(uint64_t cgid, otlp_kv_t *attrs, int max);

#ifdef __cplusplus
}
#endif
#endif /* SPNL_OTLP_CRI_H */
