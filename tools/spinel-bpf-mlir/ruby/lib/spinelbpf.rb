# spinelbpf — user 空間の側の loader の API (P001 §2・§3.6)。
#
# C の loader (bpf-mlir-loader の libbml と spinel の shim — P010、E044 で Go の c-archive を消した) を Spinel の FFI で呼ぶ。照合付きの load が唯一の入口
# (照合しない入口は作らない)。結果の種類ごとに例外の class を raise する (文言の照合で種類を決めない)。
#
# spinelbpf build が実行 file に埋め込む 3 つ (spinelbpf_elf_* ・spinelbpf_schema_sha・spinelbpf_maps_json) を weak の symbol で読む
# (埋め込みの無い program — 試験の driver — でも link できる)。
#
# **公開の API は単相** — 引数と戻り値の型が map の kind (整数 / record) で変わらない (map_get / map_get_record・map_put / map_put_record)。
# 多相の戻り値・引数は Spinel の whole-program の推論で利用者の program の eBPF の側の型を壊す (E021 / E022)。
# **loader との境界はこの file の C ABI (spinelbpf_* — 結果の kind・handle・宣言の JSON・文言) だけ**。API (load_embedded・map_get・attach_xdp・例外の class) は
# Go の型や cilium の意味に依らない — 将来 Go の無い loader に差し替えても利用者の code が変わらないように (利用者の決定 2026-09-27 — docs/status.md)。
#
# Spinel の Integer は i64 で INT64_MIN は nil の印 (docs/upstream_suspects.md S1)。map の値が Integer で表せないとき
# (u64 の 2^63 以上・符号付きの −2^63) は SpinelBPF::ValueRange を raise する — 黙って負の数や nil に化かさない。
require "bpf"

module SpinelBPFC
  ffi_source <<~C
    extern const unsigned char spinelbpf_elf_start[] __attribute__((weak));
    extern const unsigned char spinelbpf_elf_end[] __attribute__((weak));
    extern const char spinelbpf_schema_sha[] __attribute__((weak));
    extern const char spinelbpf_maps_json[] __attribute__((weak));
    extern const char spinelbpf_records[] __attribute__((weak));
    void *spinelbpf_embedded_elf(void) { return (void *)spinelbpf_elf_start; }
    long spinelbpf_embedded_elf_len(void) { return spinelbpf_elf_start ? (long)(spinelbpf_elf_end - spinelbpf_elf_start) : 0; }
    const char *spinelbpf_embedded_sha(void) { return spinelbpf_schema_sha ? spinelbpf_schema_sha : ""; }
    const char *spinelbpf_embedded_maps(void) { return spinelbpf_maps_json ? spinelbpf_maps_json : ""; }
    const char *spinelbpf_embedded_records(void) { return spinelbpf_records ? spinelbpf_records : ""; }
    /* 今の green thread と main (P012 E049 — Thread の定数を参照せずに: 参照すると全ての program が threaded の runtime になる。
       Spinel の内部の関数 — threaded でない program の current は 0 (E048 の TestSpinelThreadCurrent が性質を固定) */
    long spinelbpf_thread_current(void) { return (long)sp_Thread_current(); }
    long spinelbpf_thread_main(void) { return (long)sp_Thread_main(); }
    /* tracing (P013 E053): C の loader (bml b235ed6) の公開の bml_* を直に (spinel の shim に足さない — mojo と同じ形)。結果の handle は
       spinelbpf_result_* が読む (bml の結果と shim の結果は 1 つの handle の空間 — shim/spinel/result.c)。int64_t は x86_64 の long */
    #include <string.h>
    long bml_attach_fentry(long obj, const char *prog, long prog_len);
    long bml_attach_fexit(long obj, const char *prog, long prog_len);
    long bml_attach_kprobe(long obj, const char *prog, long prog_len);
    long bml_attach_kretprobe(long obj, const char *prog, long prog_len); /* P026 E111 — attach の後に関数の名前と KRETPROBE を照らす */
    long bml_attach_tp_btf(long obj, const char *prog, long prog_len); /* P021 E087 (bml E024) — attach の後に tp_name を宣言と照らす */
    long bml_test_run_tracing(long obj, const char *prog, long prog_len, long n);
    long bml_attach_raw_tp(long obj, const char *prog, long prog_len); /* P026 E113 — attach の後に raw tracepoint の名前を照らす */
    long bml_attach_tracepoint(long obj, const char *prog, long prog_len, long flags); /* P026 E114 — online の全ての CPU の perf の event に */
    long bml_attach_ksyscall(long obj, const char *prog, long prog_len); /* P026 E115 — syscall の wrapper の入口の kprobe、付けた後に wrapper の名前を照らす */
    long bml_test_run_ctx_inout(long obj, const char *prog, long prog_len, unsigned char *ctx_inout, long ctx_len);
    long bml_attach_fmod_ret(long obj, const char *prog, long prog_len); /* P028 E144 — 付けた後に link の attach type が MODIFY_RETURN か照らす */
    long spinelbpf_attach_trace(long obj, const char *prog, long kind) {
      long n = (long)strlen(prog);
      if (kind == 0) return bml_attach_fentry(obj, prog, n);
      if (kind == 8) return bml_attach_fmod_ret(obj, prog, n);
      if (kind == 1) return bml_attach_fexit(obj, prog, n);
      if (kind == 3) return bml_attach_tp_btf(obj, prog, n);
      if (kind == 4) return bml_attach_kretprobe(obj, prog, n);
      if (kind == 5) return bml_attach_raw_tp(obj, prog, n);
      if (kind == 7) return bml_attach_ksyscall(obj, prog, n);
      if (kind == 6) return bml_attach_tracepoint(obj, prog, n, 0); /* flags 0: possible と online の CPU が違えば誤り (後で online になる CPU を黙って落とさない) */
      return bml_attach_kprobe(obj, prog, n);
    }
    long spinelbpf_run_tracing(long obj, const char *prog, long n) { return bml_test_run_tracing(obj, prog, (long)strlen(prog), n); }
    /* sk_lookup の test run (P026 E129): struct bpf_sk_lookup (7.1.8 の UAPI — 68 byte + padding で 72) — family AF_INET・protocol・remote 127.0.0.1:40000・
       local 127.0.0.1:port (local_port は host の順)。戻り値は program の戻り値、kernel が ctx_out に書いた選んだ socket の cookie (無ければ 0) は sk_lookup_cookie で */
    static unsigned long long spinelbpf_skl_cookie = 0;
    long spinelbpf_run_sk_lookup(long obj, const char *prog, long proto, long port) {
      unsigned char c[72];
      memset(c, 0, sizeof c);
      unsigned int fam = 2, pr = (unsigned int)proto, lp = (unsigned int)port;
      memcpy(c + 8, &fam, 4);
      memcpy(c + 12, &pr, 4);
      c[16] = 127; c[19] = 1;          /* remote_ip4 127.0.0.1 (network の順) */
      c[36] = 40000 >> 8; c[37] = 40000 & 255; /* remote_port (network の順) */
      c[40] = 127; c[43] = 1;          /* local_ip4 127.0.0.1 */
      memcpy(c + 60, &lp, 4);          /* local_port (host の順) */
      long r = bml_test_run_ctx_inout(obj, prog, (long)strlen(prog), c, (long)sizeof c);
      memcpy(&spinelbpf_skl_cookie, c, 8);
      return r;
    }
    long spinelbpf_sk_lookup_cookie(void) { return (long)spinelbpf_skl_cookie; }
    /* raw_tp の test run (P026 E113): n 個 (1..12 — library が確かめる) の整数を u64 の args の配列 (n × 8 byte) に */
    long spinelbpf_run_raw_tp(long obj, const char *prog, long *args, long n) {
      unsigned long long a[12] = {0};
      for (long i = 0; i < n && i < 12; i++) a[i] = (unsigned long long)args[i];
      return bml_test_run_ctx_inout(obj, prog, (long)strlen(prog), (unsigned char *)a, n * 8);
    }
    /* sched_cls (P019 E077): tcx の attach・link の向き・tc (skb) の test run — tracing と同じく bml を直に。byte と長さは library (Ruby) が先に確かめる */
    #include <stdlib.h>
    long bml_attach_tcx(long obj, const char *prog, long prog_len, const char *ifname, long if_len);
    long bml_link_tcx_direction(long link);
    long bml_test_run_tc_data(long obj, const char *prog, long prog_len, const unsigned char *data, long n);
    long spinelbpf_attach_tcx(long obj, const char *prog, const char *ifname) { return bml_attach_tcx(obj, prog, (long)strlen(prog), ifname, (long)strlen(ifname)); }
    long spinelbpf_tcx_direction(long link) { return bml_link_tcx_direction(link); }
    /* socket_filter (P026 E126): 自分の socket への SO_ATTACH_BPF (link 無し — 値 0) と skb の test run */
    long bml_attach_socket(long obj, const char *prog, long prog_len, long sock_fd);
    long bml_test_run_skb_data(long obj, const char *prog, long prog_len, const unsigned char *data, long n);
    long spinelbpf_attach_socket(long obj, const char *prog, long fd) { return bml_attach_socket(obj, prog, (long)strlen(prog), fd); }
    long bml_attach_cgroup(long obj, const char *prog, long prog_len, long cgroup_fd); /* P026 E127: BPF_LINK_CREATE — link を返す */
    long spinelbpf_attach_cgroup(long obj, const char *prog, long fd) { return bml_attach_cgroup(obj, prog, (long)strlen(prog), fd); }
    long bml_attach_netfilter(long obj, const char *prog, long prog_len, long pf, long hooknum, long priority, long flags); /* P026 E128: 呼ぶ thread の netns */
    long bml_test_run_netfilter(long obj, const char *prog, long prog_len, const unsigned char *data, long n, long pf, long hook);
    long spinelbpf_attach_netfilter(long obj, const char *prog, long pf, long hooknum, long priority) { return bml_attach_netfilter(obj, prog, (long)strlen(prog), pf, hooknum, priority, 0); }
    long bml_attach_netns(long obj, const char *prog, long prog_len, long netns_fd); /* P026 E130: sk_lookup・flow_dissector を netns に link で */
    long bml_test_run_flow_dissector(long obj, const char *prog, long prog_len, const unsigned char *data, long n, unsigned char *keys_out, long keys_cap);
    long spinelbpf_attach_netns(long obj, const char *prog, long fd) { return bml_attach_netns(obj, prog, (long)strlen(prog), fd); }
    static unsigned char spinelbpf_fk[56]; /* 最後の flow の test run の struct bpf_flow_keys (P026 E130) */
    long spinelbpf_run_flow(long obj, const char *prog, long *bytes, long n) {
      unsigned char *b = malloc(n > 0 ? (size_t)n : 1);
      if (!b) abort();
      for (long i = 0; i < n; i++) b[i] = (unsigned char)bytes[i];
      memset(spinelbpf_fk, 0, sizeof spinelbpf_fk);
      long r = bml_test_run_flow_dissector(obj, prog, (long)strlen(prog), b, n, spinelbpf_fk, (long)sizeof spinelbpf_fk);
      free(b);
      return r;
    }
    /* key の i 番目 (SpinelBPF::FLOW_KEYS の順 — offset と幅は struct bpf_flow_keys の UAPI、little endian) */
    long spinelbpf_flow_key(long i) {
      static const int off[20] = {0, 2, 4, 6, 7, 8, 9, 10, 12, 14, 16, 20, 24, 28, 32, 36, 40, 44, 48, 52};
      static const int wid[20] = {2, 2, 2, 1, 1, 1, 1, 2, 2, 2, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4};
      if (i < 0 || i >= 20) return -1;
      long v = 0;
      for (int k = wid[i] - 1; k >= 0; k--) v = (v << 8) | spinelbpf_fk[off[i] + k];
      return v;
    }
    /* uprobe (P020 E081): target は load の引数 (JSON — bml が path を 1 回開いた fd を照合と attach に共有)・attach は照合した fd・link の file */
    long bml_load_checked_targets(const unsigned char *elf, long n, const char *sha, long sha_len, const char *maps, long maps_len, const char *config, long config_len, const char *targets, long targets_len, long caps_kind);
    long bml_attach_uprobe(long obj, const char *prog, long prog_len, long pid);
    long bml_attach_uretprobe(long obj, const char *prog, long prog_len, long pid); /* P026 E112 */
    long bml_uprobe_link_file(long obj, long link);
    long spinelbpf_load_targets(void *elf, long n, const char *sha, const char *maps, const char *config, const char *targets, long caps) {
      return bml_load_checked_targets((const unsigned char *)elf, n, sha, (long)strlen(sha), maps, (long)strlen(maps), config, (long)strlen(config), targets, (long)strlen(targets), caps);
    }
    long spinelbpf_attach_uprobe(long obj, const char *prog, long pid) { return bml_attach_uprobe(obj, prog, (long)strlen(prog), pid); }
    long spinelbpf_attach_uretprobe(long obj, const char *prog, long pid) { return bml_attach_uretprobe(obj, prog, (long)strlen(prog), pid); }
    long spinelbpf_uprobe_link_file(long obj, long link) { return bml_uprobe_link_file(obj, link); }
    long spinelbpf_run_tc_packet(long obj, const char *prog, long *bytes, long n) {
      unsigned char *b = malloc(n > 0 ? (size_t)n : 1);
      if (!b) abort(); /* 64 KiB 以下 — 確保できなければ黙って続けない */
      for (long i = 0; i < n; i++) b[i] = (unsigned char)bytes[i];
      long r = bml_test_run_tc_data(obj, prog, (long)strlen(prog), b, n);
      free(b);
      return r;
    }
    long spinelbpf_run_skb_packet(long obj, const char *prog, long *bytes, long n) { /* P026 E126 (run_tc_packet と同じ形) */
      unsigned char *b = malloc(n > 0 ? (size_t)n : 1);
      if (!b) abort();
      for (long i = 0; i < n; i++) b[i] = (unsigned char)bytes[i];
      long r = bml_test_run_skb_data(obj, prog, (long)strlen(prog), b, n);
      free(b);
      return r;
    }
    long spinelbpf_run_netfilter(long obj, const char *prog, long *bytes, long n, long pf, long hook) { /* P026 E128 */
      unsigned char *b = malloc(n > 0 ? (size_t)n : 1);
      if (!b) abort();
      for (long i = 0; i < n; i++) b[i] = (unsigned char)bytes[i];
      long r = bml_test_run_netfilter(obj, prog, (long)strlen(prog), b, n, pf, hook);
      free(b);
      return r;
    }
    /* global 変数 (P014 E058): load の設定値 (config の JSON) と global の読み — bml を直に */
    long bml_load_checked_config(const unsigned char *elf, long n, const char *sha, long sha_len, const char *maps, long maps_len, const char *config, long config_len, long caps_kind);
    long bml_global_get(long obj, const char *decl, long decl_len);
    long spinelbpf_load_config(void *elf, long n, const char *sha, const char *maps, const char *config, long caps) {
      return bml_load_checked_config((const unsigned char *)elf, n, sha, (long)strlen(sha), maps, (long)strlen(maps), config, (long)strlen(config), caps);
    }
    long spinelbpf_global_get(long obj, const char *decl) { return bml_global_get(obj, decl, (long)strlen(decl)); }
    /* lpm_trie (P026 E121): bml E016 の bml_lpm_* を直に (shim に lpm の口は無い)。prefix / address は文字列のまま bml が読む (IPv6・不正・host の bit は kernel に
       触らずに OTHER)。put の値は library が宣言の型で先に確かめる (bml は値の幅に黙って切る) */
    long bml_lpm_check_prefix(const char *prefix, long len);
    long bml_lpm_put(long obj, const char *decl, long decl_len, const char *prefix, long prefix_len, long bits);
    long bml_lpm_remove(long obj, const char *decl, long decl_len, const char *prefix, long prefix_len);
    long bml_lpm_match(long obj, const char *decl, long decl_len, const char *addr, long addr_len);
    long bml_lpm_list(long obj, const char *decl, long decl_len);
    long spinelbpf_lpm_prefix(const char *prefix) { return bml_lpm_check_prefix(prefix, (long)strlen(prefix)); }
    long spinelbpf_lpm_put(long obj, const char *decl, const char *prefix, long bits) { return bml_lpm_put(obj, decl, (long)strlen(decl), prefix, (long)strlen(prefix), bits); }
    long spinelbpf_lpm_remove(long obj, const char *decl, const char *prefix) { return bml_lpm_remove(obj, decl, (long)strlen(decl), prefix, (long)strlen(prefix)); }
    long spinelbpf_lpm_match(long obj, const char *decl, const char *addr) { return bml_lpm_match(obj, decl, (long)strlen(decl), addr, (long)strlen(addr)); }
    long spinelbpf_lpm_list(long obj, const char *decl) { return bml_lpm_list(obj, decl, (long)strlen(decl)); }
  C
  ffi_func :spinelbpf_embedded_elf, [], :ptr
  ffi_func :spinelbpf_embedded_elf_len, [], :long
  ffi_func :spinelbpf_embedded_sha, [], :str
  ffi_func :spinelbpf_embedded_maps, [], :str
  ffi_func :spinelbpf_embedded_records, [], :str
  ffi_func :spinelbpf_thread_current, [], :long
  ffi_func :spinelbpf_thread_main, [], :long
  ffi_func :spinelbpf_attach_trace, [:long, :str, :long], :long
  ffi_func :spinelbpf_run_tracing, [:long, :str, :long], :long
  ffi_func :spinelbpf_run_raw_tp, [:long, :str, :int_array, :long], :long # P026 E113
  ffi_func :spinelbpf_run_sk_lookup, [:long, :str, :long, :long], :long # P026 E129
  ffi_func :spinelbpf_sk_lookup_cookie, [], :long # P026 E129
  ffi_func :spinelbpf_attach_tcx, [:long, :str, :str], :long
  ffi_func :spinelbpf_tcx_direction, [:long], :long
  ffi_func :spinelbpf_load_targets, [:ptr, :long, :str, :str, :str, :str, :long], :long
  ffi_func :spinelbpf_attach_uprobe, [:long, :str, :long], :long
  ffi_func :spinelbpf_attach_uretprobe, [:long, :str, :long], :long # P026 E112
  ffi_func :spinelbpf_uprobe_link_file, [:long, :long], :long
  ffi_func :spinelbpf_run_tc_packet, [:long, :str, :int_array, :long], :long
  ffi_func :spinelbpf_attach_socket, [:long, :str, :long], :long
  ffi_func :spinelbpf_attach_cgroup, [:long, :str, :long], :long
  ffi_func :spinelbpf_attach_netfilter, [:long, :str, :long, :long, :long], :long
  ffi_func :spinelbpf_run_netfilter, [:long, :str, :int_array, :long, :long, :long], :long
  ffi_func :spinelbpf_attach_netns, [:long, :str, :long], :long
  ffi_func :spinelbpf_run_flow, [:long, :str, :int_array, :long], :long
  ffi_func :spinelbpf_flow_key, [:long], :long
  ffi_func :spinelbpf_run_skb_packet, [:long, :str, :int_array, :long], :long
  ffi_func :spinelbpf_load_config, [:ptr, :long, :str, :str, :str, :long], :long
  ffi_func :spinelbpf_global_get, [:long, :str], :long
  ffi_func :spinelbpf_lpm_prefix, [:str], :long
  ffi_func :spinelbpf_lpm_put, [:long, :str, :str, :long], :long
  ffi_func :spinelbpf_lpm_remove, [:long, :str, :str], :long
  ffi_func :spinelbpf_lpm_match, [:long, :str, :str], :long
  ffi_func :spinelbpf_lpm_list, [:long, :str], :long
  ffi_func :spinelbpf_load_checked, [:ptr, :long, :str, :str, :long], :long
  ffi_func :spinelbpf_attach_xdp, [:long, :str, :str], :long
  ffi_func :spinelbpf_detach, [:long], :long
  ffi_func :spinelbpf_map_get, [:long, :str, :long], :long
  ffi_func :spinelbpf_map_put, [:long, :str, :long, :long], :long
  ffi_func :spinelbpf_map_get_bytes, [:long, :str, :long, :int_array, :long], :long
  ffi_func :spinelbpf_map_put_bytes, [:long, :str, :long, :int_array, :long], :long
  ffi_func :spinelbpf_test_run_xdp, [:long, :str, :long], :long
  ffi_func :spinelbpf_test_run_xdp_packet, [:long, :str, :int_array, :long], :long
  ffi_func :spinelbpf_hash_get, [:long, :str, :int_array, :long, :int_array, :long], :long
  ffi_func :spinelbpf_hash_put, [:long, :str, :int_array, :long, :int_array, :long], :long
  ffi_func :spinelbpf_hash_delete, [:long, :str, :int_array, :long], :long
  ffi_func :spinelbpf_hash_keys, [:long, :str, :long, :int_array, :long], :long
  ffi_func :spinelbpf_possible_cpus, [], :long
  ffi_func :spinelbpf_percpu_get, [:long, :str, :int_array, :long, :int_array, :long], :long
  ffi_func :spinelbpf_percpu_put, [:long, :str, :int_array, :long, :int_array, :long], :long
  ffi_func :spinelbpf_ringbuf_open, [:long, :str], :long
  ffi_func :spinelbpf_ringbuf_read, [:long, :long, :int_array, :long], :long
  ffi_func :spinelbpf_ringbuf_close, [:long], :long
  ffi_func :spinelbpf_object_unmet, [:long], :long
  ffi_func :spinelbpf_close, [:long], :long
  ffi_func :spinelbpf_result_kind, [:long], :long
  ffi_func :spinelbpf_result_value, [:long], :long
  ffi_func :spinelbpf_result_message, [:long], :str
  ffi_func :spinelbpf_result_unmet_count, [:long], :long
  ffi_func :spinelbpf_result_unmet, [:long, :long], :str
  ffi_func :spinelbpf_result_free, [:long], :void
  ffi_func :spinelbpf_policy_version, [], :long
end

module SpinelBPF
  # 結果の種類 (bml の include/bml/kind.h と同じ値 — TestKindTable が照合)
  OK = 0
  KIND_NAMES = ["OK", "SCHEMA_MISMATCH", "PRECHECK_FAILED", "TARGET_REJECTED", "VERIFIER_REJECTED", "OTHER", "STATE", "RUNTIME_CONFLICT", "MAP_MISMATCH", "VALUE_RANGE", "CONFIG_NOT_SET", "NOT_FOUND"]

  # test_run_flow_dissector の Array の 1 番目から後の key の名前 (P026 E130 — 0 番目は判定)。順は inline の C の spinelbpf_flow_key の offset の順 (struct
  # bpf_flow_keys の UAPI)。ipv6_src[0] / [1] は ipv4_src / ipv4_dst と同じ byte (union)。address・port は network order の raw
  FLOW_KEYS = ["nhoff", "thoff", "addr_proto", "is_frag", "is_first_frag", "is_encap", "ip_proto", "n_proto", "sport", "dport",
               "ipv6_src[0]", "ipv6_src[1]", "ipv6_src[2]", "ipv6_src[3]", "ipv6_dst[0]", "ipv6_dst[1]", "ipv6_dst[2]", "ipv6_dst[3]", "flags", "flow_label"]

  class Error < StandardError
  end
  class SchemaMismatch < Error
  end
  class PrecheckFailed < Error
  end
  class TargetRejected < Error
  end
  class VerifierRejected < Error
  end
  class Other < Error
  end
  class State < Error
  end
  # RuntimeConflict (kind 7) は Go の loader の段 −1 (Go の runtime の signal の handler が替わった) — C の loader (bml — P010) は signal を入れず返さない。kind の名前として残す
  class RuntimeConflict < Error
  end
  class MapMismatch < Error
  end
  class ValueRange < Error
  end
  # NotFound は hash の map に key が無い (P008 §3 — get の戻り値の型を 1 つに保つため nil を返さない)。
  class NotFound < Error
  end
  # ConfigNotSet は load の時に必須の設定値 (BPF::Config) が置かれていない (kind 10 — 文は全ての名前、kernel の object は作らない — P014)
  class ConfigNotSet < Error
  end

  # check は結果の handle を読み、OK なら値を返し、他は種類ごとの例外を raise する (結果は放す)。
  def self.check(r)
    kind = SpinelBPFC.spinelbpf_result_kind(r)
    value = SpinelBPFC.spinelbpf_result_value(r)
    if kind == OK
      SpinelBPFC.spinelbpf_result_free(r)
      return value
    end
    msg = SpinelBPFC.spinelbpf_result_message(r)
    SpinelBPFC.spinelbpf_result_free(r)
    if kind == 1
      raise SchemaMismatch, msg
    elsif kind == 2
      raise PrecheckFailed, msg
    elsif kind == 3
      raise TargetRejected, msg
    elsif kind == 4
      # 非 root の hint (E016 — loader に依らない利用者向けの案内: C の loader (bml — P010) の文には無い、Go の loader は自分で足していた — 重ねない)
      if msg.include?("prohibited for !root") && !msg.include?("needs CAP_PERFMON")
        msg = msg + " — the verifier refused pointer arithmetic for a non-root loader: a packet window at a variable offset (`ctx.check(off, n)` with a non-constant off) needs CAP_PERFMON (or root) — bpf-mlir docs/nonroot.md"
      end
      raise VerifierRejected, msg
    elsif kind == 6
      raise State, msg
    elsif kind == 7
      raise RuntimeConflict, msg
    elsif kind == 8
      raise MapMismatch, msg
    elsif kind == 9
      raise ValueRange, msg
    elsif kind == 10
      raise ConfigNotSet, msg
    elsif kind == 11
      raise NotFound, msg
    end
    raise Other, msg
  end

  # current_thread は今の Ruby の Thread の同一性 (0 は threaded でない program — main だけ)。
  def self.current_thread
    SpinelBPFC.spinelbpf_thread_current
  end

  # main_thread? は main の Thread か (P012 — load は main だけ)。
  def self.main_thread?
    c = SpinelBPFC.spinelbpf_thread_current
    c == 0 || c == SpinelBPFC.spinelbpf_thread_main
  end

  # load_embedded は実行 file に埋め込んだ ELF を照合してから load する (唯一の入口)。main の Thread だけ (P012 E049)。
  # global の在る program は設定値の無い config (optional の列だけ — 必須の Config が在れば ConfigNotSet) で (P014 E058)。
  def self.load_embedded
    load_embedded_config(ConfigSet.new)
  end

  # load_embedded_config は load の時の設定値 (SpinelBPF::ConfigSet) を渡して load する (P014)。
  def self.load_embedded_config(cfg)
    if !SpinelBPF.main_thread?
      raise State, "SpinelBPF.load_embedded: load from the main Thread only"
    end
    elf = SpinelBPFC.spinelbpf_embedded_elf
    n = SpinelBPFC.spinelbpf_embedded_elf_len
    if global_rows.length == 0
      if cfg.values_set > 0
        raise MapMismatch, "SpinelBPF.load_embedded_config: this program has no globals, but #{cfg.values_set} config values were given"
      end
      return Loaded.new(check(SpinelBPFC.spinelbpf_load_checked(elf, n, SpinelBPFC.spinelbpf_embedded_sha, SpinelBPFC.spinelbpf_embedded_maps, 0)))
    end
    Loaded.new(check(SpinelBPFC.spinelbpf_load_config(elf, n, SpinelBPFC.spinelbpf_embedded_sha, SpinelBPFC.spinelbpf_embedded_maps, cfg.json(optional_names), 0)))
  end

  # load_embedded_targets は uprobe の target (SpinelBPF::UprobeTargets — program と binary の path) も load の引数で渡して load する (P020 E081)。
  # bml は path を 1 回だけ開き、その fd で binary の SHA-256・symbol・DWARF の型・呼び出し規約を照合し、attach_uprobe も同じ fd で行う。
  # target を与えない uprobe の program は照合が binary_unknown で止める (TargetRejected — load_embedded / load_embedded_config も同じ)。
  def self.load_embedded_targets(cfg, targets)
    if !SpinelBPF.main_thread?
      raise State, "SpinelBPF.load_embedded_targets: load from the main Thread only"
    end
    elf = SpinelBPFC.spinelbpf_embedded_elf
    n = SpinelBPFC.spinelbpf_embedded_elf_len
    config = ""
    if global_rows.length == 0
      if cfg.values_set > 0
        raise MapMismatch, "SpinelBPF.load_embedded_targets: this program has no globals, but #{cfg.values_set} config values were given"
      end
    else
      config = cfg.json(optional_names)
    end
    Loaded.new(check(SpinelBPFC.spinelbpf_load_targets(elf, n, SpinelBPFC.spinelbpf_embedded_sha, SpinelBPFC.spinelbpf_embedded_maps, config, targets.json, 0)))
  end

  # UprobeTargets は uprobe の program と target の binary の path の組 (load_embedded_targets の引数 — process の全体の状態を持たない)。
  class UprobeTargets
    def initialize
      @programs = []
      @paths = []
      @debug_root = ""
      @debug_root_set = false
    end

    def add(program, path)
      @programs.push(program)
      @paths.push(path)
      self
    end

    # debug_root は分けた DWARF の build ID の探索の root (bml の targets の "debug_root" — P029 E156)。呼ばなければ bml の既定 /usr/lib/debug、"" は探索しない。
    def debug_root(path)
      @debug_root = path
      @debug_root_set = true
      self
    end

    def json
      s = "{\"uprobe_targets\": ["
      i = 0
      while i < @programs.length
        if i > 0
          s += ", "
        end
        s += "{\"program\": \"#{SpinelBPF.json_escape(@programs[i])}\", \"path\": \"#{SpinelBPF.json_escape(@paths[i])}\"}"
        i += 1
      end
      if @debug_root_set
        return s + "], \"debug_root\": \"#{SpinelBPF.json_escape(@debug_root)}\"}"
      end
      s + "]}"
    end
  end

  # json_escape は JSON の文字列に置く値 — " と \ と改行を含む値は拒む (ValueRange — 黙って別の path にしない)。
  def self.json_escape(v)
    if v.include?("\"") || v.include?("\\") || v.include?("\n")
      raise ValueRange, "spinelbpf: #{v} has a quote, a backslash or a newline — not accepted as a uprobe program or path"
    end
    v
  end

  # global_rows は埋め込みの表の G の行 ([name, section, type, opt] — P014 E057)。
  def self.global_rows
    rows = []
    lines = SpinelBPFC.spinelbpf_embedded_records.split("\n")
    i = 0
    while i < lines.length
      p = lines[i].split("|")
      if p.length == 5 && p[0] == "G"
        rows.push([p[1], p[2], p[3], p[4]])
      end
      i += 1
    end
    rows
  end

  # optional_names は OptionalConfig の名前の列 (config の JSON の optional — 送らなければ未設定の optional も ConfigNotSet になる)。
  def self.optional_names
    out = []
    rows = global_rows
    i = 0
    while i < rows.length
      if rows[i][3] == "1"
        out.push(rows[i][0])
      end
      i += 1
    end
    out
  end

  # global_row は名前の G の行 (無ければ MapMismatch — program が使わない global は ELF に無い)。
  def self.global_row(name)
    rows = global_rows
    i = 0
    while i < rows.length
      if rows[i][0] == name
        return rows[i]
      end
      i += 1
    end
    raise MapMismatch, "spinelbpf: global #{name} is not in this executable (no eBPF program reads or adds it — rebuild, or use it on the eBPF side)"
  end

  # global_bits は宣言の型の範囲の値を config の JSON の bits (符号無しの十進) に。範囲の外は ValueRange。
  def self.global_bits(name, t, v)
    if v.nil?
      raise ValueRange, "spinelbpf: config #{name}: the value is nil (Spinel's Integer has no -2^63)"
    end
    w = t[1, 2].to_i
    if t[0] == "u"
      if v < 0 || (w < 64 && v >= (1 << w))
        raise ValueRange, "spinelbpf: config #{name}: #{v} is outside #{t}"
      end
      return v.to_s
    end
    if w < 64
      lim = 1 << (w - 1)
      if v < -lim || v >= lim
        raise ValueRange, "spinelbpf: config #{name}: #{v} is outside #{t}"
      end
      if v < 0
        return (v + (1 << w)).to_s
      end
      return v.to_s
    end
    if v >= 0
      return v.to_s
    end
    u64_decimal((v >> 32) & 0xFFFFFFFF, v & 0xFFFFFFFF)
  end

  # u64_decimal は 2 つの 32 bit の半分 (hi・lo) の 64 bit の符号無しの十進 (Ruby の Integer は i64 — 2^63 以上を直に持てない)。
  def self.u64_decimal(hi, lo)
    limbs = [hi >> 16, hi & 0xFFFF, lo >> 16, lo & 0xFFFF]
    dec = ""
    while limbs[0] != 0 || limbs[1] != 0 || limbs[2] != 0 || limbs[3] != 0
      r = 0
      j = 0
      while j < 4
        cur = r * 65536 + limbs[j]
        limbs[j] = cur / 10
        r = cur % 10
        j += 1
      end
      dec = r.to_s + dec
    end
    dec == "" ? "0" : dec
  end

  # global_value は bml の 0 拡張の bits (i64 の値) を宣言の型で (i は符号の拡張、u64 の 2^63 以上は ValueRange)。
  def self.global_value(name, t, raw)
    w = t[1, 2].to_i
    if t[0] == "u"
      if w == 64 && raw < 0
        raise ValueRange, "spinelbpf: global #{name}: a u64 value of 2^63 or more does not fit Ruby's Integer"
      end
      return raw
    end
    if w < 64 && raw >= (1 << (w - 1))
      return raw - (1 << w)
    end
    raw
  end

  # ConfigSet は load の時の設定値 (P014 — 単相: 必須は set、optional は set_optional)。名前は BPF::Config と重ねない
  # (Spinel は同じ名前の class を BPF__Config と名付け直し、frontend の呼び先の照合が BPF::Config#value を見失う — E058)
  class ConfigSet
    def initialize
      @names = []
      @bits = []
    end

    def values_set
      @names.length
    end

    def set(g, v)
      put(g.global_name, g.global_type, v)
    end

    def set_optional(g, v)
      put(g.global_name, g.global_type, v)
    end

    def put(name, t, v)
      if SpinelBPF.global_row(name)[1] != "rodata"
        raise MapMismatch, "spinelbpf: #{name} is a Counter (.bss) — it has no load-time value"
      end
      b = SpinelBPF.global_bits(name, t, v)
      i = 0
      while i < @names.length
        if @names[i] == name
          @bits[i] = b
          return self
        end
        i += 1
      end
      @names.push(name)
      @bits.push(b)
      self
    end

    def json(optional)
      s = "{\"set\": {"
      i = 0
      while i < @names.length
        if i > 0
          s += ", "
        end
        s += "\"#{@names[i]}\": #{@bits[i]}"
        i += 1
      end
      s += "}, \"optional\": ["
      i = 0
      while i < optional.length
        if i > 0
          s += ", "
        end
        s += "\"#{optional[i]}\""
        i += 1
      end
      s + "]}"
    end
  end

  def self.policy_version
    SpinelBPFC.spinelbpf_policy_version
  end

  # decl は map の宣言の JSON (maps.json の要素の形 — loader が ELF の map の行と照合する)。
  def self.decl(map)
    d = "{\"name\":\"#{map.name}\",\"kind\":\"#{map.kind}\",\"key\":\"#{map.key_type}\",\"value\":\"#{map.value_type}\",\"max_entries\":#{map.max_entries}"
    if map.kind == "lpm_trie"
      d = d + ",\"flags\":1" # E121: BPF_F_NO_PREALLOC — bml は宣言と ELF の flags を照らす (他の kind は flags の key を書かない — 今の文書と同じ)
    end
    d + "}"
  end

  # record の map の layout (埋め込みの表の行 `Map|S|size=N;m:off:type;…` — spinelbpf build が書く、P006 §3)。
  # 戻り値は [size, [[名前, offset, bytes, signed], …]] (padding の member も — Struct の member と同じ並び)。
  def self.record_layout(map)
    layout_row(map.name)
  end

  # layout_row は埋め込みの表の行 (値は `M`、hash の record の key は `M:key` — P008 §3)。
  def self.layout_row(row)
    lines = SpinelBPFC.spinelbpf_embedded_records.split("\n")
    i = 0
    while i < lines.length
      parts = lines[i].split("|")
      if parts.length == 3 && parts[0] == row
        fields = parts[2].split(";")
        size = fields[0].split("=")[1].to_i
        members = []
        j = 1
        while j < fields.length
          m = fields[j].split(":")
          members.push([m[0], m[1].to_i, m[2][1, 2].to_i / 8, m[2][0] == "i"])
          j += 1
        end
        return [size, members]
      end
      i += 1
    end
    raise MapMismatch, "spinelbpf: #{row} has no record layout in this executable — rebuild with spinelbpf build"
  end

  # record_get は record の map の value を bytes で読み、member の値の Array (Struct の member の順・padding を含む) を返す。
  # Struct は利用者が明示の引数で作る (`S.new(v[0], v[1], …)`) — library の splat の生成 (`class.new(*vals)`) は Spinel の whole-program の推論で
  # 全ての record の member の型を untyped にし eBPF の側を壊す (E021)、多相の `r[i] = v` は黙って何もしない (S6)。u64 の 2^63 以上・i64 の −2^63 は ValueRange。
  def self.record_get(h, map, key)
    lay = record_layout(map)
    size = lay[0]
    buf = Array.new(size, 0) # value の bytes (各 0..255 — IO::Buffer は require した library の中で Spinel が扱えない、E021)
    check(SpinelBPFC.spinelbpf_map_get_bytes(h, decl(map), key, buf, size))
    vals = []
    members = lay[1]
    i = 0
    while i < members.length
      vals.push(read_member(buf, members[i], map.name, key.to_s))
      i += 1
    end
    vals
  end

  def self.read_member(buf, m, name, key)
    off = m[1]
    n = m[2]
    top = buf[off + n - 1]
    if n == 8 && !m[3] && top >= 0x80
      raise ValueRange, "spinelbpf: #{name}[#{key}].#{m[0]}: the u64 value is 2^63 or more and does not fit Spinel's Integer"
    end
    neg = m[3] && top >= 0x80
    v = 0
    i = n - 1
    while i >= 0
      b = buf[off + i]
      if i == n - 1 && n == 8 && neg
        b = b & 0x7F # 符号の bit を外して組み、後で −2^63 を足す (i64 は Integer を溢れさせない)
      end
      v = (v << 8) | b
      i -= 1
    end
    if neg
      if n == 8
        if v == 0
          raise ValueRange, "spinelbpf: #{name}[#{key}].#{m[0]}: the i64 value -2^63 is Spinel's nil marker (INT64_MIN)"
        end
        return v - 9223372036854775807 - 1
      end
      return v - (1 << (n * 8))
    end
    v
  end

  # record_put は Struct の member を型の範囲で確かめて bytes にし書く (範囲の外・nil・padding の 0 以外は ValueRange — 黙って切り詰めない)。
  def self.record_put(h, map, key, rec)
    lay = record_layout(map)
    size = lay[0]
    members = lay[1]
    vals = rec.to_a
    if vals.length != members.length
      raise ValueRange, "spinelbpf: #{map.name}[#{key}]: the record has #{vals.length} members, the layout #{members.length}"
    end
    buf = Array.new(size, 0)
    i = 0
    while i < members.length
      m = members[i]
      v = vals[i]
      check_member(v, m, map.name, key.to_s)
      j = 0
      while j < m[2]
        buf[m[1] + j] = (v >> (8 * j)) & 0xFF
        j += 1
      end
      i += 1
    end
    check(SpinelBPFC.spinelbpf_map_put_bytes(h, decl(map), key, buf, size))
  end

# record_put_values は平らな値の Array を書く (record_put と同じ検査 — P016 E066)。
def self.record_put_values(h, map, key, vals)
  lay = record_layout(map)
  size = lay[0]
  members = lay[1]
  if vals.length != members.length
    raise ValueRange, "spinelbpf: #{map.name}[#{key}]: #{vals.length} values, the layout has #{members.length} (array members count element by element)"
  end
  buf = Array.new(size, 0)
  i = 0
  while i < members.length
    m = members[i]
    v = vals[i]
    check_member(v, m, map.name, key.to_s)
    j = 0
    while j < m[2]
      buf[m[1] + j] = (v >> (8 * j)) & 0xFF
      j += 1
    end
    i += 1
  end
  check(SpinelBPFC.spinelbpf_map_put_bytes(h, decl(map), key, buf, size))
end

  def self.check_member(v, m, name, key)
    where = "spinelbpf: #{name}[#{key}].#{m[0]}"
    if v.nil?
      raise ValueRange, "#{where}: nil (or INT64_MIN — Spinel's nil marker) is not a member value"
    end
    if m[0].start_with?("_pad") && v != 0
      raise ValueRange, "#{where}: padding must be 0, got #{v}"
    end
    bits = m[2] * 8
    if m[3]
      if bits < 64 && (v < -(1 << (bits - 1)) || v >= (1 << (bits - 1)))
        raise ValueRange, "#{where}: #{v} is outside i#{bits}"
      end
    elsif v < 0 || (bits < 64 && v >= (1 << bits))
      raise ValueRange, "#{where}: #{v} is outside u#{bits}"
    end
  end

  # ring_read は ring buffer の event を 1 つ読み member の値の Array を返す (期限切れは空の Array — record は member が 1 つ以上なので event と区別できる。
  # 閉じた reader・閉じた object 等の終わりは State で loud に — 期限切れと混ぜない、P007 のレビューの (b))。
  def self.ring_read(rb, ring, timeout_ms, n)
    lay = record_layout(ring)
    size = lay[0]
    buf = Array.new(size, 0)
    # 100 ms の区切りで読む (P012 E049 — 1 つの長い ffi_func の呼び出しの間は他の Thread の GC が待つ: 5 s の read で約 5 s の停止を測った)。
    # 意味は同じ: deadline までに event が来れば record、来なければ期限切れ (0)。100 ms 以下の timeout は 1 回の呼び出しのまま
    got = 0
    if timeout_ms <= 100
      got = check(SpinelBPFC.spinelbpf_ringbuf_read(rb, timeout_ms, buf, size))
    else
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) / 1_000_000 + timeout_ms
      left = timeout_ms
      while got == 0 && left > 0
        slice = left < 100 ? left : 100
        got = check(SpinelBPFC.spinelbpf_ringbuf_read(rb, slice, buf, size))
        left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) / 1_000_000
      end
    end
    vals = []
    if got == 0
      return vals
    end
    members = lay[1]
    i = 0
    while i < members.length
      vals.push(read_member(buf, members[i], ring.name, n.to_s))
      i += 1
    end
    vals
  end

  # RingReader は ring buffer の pull 型の reader (P007 §3 — mmap の写像は Go の側に閉じ、event は写しで受ける)。
  # RingReader は開いた Thread だけが read と close をする (P012 E049 — bml は同じ reader の別の thread の read を黙って直列にする: ここで loud に)。
  class RingReader
    def initialize(rb, ring)
      @rb = rb
      @ring = ring
      @n = 0
      @owner = SpinelBPF.current_thread
    end

    def own!(what)
      if SpinelBPF.current_thread != @owner
        raise State, "RingReader##{what}: the ring buffer reader belongs to the Thread that opened it — #{what} it there"
      end
    end

    # read_record は event を 1 つ待ち (timeout_ms まで)、member の値の Array (BPF.record の宣言の順・padding を含む) を返す。期限切れは空の Array。
    def read_record(timeout_ms)
      own!("read_record")
      v = SpinelBPF.ring_read(@rb, @ring, timeout_ms, @n)
      if v.length > 0
        @n += 1
      end
      v
    end

    def close
      own!("close")
      SpinelBPF.check(SpinelBPFC.spinelbpf_ringbuf_close(@rb))
    end
  end

  # hash の map の key と値の layout (P008 §3): record は埋め込みの表の行、整数は 1 つの member (名前・offset 0・byte の数・符号)。
  def self.int_layout(t, name)
    n = t[1, 2].to_i / 8
    [n, [[name, 0, n, t[0] == "i"]]]
  end

  def self.key_layout(map)
    if map.record_key?
      return layout_row(map.name + ":key")
    end
    int_layout(map.key_type, "key")
  end

  def self.value_layout(map)
    if map.record?
      return layout_row(map.name)
    end
    int_layout(map.value_type, "value")
  end

  # pack は member の値を型の範囲で確かめて bytes に (範囲の外・nil・padding の 0 以外は ValueRange — record_put と同じ)。
  def self.pack(lay, vals, name, what)
    members = lay[1]
    if vals.length != members.length
      raise ValueRange, "spinelbpf: #{name} #{what}: #{vals.length} values, the layout has #{members.length} members"
    end
    buf = Array.new(lay[0], 0)
    i = 0
    while i < members.length
      m = members[i]
      v = vals[i]
      check_member(v, m, name, what)
      j = 0
      while j < m[2]
        buf[m[1] + j] = (v >> (8 * j)) & 0xFF
        j += 1
      end
      i += 1
    end
    buf
  end

  def self.unpack(lay, buf, off, name, what)
    vals = []
    members = lay[1]
    i = 0
    while i < members.length
      m = members[i]
      vals.push(read_member(buf, [m[0], m[1] + off, m[2], m[3]], name, what))
      i += 1
    end
    vals
  end

  # hash_check は API の名前 (record の key / 値か) と map の種類の一致 (違えば MapMismatch — 単相の API)。
  def self.hash_check(map, rk, rv, api)
    if map.kind != "hash" && map.kind != "lru_hash"
      raise MapMismatch, "spinelbpf: #{map.name} is a #{map.kind} map — #{api} is for hash / lru_hash maps"
    end
    if map.record_key? != rk || map.record? != rv
      raise MapMismatch, "spinelbpf: #{map.name} has a #{map.key_type} key and a #{map.value_type} value — #{api} does not fit it"
    end
  end

  def self.hash_get(h, map, keyvals, rk, rv, api)
    hash_check(map, rk, rv, api)
    kl = key_layout(map)
    vl = value_layout(map)
    kb = pack(kl, keyvals, map.name, "key")
    vb = Array.new(vl[0], 0)
    check(SpinelBPFC.spinelbpf_hash_get(h, decl(map), kb, kl[0], vb, vl[0]))
    unpack(vl, vb, 0, map.name, "value")
  end

  def self.hash_put(h, map, keyvals, vals, rk, rv, api)
    hash_check(map, rk, rv, api)
    kl = key_layout(map)
    vl = value_layout(map)
    kb = pack(kl, keyvals, map.name, "key")
    vb = pack(vl, vals, map.name, "value")
    check(SpinelBPFC.spinelbpf_hash_put(h, decl(map), kb, kl[0], vb, vl[0]))
  end

  def self.hash_delete(h, map, keyvals, rk, api)
    hash_check(map, rk, map.record?, api)
    kl = key_layout(map)
    kb = pack(kl, keyvals, map.name, "key")
    check(SpinelBPFC.spinelbpf_hash_delete(h, decl(map), kb, kl[0])) == 1
  end

  # hash_keys は key の member の値の Array の Array (順は kernel の列挙の順 — 同時の変更の下では重複・取りこぼしがありうる)。
  def self.hash_keys(h, map, rk, api)
    hash_check(map, rk, map.record?, api)
    raw_keys(h, map)
  end

  def self.raw_keys(h, map)
    kl = key_layout(map)
    out = Array.new(kl[0] * map.max_entries, 0)
    n = check(SpinelBPFC.spinelbpf_hash_keys(h, decl(map), kl[0], out, map.max_entries))
    keys = []
    i = 0
    while i < n
      keys.push(unpack(kl, out, i * kl[0], map.name, "key"))
      i += 1
    end
    keys
  end

  # possible_cpus は possible CPU の数 (per-CPU の値の Array の長さ — P009)。
  def self.possible_cpus
    check(SpinelBPFC.spinelbpf_possible_cpus)
  end

  # sum は Integer の Array の和 (per-CPU の値の CPU ごとの和 — record は利用者が member ごとに足す)。
  def self.sum(vs)
    s = 0
    i = 0
    while i < vs.length
      s += vs[i]
      i += 1
    end
    s
  end

  # array_only は map_get / map_put 等が array の map だけを受ける (per-CPU の array は percpu_* — P009)。
  # lpm_check は lpm の API と map の種類の一致 (違えば MapMismatch — 単相の API、E121)。
  def self.lpm_check(map, api)
    if map.kind != "lpm_trie"
      raise MapMismatch, "spinelbpf: #{map.name} is a #{map.kind} map — #{api} is for lpm_trie maps"
    end
  end

  # lpm_value は put の値を宣言の型 (:u32 / :i32) の範囲で確かめる (外は ValueRange)。
  def self.lpm_value(map, v)
    if map.value_type == "i32"
      if v < -0x80000000 || v > 0x7fffffff
        raise ValueRange, "spinelbpf: #{map.name}: #{v} is outside the i32 values [-2147483648, 2147483647]"
      end
      return 0
    end
    if v < 0 || v > 0xffffffff
      raise ValueRange, "spinelbpf: #{map.name}: #{v} is outside the u32 values [0, 4294967295]"
    end
    0
  end

  # lpm_signed は bml の値の bits (4 byte を 0 で拡張) を宣言の符号で読む。
  def self.lpm_signed(map, v)
    if map.value_type == "i32" && v >= 0x80000000
      return v - 0x100000000
    end
    v
  end

  # lpm_prefix_len は prefix ("a.b.c.d/n") を確かめて長さを返す (object 無し — kernel に触らない。IPv6・不正・host の bit は Other)。
  def self.lpm_prefix_len(prefix)
    check(SpinelBPFC.spinelbpf_lpm_prefix(prefix))
  end

  def self.array_only(map, api)
    if map.kind != "array" && map.kind != "devmap" && map.kind != "sockmap" # P026 E124 / E129: devmap の ifindex・sockmap の socket の fd の put も同じ口 (key は u32 の添字)
      raise MapMismatch, "spinelbpf: #{map.name} is a #{map.kind} map — #{api} is for array maps (and devmaps)"
    end
  end

  # percpu_check は per-CPU の API の名前と map の種類の一致 (違えば MapMismatch — 単相の API)。
  def self.percpu_check(map, kind, rk, rv, api)
    if map.kind != kind
      raise MapMismatch, "spinelbpf: #{map.name} is a #{map.kind} map — #{api} is for #{kind} maps"
    end
    if map.record_key? != rk || map.record? != rv
      raise MapMismatch, "spinelbpf: #{map.name} has a #{map.key_type} key and a #{map.value_type} value — #{api} does not fit it"
    end
  end

  # percpu_get は CPU ごとの値の member の値の Array の Array (長さは possible CPU の数 — kernel の per-CPU の値は 1 つの CPU ごとに 8 byte に揃う)。
  def self.percpu_get(h, map, keyvals, kind, rk, rv, api)
    percpu_check(map, kind, rk, rv, api)
    kl = key_layout(map)
    vl = value_layout(map)
    ncpu = possible_cpus
    stride = (vl[0] + 7) / 8 * 8
    kb = pack(kl, keyvals, map.name, "key")
    out = Array.new(ncpu * stride, 0)
    check(SpinelBPFC.spinelbpf_percpu_get(h, decl(map), kb, kl[0], out, ncpu * stride))
    vals = []
    i = 0
    while i < ncpu
      vals.push(unpack(vl, out, i * stride, map.name, "value"))
      i += 1
    end
    vals
  end

  # percpu_put は CPU ごとの値を書く (per は possible CPU の数の member の値の Array — 長さが違えば ValueRange)。
  def self.percpu_put(h, map, keyvals, per, kind, rk, rv, api)
    percpu_check(map, kind, rk, rv, api)
    kl = key_layout(map)
    vl = value_layout(map)
    ncpu = possible_cpus
    if per.length != ncpu
      raise ValueRange, "spinelbpf: #{map.name}: #{per.length} per-CPU values, the host has #{ncpu} possible CPUs"
    end
    kb = pack(kl, keyvals, map.name, "key")
    vb = []
    i = 0
    while i < ncpu
      b = pack(vl, per[i], map.name, "value")
      j = 0
      while j < b.length
        vb.push(b[j])
        j += 1
      end
      i += 1
    end
    check(SpinelBPFC.spinelbpf_percpu_put(h, decl(map), kb, kl[0], vb, vb.length))
  end

  def self.firsts(vals)
    out = []
    i = 0
    while i < vals.length
      out.push(vals[i][0])
      i += 1
    end
    out
  end

  def self.wraps(vs)
    out = []
    i = 0
    while i < vs.length
      out.push([vs[i]])
      i += 1
    end
    out
  end

  class Link
    def initialize(h)
      @h = h
    end

    def handle
      @h
    end

    def detach
      SpinelBPF.check(SpinelBPFC.spinelbpf_detach(@h))
    end

    # tcx_direction は tcx の link の実際の向き ("ingress" / "egress" — kernel の link の info、P019 E077)。tcx でない・detach 済みの link は State
    def tcx_direction
      r = SpinelBPFC.spinelbpf_tcx_direction(@h)
      if SpinelBPFC.spinelbpf_result_kind(r) == SpinelBPF::OK
        m = SpinelBPFC.spinelbpf_result_message(r)
        SpinelBPFC.spinelbpf_result_free(r)
        return m
      end
      SpinelBPF.check(r)
      ""
    end
  end

  # Loaded は load した object。
  class Loaded
    def initialize(h)
      @h = h
    end

    def handle
      @h
    end

    def attach_xdp(prog, ifname)
      Link.new(SpinelBPF.check(SpinelBPFC.spinelbpf_attach_xdp(@h, prog, ifname)))
    end

    # attach_uprobe は uprobe の program を load の時に照合した target の関数の入口に attach する (P020 E081 — pid 0 は全ての process)。
    # bml は同じ fd の file offset で attach し、attach の後に perf の link の info の offset を照らす。target の無い program・他の種類は State
    def attach_uprobe(prog, pid)
      Link.new(SpinelBPF.check(SpinelBPFC.spinelbpf_attach_uprobe(@h, prog, pid)))
    end

    # attach_uretprobe は uretprobe の program を target の関数の戻りに (P026 E112 — target は load の UprobeTargets で uprobe と同じく、pid 0 は全ての process)
    def attach_uretprobe(prog, pid)
      Link.new(SpinelBPF.check(SpinelBPFC.spinelbpf_attach_uretprobe(@h, prog, pid)))
    end

    # uprobe_link_file は uprobe の link の attach の時の perf の link の info の file (P020 E081)
    def uprobe_link_file(link)
      r = SpinelBPFC.spinelbpf_uprobe_link_file(@h, link.handle)
      if SpinelBPFC.spinelbpf_result_kind(r) == SpinelBPF::OK
        m = SpinelBPFC.spinelbpf_result_message(r)
        SpinelBPFC.spinelbpf_result_free(r)
        return m
      end
      SpinelBPF.check(r)
      ""
    end

    # attach_tcx は sched_cls の program を interface の tcx に (P019 E077)。向きは宣言 (`BPF.tcx :p, :ingress`) — ELF の section から bml が決め、
    # attach の後に kernel の link の info の向きと ifindex を照らす (違えば detach して Other)。sched_cls でない program は State
    def attach_tcx(prog, ifname)
      Link.new(SpinelBPF.check(SpinelBPFC.spinelbpf_attach_tcx(@h, prog, ifname)))
    end

    # attach_socket は socket_filter の program を呼び手の socket (fd) に SO_ATTACH_BPF で付ける (P026 E126)。link は無い — 外すのは socket を閉じるか
    # SO_DETACH_BPF (filter は socket に残り、object を閉じても外れない)。socket_filter でない program は State、fd の誤りは bml の文 (Other)
    def attach_socket(prog, fd)
      SpinelBPF.check(SpinelBPFC.spinelbpf_attach_socket(@h, prog, fd))
      nil
    end

    # attach_cgroup は cgroup_skb の program を呼び手の cgroup (v2 の dir の fd) に付ける (P026 E127 — BPF_LINK_CREATE)。向きは宣言
    # (`BPF.cgroup_skb :p, :ingress`) — bml が attach の後に link の info の cgroup と attach type を照らす。cgroup_skb でない program は State、
    # cgroup でない fd は Other。Link#detach で外す
    def attach_cgroup(prog, fd)
      Link.new(SpinelBPF.check(SpinelBPFC.spinelbpf_attach_cgroup(@h, prog, fd)))
    end

    # attach_netfilter は netfilter の program を**呼ぶ thread の netns** の hook に link で付ける (P026 E128 — bml E051)。pf は NFPROTO_IPV4 2 /
    # IPV6 10、hooknum は NF_INET_PRE_ROUTING 0 … POST_ROUTING 4、priority は int32、flags は 0 (IP_DEFRAG は無い)。bml が付けた後に link の info の
    # 4 つの値を照らす。netfilter でない program は State、範囲の外は ValueRange、kernel の拒否は Other。Link#detach で外す
    def attach_netfilter(prog, pf, hooknum, priority)
      Link.new(SpinelBPF.check(SpinelBPFC.spinelbpf_attach_netfilter(@h, prog, pf, hooknum, priority)))
    end

    # attach_netns は flow_dissector の program を呼び手の network namespace (nsfs の fd — /proc/<pid>/ns/net 等) に link で付ける (P026 E130 —
    # bml が link の info の netns の inode を照らす)。flow_dissector (と sk_lookup) でない program は State、netns でない fd は Other。Link#detach で外す
    def attach_netns(prog, fd)
      Link.new(SpinelBPF.check(SpinelBPFC.spinelbpf_attach_netns(@h, prog, fd)))
    end

    # test_run_flow_dissector は flow_dissector の program を 1 回、bytes の frame (eth の header から) で走らせ、[判定, key の 20 の値] の Array を返す
    # (P026 E130 — key の名前と順は SpinelBPF::FLOW_KEYS、値は field の幅の符号なし、address・port は network order の raw)。kernel は program の後に
    # nhoff を [14, n]、thoff を [nhoff, n] に clamp する。14 byte 未満は Other、byte と長さの検査は test_run_tc_packet と同じ文
    def test_run_flow_dissector(prog, bytes)
      n = bytes.length
      if n > 0xffff
        raise Other, "spinelbpf: packet length #{n} is outside 0..65535"
      end
      i = 0
      while i < n
        v = bytes[i]
        if v < 0 || v > 255
          raise ValueRange, "spinelbpf: packet byte #{i} is #{v}, outside 0..255"
        end
        i += 1
      end
      r = SpinelBPF.check(SpinelBPFC.spinelbpf_run_flow(@h, prog, bytes, n))
      out = [r]
      i = 0
      while i < 20
        out.push(SpinelBPFC.spinelbpf_flow_key(i))
        i += 1
      end
      out
    end

    # global の読み (P014 E058 — 単相: 必須・optional・counter で別の method)。config は load の時の値、counter は今の値
    def config_get(g)
      global_get(g.global_name)
    end

    def optional_get(g)
      global_get(g.global_name)
    end

    def counter_get(g)
      global_get(g.global_name)
    end

    def global_get(name)
      row = SpinelBPF.global_row(name)
      decl = "{\"name\": \"#{row[0]}\", \"section\": \"#{row[1]}\", \"type\": \"#{row[2]}\"}"
      SpinelBPF.global_value(name, row[2], SpinelBPF.check(SpinelBPFC.spinelbpf_global_get(@h, decl)))
    end

    # tracing の attach (P013 E053 — kind ごとの method: 単相)。fentry / fexit は kernel の関数の入口 / 出口、kprobe は bml が attach の後に kernel の
    # func_name を宣言と照らす (違えば detach して誤り)。program の kind と違う method は bml の誤り (黙って通らない)
    def attach_fentry(prog)
      Link.new(SpinelBPF.check(SpinelBPFC.spinelbpf_attach_trace(@h, prog, 0)))
    end

    def attach_fexit(prog)
      Link.new(SpinelBPF.check(SpinelBPFC.spinelbpf_attach_trace(@h, prog, 1)))
    end

    def attach_kprobe(prog)
      Link.new(SpinelBPF.check(SpinelBPFC.spinelbpf_attach_trace(@h, prog, 2)))
    end

    # attach_fmod_ret は fmod_ret の program を kernel の関数の入口に (P028 E144 — 戻り値を差し替えうる: 0 でなければ元の関数を呼ばない)。
    # bml が付けた後に link の attach type (MODIFY_RETURN) と target の BTF id を照らす。test run は test_run_tracing (kernel が
    # bpf_modify_return_test を呼ぶ — 戻り値は観測しない、bml は thread の tid を返す)
    def attach_fmod_ret(prog)
      Link.new(SpinelBPF.check(SpinelBPFC.spinelbpf_attach_trace(@h, prog, 8)))
    end

    # attach_kretprobe は kretprobe の program を関数の戻りに (P026 E111 — bml が attach の後に関数の名前と KRETPROBE を照らす)
    def attach_kretprobe(prog)
      Link.new(SpinelBPF.check(SpinelBPFC.spinelbpf_attach_trace(@h, prog, 4)))
    end

    # attach_raw_tp は raw_tp の program を ELF の section の tracepoint に (P026 E113 — bml が attach の後に raw tracepoint の名前を照らす)。
    # program が読む args の添字が tracepoint の引数の数を超えると kernel が attach を -EINVAL で拒む
    def attach_raw_tp(prog)
      Link.new(SpinelBPF.check(SpinelBPFC.spinelbpf_attach_trace(@h, prog, 5)))
    end

    # attach_ksyscall は ksyscall の program を syscall の wrapper (`__x64_sys_<name>`) の入口に (P026 E115 — bml が付けた後に link の info の関数の
    # 名前を wrapper と照らす)。kprobe と同じく test run は無い — syscall を実際に呼んで試す
    def attach_ksyscall(prog)
      Link.new(SpinelBPF.check(SpinelBPFC.spinelbpf_attach_trace(@h, prog, 7)))
    end

    # attach_tracepoint は tracepoint の program を ELF の section の tracefs の event に (P026 E114 — bml が online の全ての CPU で perf の event を開き、
    # link の info の tracepoint の名前を照らす)。tracepoint の program に test run は無い — event を実際に起こして試す
    def attach_tracepoint(prog)
      Link.new(SpinelBPF.check(SpinelBPFC.spinelbpf_attach_trace(@h, prog, 6)))
    end

    # test_run_sk_lookup は sk_lookup の test run を 1 回 (P026 E129 — proto は 17 (UDP) か 6 (TCP)、local は 127.0.0.1:port)。戻り値は program の戻り値、
    # 選んだ socket の cookie (無ければ 0) は sk_lookup_cookie
    def test_run_sk_lookup(prog, proto, port)
      SpinelBPF.check(SpinelBPFC.spinelbpf_run_sk_lookup(@h, prog, proto, port))
    end

    def sk_lookup_cookie
      SpinelBPFC.spinelbpf_sk_lookup_cookie
    end

    # test_run_raw_tp は raw_tp の test run を 1 回 (P026 E113 — args は 1..12 個の整数を u64 の args[i] に、呼び手の thread の文脈で走る)。
    # 戻り値は program の戻り値
    def test_run_raw_tp(prog, args)
      if args.length < 1 || args.length > 12
        raise SpinelBPF::ValueRange, "test_run_raw_tp takes 1..12 args (u64 args[i] of bpf_raw_tracepoint_args), got #{args.length}"
      end
      SpinelBPF.check(SpinelBPFC.spinelbpf_run_raw_tp(@h, prog, args, args.length))
    end

    # attach_tp_btf は tp_btf の program を ELF の section の tracepoint に attach する (P021 E087 — bml が attach の後に raw tracepoint の
    # link の info の tracepoint の名前を宣言と照らす)。tp_btf の test run は kernel が EFAULT で走らせない — tracepoint を実際に起こして試す
    def attach_tp_btf(prog)
      Link.new(SpinelBPF.check(SpinelBPFC.spinelbpf_attach_trace(@h, prog, 3)))
    end

    # test_run_tracing は fentry / fexit の data 無しの test run を n 回 (kernel は bpf_fentry_test1〜 を呼ぶ)。bml は呼び手と違う短命の thread で
    # 走らせる — 戻り値はその thread の tid (tid ≠ tgid)
    def test_run_tracing(prog, n)
      SpinelBPF.check(SpinelBPFC.spinelbpf_run_tracing(@h, prog, n))
    end

    # map_get は整数の map の値 (Integer)。record の map は map_get_record (戻り値の型を 1 つに保つ — Integer と Array の両方を返すと、
    # 利用者の `S.new(v[0], …)` の引数が untyped になり、Spinel の whole-program の推論で record の member の型が壊れる — E022)。
    def map_get(map, key)
      SpinelBPF.array_only(map, "map_get")
      if map.record?
        raise MapMismatch, "spinelbpf: #{map.name} is a record map — read it with map_get_record"
      end
      SpinelBPF.check(SpinelBPFC.spinelbpf_map_get(@h, SpinelBPF.decl(map), key))
    end

    # unmet は load の時に止めなかった Unmet (判定できなかった requirement — 黙って捨てない) の行 (`kind\tprogram\tname\tdetail`)。
    def unmet
      r = SpinelBPFC.spinelbpf_object_unmet(@h)
      out = []
      if SpinelBPFC.spinelbpf_result_kind(r) == SpinelBPF::OK
        n = SpinelBPFC.spinelbpf_result_unmet_count(r)
        i = 0
        while i < n
          out << SpinelBPFC.spinelbpf_result_unmet(r, i)
          i += 1
        end
        SpinelBPFC.spinelbpf_result_free(r)
        return out
      end
      SpinelBPF.check(r)
      out
    end

    # map_put は map に Integer の値を書く (値の型の範囲の外・INT64_MIN は ValueRange — Spinel の nil の印と区別できない)。
    # map_get_record は record の map の member の値の Array を返す。**並びは BPF.record の宣言の順 (= Struct の member の順 —
    # frontend が一致を強制)、padding の member を含む**。Struct は `S.new(v[0], v[1], …)` で (引数の数が member の数と違えば frontend が SB024 で止める)。
    def map_get_record(map, key)
      SpinelBPF.array_only(map, "map_get_record")
      if !map.record?
        raise MapMismatch, "spinelbpf: #{map.name} is not a record map — read it with map_get"
      end
      SpinelBPF.record_get(@h, map, key)
    end

    # map_put は整数の map に Integer を書く。record の map は map_put_record (引数の型を 1 つに保つ — 公開の API は単相、E022 のレビューの P2)。
    def map_put(map, key, value)
      SpinelBPF.array_only(map, "map_put")
      if map.record?
        raise MapMismatch, "spinelbpf: #{map.name} is a record map — write it with map_put_record"
      end
      SpinelBPF.check(SpinelBPFC.spinelbpf_map_put(@h, SpinelBPF.decl(map), key, value))
    end

    # map_put_record は record の map に Struct を書く (member の値を型の範囲で確かめる — 外・nil・padding の 0 以外は ValueRange)。
    def map_put_record(map, key, rec)
      SpinelBPF.array_only(map, "map_put_record")
      if !map.record?
        raise MapMismatch, "spinelbpf: #{map.name} is not a record map — write it with map_put"
      end
      SpinelBPF.record_put(@h, map, key, rec)
    end

# map_put_record_values は record の map に平らな値の Array を書く (map_get_record と同じ並び — 配列の member は要素ごと、padding を含む — P016 E066)。
# 配列の member を持つ record はこれで書く (map_put_record の Struct の配列の member は数が合わず ValueRange)。値は Integer の Array だけ (単相)。
def map_put_record_values(map, key, values)
  SpinelBPF.array_only(map, "map_put_record_values")
  if !map.record?
    raise MapMismatch, "spinelbpf: #{map.name} is not a record map — write it with map_put"
  end
  SpinelBPF.record_put_values(@h, map, key, values)
end

    def test_run_xdp(prog, repeat)
      SpinelBPF.check(SpinelBPFC.spinelbpf_test_run_xdp(@h, prog, repeat))
    end

    # test_run_xdp_packet は program を 1 回、bytes (Integer の Array、各 0..255 — 外は ValueRange) の packet で走らせ、xdp の判定を返す (P004 §3)。
    # kernel は 14 byte 未満の data を拒否する (SpinelBPF::Error)。
    def test_run_xdp_packet(prog, bytes)
      SpinelBPF.check(SpinelBPFC.spinelbpf_test_run_xdp_packet(@h, prog, bytes, bytes.length))
    end

    # test_run_tc_packet は sched_cls の program を 1 回、bytes の packet (skb) で走らせ、判定 (BPF::TC_PASS 0 / TC_DROP 2) を返す (P019 E077)。
    # byte と長さの検査は test_run_xdp_packet と同じ文。kernel は 14 byte 未満と、ethertype の header に足りない data (IPv4 34・IPv6 54 byte 未満 —
    # net/bpf/test_run.c) を EINVAL で拒否する (SpinelBPF::Error — bml の hint 付き)
    def test_run_tc_packet(prog, bytes)
      n = bytes.length
      if n > 0xffff
        raise Other, "spinelbpf: packet length #{n} is outside 0..65535"
      end
      i = 0
      while i < n
        v = bytes[i]
        if v < 0 || v > 255
          raise ValueRange, "spinelbpf: packet byte #{i} is #{v}, outside 0..255"
        end
        i += 1
      end
      SpinelBPF.check(SpinelBPFC.spinelbpf_run_tc_packet(@h, prog, bytes, n))
    end

    # test_run_skb_packet は socket_filter の program を 1 回、bytes の frame (skb) で走らせ、判定 (BPF::SF_KEEP −1 / SF_DROP 0 — kernel の retval を int32 で) を
    # 返す (P026 E126)。byte と長さの検査は test_run_tc_packet と同じ文。kernel は eth の 14 byte を外す (len は n − 14)、14 byte 未満は EINVAL (bml の hint 付き)
    def test_run_skb_packet(prog, bytes)
      n = bytes.length
      if n > 0xffff
        raise Other, "spinelbpf: packet length #{n} is outside 0..65535"
      end
      i = 0
      while i < n
        v = bytes[i]
        if v < 0 || v > 255
          raise ValueRange, "spinelbpf: packet byte #{i} is #{v}, outside 0..255"
        end
        i += 1
      end
      SpinelBPF.check(SpinelBPFC.spinelbpf_run_skb_packet(@h, prog, bytes, n))
    end

    # test_run_netfilter は netfilter の program を 1 回、bytes の packet で走らせ、判定 (BPF::NF_ACCEPT 1 / NF_DROP 0) を返す (P026 E128)。pf は 2 / 10、
    # hook は 0〜4 (外は bml の ValueRange)。kernel は LOCAL_OUT (3) の bytes を IP の packet (len は n)、他の hook の bytes を eth の frame (len は n − 14) として
    # 扱う。byte と長さの検査は test_run_tc_packet と同じ文
    def test_run_netfilter(prog, bytes, pf, hook)
      n = bytes.length
      if n > 0xffff
        raise Other, "spinelbpf: packet length #{n} is outside 0..65535"
      end
      i = 0
      while i < n
        v = bytes[i]
        if v < 0 || v > 255
          raise ValueRange, "spinelbpf: packet byte #{i} is #{v}, outside 0..255"
        end
        i += 1
      end
      SpinelBPF.check(SpinelBPFC.spinelbpf_run_netfilter(@h, prog, bytes, n, pf, hook))
    end

    # hash の map (P008 §3 — 名前ごとに引数と戻り値の型が 1 つ): 整数の key は hash_*、record の key (`K.new(…)`) は hash_*_rk、record の値は *_record。
    # 無い key の get は SpinelBPF::NotFound (nil を返さない)、満杯の hash への新しい key の put は Other (E2BIG)、範囲の外・padding の 0 以外は ValueRange。
    def hash_get(map, k)
      SpinelBPF.hash_get(@h, map, [k], false, false, "hash_get")[0]
    end

    def hash_get_record(map, k)
      SpinelBPF.hash_get(@h, map, [k], false, true, "hash_get_record")
    end

    def hash_get_rk(map, key)
      SpinelBPF.hash_get(@h, map, key.to_a, true, false, "hash_get_rk")[0]
    end

    def hash_get_record_rk(map, key)
      SpinelBPF.hash_get(@h, map, key.to_a, true, true, "hash_get_record_rk")
    end

    def hash_has(map, k)
      begin
        SpinelBPF.hash_get(@h, map, [k], false, map.record?, "hash_has")
      rescue SpinelBPF::NotFound
        return false
      end
      true
    end

    def hash_has_rk(map, key)
      begin
        SpinelBPF.hash_get(@h, map, key.to_a, true, map.record?, "hash_has_rk")
      rescue SpinelBPF::NotFound
        return false
      end
      true
    end

    def hash_put(map, k, v)
      SpinelBPF.hash_put(@h, map, [k], [v], false, false, "hash_put")
    end

    def hash_put_record(map, k, rec)
      SpinelBPF.hash_put(@h, map, [k], rec.to_a, false, true, "hash_put_record")
    end

    def hash_put_rk(map, key, v)
      SpinelBPF.hash_put(@h, map, key.to_a, [v], true, false, "hash_put_rk")
    end

    def hash_put_record_rk(map, key, rec)
      SpinelBPF.hash_put(@h, map, key.to_a, rec.to_a, true, true, "hash_put_record_rk")
    end

    # hash_delete は在った key を消せば true、無ければ false (他の誤りは raise)。
    def hash_delete(map, k)
      SpinelBPF.hash_delete(@h, map, [k], false, "hash_delete")
    end

    def hash_delete_rk(map, key)
      SpinelBPF.hash_delete(@h, map, key.to_a, true, "hash_delete_rk")
    end

    # hash_keys は key の Integer の Array、hash_keys_rk は key の member の値の Array の Array (`K.new(k[0], …)` で Struct に)。
    def hash_keys(map)
      out = []
      ks = SpinelBPF.hash_keys(@h, map, false, "hash_keys")
      i = 0
      while i < ks.length
        out.push(ks[i][0])
        i += 1
      end
      out
    end

    def hash_keys_rk(map)
      SpinelBPF.hash_keys(@h, map, true, "hash_keys_rk")
    end

    # lpm_trie の map (E121 — IPv4 の最長一致)。prefix は "a.b.c.d/n"、address は "a.b.c.d" の文字列 (bml が読む — IPv6・不正・host の bit の立った prefix は
    # kernel に触らずに Other、文が直し方を名指す)。値は宣言の型 (:u32 / :i32) の範囲で確かめる (外は ValueRange — bml は値の幅に黙って切る)。
    # lpm_put は書く (満杯で新しい prefix は Other の ENOSPC — hash_put の E2BIG と同じ形、在る prefix の上書きは満杯でも成功)。
    def lpm_put(map, prefix, v)
      SpinelBPF.lpm_check(map, "lpm_put")
      SpinelBPF.lpm_value(map, v)
      st = SpinelBPF.check(SpinelBPFC.spinelbpf_lpm_put(@h, SpinelBPF.decl(map), prefix, v))
      if st == -28
        raise Other, "spinelbpf: lpm_put #{map.name} #{prefix}: ENOSPC — map is full (#{map.max_entries} prefixes; overwriting an existing prefix still works)"
      end
      nil
    end

    # lpm_remove は prefix を消す (消せば true、無ければ false — hash_delete と同じ)。
    def lpm_remove(map, prefix)
      SpinelBPF.lpm_check(map, "lpm_remove")
      SpinelBPF.check(SpinelBPFC.spinelbpf_lpm_remove(@h, SpinelBPF.decl(map), prefix)) == 0
    end

    # lpm_match は address の最長一致の値 (kernel の lookup — 無ければ NotFound、hash_get と同じ)。
    def lpm_match(map, addr)
      SpinelBPF.lpm_check(map, "lpm_match")
      r = SpinelBPFC.spinelbpf_lpm_match(@h, SpinelBPF.decl(map), addr)
      if SpinelBPFC.spinelbpf_result_kind(r) != SpinelBPF::OK
        SpinelBPF.check(r)
        return 0
      end
      m = SpinelBPFC.spinelbpf_result_message(r)
      v = SpinelBPFC.spinelbpf_result_value(r)
      SpinelBPFC.spinelbpf_result_free(r)
      if m != "found"
        raise NotFound, "spinelbpf: lpm_match #{map.name} #{addr}: no prefix contains the address"
      end
      SpinelBPF.lpm_signed(map, v)
    end

    # lpm_has は address を含む prefix が在るか。
    def lpm_has(map, addr)
      begin
        lpm_match(map, addr)
      rescue SpinelBPF::NotFound
        return false
      end
      true
    end

    # lpm_list は全ての prefix と値の "a.b.c.d/n v" の行 (bml の順 — 行の byte の順、v は宣言の符号の 10 進)。
    def lpm_list(map)
      SpinelBPF.lpm_check(map, "lpm_list")
      r = SpinelBPFC.spinelbpf_lpm_list(@h, SpinelBPF.decl(map))
      if SpinelBPFC.spinelbpf_result_kind(r) != SpinelBPF::OK
        SpinelBPF.check(r)
      end
      m = SpinelBPFC.spinelbpf_result_message(r)
      SpinelBPFC.spinelbpf_result_free(r)
      out = [""]
      out.pop
      lines = m.split("\n")
      i = 0
      while i < lines.length
        f = lines[i].split(" ")
        if f.length == 2
          out.push(f[0] + " " + SpinelBPF.lpm_signed(map, f[1].to_i).to_s)
        end
        i += 1
      end
      out
    end

    # per-CPU の map (P009 — 単相: CPU の数の Array、長さは SpinelBPF.possible_cpus)。percpu_array は percpu_*、percpu_hash は percpu_hash_* (record の key は _rk)。
    # user 空間の put は program の加算を上書きしうる (読んでから書く間の program の加算は失われる — 静止した表で使う)。
    def percpu_get(map, k)
      SpinelBPF.firsts(SpinelBPF.percpu_get(@h, map, [k], "percpu_array", false, false, "percpu_get"))
    end

    def percpu_get_record(map, k)
      SpinelBPF.percpu_get(@h, map, [k], "percpu_array", false, true, "percpu_get_record")
    end

    def percpu_put(map, k, vs)
      SpinelBPF.percpu_put(@h, map, [k], SpinelBPF.wraps(vs), "percpu_array", false, false, "percpu_put")
    end

    def percpu_put_record(map, k, recs)
      per = []
      i = 0
      while i < recs.length
        per.push(recs[i].to_a)
        i += 1
      end
      SpinelBPF.percpu_put(@h, map, [k], per, "percpu_array", false, true, "percpu_put_record")
    end

    def percpu_hash_get(map, k)
      SpinelBPF.firsts(SpinelBPF.percpu_get(@h, map, [k], "percpu_hash", false, false, "percpu_hash_get"))
    end

    def percpu_hash_get_record(map, k)
      SpinelBPF.percpu_get(@h, map, [k], "percpu_hash", false, true, "percpu_hash_get_record")
    end

    def percpu_hash_get_rk(map, key)
      SpinelBPF.firsts(SpinelBPF.percpu_get(@h, map, key.to_a, "percpu_hash", true, false, "percpu_hash_get_rk"))
    end

    def percpu_hash_get_record_rk(map, key)
      SpinelBPF.percpu_get(@h, map, key.to_a, "percpu_hash", true, true, "percpu_hash_get_record_rk")
    end

    def percpu_hash_put(map, k, vs)
      SpinelBPF.percpu_put(@h, map, [k], SpinelBPF.wraps(vs), "percpu_hash", false, false, "percpu_hash_put")
    end

    def percpu_hash_put_rk(map, key, vs)
      SpinelBPF.percpu_put(@h, map, key.to_a, SpinelBPF.wraps(vs), "percpu_hash", true, false, "percpu_hash_put_rk")
    end

    def percpu_hash_put_record(map, k, recs)
      per = []
      i = 0
      while i < recs.length
        per.push(recs[i].to_a)
        i += 1
      end
      SpinelBPF.percpu_put(@h, map, [k], per, "percpu_hash", false, true, "percpu_hash_put_record")
    end

    def percpu_hash_put_record_rk(map, key, recs)
      per = []
      i = 0
      while i < recs.length
        per.push(recs[i].to_a)
        i += 1
      end
      SpinelBPF.percpu_put(@h, map, key.to_a, per, "percpu_hash", true, true, "percpu_hash_put_record_rk")
    end

    def percpu_hash_has(map, k)
      begin
        SpinelBPF.percpu_get(@h, map, [k], "percpu_hash", false, map.record?, "percpu_hash_has")
      rescue SpinelBPF::NotFound
        return false
      end
      true
    end

    def percpu_hash_has_rk(map, key)
      begin
        SpinelBPF.percpu_get(@h, map, key.to_a, "percpu_hash", true, map.record?, "percpu_hash_has_rk")
      rescue SpinelBPF::NotFound
        return false
      end
      true
    end

    def percpu_hash_delete(map, k)
      SpinelBPF.percpu_check(map, "percpu_hash", false, map.record?, "percpu_hash_delete")
      kl = SpinelBPF.key_layout(map)
      SpinelBPF.check(SpinelBPFC.spinelbpf_hash_delete(@h, SpinelBPF.decl(map), SpinelBPF.pack(kl, [k], map.name, "key"), kl[0])) == 1
    end

    def percpu_hash_delete_rk(map, key)
      SpinelBPF.percpu_check(map, "percpu_hash", true, map.record?, "percpu_hash_delete_rk")
      kl = SpinelBPF.key_layout(map)
      SpinelBPF.check(SpinelBPFC.spinelbpf_hash_delete(@h, SpinelBPF.decl(map), SpinelBPF.pack(kl, key.to_a, map.name, "key"), kl[0])) == 1
    end

    def percpu_hash_keys(map)
      SpinelBPF.percpu_check(map, "percpu_hash", false, map.record?, "percpu_hash_keys")
      SpinelBPF.firsts(SpinelBPF.raw_keys(@h, map))
    end

    def percpu_hash_keys_rk(map)
      SpinelBPF.percpu_check(map, "percpu_hash", true, map.record?, "percpu_hash_keys_rk")
      SpinelBPF.raw_keys(@h, map)
    end

    # ringbuf は ring buffer (BPF::RingBuf) の reader を開く。object の close は開いている reader を先に閉じる (後の read は State)。
    def ringbuf(ring)
      RingReader.new(SpinelBPF.check(SpinelBPFC.spinelbpf_ringbuf_open(@h, ring.name)), ring)
    end

    def close
      SpinelBPF.check(SpinelBPFC.spinelbpf_close(@h))
    end
  end
end
