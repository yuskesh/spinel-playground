/*
 * otlp_k8s_span_test.c — E302 Step 3: 既存 span (E293 型の file 監査 span) に k8s.* 属性を載せ、
 * OTLP protobuf に符号化して stdout に吐く。run スクリプトが protoc --decode で wire を検証し、
 * **実 pod 名** k8s.pod.name=coredns-... が span 属性に乗ることを確認する。
 *
 * cgroup_id は E302 VM で BPF が実測した 674 (= coredns container の cgroup inode)。host には
 * /sys/fs/cgroup が無いので inode walk (spnl_k8s_lookup_by_cgroup_id) の代わりに、VM が示した
 * cgroup パスを直接 parse -> resolve -> fill_attrs する (walk 自体は VM の E2E で実証済)。
 * (A) userspace 結合: span builder (otlp_traces_generic_build) は無改変、k8s.* を attrs に足すだけ。
 */
#include "otlp_traces.h"   /* otlp_generic_span_t, otlp_traces_generic_build */
#include "otlp_k8s.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>

/* 実測 (E302 VM): BPF cgroup_id 674 の container cgroup パス。 */
static const char *CGID_674_PATH =
  "/sys/fs/cgroup/kubepods/burstable/pod1d0ff866-8ef5-41f5-a2ee-0c1ddcd4c280/"
  "9b763adf6f512b686d81705fe1267700c1de5ab427f527a84ca949b6d7eec866";

int main(void)
{
    /* uid マップ (kubectl get pods 由来、E302 実測) を temp に。 */
    char tmpl[] = "/tmp/spnl_uidmap_span_XXXXXX";
    int fd = mkstemp(tmpl);
    FILE *mf = fdopen(fd, "w");
    fputs("1d0ff866-8ef5-41f5-a2ee-0c1ddcd4c280 kube-system/coredns-ccb96694c-5kpb7\n", mf);
    fclose(mf);

    /* cgroup_id 674 -> pod 解決 -> k8s.* 属性。 */
    spnl_k8s_pod_t pod;
    spnl_k8s_parse_kubepods_path(CGID_674_PATH, &pod);
    spnl_k8s_resolve_name(&pod, tmpl);
    unlink(tmpl);

    otlp_kv_t attrs[8];
    int n = 0;
    /* E293 型の file 監査 span 属性。 */
    snprintf(attrs[n].key, sizeof attrs[n].key, "file.path");
    snprintf(attrs[n].val, sizeof attrs[n].val, "/etc/shadow"); n++;
    snprintf(attrs[n].key, sizeof attrs[n].key, "process.executable.name");
    snprintf(attrs[n].val, sizeof attrs[n].val, "cat"); n++;
    snprintf(attrs[n].key, sizeof attrs[n].key, "verdict");
    snprintf(attrs[n].val, sizeof attrs[n].val, "deny"); n++;
    /* k8s.* enrich (cgroup_id -> pod)。 */
    n += spnl_k8s_fill_attrs(&pod, attrs + n, 8 - n);

    otlp_generic_span_t s;
    memset(&s, 0, sizeof s);
    for (int i = 0; i < 16; i++) s.trace_id[i] = (uint8_t)(0x30 + i);
    for (int i = 0; i < 8; i++)  s.span_id[i]  = (uint8_t)(0xa0 + i);
    s.has_parent = false;
    s.start_unix_ns = 1789000000000000000ULL;
    s.end_unix_ns   = 1789000000001000000ULL;
    s.name = "file_open /etc/shadow";
    s.kind = 0;          /* INTERNAL */
    s.is_error = true;   /* deny -> Span.status=ERROR */
    s.attrs = attrs; s.nattrs = n;

    static uint8_t buf[8192];
    long blen = otlp_traces_generic_build(buf, sizeof buf, "spinel-e302-k8s", "0.1",
                                          "spinel-ebpf", &s);
    if (blen < 0) { fprintf(stderr, "encode failed\n"); return 1; }
    fwrite(buf, 1, (size_t)blen, stdout);
    return 0;
}
