/*
 * otlp_peer.h — conn span の宛先 (network.peer.address) を pod / service / 外部に解決する
 * enricher (E310、ADR-014 層 2)。
 *
 * conn span (E294/E296/E306) は「通信先 IP:port」までしか持たない。ここで userspace が
 * その IP を k8s の identity に解決する:
 *   - internal-pod   : pod CIDR 内 & IP マップに有り → peer.k8s.pod.name / peer.k8s.namespace.name
 *   - internal-service: service CIDR 内 & IP マップに有り → peer.k8s.service.name / peer.k8s.namespace.name
 *   - external        : どの cluster CIDR にも入らない → network.peer.external=true (+ best-effort peer.hostname)
 *   - loopback/cluster-internal-unnamed: identity 無し (属性を足さない = 正直に no-op)
 *
 * E310 Step 0 の実測 (vz k3s v1.34): **pod→ClusterIP Service の active connect の
 * network.peer.address は ClusterIP** (backend pod IP ではない) だったため、service CIDR +
 * ClusterIP→service マップの解決が必須。pod→pod は pod IP、pod→外部は生の外部 IP。
 *
 * (A) userspace 結合 (codegen 無改変・conn record layout 不変)。probe は 1 文字も変えない。
 * 適用条件を満たさなければ (SPNL_K8S_IPMAP 未設定 = 非 k8s / マップ無し) 完全 no-op で
 * span は E294/E296/E306 と byte 同一 (E304 otlp_k8s と同じ no-op エンリッチャ・パターン)。
 *
 * 設定 (env、静的スナップショット。run 開始時に kubectl 由来で採取):
 *   SPNL_K8S_IPMAP     "ip kind ns name" 行 (kind = pod|service)。これが解決の gate。
 *   SPNL_K8S_POD_CIDR  例 "10.42.0.0/16" (未設定なら k3s 既定)
 *   SPNL_K8S_SVC_CIDR  例 "10.43.0.0/16" (未設定なら k3s 既定)
 *   SPNL_K8S_PEER_RDNS "1" で外部 IP の逆引き (peer.hostname、既定 off・cache 付き)
 *
 * libbpf 非依存・pure C (host 単体テスト可、tests/runtime)。
 */
#ifndef SPNL_OTLP_PEER_H
#define SPNL_OTLP_PEER_H

#include <stdint.h>
#include "otlp_http.h"   /* otlp_kv_t */

#ifdef __cplusplus
extern "C" {
#endif

enum {
    SPNL_PEER_NONE     = 0,  /* 未判定 / 属性なし */
    SPNL_PEER_POD      = 1,  /* pod CIDR & マップ有 */
    SPNL_PEER_SERVICE  = 2,  /* service CIDR & マップ有 */
    SPNL_PEER_EXTERNAL = 3,  /* cluster CIDR 外 */
    SPNL_PEER_LOOPBACK = 4,  /* 127.0.0.0/8 / ::1 */
    SPNL_PEER_CLUSTER  = 5,  /* cluster CIDR 内だがマップに名前なし (node gw 等) */
};

typedef struct {
    int  kind;
    char address[46];      /* ::ffff: を剥がした IP 文字列 */
    char namespace_[128];  /* pod/service の namespace */
    char name[256];        /* pod 名 or service 名 */
    char hostname[256];    /* 外部のみ: best-effort 逆引き (取れなければ空) */
} spnl_peer_t;

/* network.peer.address 文字列を分類する。kind を返す (spnl_peer_t.kind と同値)。
 * SPNL_K8S_IPMAP が未設定なら常に SPNL_PEER_NONE (完全 no-op)。 */
int spnl_peer_classify(const char *addr, spnl_peer_t *out);

/* 解決済 peer から semconv/独自属性を attrs[] に詰める (空値は載せない)。詰めた件数を返す。 */
int spnl_peer_fill_attrs(const spnl_peer_t *p, otlp_kv_t *attrs, int max);

/* 便宜: address 1 個から attrs までを一括 (classify -> fill)。詰めた件数を返す。
 * SPNL_K8S_IPMAP 未設定 / addr 空なら 0 (span byte 不変)。 */
int spnl_peer_enrich_attrs(const char *addr, otlp_kv_t *attrs, int max);

#ifdef __cplusplus
}
#endif
#endif /* SPNL_OTLP_PEER_H */
