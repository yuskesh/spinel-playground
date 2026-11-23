/*
 * otlp_enrich_test.c — E313/E315: 層 2 enricher レジストリ (ADR-014) の単体テスト。
 *
 * 検証内容:
 *  (1) registry introspection: 登録 3 個 (k8s -> cri -> peer)、per-signal 適用可否 (signal_mask)。
 *  (2) no-op: env 未設定なら CONN でも 0 属性 (span byte 不変) — forked child で確認
 *      (lazy init は one-shot なので親の状態を汚染しない)。
 *  (2b) E315 後方互換 (最重要ゲート): CRIMAP 未設定 -> k8s.container.name = container_id (E304 と byte 同一)。
 *  (2c) E315 CRI 解決 + last-writer-wins: CRIMAP 有 -> k8s.container.name = 実名 "coredns" を 1 個だけ
 *       (k8s の id を後勝ちで上書き、重複 append しない、他の k8s.* は温存)。
 *  (3) CONN: k8s (発信元 pod) + peer (宛先) の**両方**が適用され、**k8s 属性が peer 属性より
 *      先**に並ぶ (= otlp_agent.c の直呼び E304->E310 と byte 同一の順序)。
 *  (4) DNS: peer_addr を渡しても peer は signal_mask で除外され **k8s のみ** = E304 と byte 同一。
 *  (5) cap 上限を尊重。
 *
 * fake kubepods 階層を temp に作り、その container ディレクトリの inode を cgid として使うので
 * 実カーネル不要 (host = macOS / Linux で完結)。libbpf/nanopb 非依存。
 * cc -I src/runtime/otlp -I include で otlp_enrich.c + otlp_k8s.c + otlp_peer.c + otlp_cri.c と link。
 */
#include "otlp_enrich.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/types.h>

static int fails = 0;
#define CHK(cond, msg) do { if (cond) { printf("  ok: %s\n", msg); } \
    else { printf("  FAIL: %s\n", msg); fails++; } } while (0)

/* 属性配列で key の index を返す (無ければ -1)。 */
static int attr_idx(const otlp_kv_t *a, int n, const char *k) {
    for (int i = 0; i < n; i++) if (!strcmp(a[i].key, k)) return i;
    return -1;
}

static const char *POD_UID = "1d0ff866-8ef5-41f5-a2ee-0c1ddcd4c280";
static const char *CTR_ID  = "9b763adf6f512b686d81705fe1267700c1de5ab427f527a84ca949b6d7eec866";
static const char *POD_IP  = "10.42.0.20";

int main(void) {
    /* ---- fake kubepods 階層を temp に作る (container inode = cgid) ---- */
    char cgroot[] = "/tmp/e313_cg_XXXXXX";
    if (!mkdtemp(cgroot)) { perror("mkdtemp cgroot"); return 2; }
    char p1[512], p2[512], p3[512], p4[512];
    snprintf(p1, sizeof p1, "%s/kubepods", cgroot);                mkdir(p1, 0755);
    snprintf(p2, sizeof p2, "%s/burstable", p1);                   mkdir(p2, 0755);
    snprintf(p3, sizeof p3, "%s/pod%s", p2, POD_UID);              mkdir(p3, 0755);
    snprintf(p4, sizeof p4, "%s/%s", p3, CTR_ID);                  mkdir(p4, 0755);
    struct stat st;
    if (stat(p4, &st) != 0) { perror("stat container dir"); return 2; }
    uint64_t cgid = (uint64_t)st.st_ino;

    /* uid マップ / ip マップ (kubectl 由来を模擬) */
    char uidmap[] = "/tmp/e313_uid_XXXXXX";
    { int fd = mkstemp(uidmap); FILE *f = fdopen(fd, "w");
      fprintf(f, "%s kube-system/coredns-ccb96694c-5kpb7\n", POD_UID); fclose(f); }
    char ipmap[] = "/tmp/e313_ip_XXXXXX";
    { int fd = mkstemp(ipmap); FILE *f = fdopen(fd, "w");
      fprintf(f, "%s pod default echo-srv\n", POD_IP); fclose(f); }
    /* E315: CRIMAP (cgid -> 実 container 名)。container inode を coredns にマップ。 */
    char crimap[] = "/tmp/e315_cri_XXXXXX";
    { int fd = mkstemp(crimap); FILE *f = fdopen(fd, "w");
      fprintf(f, "%llu coredns\n", (unsigned long long)cgid); fclose(f); }

    /* ---- (1) registry introspection (env 非依存、lazy init は起こさない) ---- */
    printf("[enrich] (1) registry introspection\n");
    CHK(otlp_enrich_count() == 3, "3 enrichers registered (k8s, cri, peer)");
    const otlp_enricher_t *e0 = otlp_enrich_at(0);
    const otlp_enricher_t *e1 = otlp_enrich_at(1);
    const otlp_enricher_t *e2 = otlp_enrich_at(2);
    CHK(e0 && !strcmp(e0->name, "k8s"),  "slot 0 = k8s (先に適用)");
    CHK(e1 && !strcmp(e1->name, "cri"),  "slot 1 = cri (k8s の後 = container 名を後勝ち上書き)");
    CHK(e2 && !strcmp(e2->name, "peer"), "slot 2 = peer (最後に適用)");
    CHK(e0 && e0->signal_mask == OTLP_SIG_ALL, "k8s: 全 signal に適用");
    CHK(e1 && e1->signal_mask == OTLP_SIG_ALL, "cri: 全 signal に適用");
    CHK(e2 && (e2->signal_mask & OTLP_SIG_BIT(OTLP_SIGNAL_CONN)) != 0, "peer: CONN に適用");
    CHK(e2 && (e2->signal_mask & OTLP_SIG_BIT(OTLP_SIGNAL_DNS))  == 0, "peer: DNS には非適用");
    CHK(e2 && (e2->signal_mask & OTLP_SIG_BIT(OTLP_SIGNAL_HTTP)) == 0, "peer: HTTP には非適用");
    CHK(otlp_enrich_at(3) == NULL,  "範囲外 index -> NULL");
    CHK(otlp_enrich_at(-1) == NULL, "負 index -> NULL");

    /* ---- (2) no-op (env 未設定) を forked child で確認 (one-shot lazy を汚染しない) ---- */
    printf("[enrich] (2) no-op: env 未設定なら CONN でも 0 属性 (forked child)\n");
    { char empty[] = "/tmp/e313_empty_XXXXXX"; (void)mkdtemp(empty);   /* kubepods 無しの空 root */
      pid_t pid = fork();
      if (pid == 0) {
          unsetenv("SPNL_K8S_IPMAP");            /* peer off */
          unsetenv("SPNL_K8S_CRIMAP");           /* cri off */
          setenv("SPNL_K8S_CGROUP_ROOT", empty, 1);  /* kubepods 無し -> k8s disabled */
          otlp_enrich_ctx_t ec = { OTLP_SIGNAL_CONN, cgid, POD_IP };   /* 入力は在るのに */
          otlp_kv_t a[16];
          _exit(otlp_enrich_run(&ec, a, 16) == 0 ? 0 : 1);            /* 完全 no-op を期待 */
      }
      int stt = 0; waitpid(pid, &stt, 0);
      CHK(WIFEXITED(stt) && WEXITSTATUS(stt) == 0, "no env -> CONN でも 0 属性 (span byte 不変)");
    }

    /* ---- (2b) E315 後方互換 (最重要ゲート): CRIMAP 未設定 -> k8s.container.name = container_id ----
     * cri は no-op なので k8s の id 出力が残る = E304/E310 と byte 同一。forked child で
     * (one-shot lazy を親と分離、k8s だけ有効・CRIMAP 未設定)。 */
    printf("[enrich] (2b) E315 no CRIMAP -> k8s.container.name = container_id (E304 byte 同一)\n");
    { pid_t pid = fork();
      if (pid == 0) {
          setenv("SPNL_K8S_CGROUP_ROOT", cgroot, 1);
          setenv("SPNL_K8S_UIDMAP", uidmap, 1);
          unsetenv("SPNL_K8S_IPMAP");             /* peer off */
          unsetenv("SPNL_K8S_CRIMAP");            /* cri off = 後方互換 */
          otlp_enrich_ctx_t ec = { OTLP_SIGNAL_CONN, cgid, NULL };
          otlp_kv_t a[16]; int n = otlp_enrich_run(&ec, a, 16);
          int ci = attr_idx(a, n, "k8s.container.name");
          int ok = (ci >= 0 && !strcmp(a[ci].val, CTR_ID));   /* 実名でなく container id のまま */
          if (!ok) printf("  child: k8s.container.name=%s (want id)\n", ci>=0?a[ci].val:"(none)");
          _exit(ok ? 0 : 1);
      }
      int stt = 0; waitpid(pid, &stt, 0);
      CHK(WIFEXITED(stt) && WEXITSTATUS(stt) == 0,
          "no CRIMAP -> k8s.container.name = container_id (E304 と byte 同一)");
    }

    /* ---- (2c) E315 CRI 解決 + last-writer-wins: CRIMAP 有 -> 実名 "coredns"、重複なし ----
     * cri が k8s の container_id を後勝ちで上書き。k8s.container.name は 1 個だけ (append でなく置換)。 */
    printf("[enrich] (2c) E315 CRIMAP 有 -> k8s.container.name = coredns (実名、last-writer-wins)\n");
    { pid_t pid = fork();
      if (pid == 0) {
          setenv("SPNL_K8S_CGROUP_ROOT", cgroot, 1);
          setenv("SPNL_K8S_UIDMAP", uidmap, 1);
          unsetenv("SPNL_K8S_IPMAP");             /* peer off (CONN でも peer 無しに) */
          setenv("SPNL_K8S_CRIMAP", crimap, 1);   /* cri on: cgid -> coredns */
          otlp_enrich_ctx_t ec = { OTLP_SIGNAL_CONN, cgid, NULL };
          otlp_kv_t a[16]; int n = otlp_enrich_run(&ec, a, 16);
          /* k8s.container.name は実名 coredns、かつ 1 個だけ (last-writer-wins = 重複 append しない) */
          int cnt = 0, ci = -1;
          for (int i = 0; i < n; i++) if (!strcmp(a[i].key, "k8s.container.name")) { cnt++; ci = i; }
          int ok = (cnt == 1 && ci >= 0 && !strcmp(a[ci].val, "coredns"));
          /* 他の k8s.* (pod.name 等) は温存されている (上書きは container.name だけ) */
          int keep = attr_idx(a, n, "k8s.pod.name") >= 0;
          if (!ok) printf("  child: cnt=%d val=%s (want 1x coredns)\n", cnt, ci>=0?a[ci].val:"(none)");
          _exit((ok && keep) ? 0 : 1);
      }
      int stt = 0; waitpid(pid, &stt, 0);
      CHK(WIFEXITED(stt) && WEXITSTATUS(stt) == 0,
          "CRIMAP 有 -> k8s.container.name=coredns (実名) を 1 個だけ (last-writer-wins)");
    }

    /* ---- 親: env をセットしてから positive tests (lazy init は最初の enrich 呼で 1 回) ---- */
    setenv("SPNL_K8S_CGROUP_ROOT", cgroot, 1);
    setenv("SPNL_K8S_UIDMAP", uidmap, 1);
    setenv("SPNL_K8S_IPMAP", ipmap, 1);
    setenv("SPNL_K8S_POD_CIDR", "10.42.0.0/16", 1);
    setenv("SPNL_K8S_SVC_CIDR", "10.43.0.0/16", 1);
    setenv("SPNL_K8S_PEER_RDNS", "0", 1);

    /* ---- (3) CONN: k8s + peer 両方、k8s が peer より先 ---- */
    printf("[enrich] (3) CONN: k8s(発信元) + peer(宛先)、順序 k8s -> peer\n");
    { otlp_enrich_ctx_t ec = { OTLP_SIGNAL_CONN, cgid, POD_IP };
      otlp_kv_t a[16]; int n = otlp_enrich_run(&ec, a, 16);
      int i_k8s_ns   = attr_idx(a, n, "k8s.namespace.name");
      int i_k8s_pod  = attr_idx(a, n, "k8s.pod.name");
      int i_peer_pod = attr_idx(a, n, "peer.k8s.pod.name");
      int i_peer_ns  = attr_idx(a, n, "peer.k8s.namespace.name");
      CHK(i_k8s_ns  >= 0, "k8s.namespace.name 付与 (発信元 pod)");
      CHK(i_k8s_pod >= 0 && !strcmp(a[i_k8s_pod].val, "coredns-ccb96694c-5kpb7"),
          "k8s.pod.name=coredns-... (cgid->pod 解決)");
      CHK(i_peer_pod >= 0 && !strcmp(a[i_peer_pod].val, "echo-srv"),
          "peer.k8s.pod.name=echo-srv (宛先 IP 解決)");
      CHK(i_peer_ns >= 0, "peer.k8s.namespace.name 付与");
      /* byte-identical の肝: k8s 属性は peer 属性より前に並ぶ (registry 順) */
      CHK(i_k8s_pod < i_peer_pod, "k8s 属性が peer 属性より先 (span byte 順序)");
      CHK(i_k8s_ns  < i_peer_pod, "k8s.* 全体が peer.* の前");
    }

    /* ---- (4) DNS: peer_addr を渡しても peer は非適用 (signal_mask)、k8s のみ ---- */
    printf("[enrich] (4) DNS: peer_addr 有でも peer は除外 (mask) = E304 と byte 同一\n");
    { otlp_enrich_ctx_t ec = { OTLP_SIGNAL_DNS, cgid, POD_IP };   /* peer_addr を敢えて渡す */
      otlp_kv_t a[16]; int n = otlp_enrich_run(&ec, a, 16);
      CHK(attr_idx(a, n, "k8s.pod.name") >= 0, "DNS に k8s.pod.name (全 signal 適用)");
      CHK(attr_idx(a, n, "peer.k8s.pod.name") < 0,
          "DNS に peer.* は無し (peer は CONN 専用 = E304 と byte 同一)");
    }

    /* ---- (5) no-op (入力欠如) + cap 上限 ---- */
    printf("[enrich] (5) 入力欠如の no-op + cap 上限\n");
    { otlp_enrich_ctx_t ec = { OTLP_SIGNAL_CONN, 0, NULL };   /* cgid=0 + peer 無し */
      otlp_kv_t a[16]; int n = otlp_enrich_run(&ec, a, 16);
      CHK(n == 0, "cgid=0 + peer 無し -> 0 属性 (no-op)"); }
    { otlp_enrich_ctx_t ec = { OTLP_SIGNAL_CONN, cgid, POD_IP };
      otlp_kv_t a[2]; int n = otlp_enrich_run(&ec, a, 2);
      CHK(n <= 2, "cap=2 を超えて詰めない"); }

    /* best-effort cleanup */
    rmdir(p4); rmdir(p3); rmdir(p2); rmdir(p1); rmdir(cgroot);
    unlink(uidmap); unlink(ipmap); unlink(crimap);

    if (fails == 0) { printf("[enrich] PASS (registry: k8s->cri->peer, per-signal mask, byte-order, CRI last-writer-wins)\n"); return 0; }
    printf("[enrich] FAIL: %d\n", fails); return 1;
}
