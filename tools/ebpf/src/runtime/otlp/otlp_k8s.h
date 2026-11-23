/*
 * otlp_k8s.h — cgroup_id -> k8s pod 解決 (E302)。
 *
 * eBPF 側は cgroup_id() builtin (E302) で bpf_get_current_cgroup_id() = cgroup ディレクトリの
 * inode を emit する。userspace はここで cgroup_id を pod に解決し、semconv `k8s.*` 属性
 * (k8s.pod.uid / k8s.pod.name / k8s.namespace.name / k8s.container.name) を span に載せる。
 * これで「どの pod のどのプロセスが何をしたか」が Splunk APM で検索・相関できる。
 *
 * (A) userspace 結合 (codegen 無改変)。解決経路:
 *   cgroup_id (inode) --walk /sys/fs/cgroup/kubepods--> .../pod<UID>/<container-id>
 *                     --パス解析--> {qos, pod_uid, container_id}
 *   pod_uid --uid マップ (`kubectl get pods` 由来の "uid ns/name" ファイル)--> {namespace, pod_name}
 *
 * MVP: cgroupfs ドライバ形 (kubepods/<qos>/pod<UID>/<id>、k3s 既定) を解析。
 * systemd 形 (kubepods.slice/…-pod<UID>.slice/cri-containerd-<id>.scope) は E303+。
 * container 名の CRI 解決 (container_id -> name) も E303+ (MVP は container_id を載せる)。
 * libbpf 非依存・pure C (host 単体テスト可、tests/runtime)。
 */
#ifndef SPNL_OTLP_K8S_H
#define SPNL_OTLP_K8S_H

#include <stdint.h>
#include "otlp_http.h"   /* otlp_kv_t */

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    char pod_uid[40];        /* pod<UID> の UID (ダッシュ正規化済) */
    char container_id[68];   /* container cgroup ディレクトリ名 (CRI container id) */
    char qos[16];            /* besteffort / burstable / guaranteed */
    char namespace_[128];    /* uid マップから解決 (未解決なら空) */
    char pod_name[256];      /* uid マップから解決 (未解決なら空) */
    char deployment[256];    /* E310: owning workload (Deployment 等)。uid マップ 3 列目、無ければ空 */
    char service[256];       /* E310: pod を選択する Service。uid マップ 4 列目、無ければ空 */
    int  found;              /* 1 = kubepods の pod/container パスとして解析成功 */
} spnl_k8s_pod_t;

/* kubepods cgroup パス文字列から {qos, pod_uid, container_id} を抽出。
 * 例 /sys/fs/cgroup/kubepods/burstable/pod<UID>/<container-id>
 * pod ディレクトリ (container_id 無し) でも 1 を返す (container_id は空)。
 * kubepods パスでなければ 0。 */
int spnl_k8s_parse_kubepods_path(const char *cgroup_path, spnl_k8s_pod_t *out);

/* cgroup_root (通常 "/sys/fs/cgroup") 以下を walk し、inode == cgid のディレクトリを探して
 * spnl_k8s_parse_kubepods_path を適用。見つかれば 1 (Linux 専用 — /sys/fs/cgroup 必須)。 */
int spnl_k8s_lookup_by_cgroup_id(uint64_t cgid, const char *cgroup_root, spnl_k8s_pod_t *out);

/* pod_uid を uid マップファイルで解決 (kubectl 由来)。行形式は後方互換:
 *   "<uid> <namespace>/<name>"                          (E302/E304、最小)
 *   "<uid> <namespace>/<name> <deployment> <service>"    (E310、workload/service 追加列)
 * 見つかれば p->namespace_ / p->pod_name を埋め (あれば deployment/service も)、1 を返す。
 * 3/4 列目が "-" or 空なら該当フィールドは空のまま (属性を足さない)。 */
int spnl_k8s_resolve_name(spnl_k8s_pod_t *p, const char *uidmap_file);

/* 解決済 pod から semconv k8s.* 属性を attrs[] に詰める (空値は載せない)。詰めた件数を返す。
 * key: k8s.pod.uid / k8s.pod.name / k8s.namespace.name / k8s.container.name
 *      (+ E310: k8s.deployment.name / k8s.service.name が uid マップから解決できたとき) */
int spnl_k8s_fill_attrs(const spnl_k8s_pod_t *p, otlp_kv_t *attrs, int max);

/* 便宜: cgroup_id 1 個から attrs までを一括 (lookup -> resolve -> fill)。詰めた件数を返す。
 * cgroup_root/uidmap_file は NULL 可 (既定 "/sys/fs/cgroup" / 解決スキップ)。 */
int spnl_k8s_enrich_attrs(uint64_t cgid, const char *cgroup_root,
                          const char *uidmap_file, otlp_kv_t *attrs, int max);

#ifdef __cplusplus
}
#endif
#endif /* SPNL_OTLP_K8S_H */
