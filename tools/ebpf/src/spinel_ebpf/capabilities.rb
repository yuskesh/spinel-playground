# frozen_string_literal: true
#
# E314 (ADR-014 層1): ドメイン capability registry。
#
# ADR-014 は機能を 3 層に分ける。層1 (probe DSL、カーネル側) の builtin を
# **ドメイン (Observability / Enforcement / Net / L7)** で括る分類メタデータ。
#
# 目的 (ADR-014 の明示制約に忠実):
#   * builtin は **flat のまま** (必須 dotted 名にしない、ワンショットのエルゴノミクスを殺さない)。
#     このモジュールは新しい言語機構ではなく、**既存 builtin を分類する純データ + 内省配線**。
#   * 発見可能性: 「このドメインにどの builtin と attach 種別がセットで来るか」を一覧化。
#   * context 契約の中央化: E286 の d_path ゲート (この builtin はこの hook でしか使えない、
#     compile 時 die) の allowlist を **単一の権威 (DPATH_OK_SECS)** に集約し、
#     codegen (Ruby oracle) と krew カタログ・内省が同じ真実を参照する。
#
# 非目標: 既存 probe の挙動・生成コードは一切変えない。これは分類メタデータであって、
# codegen ではない。die() ロジック自体は codegen_bpf.rb / spinel_ebpf_cc.c にある
# (本モジュールは allowlist の値だけを所有し、Ruby oracle がそれを参照する)。
#
# 依存なし (codegen_bpf.rb を require しない): builtin 名は下にリテラルで持つ。
# codegen の BUILTIN_NAMES との一致は tests/spinel_ebpf/capabilities_test.rb が守る
# (完全分割 = 未分類の新 builtin があれば test が落ちる = ADR-014 のガバナンス)。

module SpinelEbpf
  module Capabilities
    module_function

    # E286/E287/E289/E390 で実測した d_path ゲートの allowlist (単一の権威)。
    # bpf_d_path はカーネル gate 付きで、単純な名前リストではない — 実測で LOAD_OK した
    # hook のみ (ADR-003: 予測で足さない)。E390 が 7.1.5-ebpf で全マス実測した結果、
    # gate の形が見えた:
    #   * LSM prog       : **sleepable な lsm hook** でだけ許可 (だから lsm/file_open は
    #                      通り lsm/file_permission と lsm/path_chroot は落ちる)
    #   * fmod_ret/fentry: カーネル固定の btf_allowlist_d_path にある関数だけ
    #                      (だから fmod_ret/security_mmap_file は LSM 版が通るのに落ちる)
    #   * kprobe         : 構造的に不可 ("program of this type cannot use helper")
    #
    # 2 つ目の軸が **どの引数がパスを持つか**。hook ごとに違うので、SEC → 形 を持つ:
    #   :file   -> &((struct file *)arg)->f_path
    #   :path   -> (struct path *)arg                (security_path_* family、変換不要)
    #   :binprm -> &((struct linux_binprm *)arg)->file->f_path
    # guard: true は bpf_d_path の前に NULL チェック。lsm/mmap_file は防御ではなく
    # **load 必須** (引数が file__nullable、無 guard は "R1 pointer arithmetic on
    # trusted_ptr_or_null_ prohibited" で拒否 — E390 c12 vs c10)。
    #
    # codegen_bpf.rb の MethodEmitter::DPATH_OK_SECS はこの定数を参照する。
    # (production C codegen spinel_ebpf_cc.c は自前のコピーを持ち、両者の一致は
    # capabilities_test が守る。)
    # **`measured` は「load できた」しか言っていない (E418)**。利用者が知りたいのは
    # 「書いたポリシーは発火するか」なので、E418 が 32 本すべてを実発火まで測り、
    # 次の 3 列を足した:
    #
    #   fire:   :deny    発火 + **遮断まで**実測 (verdict を持つ hook)
    #           :observe 発火は実測。**戻り値は無視される** (fentry/fexit は verdict を
    #                    持たず、void hook は creds 確定後なので) = 監査専用
    #           :load_only  load しか確かめていない  ← E418 後は 0 件
    #   by:     **実測で** その hook に届いた操作。「自然に踏めそうな操作」ではない —
    #           close(2) は filp_close に、stat(2) は vfs_getattr に **届かない**
    #   fired:  その発火を測った Edoc の case id (弱い tier ほど出典が要る、E409 と同じ規則)
    #   caveat: 「素直に思いつく操作では踏めない」「取れるパスが期待と違う」hook にだけ付く。
    #           **これが本 registry で一番価値のある列**である (沈黙する誤解はここに集まる)
    #   no_select: **E420**。パスは取れるが、それが呼び出し側から見えるパスではないので
    #           **パス基準の選別 (`path_eq` / `path_starts_with` / `path_contains`) が
    #           構造的に成立しない** hook にだけ付く (現在 4 本)。E418 は caveat = 散文の
    #           警告に留めたが、ADR-003 は loud を求めており、**codegen は compile 時に
    #           両方の事実 (どの builtin か / どの SEC か) を知っている** ⇒ C 側
    #           (`CcDpathHook.no_select`) が die する。**非対称**であることが肝で、
    #           `emit_path` (記録) と `parent_path_eq` (パスが task chain 由来) は
    #           同じ hook で今も通る。set が C と一致することは capabilities_test が守る
    #
    # 注: `lsm/*` は **active LSM に `bpf` が入っていないと attach しても沈黙する**
    # (E390 負の対照 / E418 で再確認: 同一 probe が spnl715lsm では 605 回、
    # spnl715 では 0 回)。`fmod_ret` / `fentry` / `fexit` は tracing 型なので非依存
    # (E418 実測)。これは hook 個別でなく種別の性質なので `lsm_active_required?` で出す。
    DPATH_HOOKS = {
      # --- E286/E284: 起点の 3 hook (生成コードは byte-identical のまま) ---
      "lsm/file_open"                      => { form: :file,   guard: false, measured: "E286",
        fire: :deny,    by: "open(2)",                                fired: "E418 h01" },
      "fmod_ret/security_file_open"        => { form: :file,   guard: false, measured: "E286",
        fire: :deny,    by: "open(2)",                                fired: "E418 h16" },
      "fmod_ret/security_file_permission"  => { form: :file,   guard: false, measured: "E284 P7",
        fire: :deny,    by: "access checks of read(2)/write(2) and similar",       fired: "E418 h17" },
      # --- E390: `struct file *` 引数 ---
      "lsm/mmap_file"                      => { form: :file,   guard: true,  measured: "E390 c10",
        fire: :deny,    by: "mmap(2) (mapping a file)",           fired: "E418 h02" },
      "lsm/file_ioctl"                     => { form: :file,   guard: false, measured: "E390 c40",
        fire: :deny,    by: "ioctl(2)",                               fired: "E418 h03",
        caveat: "an ioctl on a regular file fails with **ENOTTY** even when let through. Judge the block " \
                "by **whether it is EPERM**, not by \"whether it succeeded\" (E418 measured: target=EPERM / control=ENOTTY)" },
      "lsm/file_lock"                      => { form: :file,   guard: false, measured: "E390 c41",
        fire: :deny,    by: "flock(2)",                               fired: "E418 h04" },
      "lsm/file_receive"                   => { form: :file,   guard: false, measured: "E390 c42",
        fire: :deny,    by: "recvmsg(2) receiving an fd with SCM_RIGHTS", fired: "E418 h05" },
      # --- E390: `struct linux_binprm *` 引数 (exec) ---
      "lsm/bprm_check_security"            => { form: :binprm, guard: true,  measured: "E390 c20",
        fire: :deny,    by: "execve(2)",                              fired: "E390 e2e" },
      "lsm/bprm_creds_for_exec"            => { form: :binprm, guard: true,  measured: "E390 c21",
        fire: :deny,    by: "execve(2)",                              fired: "E418 h06" },
      "lsm/bprm_committed_creds"           => { form: :binprm, guard: true,  measured: "E390 c22",
        fire: :observe, by: "execve(2)",                              fired: "E418 h07",
        caveat: "**void hook** — it fires but its return value is discarded (after creds are committed, so it cannot block). " \
                "E418 measured: exec succeeded even when it returned `-1`. Audit (emit_path) only" },
      # --- E390: 引数が既に `struct path *` ---
      "lsm/path_unlink"                    => { form: :path,   guard: false, measured: "E390 c30",
        fire: :deny,    by: "unlink(2) (ctx[0] is the parent directory)",    fired: "E390 e2e" },
      "lsm/path_rename"                    => { form: :path,   guard: false, measured: "E390 c31/c32",
        fire: :deny,    by: "rename(2) (ctx[0]=old_dir / ctx[2]=new_dir, both parent directories)",
        fired: "E418 h08" },
      "lsm/path_mkdir"                     => { form: :path,   guard: false, measured: "E390 c33",
        fire: :deny,    by: "mkdir(2) (ctx[0] is the parent directory)",     fired: "E418 h09" },
      "lsm/path_rmdir"                     => { form: :path,   guard: false, measured: "E390 c34",
        fire: :deny,    by: "rmdir(2) (ctx[0] is the parent directory)",     fired: "E418 h10" },
      "lsm/path_symlink"                   => { form: :path,   guard: false, measured: "E390 c35",
        fire: :deny,    by: "symlink(2) (ctx[0] is the parent directory)",   fired: "E418 h11" },
      "lsm/path_link"                      => { form: :path,   guard: false, measured: "E390 c36",
        fire: :deny,    by: "link(2)",                                fired: "E418 h12",
        caveat: "**the path is ctx[1] (new_dir)** — the only one in this family that is not ctx[0] " \
                "(ctx[0] is old_dentry, not a `struct path *`)" },
      "lsm/path_truncate"                  => { form: :path,   guard: false, measured: "E390 c37",
        fire: :deny,    by: "truncate(2) (path-based)",                fired: "E390 e2e",
        caveat: "**does not fire for ftruncate(2) or open(O_TRUNC)** — those are file-based and " \
                "go to `security_file_truncate` (outside the gate). The case E390 missed" },
      "lsm/path_chmod"                     => { form: :path,   guard: false, measured: "E390 c38",
        fire: :deny,    by: "chmod(2)",                               fired: "E418 h13" },
      "lsm/path_chown"                     => { form: :path,   guard: false, measured: "E390 c39",
        fire: :deny,    by: "chown(2)",                               fired: "E418 h14" },
      "lsm/inode_getattr"                  => { form: :path,   guard: false, measured: "E390 c43",
        fire: :deny,    by: "stat(2)/statx(2)",                       fired: "E418 h15" },
      "fmod_ret/security_path_truncate"    => { form: :path,   guard: false, measured: "E390 c3c",
        fire: :deny,    by: "truncate(2) (path-based)",                fired: "E390 e2e",
        caveat: "**does not fire for ftruncate(2) or open(O_TRUNC)** (the same granularity as lsm/path_truncate)" },
      "fmod_ret/security_inode_getattr"    => { form: :path,   guard: false, measured: "E390 c44",
        fire: :deny,    by: "stat(2)/statx(2)",                       fired: "E418 h18" },
      # --- E390: カーネル自身の btf_allowlist_d_path (観測専用 — fentry/fexit は
      # verdict を持たないので、ここに deny を書いても黙って無視される。E418 で実測) ---
      "fentry/filp_close"                  => { form: :file,   guard: false, measured: "E390 c60",
        fire: :observe, by: "fd cleanup at process exit (put_files_struct) / O_CLOEXEC cleanup at exec " \
                          "(do_close_on_exec) / dup2(2)", fired: "E418 h19",
        caveat: "**does not fire for close(2)** — close(2) in 7.1.5 calls `filp_flush` directly " \
                "(ftrace measured: filp_flush<-__arm64_sys_close 30 times, filp_close 0 times)" },
      "fexit/filp_close"                   => { form: :file,   guard: false, measured: "E390 c66",
        fire: :observe, by: "fd cleanup at process exit (put_files_struct) / O_CLOEXEC cleanup at exec " \
                          "(do_close_on_exec) / dup2(2)", fired: "E418 h20",
        caveat: "**does not fire for close(2)** (the same as fentry/filp_close)" },
      "fentry/vfs_fallocate"               => { form: :file,   guard: false, measured: "E390 c64",
        fire: :observe, by: "fallocate(2)",                           fired: "E418 h21" },
      "fexit/vfs_fallocate"                => { form: :file,   guard: false, measured: "E390 c6a",
        fire: :observe, by: "fallocate(2)",                           fired: "E418 h22" },
      "fentry/vfs_truncate"                => { form: :path,   guard: false, measured: "E390 c61",
        fire: :observe, by: "truncate(2) (path-based)",                fired: "E418 h23",
        caveat: "**does not fire for ftruncate(2) or open(O_TRUNC)** (path-based only)" },
      "fexit/vfs_truncate"                 => { form: :path,   guard: false, measured: "E390 c67",
        fire: :observe, by: "truncate(2) (path-based)",                fired: "E418 h24",
        caveat: "**does not fire for ftruncate(2) or open(O_TRUNC)** (path-based only)" },
      "fentry/dentry_open"                 => { form: :path,   guard: false, measured: "E390 c62",
        fire: :observe, by: "kernel-internal calls such as overlayfs's `ovl_path_open` / `fsmount(2)`", fired: "E418 h25",
        caveat: "**does not fire for open(2)** (open goes through do_filp_open and does not pass here; ftrace measured 0 times). " \
                "Also, the path it gets is drawn **relative to overlayfs's internal mount**, not the path " \
                "the caller sees (E418 measured: `/f`, not `/tmp/x/low/f`). **It cannot tell a file from a " \
                "file of the same name in another directory**, so do not write path-based selection here",
        no_select: "the path is available but relative to overlayfs's internal mount (E418 measured `/f`), and the control's " \
                   "file of the same name in another directory was drawn as the same `/f` ⇒ selection does not hold. " \
                   "Recording is still possible with `emit_path`. To select open(2), use " \
                   "`def lsm__file_open` / `def fmod_ret__security_file_open`" },
      "fexit/dentry_open"                  => { form: :path,   guard: false, measured: "E390 c68",
        fire: :observe, by: "kernel-internal calls such as overlayfs's `ovl_path_open` / `fsmount(2)`", fired: "E418 h26",
        caveat: "**does not fire for open(2)**. The path is also relative to overlayfs internals (the same as fentry/dentry_open)",
        no_select: "the same as fentry/dentry_open (E418 h25/h26 are drawn identically on both sides). " \
                   "To select open(2), use `def lsm__file_open` / `def fmod_ret__security_file_open`" },
      "fentry/vfs_getattr"                 => { form: :path,   guard: false, measured: "E390 c63",
        fire: :observe, by: "kernel-internal calls such as overlayfs copy-up (`ovl_copy_up_one`)",
        fired: "E418 h27",
        caveat: "**does not fire for stat(2)** — stat calls `vfs_getattr_nosec` directly " \
                "(ftrace measured: nosec 79 times against vfs_getattr 0 times). To see stat, " \
                "use `lsm/inode_getattr` or `fmod_ret/security_inode_getattr`. " \
                "The path is also relative to overlayfs internals (`/f`) and cannot be told from a file of the same name in another directory",
        no_select: "the path is available but relative to overlayfs's internal mount (E418 measured `/f`), so selection does not hold. " \
                   "Recording is still possible with `emit_path`. To select stat(2), use " \
                   "`def lsm__inode_getattr` / `def fmod_ret__security_inode_getattr`" },
      "fexit/vfs_getattr"                  => { form: :path,   guard: false, measured: "E390 c69",
        fire: :observe, by: "kernel-internal calls such as overlayfs copy-up (`ovl_copy_up_one`)",
        fired: "E418 h28",
        caveat: "**does not fire for stat(2)** (the same as fentry/vfs_getattr; stat goes to lsm/inode_getattr)",
        no_select: "the same as fentry/vfs_getattr. To select stat(2), use " \
                   "`def lsm__inode_getattr` / `def fmod_ret__security_inode_getattr`" },
    }.freeze

    # E420: パス**選別**が構造的に成立しない SEC (上の `no_select`)。C 側の
    # `CcDpathHook.no_select` が実際に die する側で、この定数は「利用者に何と言うか」。
    # 両者の **集合が一致すること** を capabilities_test が守る (散文は言語ごとに別)。
    DPATH_NO_SELECT_SECS = DPATH_HOOKS.select { |_, v| v[:no_select] }.keys.freeze

    # E420: 拒否される builtin と、同じ hook で許される builtin。非対称であること自体が
    # 本 gate の主張なので、両側を名指しで持つ (片側だけだと「hook ごと降ろした」と
    # 区別が付かない)。
    DPATH_SELECT_BUILTINS  = %w[path_eq path_starts_with path_contains].freeze
    DPATH_NONSELECT_BUILTINS = %w[emit_path emit_parent_path parent_path_eq].freeze

    # 実測で **落ちた** hook (E390)。gate に入れないが、理由つきで残す — 「同じ関数でも
    # attach 種別で結果が変わる」という E286 の教訓の実データ (推測で足さない根拠)。
    DPATH_MEASURED_REJECTED = {
      "lsm/file_permission"           => "helper call is not allowed in probe (a non-sleepable lsm hook, E286/E390 c04)",
      "lsm/path_chroot"               => "helper call is not allowed in probe (a non-sleepable lsm hook, E390 c3a)",
      "fmod_ret/security_mmap_file"   => "not in btf_allowlist_d_path (the LSM form lsm/mmap_file passes, E390 c11)",
      "fmod_ret/security_bprm_check"  => "not in btf_allowlist_d_path (E390 c23)",
      "fmod_ret/security_path_unlink" => "not in btf_allowlist_d_path (the LSM form lsm/path_unlink passes, E390 c3b)",
      "kprobe/*"                      => "program of this type cannot use helper bpf_d_path (structurally impossible, E390 c65 / E296)",
    }.freeze

    DPATH_OK_SECS = DPATH_HOOKS.keys.freeze

    # 層1 ドメイン registry。各ドメイン = {summary, builtins, attach_kinds}。
    # builtins は flat 名のまま (dotted に畳まない)。attach_kinds は「このドメインの
    # builtin が典型的に載る attach 種別」で、緩いメタデータ (強制ではない)。
    DOMAINS = {
      observability: {
        summary: "general observation — hist/latency/stack/profile/emit/task-storage, the counterpart of bcc tools",
        builtins: %w[
          spnl_emit spnl_emit_str spnl_emit_pair spnl_emit3 spnl_emit4
          emit_argv emit_comm comm_hash
          hist_observe hist_observe_by hist_observe_linear
          ktime_ns latency_start latency_end lat_start lat_end
          stack_id user_stack_id off_cpu_start off_cpu_observe
          task_load task_store task_incr task_swap
          leak_record leak_forget lock_edge
          mim_inc mim_get fifo_push fifo_pop lifo_push lifo_pop
          iter_task depth_inc depth_dec path_counter_inc
          kfield kptr emit_kfield_str kfield_str_eq
          attached_index attached_symbol_eq
          user_ringbuf_drain
        ].freeze,
        attach_kinds: %i[
          kprobe kprobe_multi kretprobe tracepoint raw_tp fentry fexit
          uprobe uretprobe usdt perf_event iter_task
        ].freeze,
      }.freeze,
      enforcement: {
        summary: "blocking, audit and lineage — deny (lsm/fmod_ret return value) + path/parent-path selectors (the counterpart of Tetragon)",
        builtins: %w[
          emit_path emit_parent_path path_eq path_starts_with path_contains parent_path_eq ppid
          has_cap has_cap_permitted has_cap_inheritable cap_effective ns_id in_host_ns file_type
        ].freeze,
        attach_kinds: %i[lsm fmod_ret kprobe tracepoint].freeze,
      }.freeze,
      net: {
        summary: "packet/socket datapath — pkt/xdp/tc/LB/NAT/conntrack/qdisc/tcp_cc/network span",
        builtins: %w[
          pkt_len pkt_eth_proto pkt_l4_proto pkt_ip4_src pkt_ip4_dst
          pkt_l4_sport pkt_l4_dport pkt_tcp_flags pkt_l4_payload_len
          pkt_ip6_src_hi pkt_ip6_src_lo pkt_ip6_dst_hi pkt_ip6_dst_lo
          pkt_tcp_seq pkt_tcp_ack
          pkt_dynptr_byte_at
          tail_call_to
          tcp_syncookie_gen tcp_syncookie_check tcp_synack_cookie
          tcp_reply_header tcp_reply_synack tcp_reply_data payload_starts
          emit_connect sock_owner_set
          blocklist_match cidr_blocklist_match
          sock_addr_ip4 sock_addr_port
          sock_sport sock_dport sock_saddr sock_daddr sock_family sock_state sock_protocol
          sock_saddr6_hi sock_saddr6_lo sock_daddr6_hi sock_daddr6_lo
          udp_dport udp_daddr
          cpumap_redirect xsk_redirect dev_redirect
          fib_lookup fib_lookup6 sk_lookup_tcp sk_assign_tcp redirect
          skb_load_byte skb_load_u16 skb_load_u32
          skb_store_byte skb_store_u16 skb_store_u32
          l3_csum_replace l3_csum_replace_ip l4_csum_replace l4_csum_replace_ip l4_offset
          flow_get flow_set flow_del
          arena_set arena_get arena_hash_set arena_hash_get arena_hash_del
          arena_list_push arena_list_sum
          tcp_sock_snd_cwnd tcp_sock_snd_ssthresh tcp_sock_snd_nxt tcp_sock_snd_una
          tcp_sock_packets_out tcp_sock_delivered tcp_sock_snd_cwnd_cnt
          tcp_sock_snd_cwnd_clamp tcp_sock_prior_cwnd
          tcp_sock_snd_cwnd_set tcp_sock_snd_ssthresh_set tcp_sock_snd_cwnd_cnt_set
          tcp_sock_snd_cwnd_add tcp_sock_snd_cwnd_cnt_add
          qdisc_skb_drop qdisc_init_prologue qdisc_reset_destroy_epilogue
          qdisc_watchdog_schedule qdisc_bstats_update
          queue_push queue_pop
          sock_ops_op sock_ops_state
          reuseport_hash worker_select
        ].freeze,
        attach_kinds: %i[
          xdp xdp_tail tc_ingress tc_egress
          sk_reuseport sk_msg sk_skb_verdict sk_skb_parser sock_ops
          cgroup_connect4 cgroup_bind4 sk_lookup socket_filter flow_dissector
          tcp_cc qdisc
        ].freeze,
      }.freeze,
      l7: {
        summary: "application protocol observation — HTTP/Redis/TLS plaintext/DNS span + L7 latency + off-CPU correlation",
        builtins: %w[
          http_req_start http_resp_stash http_emit
          redis_req_start redis_resp_stash redis_emit
          ssl_req_start ssl_resp_stash ssl_emit
          go_tls_write go_tls_req go_tls_resp_stash go_tls_emit
          dns_req_start dns_resp_stash dns_emit emit_dns emit_tcp_payload emit_tcp_stream
          req_start emit_l7
          offcpu_recv_stash offcpu_begin offcpu_account offcpu_emit
        ].freeze,
        attach_kinds: %i[kprobe kretprobe uprobe uretprobe tracepoint].freeze,
      }.freeze,
      core: {
        summary: "domain-independent primitives — arithmetic/process identity/cgroup id/control channel/sched_ext",
        builtins: %w[
          divu i32 pid tgid tid uid gid cpu_id cgroup_id field_exists
          scx_dispatch scx_consume scx_kick_cpu scx_pick_idle_cpu scx_create_dsq
        ].freeze,
        attach_kinds: %i[sched_ext].freeze,
      }.freeze,
    }.freeze

    # E286 context ゲート: これらの builtin は attach SEC が valid_secs に無いと
    # compile 時に die() する。die() 本体は codegen にあり、ここは「どの builtin が
    # どの context を要求するか」の中央メタデータ (domain -> valid-context の正本)。
    CONTEXT_GATES = {
      "emit_path"        => { domain: :enforcement, valid_secs: DPATH_OK_SECS }.freeze,
      "emit_parent_path" => { domain: :enforcement, valid_secs: DPATH_OK_SECS }.freeze,
      "path_eq"          => { domain: :enforcement, valid_secs: DPATH_OK_SECS }.freeze,
      "path_starts_with" => { domain: :enforcement, valid_secs: DPATH_OK_SECS }.freeze,
      "path_contains"    => { domain: :enforcement, valid_secs: DPATH_OK_SECS }.freeze,
      "parent_path_eq"   => { domain: :enforcement, valid_secs: DPATH_OK_SECS }.freeze,
    }.freeze

    # E435 Part B / D5: **取り違えると静かに間違う組**。
    #
    # E428 が見つけた形はこうである — 2 つの綴りがあり、(1) 同じ位置で両方とも型が
    # 通り、(2) 間違った方はエラーではなく**もっともらしい数**を返し、(3) よく試す
    # 環境では 2 つが**同じ数**を返すのでテストが素通りし、(4) 別の環境で静かに
    # 食い違う。E428 は 1 組を直したが、防ぐものは入れなかった。
    #
    # **在庫ではなく契約として持つ**: `gate:` を名乗る組は codegen が本当に拒否できな
    # ければならず、`gate: nil` の組は **なぜ gate にできないか** を書かねばならない
    # (E434 の `unexpressible` と同じ作法 — 「散文のまま置いておく」を既定にすると
    # 「全部機械可読」という嘘になる)。`evidence:` は :measured (Edoc に実測がある) /
    # :documented (機構は文書化済だが走らせていない) の 2 値。
    #
    # ⚠ **これは網羅ではない**。195 builtin を 4 条件で洗って残ったものであって、
    # 「他に無い」ことは測っていない。逆向き (実装 → claim) の掃き方が無いのが理由で、
    # E409 が map で作れた coverage に相当するものを、この軸ではまだ作れていない。
    CONFUSABLE = [
      { id: "udp_dst_direction",
        a: "sock_dport", b: "udp_dport",
        also: %w[sock_daddr udp_daddr],
        question_a: "the peer this socket is connected to",
        question_b: "where this datagram goes (msg_name wins; otherwise the connected peer)",
        agree_when: "a sender that connects (glibc res_send / python / busybox nslookup all do) — " \
                    "the 3 resolvers E295 passed all connected",
        disagree_when: "with an unconnected sender (dnsmasq's upstream forwarding is a bare sendto) " \
                       "skc_dport is 0 ⇒ `sock_dport(sk) == 53` is false and **nothing is reported**",
        wrong_answer: "0 (zero, not merely fewer)",
        gate: "cc_require_dgram_dst_direction",
        why_ungated: nil,
        evidence: :measured, experiment: "E428/E435" }.freeze,
      { id: "udp_dst_on_recv",
        a: "udp_dport", b: "sock_dport",
        also: %w[udp_daddr sock_daddr],
        question_a: "this datagram's destination — meaningful only in a send hook",
        question_b: "this socket's peer (the only thing that knows it on the receive side)",
        agree_when: "`recv()` / `recvfrom(…, NULL, NULL)` have a NULL msg_name, so " \
                    "udp_dport falls through to the connected peer and returns the right number",
        disagree_when: "a receiver (server / forwarder) that passes an address buffer to `recvmsg()` — " \
                       "at function entry it reads the **output buffer** the kernel has not written yet as a sockaddr",
        wrong_answer: "0 (when the family byte is not AF_INET/AF_INET6) or any 16-bit value",
        gate: "cc_require_dgram_dst_direction",
        why_ungated: nil,
        evidence: :documented, experiment: "E428/E435" }.freeze,
      { id: "current_task_in_softirq",
        a: "pid", b: "kfield(<task ptr>, \"task_struct\", \"tgid\")",
        also: %w[tgid tid uid gid cgroup_id comm_hash emit_comm ppid stack_id],
        question_a: "the tgid of the task now on the CPU",
        question_b: "the tgid of the task handed in",
        agree_when: "hooks that fire in process context (for loopback / same-host traffic " \
                    "state changes also happen in process context)",
        disagree_when: "hooks that fire via softirq — E294 measured: for outbound traffic " \
                       "`tracepoint__sock__inet_sock_set_state` gives `pid=0 comm=swapper/0`",
        wrong_answer: "the real pid of another task (neither an error nor zero)",
        gate: nil,
        why_ungated: "`cc_require_task_ctx` (E396) already exists for **the same read**, " \
                     "but only the 6 has_cap functions call it. Widening it to pid/uid/cgroup_id and so on " \
                     "**is not a compatible change** — probes shipped today use them in packet/socket context, " \
                     "and E294's case (a tracepoint) " \
                     "passes even today's gate, because `cc_task_ctx_kind_ok` **classifies by program type**. " \
                     "The right gate requires the invocation context, which the attach kind does not decide. " \
                     "E399 **rejects** `filter_by :pid` on the same hook, so " \
                     "the asymmetry remains: the declared form is protected and the hand-written form is not (measured and declared in E435)",
        evidence: :measured, experiment: "E294/E396/E399" }.freeze,
      { id: "sock_addr_family",
        a: "sock_daddr", b: "sock_daddr6_hi / sock_daddr6_lo",
        also: %w[sock_saddr sock_saddr6_hi sock_saddr6_lo],
        question_a: "the IPv4 address (skc_daddr) — meaningful only for AF_INET",
        question_b: "the IPv6 address (skc_v6_daddr)",
        agree_when: "IPv4-only traffic (all fixtures and examples are)",
        disagree_when: "an AF_INET6 socket — the default for dual-stack listeners (Go / Java / nginx binding `::`)",
        wrong_answer: "another address that looks routable. E395 m03 measured: `0x7f000006` = 127.0.0.6",
        gate: nil,
        why_ungated: "which one is right is decided by **`sock_family` at run time**, unknown at compile time. " \
                     "A gate could only target the shape \"reads one side without looking at the family\", " \
                     "and that would also reject legitimate probes (paths known to be v4 only). " \
                     "The affordance already says `meaningful only when sock_family == AF_INET`",
        evidence: :measured, experiment: "E395" }.freeze,
      { id: "sock_ops_state_outside_state_cb",
        a: "sock_ops_state", b: "sock_ops_state (guarded by sock_ops_op == STATE_CB)",
        also: [],
        question_a: "ctx->args[1] — \"the new TCP state\" only for STATE_CB",
        question_b: "the same read, limited to the callback where it has a meaning",
        agree_when: "a program whose cgroup flag enables only STATE_CB (the bundled demo and fixture both do)",
        disagree_when: "a program that also enables the CONNECT/RTT/RTO callbacks — args[1] is a different per-callback value",
        wrong_answer: "a small integer. `args[1] == 1` reads as equal to `TCP_STATE_ESTABLISHED`",
        gate: nil,
        why_ungated: "a kind gate exists (anything but sockops is rejected), but **on a different axis**. The right gate is " \
                     "**the data flow inside the program**: \"does the same handler look at `sock_ops_op` first\", " \
                     "and codegen does not look there today. E428 D3 named it as the same family and left it alone",
        evidence: :documented, experiment: "E428" }.freeze,
      { id: "implicit_tid_latency_key",
        a: "latency_start / latency_end", b: "lat_start(key) / lat_end(key)",
        also: [],
        question_a: "one map keyed by the current tid (one per unit)",
        question_b: "a key the author chose",
        agree_when: "one kprobe/kretprobe pair, non-recursive, same thread — every fixture and E083's own measurement",
        disagree_when: "two measured pairs in one unit, recursion, entry and exit on different threads " \
                       "(this codebase already says in `go_tls_resp_stash` that **the tid moves across a blocking Read**)",
        wrong_answer: "the inner (much shorter) difference, or 0 — both fall into the histogram's first bucket",
        gate: nil,
        why_ungated: "both are legitimate, and the choice is intent. A gate could only target " \
                     "the shape \"latency_start in two places in one unit\", which is exactly why E120 " \
                     "made `lat_start(key)`. **Not measured** (no measurement; " \
                     "only the template was read), so counting comes first",
        evidence: :documented, experiment: "E083/E120" }.freeze,
      { id: "sock_addr_port_direction",
        a: "sock_addr_port (in cgroup__connect4)", b: "sock_addr_port (in cgroup__bind4)",
        also: %w[sock_addr_ip4],
        question_a: "connect4: the **destination** about to be connected",
        question_b: "bind4: **its own** address about to be bound",
        agree_when: "a probe tested only with connect4 — both return a plausible port",
        disagree_when: "when the same probe is moved to bind4. The meanings swap",
        wrong_answer: "the port of the address on the other side",
        gate: nil,
        why_ungated: "the context declaration **allows both** (`kinds: %i[cgroup_connect4 cgroup_bind4]`), so " \
                     "the affordance gives no ground to reject. Codegen has no kind-mask die() either, and " \
                     "the declaration is **not enforced** today. The first thing to fix is the affordance's description; " \
                     "E435 only measured and declared it",
        evidence: :documented, experiment: "E105" }.freeze,
    ].freeze

    # E307 krew probe カタログ (--probe dns|file|l7|net) と層1 ドメインの対応。
    # file 監査 = Enforcement、dns/l7 = L7 (DNS は L7 プロトコル)、net = Net。
    KREW_PROBE_DOMAINS = {
      "dns"  => :l7,
      "file" => :enforcement,
      "l7"   => :l7,
      "net"  => :net,
    }.freeze

    # ===================================================================
    # E370 (S3、ringbuf 型付きチャネル計画): **record 契約を affordance に出す**。
    #
    # packed-record emit builtin (emit_dns 等) は「ringbuf に何バイト書き、それが
    # 最終的にどの OTLP 属性の span になるか」という契約の片端でしかない。S1 (E368) が
    # 物理レイアウトを、S3 (本節) が意味束縛を **data** にした。正本:
    #
    #   src/codegen_c/record_schema.h   -- 唯一の宣言 (フィールド + egress 属性)
    #     -> kernel の record struct     (S1、spinel_ebpf_cc.c が直読)
    #     -> userspace mirror + SPNL_EGRESS_* マクロ (S2/S3、runtime が消費)
    #     -> record_schema_gen.json      (S3、**この Ruby が読む**)
    #
    # **offset は読むだけで計算しない**。align 規則の実装は tools/gen_record_mirror.c の
    # layout() 1 箇所きり (E369 の申し送り: Ruby で書き直すのは 3 度目の手書き = 禁じ手)。
    # 再生成は `make -C src/codegen_c mirror` (JSON も header も同時に出る)。
    # ===================================================================

    RECORD_SCHEMA_JSON = File.expand_path("record_schema_gen.json", __dir__).freeze

    # ===================================================================
    # E433: **the record layouts also travel inside the .bpf.o**.
    #
    # Everything above is readable only by something that can run this Ruby. The
    # .bpf.o goes further than that -- E432 handed one to Go -- and until E433 it
    # WROTE the records without saying what they look like: a RINGBUF map declares
    # no value type and the struct is only ever a local pointer inside a `static`
    # function, so clang had no reason to put it in .BTF. The reader then copies
    # the layout by hand and is wrong silently.
    #
    # The fix is one pointer per channel that nothing reads, in a section libbpf
    # does not map. It makes clang emit the struct, and because all the witnesses
    # share one section the object also carries an INDEX of its record types
    # (DATASEC .spnl_records), so a generator on the other side does not have to
    # be told which types matter.
    #
    # `not_a_map` and `costs` are stated because the obvious spellings of the same
    # idea are not free, and a reader deciding whether to trust this needs the
    # difference: `__type(value, struct X)` on a ringbuf puts the type in BTF and
    # then FAILS TO LOAD under libbpf (the kernel refuses a ringbuf with
    # value_size != 0 -- measured: all 13 packed-channel goldens went ok ->
    # verifier_reject), and a witness with no section lands in .bss, where libbpf
    # creates an extra map.
    # ===================================================================
    RECORD_BTF = {
      section: ".spnl_records",
      var: "_spnl_rec_<struct_suffix>",
      emitted_for: "every packed-record channel the unit actually emits",
      index: "BTF DATASEC '.spnl_records' lists one Var per channel; each Var is a " \
             "pointer to that channel's record struct",
      reader_recipe: "bpf2go -type <unit>_<struct_suffix> (or ebpf-go's btf package: " \
                     "walk the .spnl_records datasec)",
      not_a_map: "libbpf skips the section (it prints 'elf: skipping unrecognized data " \
                 "section .spnl_records' at open) and creates nothing; the kernel-side " \
                 "map set is unchanged",
      costs: { text_bytes: 0, section_bytes_per_channel: 8, btf_bytes_per_channel: "~410-443",
               object_bytes_per_channel: "~576-616" },
      rejected_spellings: [
        { spelling: "__type(value, struct X) on the ringbuf map",
          in_btf: true, libbpf_loads: false,
          why: "libbpf sets value_size = sizeof(X); the kernel refuses a RINGBUF with " \
               "key_size or value_size != 0 (EINVAL). ebpf-go zeroes it instead " \
               "(MapType.canHaveValueSize), so this spelling looks correct if the only " \
               "loader tried is Go -- cilium/ebpf's own prebuilt ringbuffer example does " \
               "not load under libbpf either" },
        { spelling: "BTF_TYPE_EMIT(struct X)",
          in_btf: false, libbpf_loads: true,
          why: "((void)(type *)0) is the kernel's DWARF->pahole idiom. clang -target bpf " \
               "generates .BTF itself and only for types the program uses, so the cast is " \
               "optimised away and nothing is emitted" },
        { spelling: "a global witness with no SEC",
          in_btf: true, libbpf_loads: true,
          why: "lands in .bss, so libbpf creates an extra internal map (the skeleton grows " \
               "a `bss` member) -- a change to what the kernel loads, not just to metadata" },
        { spelling: "__attribute__((btf_decl_tag)) on the struct alone",
          in_btf: false, libbpf_loads: true,
          why: "a decl tag is emitted only for a type clang already emits; it cannot keep " \
               "an otherwise-unreferenced struct alive" },
      ],
    }.freeze

    # ===================================================================
    # E374 (ADR-017 D3-5): **userspace consumer DSL の語彙**を機械可読に。
    #
    # channel ごとの契約 (上の record_channels) が「何が読めるか」なら、こちらは
    # 「どう書くか」— `on_emit :<ch>` / `to_span` / `send_otlp` / `consume_records`、
    # そして `to_span` の**解決規則**。ここに載せるのは ADR-017 D3-5 の要求:
    # 「`to_span` は `on_emit :<ch>` ブロック内で解決される。スコープを越える書き方では
    # `<ch>_span(ev)` を使え」を、散文でなく **`context_note` として** (emit_path の
    # context gate と同型に) 出す。
    #
    # 層の線引き (ADR-017 D1/D2): これらは層 1 の**汎用の口**であって、span の中身は
    # 層 2 (egress 宣言) が所有する。だから `to_span` に「属性を足す引数」は無い —
    # probe が持つ自由は「送るか / いつ / 何回」であって span の中身ではない (D2)。
    # ===================================================================
    # ===================================================================
    # E392 (P011 S3): runtime parameters — the DSL surface, not a probe's
    # parameters. `describe` lists what a GIVEN probe declares; this key answers
    # the prior question an AI has to answer first: "can this program be narrowed
    # without writing a new one?" Getting that wrong is expensive in exactly one
    # direction — a model that does not know `param` exists will regenerate the
    # whole .rb to change a pid.
    #
    # `not_for` is load-bearing. The tempting misuse is a knob that changes while
    # the probe runs; .rodata is frozen at load, so that is a different mechanism
    # (E335, map-backed) with a different price (no dead-code elimination, kernel
    # floor 5.5). Saying so here is cheaper than saying it in a bug report.
    # ===================================================================
    RUNTIME_PARAMS = {
      form: "param :<name>[, default: <int literal>]   # top level, before the handlers",
      read_as: "the bare name inside an eBPF handler, e.g. `if target_pid == 0 || pid == target_pid`",
      set_by: "environment: SPNL_PARAM_<NAME> (uppercased name). Read once, at load.",
      type: "__s64 only (spinel-ebpf has no other scalar in eBPF, so there is no type to get wrong)",
      # Literal, not `Param::IMPLICIT_DEFAULT`: this file deliberately requires
      # nothing (see the header). Drift is caught by a unit test instead.
      default_when_omitted: 0,
      lowering: "volatile const __s64 spnl_param_<name> in .rodata; the loader assigns " \
                "skel->rodata-><sym> between __open() and __load(), then the kernel freezes the map.",
      kernel_floor: "5.2 (read-only map + BPF_MAP_FREEZE) — the same floor eBPF already needs, " \
                    "so declaring parameters does not narrow where a probe can run.",
      dead_code: "a parameter left at 0 is folded by the verifier, so a guard on it is absent from " \
                 "the loaded program rather than always-true. Adding a filter therefore costs nothing " \
                 "when it is not used (measured: E392, `bpftool prog dump xlated`).",
      not_for: "changing a value while the probe runs — .rodata is frozen at load. A live knob is a " \
               "map (E335), which cannot be constant-folded and needs kernel 5.5.",
      refused: [
        "a declared parameter no handler reads (the switch would be wired to nothing)",
        "a name that a builtin already owns — the builtin wins, so the parameter is unreachable",
        "`default:` that is not an integer literal (it is baked in at compile time)",
        "SPNL_PARAM_<X> set for an <X> this program never declared",
        "a value that does not parse completely as a 64-bit integer",
      ].freeze,
    }.freeze

    # ===================================================================
    # E399 (P011 S10): the in-kernel common filter.
    #
    # RUNTIME_PARAMS above answers "can this program be narrowed without being
    # rewritten". This key answers the one that comes before it, and that a model
    # asked to write a probe answers wrongly by default: **should it narrow at
    # all, and where does the narrowing go**. A probe that narrows in four of its
    # five handlers still reports everything, and no gate in this project can see
    # that (E386 S5: the channel balance report can say "nothing came out", never
    # "the wrong things came out"). One declaration covering the whole unit is the
    # shape that has no fifth handler to forget.
    #
    # `covers` / `refuses` are load-bearing and deliberately not softened: the
    # declaration is refused, not partially applied, when a handler in the unit is
    # a hook where "skip this event" would be a security decision.
    # ===================================================================
    COMMON_FILTER = {
      form: "filter_by :<key>[, :<key>...]   # top level, one declaration for the whole unit",
      applies_to: "every attach handler in the unit — injected by the codegen, not called by the handler",
      keys: {
        "pid"       => { env: "SPNL_FILTER_PID",       unset: 0,  means: "thread-group id (what userspace calls the pid)" },
        "tid"       => { env: "SPNL_FILTER_TID",       unset: 0,  means: "kernel thread id" },
        "uid"       => { env: "SPNL_FILTER_UID",       unset: -1, means: "effective uid; unset is -1 because uid 0 is root and must be selectable" },
        "gid"       => { env: "SPNL_FILTER_GID",       unset: -1, means: "effective gid; unset is -1 for the same reason" },
        "cgroup_id" => { env: "SPNL_FILTER_CGROUP_ID", unset: 0,  means: "cgroup id (= cgroup-dir inode) — one container / pod" },
        "comm"      => { env: "SPNL_FILTER_COMM",      unset: "", means: "task comm, exact 16-byte match, at most 15 characters" },
      }.freeze,
      combining: "AND over the keys that are SET. An unset key does not constrain, so " \
                 "SPNL_FILTER_PID=1 SPNL_FILTER_COMM=curl keeps only events that are both.",
      set_by: "environment, read once at load (same .rodata mechanism as `param`).",
      dead_code: "a key left unset is folded away by the verifier together with the " \
                 "bpf_get_current_* call it would have needed, so declaring keys you do not " \
                 "set costs nothing at run time (measured: E399, `bpftool prog dump xlated`).",
      covers: %w[kprobe kretprobe tracepoint raw_tp fentry fexit uprobe uretprobe usdt perf_event].freeze,
      refuses: [
        "a unit that also has a verdict hook (lsm / fmod_ret / xdp / tc / sk_* / cgroup-sock-addr): " \
        "there `return 0` is a decision, not a skip — split the probe",
        "a unit with no handler the filter can cover (the declaration would be wired to nothing)",
        "an unknown key, a key listed twice, a second `filter_by`, a non-symbol key",
        "SPNL_FILTER_<X> set for a key this program did not declare",
        "SPNL_FILTER_COMM longer than 15 characters (it could never match a task comm)",
      ].freeze,
      hand_written_equivalent: "`param :target_pid` + `if target_pid == 0 || pid == target_pid` per handler. " \
                               "Same generated guard; the difference is that the declaration cannot be " \
                               "applied to only some of the handlers.",
      not_for: "per-handler narrowing, or anything probe-specific (a path, a port, a syscall number). " \
               "That is `param` — the common filter only covers what every process-context hook has.",
    }.freeze

    # ===================================================================
    # E398 (P011 S9): the declarative USERSPACE consumer filter.
    #
    # COMMON_FILTER above answers "should this probe narrow, and where". This key
    # answers what is left over: the narrowings the kernel cannot do at all. The
    # two are not alternatives, and the question an AI gets wrong is which one it
    # is holding — so `line` is the first thing here, and the refusal that
    # enforces it is `refuses`[0].
    #
    # `not_implemented` is deliberately in the machine-readable surface rather
    # than only in prose: sort / top-N look adjacent to a filter, `SPNL_MAX_EVENTS`
    # already occupies the neighbouring space with a DIFFERENT meaning, and the
    # cheapest way to stop a model inventing `keep_if :dns, top: 10` is to say
    # here that it does not exist and what does.
    # ===================================================================
    CONSUMER_FILTER = {
      form: "keep_if :<channel>, <property>: :<operator>[, ...]   # top level, one per channel",
      applies_to: "the records the channel's `on_emit :<channel> do |ev|` block turns into spans — " \
                  "hoisted to the head of the generated handler, so it cannot be written too late",
      vocabulary: "the channel's published properties (channels[<id>].consumer.properties) — the " \
                  "same names `ev.<name>` reads. An unknown name is a compile error listing the real set.",
      operators: {
        "eq"       => { types: %w[int str], means: "value == the environment's" },
        "ne"       => { types: %w[int str], means: "value != the environment's" },
        "ge"       => { types: %w[int],     means: "value >= the environment's (e.g. only the slow ones)" },
        "le"       => { types: %w[int],     means: "value <= the environment's" },
        "contains" => { types: %w[str],     means: "substring, case-sensitive" },
      }.freeze,
      set_by: "environment: SPNL_KEEP_<CHANNEL>_<PROPERTY>, read per record by the generated " \
              "consumer. Unset does not constrain; an explicitly empty value is refused.",
      combining: "AND over the predicates that are SET — the same rule as the in-kernel filter, " \
                 "so there is one rule to learn rather than two.",
      # The line D1 draws, stated as the property it actually is.
      line: "a `keep_if` predicate may only name a narrowing the in-kernel filter cannot do. " \
            "`:eq` on a property whose declaration carries a `kfilter` (channels[<id>].consumer." \
            "properties[].kfilter) is refused and redirected to `filter_by :<key>`, which drops the " \
            "record before it is created and so saves the ringbuf and the drain as well as the send.",
      why_userspace: {
        "derived"       => "the value does not exist until userspace computes it (dns qname, http " \
                           "method/path/status, conn peer/direction) — E295: the in-kernel QNAME " \
                           "walk blows up verifier state, which is why it is a derivation at all",
        "no_kernel_key" => "the kernel wrote the field, but the common filter's vocabulary is fixed " \
                           "(pid tid uid gid cgroup_id comm) and has no key for a port or a duration",
        "cross_task"    => "the field is not the current task's value: conn/l7/http fill pid/comm/cgid " \
                           "from an entry stashed in an earlier task (E296 sock_owner_set), so the " \
                           "kernel key would select a different set — that is why `kfilter` is " \
                           "declared per field and not per name",
        "operator"      => "the in-kernel filter is equality-AND only: negation, thresholds and " \
                           "substrings have no in-kernel form",
      }.freeze,
      cost: "measured (E373): a record dropped here costs 0.41 us, a record sent costs 8.83 us, so " \
            "dropping 3.2% pays for the filter. It does NOT save the ringbuf or the drain — those " \
            "are already spent by the time the predicate runs.",
      span_unchanged: "a record that passes produces exactly the span the egress declaration says " \
                      "(ADR-017 D2). The filter changes whether a span is sent, never its contents; " \
                      "there is no way to add, drop or rewrite an attribute from Ruby.",
      refuses: [
        "`:eq` on a property with a kernel equivalent — use `filter_by :<key>` (it drops earlier)",
        "a property the channel does not publish (the message lists the real set)",
        "an operator the property's type does not accept (`qname: :ge`, `pid: :contains`)",
        "a channel with no typed consumer, or one this program does not consume",
        "a second `keep_if` for the same channel, or the same property twice",
        "SPNL_KEEP_<X> set for a predicate this program did not declare (loader sweep)",
        "an integer predicate whose value does not parse completely, or any empty value",
      ].freeze,
      hand_written_equivalent: "`next unless ev.<prop>.include?(ENV[...])` as the first statement of " \
                               "the block. Same generated Ruby; what the declaration adds is that it " \
                               "cannot be the second statement, cannot name an env var the loader " \
                               "does not know, and can be told apart from a narrowing the kernel " \
                               "could have done.",
      not_implemented: {
        "sort / top-N" => "not implemented. Ranking needs the stream stopped and a window declared, " \
                          "which is a different mechanism from a per-record predicate. Note that " \
                          "SPNL_MAX_EVENTS (E323) is NOT it: that is the FIRST K events then exit.",
        "--fields"     => "not offered, and not an omission: choosing which attributes leave the " \
                          "process is exactly what ADR-017 D2 rules out — the egress declaration " \
                          "owns the span's contents.",
        "-o json"      => "already exists as OTEL_EXPORTER_OTLP_PROTOCOL=http/json (E269). A second " \
                          "JSON would be a second name for the same thing.",
      }.freeze,
      not_for: "narrowing that the kernel can do (that is `filter_by`), or per-handler narrowing of " \
               "kernel-side work (that is `param`). This filter runs after the record has already " \
               "crossed into userspace.",
    }.freeze

    CONSUMER_DSL = [
      { name: "on_emit :<channel>",
        form: "on_emit :<channel> do |ev| ... end",
        layer: 1,
        summary: "a typed record consumer. The block is called once per record, and `ev` is a handle inside the drain " \
                 "(opaque). The set of `ev.<prop>` comes from the channel declaration (channels[<id>].consumer.properties).",
        context_note: "<channel> is only **a channel id that published a typed consumer**. " \
                      "An id that did not publish one (redis/offcpu/l7stream) is treated as an E242 named event " \
                      "(backward compatible). If an `emit :<channel>, v` of the same name is also present, compile fails.",
        gotcha: "`ev` is valid only within the current drain cycle. To keep values across cycles, copy the properties into Ruby variables." }.freeze,
      { name: "to_span",
        form: "to_span(ev)",
        layer: 1,
        summary: "builds one record into a span as the egress declaration says (channels[<id>].egress is authoritative). " \
                 "Returns a span handle; 0 = a record that does not become a span.",
        context_note: "**resolved when applied to the block-param of an `on_emit :<channel>` block, inside that block** " \
                      "(ADR-017 D3). In a program that consumes several channels, applying it outside the block or to a handle " \
                      "copied into another variable is a **compile error**. Then use the explicit form `<channel>_span(ev)`. " \
                      "In a program with only one typed channel it resolves wherever it is written.",
        gotcha: "there is no API to add span content from Ruby (ADR-017 D2: the egress declaration is authoritative). " \
                "The probe's freedom is \"whether / when / how many times to send\"." }.freeze,
      { name: "<channel>_span",
        form: "dns_span(ev)",
        layer: 1,
        summary: "the explicit form of `to_span` (an escape hatch that names the channel). For code the scope rule does not reach.",
        context_note: "**an escape hatch, not the main form** (ADR-017 D3-4). Normally use `to_span(ev)` " \
                      "inside an `on_emit :<channel>` block. Naming a channel that is not consumed is a compile error." }.freeze,
      { name: "send_otlp",
        form: "send_otlp(to_span(ev), endpoint)",
        layer: 1,
        summary: "adds a span to the send batch (the same as E308's funnel). Handle 0 is a no-op, so Ruby need not branch.",
        context_note: "the endpoint is the one from the first call in the cycle. The generated driver flushes once at the end of the cycle " \
                      "(one POST batch even when several channels are consumed)." }.freeze,
      { name: "consume_records",
        form: "st = consume_records(timeout_ms)",
        layer: 1,
        summary: "drain -> dispatch each record to its on_emit block -> flush the send batch. Returns the HTTP status of the last POST.",
        context_note: "**if it is not called, the handlers are never called** (E325: compile and verify stay green with 0 spans). " \
                      "Call it periodically inside the loop. When several channels are consumed, one call drains them all." }.freeze,
    ].freeze

    def self.deep_freeze(o)
      case o
      when Hash  then o.each_value { |v| deep_freeze(v) }; o.freeze
      when Array then o.each { |v| deep_freeze(v) }; o.freeze
      else o.freeze
      end
    end
    private_class_method :deep_freeze

    # 生成 JSON の channels (lazy、memoized)。欠けていたら **loud に落ちる**
    # (silent に空を返すと「契約が無い」と「生成し忘れ」が区別できない)。
    def record_schema_doc
      @record_schema_doc ||= begin
        require "json"
        unless File.exist?(RECORD_SCHEMA_JSON)
          raise "record schema artifact missing: #{RECORD_SCHEMA_JSON} " \
                "(regenerate with `make -C src/codegen_c mirror`)"
        end
        deep_freeze(JSON.parse(File.read(RECORD_SCHEMA_JSON), symbolize_names: true))
      end
    end

    def record_channels
      @record_channels ||= deep_freeze(record_schema_doc[:channels] || [])
    end

    # E397: 宣言された値マップ (型駆動 derived の正本)。**閉じた集合**の値 -> 名前で、
    # `authority` がその名前の出どころ、`btf_*` がそれを機械照合するための座標。
    # 属性値の候補を「実際に走らせて 1 個見る」以外の方法で知れる唯一の面なので、
    # describe / capabilities --json の両方に出す (ADR-015: AI がこれを読んで書ける形)。
    # E400: every declared metric, flattened across channels (each entry keeps its
    # channel id so a reader can get back to the records it aggregates).
    def record_metrics
      record_channels.flat_map { |c| Array(c[:metrics]).map { |m| m.merge(channel: c[:id]) } }
    end

    # E434 D0: the clock a record's timestamps are on, and the conversion to a
    # wall clock. A consumer that skips it emits spans dated 1970 and nothing
    # anywhere reports an error, so the conversion is published rather than
    # described.
    def record_clocks
      @record_clocks ||= deep_freeze(record_schema_doc[:clocks] || [])
    end

    # E434 D1/D2: the two rules a reader needs before it can build a span at all
    # -- what the start and end ARE, and which records make no span.
    def record_timing_line(egress)
      tf = egress[:timing_form] || {}
      clk = tf[:clock].to_s.empty? ? "" : format(" [%s]", tf[:clock])
      format("      span time: start = %s%s, end = %s; no span when: %s\n",
             tf[:start], clk, tf[:end], egress[:drop_when])
    end

    def record_bounds_sets
      Array(record_schema_doc[:bounds_sets])
    end

    def record_value_maps
      @record_value_maps ||= deep_freeze(record_schema_doc[:value_maps] || [])
    end

    # map id -> map (無ければ nil)。
    def record_value_map(id)
      record_value_maps.find { |m| m[:id] == id.to_s }
    end

    # channel id ("dns") -> channel hash (無ければ nil)。
    def record_channel(id)
      record_channels.find { |c| c[:id] == id.to_s }
    end

    # E372 (S5): **型付き consumer を公開している** channel だけ (`consumer` ブロックを
    # 持つもの)。S1-S3 だけ済んだ channel (conn/l7/http/…) は宣言的だが
    # `on_emit :<id>` の意味は変えない — そこは E242 named event のままでなければ
    # 既存プログラムが黙って別物になる。「宣言してある」と「Ruby の受け口がある」は
    # 別の話なので、id の集合も別にする。
    def typed_record_channels
      record_channels.select { |c| c[:consumer] }
    end

    # 型付き consumer を持つ channel id (`on_emit :<id>` が typed record になる集合)。
    def typed_record_channel_ids
      typed_record_channels.map { |c| c[:id] }
    end

    # emit builtin -> その builtin が書く channel (producer でなければ nil)。
    def record_channel_for(builtin)
      record_channels.find { |c| Array(c[:producers]).include?(builtin) }
    end

    # packed record を書く builtin すべて (sorted)。
    def record_producers
      record_channels.flat_map { |c| Array(c[:producers]) }.sort.freeze
    end

    # E371 (S4): channel id -> 型付き consumer が読めるプロパティ宣言
    # ([{name:, kind:, expose:, ffi:, ffi_ret:, source:, note:}])。
    # `on_emit :<id> do |ev|` の `ev.<name>` の**権威集合**で、consumer.rb の
    # 変換はここに無い名前を compile 時に落とす。
    def record_properties(id)
      c = record_channel(id)
      Array(c && c.dig(:consumer, :properties))
    end

    # --- query API (内省が使う) ---

    # すべての分類済 builtin (sorted)。
    def all_builtins
      DOMAINS.values.flat_map { |d| d[:builtins] }.sort.freeze
    end

    # builtin 名 -> ドメイン symbol (未分類なら nil)。
    def domain_of(name)
      DOMAINS.each { |dom, spec| return dom if spec[:builtins].include?(name) }
      nil
    end

    def builtins_for(domain)
      DOMAINS.dig(domain, :builtins) || []
    end

    # gated builtin -> {domain:, valid_secs:} (非 gate なら nil)。
    def gate_for(name)
      CONTEXT_GATES[name]
    end

    # E418: この SEC は「発火するか」まで実測されているか。gate に無ければ nil。
    def dpath_fire(sec)
      DPATH_HOOKS[sec]
    end

    # E418: `lsm/*` は active LSM に `bpf` が無いと **attach しても沈黙する**
    # (E390 負の対照 / E418 で同一 probe が 605 回 vs 0 回)。fmod_ret/fentry/fexit は
    # tracing 型なので非依存 (E418 実測)。hook 個別でなく **種別** の性質。
    def lsm_active_required?(sec)
      sec.to_s.start_with?("lsm/")
    end

    # E418: 1 hook を 1 行で。「何で踏めるか」「遮断できるか」「落とし穴」。
    def dpath_fire_line(sec)
      h = DPATH_HOOKS[sec] or return nil
      tier = { deny: "fire + block measured", observe: "fire only measured (**the return value is ignored**)",
               load_only: "**only load was checked**" }[h[:fire]] || h[:fire].to_s
      s = format("%s — %s / operations that trigger it: %s [%s]", sec, tier, h[:by], h[:fired])
      s += "\n      ⚠ #{h[:caveat]}" if h[:caveat]
      # E420: 警告ではなく**事実**として出す — この hook で選別を書いた probe は
      # そもそも compile を通っていないので、`describe` の読者は「書けない」と
      # 「書いたが効かない」を混同しない。
      s += "\n      ✗ path selection (#{DPATH_SELECT_BUILTINS.join(' / ')}) **dies at compile time** " \
           "— #{h[:no_select]} / recording (#{DPATH_NONSELECT_BUILTINS.join(' / ')}) is allowed" if h[:no_select]
      s += "\n      ⚠ without `bpf` in the active LSMs, attaching **stays silent** " \
           "(the counter stays 0. E390/E418 measured)" if lsm_active_required?(sec)
      s
    end

    # 与えた builtin 名の集合を使っているドメインだけ {domain => [names(sorted)]} で返す。
    def domains_used(names)
      seen = names.to_a.uniq
      DOMAINS.each_key.filter_map do |dom|
        hit = builtins_for(dom) & seen
        [dom, hit.sort] unless hit.empty?
      end.to_h
    end

    # E370 (S3): packed-record チャネルの人間可読ダンプ。
    # 「この builtin を書くと ringbuf に何が流れ、どの属性の span になるか」の 1 画面。
    def record_channels_report
      out = +"record channels (E368-E371 — the byte image flowing through the ringbuf / typed consumer / the span it becomes):\n"
      record_channels.each do |c|
        out << format("  %-6s %s (%d B) <- %s\n",
                      c[:id], c[:record_struct], c[:record_bytes], Array(c[:producers]).join(" / "))
        c[:fields].each do |f|
          type = f[:count].to_i > 0 ? "#{f[:ctype]}[#{f[:count]}]" : f[:ctype]
          out << format("    @%-4d %-14s %-22s %s\n", f[:offset], f[:name], type, f[:note])
        end
        cons = c[:consumer]
        if cons
          # E371 (S4): 型付き consumer — 同じ record を Ruby で受けて自前ロジックを
          # 挟める形。properties が `ev.<name>` の権威集合 (これ以外は compile error)。
          out << format("    consumer: %s   (drain %s / to_span %s / send %s)\n",
                        cons[:form], cons[:drain_fn], cons[:to_span_fn], cons[:send_fn])
          Array(cons[:properties]).each do |p|
            # E378: derived な文字列プロパティは **出力容量**も宣言の一部 (accessor と span
            # builder が同じ幅を渡す = E377)。宣言 >= 返しうる最大長 なので「この値は最大
            # 何バイトか」が層 1 から読める。フィールド由来は record のバイトを直接読むので
            # 幅はフィールドの bytes (上の行) が持つ。
            # 表示は「値の最大バイト数」= 宣言 cap - 1 (cap は NUL を含む器の大きさ)。
            width = p[:cap].to_i > 1 ? format(" (<=%dB)", p[:cap].to_i - 1) : ""
            # E434: for a derived property, WHO computes the body. "declared" = the
            # contract does; anything else names work a consumer outside this
            # process has to do (and "ambient" names work it cannot do at all).
            res = p[:kind] == "derived" ? format("  {%s}", p[:residue]) : ""
            out << format("      ev.%-12s %-4s %-8s <- %s%s%s\n",
                          p[:name], p[:expose], p[:kind], p[:source], width, res)
          end
        end
        e = c[:egress]
        next unless e
        out << format("    egress: %s -> span \"%s\" (SpanKind %s)\n", e[:push_fn], e[:span_name], e[:span_kind])
        out << record_timing_line(e)
        e[:attributes].each do |a|
          out << format("      %-24s %-8s <- %s  [%s]\n", a[:key], a[:stability], a[:source], a[:present])
        end
        out << format("      + layer-2 enricher (env-gated, probe unchanged): %s\n", Array(e[:enrichers]).join(", ")) unless Array(e[:enrichers]).empty?
      end
      record_channels.each do |c|
        next if Array(c[:metrics]).empty?
        out << record_metric_lines(c)
      end
      out << "\n"
      out << consumer_dsl_report
      out
    end

    # E400: channel -> metric の可読ダンプ。**label の安全性を数で出す**のがこの関数の
    # 存在理由 — metric の代金は値ではなく label で、その代金は宣言を読まないと分からず、
    # 間違えても exit 0 のまま backend の請求書に出る。だから series の上限 (label の
    # bound の積) と、その bound が **どこから来たか** を必ず並べる:
    #   declared_set … 許容集合をここで宣言し、集合外は fallback として出す (span は
    #                  正確な値を持ち続ける = 宣言された粗視化)
    #   value_map    … 元のプロパティが既に閉じている (E397)。粗視化は起きない
    def record_metric_lines(c)
      out = +""
      out << format("  %-6s metrics (E400):\n", c[:id])
      Array(c[:metrics]).each do |m|
        val = m[:value_from].to_s.empty? ? "records" :
              format("%s [%s -> %s]", m[:value_from], m[:value_unit], m[:unit])
        out << format("    %s  %s  unit=%s  value=%s\n", m[:name], m[:kind], m[:unit], val)
        out << format("      series <= %d  (= %s)\n", m[:series_bound],
                      Array(m[:labels]).empty? ? "1, no labels" :
                        Array(m[:labels]).map { |l| l[:bound] }.join(" x "))
        Array(m[:labels]).each do |l|
          how = l[:bound_from] == "declared_set" ?
                format("declared set of %d + fallback %s (values outside it are NOT a new series; " \
                       "the span keeps the exact value)", Array(l[:values]).length, l[:fallback].inspect) :
                format("closed value map `%s` (nothing else can occur)", l[:value_map])
          out << format("      label %-28s <- ev.%-12s bound %-4d %s\n",
                        l[:key], l[:from], l[:bound], how)
        end
        out << format("      buckets: %s (%s)\n", Array(m[:boundaries]).join(", "), m[:bounds]) if m[:kind] == "histogram"
      end
      out
    end

    # E409: map 語彙の人間可読ダンプ。「この surface を書くと、どの map が、
    # どれだけの容量で出来て、溢れたら何が起きるか」の 1 画面。
    def maps_report
      out = +"maps (E409 — the maps that writing this surface creates, with capacity and \"when full\"):\n"
      MAPS.group_by { |m| m[:declared_as] }.each do |form, entries|
        out << format("  [%s] %d\n", form, entries.size)
        entries.each do |m|
          cap = m[:max_entries] ? "max_entries=#{m[:max_entries]}" : "no max_entries"
          out << format("    %-26s %-14s %-22s %s\n", m[:map], m[:type], cap,
                        m[:per_cpu] ? "per-CPU (userspace sums every CPU)" : "")
          out << format("      <- %s\n", m[:created_by].join(" "))
          out << format("      %s\n", m[:role])
          out << format("      when full: %s\n", m[:when_full])
        end
      end
      out << format("  total %d maps / %d types. Withdrawn types (removed with their surface): %s\n\n",
                    MAPS.size, MAPS.map { |m| m[:type] }.uniq.size, WITHDRAWN_MAPS.keys.join(" "))
      out
    end

    # 使っている surface 名の集合 -> それが作る map エントリ (E409)。
    def maps_created_by(names)
      used = names.to_a.map(&:to_s)
      MAPS.select { |m| !(m[:created_by] & used).empty? }
    end

    # E374 (ADR-017 D3-5): consumer DSL の語彙 + `to_span` の解決規則 (人間可読)。
    def consumer_dsl_report
      ids = typed_record_channel_ids
      out = +"userspace consumer DSL (E371/E374 — the ringbuf into a Ruby receiver):\n"
      out << format("  typed channels (ids for which `on_emit :<id>` becomes a typed record): %s\n",
                    ids.empty? ? "(none)" : ids.join(", "))
      out << "  any other id stays an E242 named event (backward compatible)\n"
      CONSUMER_DSL.each do |v|
        out << format("  %-22s %s\n", v[:name], v[:form])
        out << format("      %s\n", v[:summary])
        out << format("      context: %s\n", v[:context_note])
        out << format("      note: %s\n", v[:gotcha]) if v[:gotcha]
      end
      out << "\n"
      out << consumer_filter_report
      out
    end

    # E398: `keep_if` の語彙と、**kernel 側 filter との線引き**。
    # 一番上に line を置くのは、AI が最初に間違えるのが「どちらを持っているか」だから。
    def consumer_filter_report
      f = CONSUMER_FILTER
      out = +"userspace consumer filter (E398 — dropped after the drain, before sending):\n"
      out << "  #{f[:form]}\n"
      out << "  values: #{f[:set_by]}\n"
      out << "  combining: #{f[:combining]}\n"
      out << "  operators:\n"
      f[:operators].each { |n, o| out << format("    %-9s %-8s %s\n", ":#{n}", o[:types].join("/"), o[:means]) }
      out << "  the line (against the kernel-side filter_by):\n"
      out << "    #{f[:line]}\n"
      f[:why_userspace].each { |k, v| out << format("    %-14s %s\n", k, v) }
      out << "  cost: #{f[:cost]}\n"
      out << "  span: #{f[:span_unchanged]}\n"
      out << "  not implemented (not dropped silently):\n"
      f[:not_implemented].each { |k, v| out << format("    %-14s %s\n", k, v) }
      out << "\n"
      out
    end

    # 全 registry の人間可読ダンプ (CLI `spinel-ebpf capabilities`)。
    def catalog_report
      out = +"spinel-ebpf capabilities — ADR-014 layer 1 domain registry\n\n"
      DOMAINS.each do |dom, spec|
        out << format("%-14s (%d builtins)\n", dom, spec[:builtins].length)
        out << "  #{spec[:summary]}\n"
        out << "  attach: #{spec[:attach_kinds].join(', ')}\n" unless spec[:attach_kinds].empty?
        out << "  builtins: #{spec[:builtins].sort.join(' ')}\n\n"
      end
      unless CONTEXT_GATES.empty?
        out << "context gates (E286/E390 — die at compile time, usable only in this hook):\n"
        # 同じ allowlist を共有する builtin はまとめて 1 回だけ出す (d_path gate は
        # 6 builtin × 30+ hook。全部を builtin ごとに並べると読めない — E390)。
        CONTEXT_GATES.group_by { |_, g| g[:valid_secs] }.each do |secs, entries|
          names = entries.map(&:first)
          out << format("  %s [%s]\n", names.join(" / "), entries.first.last[:domain])
          if secs.equal?(DPATH_OK_SECS)
            # hook ごとに「どの引数がパスを持つか」が違うので、そこで束ねる (選ぶのはそこ)。
            { file: "argument is struct file * ", path: "argument is struct path * ",
              binprm: "argument is linux_binprm *" }.each do |form, label|
              hooks = DPATH_HOOKS.select { |_, v| v[:form] == form }.keys
              out << format("    %s: %s\n", label, hooks.join(" | "))
            end
            # E418: gate は「load できる」しか保証していなかった。発火まで測った結果を
            # tier で出す。**壁のように 32 本並べない** — 読み手が知りたいのは
            # 「遮断できるのはどれか」と「素直な操作では踏めないのはどれか」だけ。
            by_fire = DPATH_HOOKS.group_by { |_, v| v[:fire] }
            out << format("    fire measured (E418): %s\n",
                          %i[deny observe load_only].map { |t|
                            format("%s=%d", t, (by_fire[t] || []).length)
                          }.join(" / "))
            out << "      deny    = fire + block measured (a policy can be written)\n"
            out << "      observe = fire measured, **the return value is ignored** (audit only)\n"
            caveats = DPATH_HOOKS.select { |_, v| v[:caveat] }
            unless caveats.empty?
              out << "    ⚠ hooks the obvious operation does not trigger, or whose path differs from what is expected " \
                     "(#{caveats.length}/#{DPATH_HOOKS.length}, E418 measured):\n"
              caveats.each { |sec, v| out << format("      %-34s %s\n", sec, v[:caveat]) }
            end
            # E420: caveat が「書いてはいけない」と言っていた 4 本は compile 時に die する
            # ようになった。**非対称**なので、拒否される綴りと許される綴りを両方出す
            # (hook ごと降ろしたのではない、と読めなければ意味が変わる)。
            unless DPATH_NO_SELECT_SECS.empty?
              out << "    ✗ path **selection** is structurally impossible = dies at compile time " \
                     "(#{DPATH_NO_SELECT_SECS.length}/#{DPATH_HOOKS.length}, E418 measured -> made loud in E420):\n"
              out << "      rejected: #{DPATH_SELECT_BUILTINS.join(' / ')}   " \
                     "allowed: #{DPATH_NONSELECT_BUILTINS.join(' / ')} (recording and paths from the task chain)\n"
              DPATH_NO_SELECT_SECS.each do |sec|
                out << format("      %-34s %s\n", sec, DPATH_HOOKS[sec][:no_select])
              end
            end
            n_lsm = DPATH_HOOKS.keys.count { |s| lsm_active_required?(s) }
            out << "    ⚠ `lsm/*` (#{n_lsm} hooks) stay silent when attached " \
                   "without `bpf` in the active LSMs (E390/E418 measured)\n"
            out << "    measured REJECTED (not in the gate — the same function gives different results by attach kind):\n"
            DPATH_MEASURED_REJECTED.each { |sec, why| out << format("      %-32s %s\n", sec, why) }
          else
            out << format("    valid: %s\n", secs.join(" | "))
          end
        end
        out << "\n"
      end
      out << "required sets (E317 — partners that produce no span alone, enforced loudly at compile time):\n"
      REQUIRED_SETS.each do |rule|
        if rule[:mode] == :all
          out << format("  [%s] %s (all-or-none)\n", rule[:experiment], rule[:members].join(" + "))
        else
          out << format("  [%s] %s requires %s\n", rule[:experiment], rule[:trigger], rule[:requires].join(", "))
        end
      end
      out << "\n"
      out << "builtin groups (E322 — related builtins: pack relations/pairs/families, with call examples):\n"
      BUILTIN_GROUPS.each do |g|
        forms = g[:members].map { |m| example_for(m) || m }
        out << format("  %s\n", g[:name])
        out << "    #{forms.join('  ')}\n"
        out << "    #{g[:note]}\n"
      end
      out << "\n"
      out << maps_report
      out << record_channels_report
      out << "krew probe (E307) -> domain:\n"
      KREW_PROBE_DOMAINS.each { |p, d| out << format("  --probe %-5s -> %s\n", p, d) }
      out << "\nattach kinds (#{ATTACH_KINDS.length}) — the list with conventions: `spinel-ebpf capabilities --json`:\n"
      out << "  #{ATTACH_KINDS.map { |a| a[:kind] }.join(' ')}\n"
      out << "\nAI-authoring contract (machine-readable): spinel-ebpf capabilities --json\n"
      out
    end

    # ===================================================================
    # E316 (ADR-015 原則4「affordance を公開する」): 機械可読な authoring 契約。
    #
    # builtin の signature (arity/params)・attach-kind の作法・Ruby サブセットの
    # 書ける/書けない・層2 enricher を **純データ** として持ち、`capabilities --json`
    # で 1 つの JSON にまとめて出す。作者 (=AI) が「打てる手」を機械可読で読める。
    #
    # 完全性 (全 builtin/attach が現れる) と codegen との arity drift 無しは
    # tests/spinel_ebpf/capabilities_test.rb が機械強制する (ADR-015 の肝)。
    #
    # signature の正本: codegen_bpf.rb の `expects N` / `expect_no_args` チェック。
    # capabilities.rb は codegen を require できない (循環: codegen が本モジュールの
    # DPATH_OK_SECS を参照) ため arity をここに **ミラー** し、test がソースを parse
    # して drift を検出する。機械的に param 名が取れない builtin は opaque: true で正直に印。
    # ===================================================================

    # 構造グループ (codegen 側と同じ名前集合、drift は完全分割 test が守る)。
    PKT_FIELD_BUILTINS = %w[
      pkt_len pkt_eth_proto pkt_l4_proto pkt_ip4_src pkt_ip4_dst
      pkt_l4_sport pkt_l4_dport pkt_tcp_flags pkt_l4_payload_len
      pkt_ip6_src_hi pkt_ip6_src_lo pkt_ip6_dst_hi pkt_ip6_dst_lo
      pkt_tcp_seq pkt_tcp_ack
    ].freeze
    TCP_SOCK_READER_BUILTINS = %w[
      tcp_sock_snd_cwnd tcp_sock_snd_ssthresh tcp_sock_snd_nxt tcp_sock_snd_una
      tcp_sock_packets_out tcp_sock_delivered tcp_sock_snd_cwnd_cnt
      tcp_sock_snd_cwnd_clamp tcp_sock_prior_cwnd
    ].freeze
    TCP_SOCK_WRITER_BUILTINS = %w[
      tcp_sock_snd_cwnd_set tcp_sock_snd_ssthresh_set tcp_sock_snd_cwnd_cnt_set
    ].freeze
    TCP_SOCK_ADDER_BUILTINS = %w[
      tcp_sock_snd_cwnd_add tcp_sock_snd_cwnd_cnt_add
    ].freeze
    OPAQUE_KFUNC_BUILTINS = %w[
      scx_dispatch scx_consume scx_kick_cpu scx_pick_idle_cpu scx_create_dsq
      qdisc_skb_drop qdisc_init_prologue qdisc_reset_destroy_epilogue
      qdisc_watchdog_schedule qdisc_bstats_update
    ].freeze

    # 明示 signature 表。value = [arity, params|nil, summary]。opaque は params.nil? で導出。
    #   arity  : Integer | :variadic
    #   params : 引数名の配列 (codegen の "expects (...)" / expect_no_args から)、opaque は nil
    # arity/param は codegen が単一の権威 (test が drift を検出)。pkt_*/tcp_sock_* は下で生成。
    SIG_TABLE = {
      # --- observability: emit / hist / latency / task / stack / etc. ---
      "spnl_emit"        => [1, %w[value],            "emit one __s64 to the ringbuf (16B hdr)"],
      "spnl_emit_str"    => [1, %w[ptr],              "emit the string at a user ptr to the str ringbuf"],
      "spnl_emit_pair"   => [2, %w[a b],              "emit 2 values in one event"],
      "spnl_emit3"       => [3, %w[a b c],            "emit 3 values in one event"],
      "spnl_emit4"       => [4, %w[a b c d],          "emit 4 values in one event"],
      "emit_argv"        => [1, %w[argv],             "walk execve argv[] and emit to the str ringbuf"],
      "emit_comm"        => [0, [],                   "emit the current process's comm to the str ringbuf"],
      "comm_hash"        => [0, [],                   "return the first 8B of comm as __s64 (grouping)"],
      "hist_observe"     => [1, %w[value],            "one sample into a log2 histogram"],
      "hist_observe_by"  => [2, %w[key value],        "one sample into a keyed log2 histogram"],
      "hist_observe_linear" => [1, %w[slot],          "linear histogram (caller pre-bucketed)"],
      "ktime_ns"         => [0, [],                   "bpf_ktime_get_ns()"],
      "latency_start"    => [0, [],                   "BEGIN: record the entry ktime keyed by tid"],
      "latency_end"      => [0, [],                   "END: return the delta ns and delete the entry"],
      "lat_start"        => [1, %w[key],              "latency BEGIN with any key"],
      "lat_end"          => [1, %w[key],              "latency END with any key (returns the delta)"],
      "task_load"        => [0, [],                   "read the per-task storage value"],
      "task_store"       => [1, %w[value],            "write a value to per-task storage"],
      "task_incr"        => [1, %w[delta],            "add delta to per-task storage (single-get RMW)"],
      "task_swap"        => [1, %w[value],            "swap the per-task storage value (general RMW)"],
      "stack_id"         => [0, [],                   "kernel stack id (STACK_TRACE map)"],
      "user_stack_id"    => [0, [],                   "user stack id (STACK_TRACE map)"],
      "off_cpu_start"    => [1, %w[pid],              "off-CPU start (stash ktime+stack keyed by pid)"],
      "off_cpu_observe"  => [1, %w[pid],              "off-CPU return: bin the delta into a keyed hist"],
      "leak_record"      => [3, %w[ptr size stack_id],"record an alloc (memleak)"],
      "leak_forget"      => [1, %w[ptr],              "delete the record on free (memleak)"],
      "lock_edge"        => [2, %w[a b],              "record a lock-acquisition-order edge (deadlock)"],
      "mim_inc"          => [2, %w[group key],        "map-in-map: add to inner[key]"],
      "mim_get"          => [2, %w[group key],        "map-in-map: read inner[key]"],
      "fifo_push"        => [1, %w[value],            "push to a QUEUE map"],
      "fifo_pop"         => [0, [],                   "pop from a QUEUE map"],
      "lifo_push"        => [1, %w[value],            "push to a STACK map"],
      "lifo_pop"         => [0, [],                   "pop from a STACK map"],
      "depth_inc"        => [1, %w[key],              "recursion depth counter +1"],
      "depth_dec"        => [1, %w[key],              "recursion depth counter -1"],
      "path_counter_inc" => [1, %w[key],              "atomically add to bpf_path_counts[key] (general keyed counter)"],
      "kfield"           => [:variadic, %w[ptr struct field], "safely read a kernel struct field with BPF_CORE_READ (variable hops)"],
      "kptr"             => [2, %w[ptr struct],       "register local→struct (for the .field dot accessor)"],
      "emit_kfield_str"  => [:variadic, %w[ptr struct field], "emit a kernel struct's **string** field to the str ringbuf (the string version of kfield's scalar, variable hops). Comma = pointer hop / dot = embedded (as in kfield). Whether the last hop is char[N] (the contents) or char * (what it points to) is decided at compile time from the C type, so no separate spelling is needed — a mix-up fails at _Static_assert (E394). No gate (bpf_probe_read_kernel_str measured LOAD_OK in every prog type)"],
      "kfield_str_eq"    => [:variadic, %w[ptr struct field literal], "a predicate on whether a kernel struct's **string** field equals a literal (an expression, no gate, purpose-neutral: deny/audit/routing and so on — the action is decided by the handler's return value; kfield_str_eq only decides). **The last string argument is the compared value**, and everything before it is the field path. Unlike bpf_d_path it works in kprobes too (file->f_path.dentry->d_name.name can be read even in hooks where bpf_d_path is structurally impossible (E390 c65), E394)"],
      # --- enforcement: audit / lineage / deny selector ---
      "emit_path"        => [1, %w[file],             "the full path via bpf_d_path to the str ringbuf (gated)"],
      "emit_parent_path" => [0, [],                   "emit the parent exe's full path (direct deref, gated)"],
      "path_eq"          => [2, %w[file path_literal], "a predicate on whether the file's full path equals a literal (an expression, gated, purpose-neutral: deny/audit/routing and so on — the action is decided by the handler's return value; path_eq only decides)"],
      "path_starts_with" => [2, %w[file path_literal_prefix], "a predicate on whether the file's full path starts with a literal prefix (an expression, gated, purpose-neutral: deny/audit/routing and so on — the action is decided by the handler's return value; path_starts_with only decides. A percpu-scratch version that matches long paths correctly up to PATH_MAX)"],
      "path_contains"    => [2, %w[file path_literal_substr], "a predicate on whether a literal appears as a substring of the file's full path (any offset, an expression, gated, purpose-neutral: deny/audit/routing and so on — the action is decided by the handler's return value; path_contains only decides. A no-bypass version that searches the whole PATH_MAX with a bpf_loop sliding window)"],
      "parent_path_eq"   => [1, %w[path_literal],     "a predicate on whether the parent exe path equals a literal (an expression, gated, purpose-neutral — the action is decided by the return value)"],
      "ppid"             => [0, [],                   "parent tgid (init-ns pid)"],
      # E396: capability / namespace / FileType — Tetragon の matchCapabilities /
      # matchNamespaces / FileType に対応する 3 セレクタ。いずれも kfield で「届く」
      # (cred / nsproxy / i_mode は普通の CO-RE chain)。名前が買うのは到達性ではなく
      # **その値の比べ方**で、3 つとも「生の値では正しく比較できない」種類:
      # bit set / 単独では意味を持たない inode / 型とパーミッションが同居した mode。
      # 先頭 6 個は**現タスク**を読むので process-context hook 以外では codegen が die
      # (E396 m05: 同じ呼出を XDP に置くと、別マシンから来たパケットに対して
      #  CPU バーナーの capability を **エラーなく** 返す)。file_type だけは hook から
      # 渡されたポインタを読むので kfield と同じく非 gate。
      "has_cap"          => [1, %w[cap],              "a predicate on whether the current task holds one **effective** capability (0/1). `has_cap(CAP::SYS_ADMIN)`. **Testing the raw value yourself is wrong** — CAP_SYS_ADMIN is bit number 21, not a mask, so `cap_effective & CAP_SYS_ADMIN` looks at bits 0/2/4 and returns 21 whether the task holds it or not (E396 m01 measured). It is AOT, so in xlated it is two instructions, `r1 &= 2097152` plus a branch (Tetragon uses a value-set map + an interpreter walk)"],
      "has_cap_permitted"   => [1, %w[cap],           "whether the capability is in the current task's **permitted** set (0/1). Effective is the authority usable now; permitted is the ceiling effective can be raised to (E396)"],
      "has_cap_inheritable" => [1, %w[cap],           "whether the capability is in the current task's **inheritable** set (0/1). The set passed across exec (E396)"],
      "cap_effective"    => [0, [],                   "the current task's effective capability set **itself** (a 64-bit bit set). **For reporting** — use has_cap to decide. `& CAP_*` is always wrong (above). For emitting to userspace and decoding there (E396)"],
      "ns_id"            => [1, %w[key],              "the inode number of the current task's namespace. key is a symbol literal (:mnt :net :uts :ipc :cgroup :time :user :pid). **:pid follows thread_pid** — nsproxy->pid_ns_for_children is the namespace \"children enter\", which differs for a task that unshared without forking (E396 m02 run D measured; both look like ordinary inode numbers). The value is for correlation (whether it is the host: in_host_ns, E396)"],
      "in_host_ns"       => [1, %w[key],              "whether the current task is in that namespace's **initial (host) namespace** (0/1). key is the same symbol as ns_id. The initial namespace's inode is read from untyped ksyms (`init_nsproxy`/`init_user_ns`, resolved by libbpf from kallsyms at load) — **reading /proc/1/ns is wrong inside a container, because it points to the container's init** (E396 m03 measured: 4026532237 against the real 4026531832). BTF has no init_* VAR, so typed ksyms fail with LOAD_FAIL (E396)"],
      "file_type"        => [1, %w[file],             "the **file type** of a `struct file *`'s inode (S_IFMT-masked). Compare in the form `file_type(f) == FileType::REG`. **Returning it masked is the point** — the raw i_mode holds type and permissions together, so `i_mode == S_IFREG` is false for every regular file and `i_mode & S_IFDIR` is **true for a socket** (E396 m04 measured). The types are FileType::REG/DIR/LNK/SOCK/BLK/CHR/FIFO (= S_IFREG…). Not gated (like kfield, it only reads the pointer the hook passes)"],
      # --- l7: HTTP / TLS / DNS span + L7 latency + off-CPU 相関 ---
      "http_req_start"   => [2, %w[sk msg],           "read the send buffer and, if it is an HTTP req, record it keyed by sock"],
      "http_resp_stash"  => [2, %w[sk msg],           "stash the receive buffer keyed by tid"],
      "http_emit"        => [1, %w[ret],              "read the stash, correlate by sock, emit one HTTP span"],
      "redis_req_start"  => [3, %w[sk msg size],      "read the send buffer (first size B) and, if it is a RESP command, record it keyed by sock (Redis L7 RED)"],
      "redis_resp_stash" => [2, %w[sk msg],           "stash the receive buffer keyed by tid (Redis L7 RED)"],
      "redis_emit"       => [1, %w[ret],              "read the stash, correlate by sock, emit one Redis span (command/-ERR/duration)"],
      "ssl_req_start"    => [2, %w[ssl buf],          "read SSL_write's plaintext and, if it is HTTP, record it keyed by SSL*"],
      "ssl_resp_stash"   => [2, %w[ssl buf],          "stash buf keyed by tid at SSL_read entry"],
      "ssl_emit"         => [1, %w[ret],              "correlate the decrypted buf by SSL*, emit a TLS plaintext span"],
      "go_tls_write"     => [3, %w[conn ptr len],     "read the plaintext slice (ptr,len) of Go crypto/tls.(*Conn).Write and emit an HTTP req span (uprobe, no sock -> https)"],
      "go_tls_req"       => [3, %w[conn ptr len],     "read Go (*Conn).Write's plaintext len-bound and stash it in http_pending keyed by conn (the request half of full RED)"],
      "go_tls_resp_stash"=> [2, %w[conn ptr],         "stash the receive buffer at Go (*Conn).Read entry keyed by the g register (goroutine) — because the tid moves across a blocking Read"],
      "go_tls_emit"      => [1, %w[ret],              "at Go (*Conn).Read RET (go_uret) look up by the g key → correlate the request by conn → emit a full RED span"],
      "dns_req_start"    => [2, %w[sk msg],           "start correlating a DNS query"],
      "dns_resp_stash"   => [2, %w[sk msg],           "stash the DNS response buffer"],
      "dns_emit"         => [1, %w[ret],              "DNS span emit"],
      "emit_dns"         => [1, %w[msg],              "packed-emit the DNS query of udp_sendmsg. **It depends neither on the resolver's implementation language nor on how it sends** — it reads the same bytes whether connected or not, with one iovec or several (E428 implemented the second half; before that it read only connected, single-buffer sends). ⚠ What it cannot read is **a send whose bytes are not in user memory** (splice/vmsplice = ITER_BVEC); then the record carries an empty raw and the drain reports it as `unreadable_payload` (not silently a zero-filled span). Write destination filtering with `udp_dport(sk, msg)` (`sock_dport` is 0 when unconnected)"],
      "emit_tcp_payload" => [1, %w[msg],              "str-emit the first 128B of tcp_sendmsg's send buffer (for L7 parsing in userspace, protocol-independent)"],
      "emit_tcp_stream"  => [3, %w[sk msg size],      "emit tcp_sendmsg's send buffer as a packed record with the sock key (sock,len,raw[128]) — for reassembling streams over many connections; userspace accumulates per connection by sock"],
      "req_start"        => [1, %w[sk],               "record the start time of an L7 round trip at tcp_sendmsg"],
      "emit_l7"          => [1, %w[sk],               "emit an L7 round-trip latency span at tcp_cleanup_rbuf"],
      "offcpu_recv_stash"=> [2, %w[sk msg],           "open the tid's off-CPU window on an HTTP req (stash)"],
      "offcpu_begin"     => [1, %w[ret],              "open the off-CPU window (kretprobe)"],
      "offcpu_account"   => [3, %w[prev_pid prev_state next_pid], "accumulate the voluntary off-CPU stacks within the window"],
      "offcpu_emit"      => [2, %w[sk msg],           "close the window and emit a span with the off-CPU breakdown"],
      # --- net: connect / L4 / datapath / conntrack / arena / tcp slice ---
      "emit_connect"     => [7, %w[skaddr daddr dport family oldstate daddr6_hi daddr6_lo], "emit a connect as one packed record (process+peer+srtt)"],
      "sock_owner_set"   => [1, %w[sk],               "record sock→{pid,comm} at tcp_v4_connect (to recover the owner in softirq context)"],
      "blocklist_match"  => [1, %w[ip],               "a predicate on whether ip is in a set (exact HASH map) (host order, purpose-neutral: match→deny=blocklist / match→allow=allowlist is decided by the return value). Seed the set in userspace: declare `ffi_func :sp_bpf_blocklist_add, [:uint32], :int` in a `module M` (not a class) and call `M.sp_bpf_blocklist_add(0x0a000001)` (an integer-literal ip) at top level"],
      "cidr_blocklist_match" => [1, %w[ip],           "a predicate on whether ip is in a CIDR set (LPM_TRIE, longest-prefix) (host order, purpose-neutral: blocklist/allowlist is decided by the return value). Seed the set in userspace: declare `ffi_func :sp_bpf_cidr_blocklist_add, [:uint32,:uint32], :int` in a `module M` (not a class) and call `M.sp_bpf_cidr_blocklist_add(0x7f000000, 8)` (integer-literal ip, prefixlen) at top level. Calling it again at run time updates it dynamically (`_del` has the same shape)"],
      "pkt_dynptr_byte_at" => [1, %w[off],            "read one byte of an XDP frame at a **run-time offset** (0-255; out of range or not XDP gives -1). Underneath is bpf_dynptr_from_xdp + bpf_dynptr_slice; the dynptr holds the bounds check, so the caller needs no `data + off > data_end` (the pkt_* readers have fixed offsets and do not need this). The TC counterpart is skb_load_byte(off)"],
      "tail_call_to"     => [1, %w[slot],             "**transfer control** to the program at slot `slot` of this unit's PROG_ARRAY (bpf_tail_call; it does not return = the caller does not resume). slot is the **declaration order** 0,1,... of `def xdp_tail__<name>`, and the loader (_spnl_prog_array_populate, E065) writes the fds in that order. ⚠ **A failure is not loud** — a jump to an empty slot returns no error and **silently falls through**, and the next statement runs (which is why the idiom puts `XDP_PASS` after `tail_call_to`). An integer-literal slot outside the number of declared targets **dies at compile time**, but a computed slot (`tail_call_to(n)`) cannot be checked. Nesting is limited to 33 levels by the kernel. The reason to split is that **the 1M instruction budget is per program** (E063)"],
      "user_ringbuf_drain" => [0, [],                 "take out the commands that arrived **host → kernel** (E061/E414). It takes **all** records in this unit's `bpf_user_cmds` (USER_RINGBUF, 256 KB) **in FIFO order** and calls this unit's `def user_ringbuf__<name>(value)` once per record. It can be called **anywhere** (LOAD_OK measured in all 12 program types, E414) ⇒ no context gate. ⚠ **The author calls drain** — which hook picks it up decides the command's delay, so it is not synthesized (per packet for `def xdp__<name>`, per call for `def kprobe__<func>`). A callback without a drain / a drain without a callback / two callbacks **die at compile time**. ⚠ **A record is a fixed 8 bytes**; the sender is the glue's `sp_bpf_user_cmd_push(value)` (`ffi_func :sp_bpf_user_cmd_push, [:int64], :int` in a `module M`). If a pusher of your own sends fewer than 8 bytes, **the callback fires and the count grows, but the value is 0** (`bpf_dynptr_read` gives up silently with -E2BIG, E414 measured). ⚠ **Kernel floor 6.1** — unlike `param` (.rodata, 5.2) it raises the contract's floor. **Division of labour with `param`**: `param` is once before load and frozen; this is **any number of times while running**, FIFO, batched"],
      "cpumap_redirect"  => [1, %w[cpu],              "bpf_redirect_map to a CPUMAP"],
      # E051-E054 / E416: the pure-XDP TCP slice builtins. All seven are XDP-only
      # (the helpers rewrite and RESIZE the frame through `struct xdp_md`), and
      # all seven return __s64 so `< 0` is the error check every example uses.
      "tcp_syncookie_gen"   => [0, [],                 "make a **stateless SYN cookie** for this SYN (bpf_tcp_raw_gen_syncookie_ipv4). The return is >= 0 with **the low 32 bits = cookie (the SYN-ACK's seq) and the high bits = MSS**, negative on error or non-TCP. ⚠ **It grows the frame to a 60-byte TCP header before returning** — the kfunc requires TCP_MAXLEN (60) to be readable whatever the real header length, so growing is not an optimization but **a condition for the call** (E416 measured: without growing, `invalid access to packet, off=34 size=60` and it **does not load**. The retired Ruby oracle emitted that shape, and **it could not load even then**). The only consumer, `tcp_reply_synack(cookie)`, shrinks the grown frame to 14+20+24. **To do both steps in one call, use `tcp_synack_cookie`** (no intermediate state leaks out)"],
      "tcp_syncookie_check" => [0, [],                 "**verify the cookie** that the handshake's ACK returned (bpf_tcp_raw_check_syncookie_ipv4). >= 0 means valid (= this 3-way handshake is one we answered with a SYN-ACK); negative means invalid. ⚠ **It does not touch the frame** — the kfunc does not require TCP_MAXLEN, so no grow is needed and the ACK passes intact (this is the asymmetry with `gen`). ⚠ After passing it, **do not hand that ACK to the kernel**: there is no listen socket, so the stack answers with RST and the connection drops ⇒ consume it with `XDP::DROP`"],
      "tcp_reply_header"    => [3, %w[seq ack flags],  "rewrite the current packet into a **TCP reply without payload** (swap MAC/IP/port, set seq/ack and the flag byte, doff=5, recompute the IP/TCP checksums, resize to 14+20+20). `seq`/`ack` are numbers in **host order**, `flags` is the TCP flag byte (`TCP::Flag::FIN | TCP::Flag::ACK` and so on). Returns 0 / -1; the caller returns `XDP::TX`. For FIN-ACK or a lone ACK — to return a body, use `tcp_reply_data`"],
      "tcp_reply_synack"    => [1, %w[cookie],         "rewrite the current SYN into a **SYN-ACK with an MSS option** (pass `tcp_syncookie_gen`'s return value as it is — seq comes from the low bits, MSS from the high bits). ack is the received seq+1, doff=6 (a 24-byte header), and finally a resize to 14+20+24. Returns 0 / -1; the caller returns `XDP::TX`. ⚠ This call shrinks the frame `tcp_syncookie_gen` grew, so **always call it after gen** (otherwise a frame with a 60-byte header is sent)"],
      "tcp_synack_cookie"   => [0, [],                 "complete SYN → SYN-ACK **in one call** (grow-to-60 → cookie generation → building the SYN-ACK with MSS → shrink). The same result as `tcp_syncookie_gen` + `tcp_reply_synack`, **without exposing the intermediate grown frame**. Returns 0 / -1; the caller returns `XDP::TX`. The public example (`ruby_slice.rb`) uses this one"],
      "tcp_reply_data"      => [3, %w[seq ack payload], "rewrite the current packet into a **reply with a body** (swap, seq/ack, FIN|PSH|ACK, doff=5, write the body, checksum, resize to 14+20+20+len). `payload` must be **a compile-time string literal** (burned into a const byte array; its length decides the generated header's total size), at most 1024 bytes. Returns 0 / -1; the caller returns `XDP::TX`. ⚠ **The body must fit in the received frame** (it shrinks at the end, so a reply longer than the GET line cannot be written). Writing the same literal many times still makes one helper (up to 8 distinct per unit)"],
      "payload_starts"      => [1, %w[prefix],         "whether the current packet's **TCP payload starts with a literal** (1 / 0). `prefix` must be **a compile-time string literal**, at most 64 bytes, and it is **unrolled into one comparison per byte** (no loop and no bounded read, so it is cheap for the verifier = a shape where AOT applies directly). ⚠ **It does not touch the frame**. Writing the same literal many times still makes one helper (up to 8 distinct per unit)"],
      "xsk_redirect"     => [1, %w[qid],              "bpf_redirect_map to an XSKMAP (AF_XDP)"],
      "dev_redirect"     => [1, %w[idx],              "bpf_redirect_map to a DEVMAP"],
      "sock_ops_op"      => [0, [],                   "the sockops event kind (ctx->op; compare with BPF::SockOps::*)"],
      "sock_ops_state"   => [0, [],                   "the new TCP state in sockops STATE_CB (ctx->args[1]; compare with TCP_STATE_*)"],
      # E041/E043/E413: SO_REUSEPORT worker selection. The pair is one feature --
      # reading the hash without steering is a filter, steering without the hash
      # is a pin; both are legitimate, which is why they are separate builtins.
      "reuseport_hash"   => [0, [],                   "**the 5-tuple hash the kernel computed** for this SYN (sk_reuseport_md->hash). The input to consistent hashing: the same 4-tuple always gives the same value ⇒ `reuseport_hash % N` sticks to the same worker (keepalive cache locality). **The return is non-negative** (the source is __u32), so `% N` becomes unsigned and passes the verifier for a literal N (`% 4` → `&3`, `% 3` → unsigned BPF_MOD). ⚠ **When N is a run-time value (a map / `param`), clang fails with `unsupported signed division`** — clang says it, not spinel-ebpf (E413 measured)"],
      "worker_select"    => [1, %w[idx],              "**steer** this connection to socket number `idx` of the REUSEPORT_SOCKARRAY (bpf_sk_select_reuseport). **Userspace decides** what is in each slot: each worker calls `sp_bpf_reuseport_register(listen_fd, idx)`, and one of them attaches the prog to the group with `sp_bpf_reuseport_attach(listen_fd, \"sk_reuseport__<name>\")` (both are existing FFI, E043). ⚠ **Selecting an empty slot does not fail** — the helper returns -ENOENT, but codegen discards it and the kernel **silently falls back to the default 5-tuple spread** ⇒ \"BPF chose\" and \"BPF did not choose and the kernel did\" cannot be told apart from the probe's output (E413 D3). Matching the number of registered workers to your `% N` is the author's responsibility (`spinel-ebpf describe` prints the number of slots reached)"],
      "sock_addr_ip4"    => [0, [],                   "the destination IPv4 of connect4/bind4 (host order)"],
      "sock_addr_port"   => [0, [],                   "the destination port of connect4/bind4 (host order)"],
      # E395: 任意 context の `struct sock *` を名前で読む。値は**全て host order**
      # (= pkt_*/sock_addr_* と同じ規約)。struct sock_common はフィールドごとに
      # バイト順が違う (skc_dport=__be16 / skc_num=__u16) ので、変換は accessor 側に
      # 焼いてある — 呼ぶ側が一律のルールを書くと必ずどちらかが静かに間違う (E395 D1)。
      "sock_sport"       => [1, %w[sk],               "the source port (host order). Underneath is skc_num, which is **host order to begin with** — unlike dport it is not converted. The raw read is 60404 and dport's raw read is 47903, and both look like ports, so converting both with ntohs and leaving both as they are are equally wrong (E395)"],
      "sock_dport"       => [1, %w[sk],               "the port of **the peer this socket is connected to** (host order). Underneath is skc_dport (**__be16 = network order**), already ntohs'd — the raw value is 47903 = ntohs(8123), as E132 recorded (E395). ⚠ **Do not use it to filter UDP sends** — for an unconnected sender (one that passes the destination to sendto every time, as dnsmasq does) skc_dport is **0**, so `== 53` is always false and the probe **reports nothing** rather than misreading (E428 measured). A datagram's destination is `udp_dport(sk, msg)`"],
      "sock_saddr"       => [1, %w[sk],               "the source IPv4 (host order, skc_rcv_saddr already ntohl'd; the raw value has the 16777343 form). **Meaningful only when sock_family == AF_INET** — on an AF_INET6 socket it still returns **plausible numbers** such as 0 or 127.0.0.6 (measured E395 m03)"],
      "sock_daddr"       => [1, %w[sk],               "the IPv4 of **the peer this socket is connected to** (host order, skc_daddr already ntohl'd). **Meaningful only when sock_family == AF_INET** (E395). ⚠ For UDP sends it has the same trap as sock_dport — 0 when unconnected. A datagram's destination is `udp_daddr(sk, msg)` (E428)"],
      "sock_family"      => [1, %w[sk],               "AF_INET (2) / AF_INET6 (10). Host order. Branch on this before reading an address accessor (E395)"],
      "sock_state"       => [1, %w[sk],               "the TCP state (TCP_STATE_ESTABLISHED and so on). Host order (E395)"],
      "sock_protocol"    => [1, %w[sk],               "IPPROTO_TCP / IPPROTO_UDP and so on. Host order (E395)"],
      "sock_saddr6_hi"   => [1, %w[sk],               "the high 64 bits of the source IPv6. E080's hi/lo split, host order per 32-bit word (::1 is hi=0/lo=1). **Meaningful only when sock_family == AF_INET6** (E395)"],
      "sock_saddr6_lo"   => [1, %w[sk],               "the low 64 bits of the source IPv6 (E080 hi/lo convention, host order). **Only for AF_INET6** (E395)"],
      "sock_daddr6_hi"   => [1, %w[sk],               "the high 64 bits of the destination IPv6 (E080 hi/lo convention, host order). **Only for AF_INET6** (E395)"],
      "sock_daddr6_lo"   => [1, %w[sk],               "the low 64 bits of the destination IPv6 (E080 hi/lo convention, host order). **Only for AF_INET6** (E395)"],
      # E428: 「この datagram はどこへ行くのか」。sock_* は socket について答えるが、
      # UDP ではその 2 つが一致するのは connect 済みのときだけで、未接続なら宛先は
      # msg_name にある。udp_sendmsg 自身の規則 (msg_name が勝ち、無ければ接続先) を
      # 畳み込んであるので、書き手はその規則を知る必要も、半分だけ適用する余地も無い。
      "udp_dport"        => [2, %w[sk msg],           "the destination port **of this send** (host order). Pass the two arguments of `def kprobe__udp_sendmsg(sk, msg, len)` as they are. **Correct for an unconnected socket too** — `msg_name`'s port if present, otherwise the connected peer's port (= exactly udp_sendmsg's order of decision). This is the only difference from `sock_dport(sk)`: for an unconnected sender sock_dport returns 0 and a filter quietly drops everything (E428 measured: dnsmasq's upstream forwarding is a bare sendto, so not one query showed in E295's probe). Supports both AF_INET and AF_INET6. ⚠ **For send hooks only** — in `udp_recvmsg` `msg_name` is **the output the kernel is about to write**, so reading it on the receive side interprets uninitialized bytes as a port. The receive side has no such question (the peer's address is known after returning), so there the right limit is `sock_dport(sk)`, meaningful only for a connected socket"],
      "udp_daddr"        => [2, %w[sk msg],           "the destination IPv4 **of this send** (host order). The same rule as udp_dport (msg_name wins; otherwise the connected peer) and the same limit (**for send hooks only**). Returns 0 when the destination is IPv6 (v6 belongs to sock_daddr6_*)"],
      "iter_task"        => [0, [],                   "the current task_struct* of iter/task (__s64)"],
      "fib_lookup"       => [1, %w[dst],              "IPv4 FIB route lookup (egress ifindex)"],
      "fib_lookup6"      => [2, %w[dst_hi dst_lo],    "IPv6 FIB route lookup"],
      "sk_lookup_tcp"    => [4, %w[saddr daddr sport dport], "look up a TCP socket by 4-tuple"],
      "sk_assign_tcp"    => [4, %w[saddr daddr sport dport], "sk_lookup → steer to the socket"],
      "redirect"         => [1, %w[ifindex],          "bpf_redirect (L3 forwarding)"],
      "skb_load_byte"    => [1, %w[offset],           "read 1 byte from the skb"],
      "skb_load_u16"     => [1, %w[offset],           "read a u16 from the skb"],
      "skb_load_u32"     => [1, %w[offset],           "read a u32 from the skb"],
      "skb_store_byte"   => [2, %w[offset value],     "write 1 byte to the skb"],
      "skb_store_u16"    => [2, %w[offset value],     "write a u16 to the skb"],
      "skb_store_u32"    => [2, %w[offset value],     "write a u32 to the skb"],
      "l3_csum_replace"  => [3, %w[offset from to],   "incremental L3 checksum fix (16-bit)"],
      "l3_csum_replace_ip" => [3, %w[offset from to], "incremental L3 checksum fix (32-bit IP)"],
      "l4_csum_replace"  => [3, %w[offset from to],   "incremental L4 checksum fix (16-bit)"],
      "l4_csum_replace_ip" => [3, %w[offset from to], "incremental L4 checksum fix (32-bit, pseudo-hdr)"],
      "l4_offset"        => [0, [],                   "the L4 start offset (14 + IHL*4, handles IP options)"],
      "flow_get"         => [2, %w[map_name field],   "conntrack: read a field of the current flow (symbol argument)"],
      "flow_set"         => [3, %w[map_name field value], "conntrack: write a field of the current flow (symbol argument)"],
      "flow_del"         => [1, %w[map_name],         "conntrack: delete the current flow's entry (symbol argument)"],
      "queue_push"       => [2, %w[skb to_free],      "enqueue an skb to a BPF list (qdisc)"],
      "queue_pop"        => [0, [],                   "dequeue an skb from a BPF list (qdisc)"],
      "arena_set"        => [2, %w[index value],      "write to an arena flat array"],
      "arena_get"        => [1, %w[index],            "read an arena flat array"],
      "arena_hash_set"   => [2, %w[key value],        "write to an arena hash"],
      "arena_hash_get"   => [1, %w[key],              "read an arena hash"],
      "arena_hash_del"   => [1, %w[key],              "delete from an arena hash"],
      "arena_list_push"  => [1, %w[value],            "push to an arena linked list"],
      "arena_list_sum"   => [0, [],                   "aggregate an arena linked list"],
      # --- core: identity / cgroup / control channel ---
      "divu"             => [2, %w[a b],              "unsigned 64-bit division (avoids the signed div reject)"],
      "i32"              => [1, %w[x],                "truncate a 32-bit kernel arg and sign-extend it (against upper-bit garbage on arm64)"],
      "pid"              => [0, [],                   "the userspace-style pid (the upper 32 bits of tgid)"],
      "tgid"             => [0, [],                   "thread group id"],
      "tid"              => [0, [],                   "kernel thread id"],
      "uid"              => [0, [],                   "the effective uid (the lower 32 bits of bpf_get_current_uid_gid, E399)"],
      "gid"              => [0, [],                   "the effective gid (the upper 32 bits of bpf_get_current_uid_gid, E399)"],
      "cpu_id"           => [0, [],                   "bpf_get_smp_processor_id()"],
      "cgroup_id"        => [0, [],                   "the current cgroup id (kernfs inode, the key for k8s pod correlation)"],
      # E401 (P011 S12): 複数シンボルに載った 1 つの body が「今どのシンボルか」を
      # 訊く**唯一の綴り**。展開でも kprobe_multi でも同じ形に lower する
      # (前者はリテラル、後者は bpf_get_attach_cookie) ので、リストが伸びて
      # codegen が機構を切り替えても body は変わらない。
      "attached_index"      => [0, [],                "multi-symbol handler: its own index in the declared list"],
      "attached_symbol_eq"  => [1, %w[symbol],        "multi-symbol handler: whether it is \"<symbol>\" (a literal, resolved to an index at compile time)"],
      "field_exists"     => [3, %w[ptr struct field], "whether BTF has struct.field (CO-RE)"],
    }.freeze

    # ===================================================================
    # E406: **降ろした** builtin — かつて SIG_TABLE に載っていたが、本番 C codegen
    # (ADR-011 Stage 2) には移植されていないことを実測したもの。
    #
    # なぜ表として残すのか (単に消さないのか):
    #   1. **記録** — 「無かったことにする」のは黙って消すのと同じ。E063/E064 等の
    #      Edoc は実在の測定であり、失われたのは実装であって観測ではない。
    #   2. **ゲートの常設 negative control** — tools/affordance_gate.rb は
    #      「advertised は全部通る」と「withdrawn は全部落ちる」の**両方**を毎回測る。
    #      片方だけだと、ゲートが「常に ok」に退化しても緑のままになる (E405 の教訓:
    #      壊れた出力が安定していると text 比較のゲートは何も言わない)。
    #      両方向を見るので、退化したゲートは自分で落ちる。
    #   3. **再移植の検出** — ここに載ったまま実装が戻ると gate が落ちる ⇒
    #      「実装したのに affordance に戻し忘れた」を捕まえる。
    #
    # `ctx` は最小 probe を組むための attach 形 (gate が使う)。`why` は
    # 「なぜ (a) 移植でなく (b) 降格を選んだか」、`instead` は **代わりに何を書くか**
    # (E419: WITHDRAWN_ATTACH は E407 から `instead` を持っていたが、こちらは
    # `why` の散文に混ぜていた。降格を JSON だけで読む消費者にとって
    # 「使えない」だけは半分の情報なので、両表で同じ形にした)。
    # ===================================================================
    WITHDRAWN = {
      # `reuseport_hash` / `worker_select` lived here between E406 and E413.
      # E413 re-ported them with the REUSEPORT_SOCKARRAY they index; the glue
      # half (sp_bpf_reuseport_register / sp_bpf_reuseport_attach) had never
      # been lost, which is the part E406's stated reason got wrong. The entries
      # are gone rather than kept to keep this table non-empty -- E415 moved the
      # gate's detection power off this inventory.
      # `tail_call_to` lived here between E406 and E412. E412 re-ported it
      # together with the two halves it needs (the `xdp_tail__` attach kind and
      # the PROG_ARRAY), so the entry is gone rather than kept to keep this table
      # non-empty -- E415 moved the gate's detection power off this inventory.
      "xdp_match_health" => { edoc: "E047", ctx: :xdp, arity: 0,
                              why: "the M004 XDP_TX version. A big one that includes compile-time precomputation of the checksum, and E048/E050 measured a structural reliability ceiling of ~35-50%; it was replaced by E053/E054's pure-XDP TCP slice",
                              instead: "`def xdp__tcp_slice__health; XDP_PASS; end` (E054, **ported to the C codegen in E416**) — the successor that completes the same M004 `/health` without the kernel TCP stack. Codegen emits the handshake / retransmission / FIN, so it has no ~35-50% reliability ceiling that these 2 builtins had structurally (E053 measured sequential 100%)" },
      "xdp_reply_health" => { edoc: "E047", ctx: :xdp, arity: 0,
                              why: "as above (the M004 XDP_TX version, replaced by the TCP slice)",
                              instead: "as above — `def xdp__tcp_slice__health` (E054/E416). The 2 builtins were used as a pair, so the replacement is the same single attach kind" },
      # The seven TCP-slice builtins (tcp_syncookie_gen/_check, tcp_reply_header/
      # _synack, tcp_synack_cookie, tcp_reply_data, payload_starts) lived here
      # between E406 and E416. E416 re-ported them together with the
      # `xdp__tcp_slice__` attach kind whose absence was E406's stated reason, so
      # the entries are gone rather than kept to keep this table non-empty --
      # E415 moved the gate's detection power off this inventory.
      # `user_ringbuf_drain` lived here between E406 and E414. E414 re-ported it
      # with the two halves it needs (the USER_RINGBUF map and the SEC-less
      # `user_ringbuf__` callback) plus the loader half that never existed
      # (`sp_bpf_user_cmd_push`), so the entry is gone rather than kept to keep
      # this table non-empty -- E415 moved the gate's detection power off this
      # inventory.
    }.freeze

    # ===================================================================
    # E407: **降ろした attach kind**。builtin の WITHDRAWN と同じ役割だが、
    # 沈黙の質が違うので別表にしてある。
    #
    #   未移植の **builtin** は `CallNode not yet ported (Stage 1)` で loud に死ぬ。
    #   未移植の **attach kind** は死なない。method 名が何にも match しないだけなので
    #   codegen はそれを普通のメソッドとして `SEC("syscall")` で包み、**load して
    #   何にも attach せず一度も発火しない program** を exit 0 で出す (E407 実測:
    #   出力は attach 接頭辞を持たないメソッドと byte 一致)。
    #
    # ⇒ affordance から降ろすのは**半分**でしかない。もう半分は codegen 側の
    #   `CC_WITHDRAWN_ATTACH` (spinel_ebpf_cc.c) で、これらの method 名を
    #   **compile 時に loud に拒否**する (ADR-003)。表と拒否は 1:1 で、
    #   tools/affordance_gate.rb が両方向を毎回突き合わせる:
    #     advertised な kind は宣伝どおりの SEC を出す /
    #     withdrawn な kind は必ず落ちる (= gate 自身が「差を見分けられる」ことの再証明)。
    #
    # `probe` は gate/監査が最小 probe を書くための表面 (method 名 or reactor 形)。
    # ===================================================================
    WITHDRAWN_ATTACH = {
      # EMPTY, and that is the finished state, not a gap.
      #
      # `timer:` entered here in E407 and left in E411 (P011 A2), `xdp_tail:` in
      # E407/E412, `user_ringbuf:` in E407/E414, and `xdp_tcp_slice:` -- the last
      # one -- in E407/E416. Every attach kind this codegen advertises is now
      # implemented, which is the claim E407 could not make about any of them.
      #
      # Nothing is invented to keep the record non-empty. E415 removed the gate's
      # abort-on-empty for exactly this moment, and A5 already emptied
      # WITHDRAWN_SUGAR and WITHDRAWN_MAPS without a replacement. The pressure to
      # keep an inventory armed by leaving something broken in the shipped
      # product is the thing E415 is about; the negative controls that used to
      # live off this table are synthesised now
      # (tools/affordance_gate.rb --section attach self-check).
    }.freeze

    # 全 builtin の signature を組み立てる (SIG_TABLE + 構造生成)。
    SIGNATURES = begin
      sigs = {}
      SIG_TABLE.each do |name, (arity, params, summary)|
        sigs[name] = { arity: arity, params: params, opaque: params.nil?, summary: summary }.freeze
      end
      PKT_FIELD_BUILTINS.each do |name|
        field = name.sub(/\Apkt_/, "")
        sigs[name] = { arity: 0, params: [], opaque: false,
                       summary: "packet field #{field} (xdp/tc, host order)" }.freeze
      end
      TCP_SOCK_READER_BUILTINS.each do |name|
        f = name.sub(/\Atcp_sock_/, "")
        sigs[name] = { arity: 1, params: %w[sk], opaque: false,
                       summary: "read tcp_sock->#{f} (tcp_cc)" }.freeze
      end
      TCP_SOCK_WRITER_BUILTINS.each do |name|
        f = name.sub(/\Atcp_sock_/, "").sub(/_set\z/, "")
        sigs[name] = { arity: 2, params: %w[sk value], opaque: false,
                       summary: "set tcp_sock->#{f} (tcp_cc)" }.freeze
      end
      TCP_SOCK_ADDER_BUILTINS.each do |name|
        f = name.sub(/\Atcp_sock_/, "").sub(/_add\z/, "")
        sigs[name] = { arity: 2, params: %w[sk delta], opaque: false,
                       summary: "tcp_sock->#{f} += delta (tcp_cc)" }.freeze
      end
      # opaque kfunc: arity は codegen の kfunc table から既知、Ruby 側 param 名は
      # struct_ops member シグネチャ由来で機械的に取れない ⇒ 正直に opaque。
      { "scx_dispatch" => 4, "scx_consume" => 1, "scx_kick_cpu" => 2,
        "scx_pick_idle_cpu" => 2, "scx_create_dsq" => 2,
        "qdisc_skb_drop" => 2, "qdisc_init_prologue" => 2,
        "qdisc_reset_destroy_epilogue" => 1, "qdisc_watchdog_schedule" => 3,
        "qdisc_bstats_update" => 2 }.each do |name, arity|
        sigs[name] = { arity: arity, params: nil, opaque: true,
                       summary: "kfunc passthrough (passes a kernel struct ptr from a struct_ops member)" }.freeze
      end
      sigs.freeze
    end

    # builtin -> context 要件 (codegen が compile 時 die で強制する hook)。
    #   { secs: [SEC...] }   d_path gate (E286)
    #   { kinds: [attach kind...] }  attach-kind gate
    # 無い builtin は codegen 非強制 (best-effort の context_note を付ける)。
    CONTEXT_REQUIREMENTS = begin
      reqs = {
        "emit_path"        => { secs: DPATH_OK_SECS },
        "emit_parent_path" => { secs: DPATH_OK_SECS },
        "path_eq"          => { secs: DPATH_OK_SECS },
        "path_starts_with" => { secs: DPATH_OK_SECS },
        "path_contains"    => { secs: DPATH_OK_SECS },
        "parent_path_eq"   => { secs: DPATH_OK_SECS },
        # E460: kinds に :xdp を含む mask は :xdp_tail も含む。`xdp_tail__` は C 側で
        # AK_XDP を共有し (tail の着地先は XDP プログラムそのもの)、C の gate は両者を
        # 区別しない — payload_starts / pkt_len を xdp_tail__ 内で実測して確認済み。
        # ここが :xdp だけだと affordance が合法手を隠す (claim が実装より狭い drift)。
        # :xdp_tcp_slice は含めない (body が discarded なので "allowed" が嘘になる、下記)。
        # この規則は capabilities_test の E460 lockstep test が C ソースから検証する。
        "cpumap_redirect"  => { kinds: %i[xdp xdp_tail] },
        "xsk_redirect"     => { kinds: %i[xdp xdp_tail] },
        # E060/E410: the helper's first parameter is a `struct xdp_md *`
        # (bpf_dynptr_from_xdp). TC has bpf_dynptr_from_skb, but E060 never
        # shipped that side and TC already reads bytes with skb_load_byte, so
        # the gate is XDP-only -- the same mask the C codegen enforces.
        "pkt_dynptr_byte_at" => { kinds: %i[xdp xdp_tail] },
        # E063/E412: a tail call lands in a program of the CALLER's own type, and
        # `spnl_prog_array` only ever holds this unit's `def xdp_tail__<name>` --
        # XDP programs. `xdp_tail` is itself an XDP kind here (a target may jump
        # onward, up to the kernel's 33-deep limit), so the one mask covers both
        # spellings of a dispatcher.
        "tail_call_to"     => { kinds: %i[xdp xdp_tail] },
        "dev_redirect"     => { kinds: %i[xdp xdp_tail] },
        # E051-E054/E416: the seven TCP-slice builtins. XDP-only because they
        # rewrite and RESIZE the raw frame (bpf_xdp_adjust_tail) through
        # `struct xdp_md`, and the two syncookie ones bottom out in kfuncs whose
        # first parameter is an XDP packet pointer. `xdp_tcp_slice` is NOT in the
        # mask: that kind's body is discarded, so a builtin written in it would
        # be silently dropped -- which is the one context where "allowed" would
        # be a lie. (Measured LOAD status per builtin: results/E416/d1_builtin_matrix.txt.)
        "tcp_syncookie_gen"   => { kinds: %i[xdp xdp_tail] },
        "tcp_syncookie_check" => { kinds: %i[xdp xdp_tail] },
        "tcp_reply_header"    => { kinds: %i[xdp xdp_tail] },
        "tcp_reply_synack"    => { kinds: %i[xdp xdp_tail] },
        "tcp_synack_cookie"   => { kinds: %i[xdp xdp_tail] },
        "tcp_reply_data"      => { kinds: %i[xdp xdp_tail] },
        "payload_starts"      => { kinds: %i[xdp xdp_tail] },
        "sock_addr_ip4"    => { kinds: %i[cgroup_connect4 cgroup_bind4] },
        "sock_addr_port"   => { kinds: %i[cgroup_connect4 cgroup_bind4] },
        "sock_ops_op"      => { kinds: %i[sock_ops] },
        "sock_ops_state"   => { kinds: %i[sock_ops] },
        # E043/E413: `struct sk_reuseport_md` and bpf_sk_select_reuseport exist for
        # exactly one program type. The gate is on the kind NAME rather than the
        # C codegen's AttachKind because sk_reuseport shares AK_SK_VERDICT with
        # six other hooks, each with a different ctx struct.
        "reuseport_hash"   => { kinds: %i[sk_reuseport] },
        "worker_select"    => { kinds: %i[sk_reuseport] },
        "iter_task"        => { kinds: %i[iter_task] },
        # E401: only a multi-symbol handler HAS a "which symbol" question. In a
        # 1-to-1 handler the attach point is the method name, so the codegen
        # refuses these rather than emitting a constant.
        "attached_index"     => { kinds: %i[kprobe_multi] },
        "attached_symbol_eq" => { kinds: %i[kprobe_multi] },
        "flow_get"         => { kinds: %i[xdp xdp_tail tc_ingress tc_egress] },
        "flow_set"         => { kinds: %i[xdp xdp_tail tc_ingress tc_egress] },
        "flow_del"         => { kinds: %i[xdp xdp_tail tc_ingress tc_egress] },
      }
      # E405 packet-context gate (cc_require_pkt_ctx). The codegen has refused
      # these outside a packet program since E405, but the affordance never said
      # so: `capabilities` reported them `gated: false` while the compiler died.
      # That is the same drift E406 is about, pointing the other way (the
      # affordance understating a constraint instead of overstating a capability),
      # so it is recorded here rather than left for a reader to discover by
      # hitting it. Masks mirror the C exactly.
      %w[redirect sk_lookup_tcp fib_lookup fib_lookup6]      # CC_CTX_PKT
        .each { |b| reqs[b] = { kinds: %i[xdp xdp_tail tc_ingress tc_egress] } }
      # CC_CTX_TC: they read/write `struct __sk_buff`, which XDP does not have.
      %w[skb_load_byte skb_load_u16 skb_load_u32
         skb_store_byte skb_store_u16 skb_store_u32
         l3_csum_replace l3_csum_replace_ip l4_csum_replace l4_csum_replace_ip
         l4_offset].each { |b| reqs[b] = { kinds: %i[tc_ingress tc_egress] } }
      reqs["sk_assign_tcp"] = { kinds: %i[tc_ingress] }     # CC_CTX_TC_INGRESS
      # E396 process-context gate (cc_require_task_ctx). These read the CURRENT
      # TASK, so outside a hook where the current task caused the event they are
      # not wrong-ish, they are about a different process -- measured (E396 m05):
      # an XDP program answered has_cap(CAP::SYS_ADMIN) TRUE about a CPU burner
      # for packets sent by another machine, while the real actor answered FALSE
      # in a kprobe in the same run. The kinds mirror cc_task_ctx_kind_ok exactly.
      # (file_type is deliberately NOT here: it reads the hook's own pointer, so
      # it is ungated like kfield.)
      %w[has_cap has_cap_permitted has_cap_inheritable cap_effective ns_id in_host_ns]
        .each { |b| reqs[b] = { kinds: %i[kprobe kretprobe kprobe_multi tracepoint raw_tp
                                          fentry fexit uprobe uretprobe usdt perf_event
                                          lsm fmod_ret cgroup_connect4 cgroup_bind4] } }
      PKT_FIELD_BUILTINS.each { |b| reqs[b] = { kinds: %i[xdp xdp_tail tc_ingress tc_egress] } }
      (TCP_SOCK_READER_BUILTINS + TCP_SOCK_WRITER_BUILTINS + TCP_SOCK_ADDER_BUILTINS)
        .each { |b| reqs[b] = { kinds: %i[tcp_cc] } }
      %w[scx_dispatch scx_consume scx_kick_cpu scx_pick_idle_cpu scx_create_dsq]
        .each { |b| reqs[b] = { kinds: %i[sched_ext] } }
      %w[qdisc_skb_drop qdisc_init_prologue qdisc_reset_destroy_epilogue
         qdisc_watchdog_schedule qdisc_bstats_update]
        .each { |b| reqs[b] = { kinds: %i[qdisc] } }
      reqs.each_value(&:freeze)
      reqs.freeze
    end

    # 非 gate builtin の best-effort context note (codegen は強制しない)。
    DOMAIN_CONTEXT_NOTE = {
      observability: "process-context probe (kprobe/kretprobe/tracepoint/fentry/fexit/perf_event/uprobe/usdt); not enforced by codegen",
      enforcement:   "process-context security hook; not enforced by codegen",
      net:           "packet/socket datapath prog (xdp/tc/sk_*); not enforced by codegen",
      l7:            "process-context kprobe/uprobe aimed at tcp_*/SSL_*; not enforced by codegen",
      core:          "any :ebpf method; not enforced by codegen",
    }.freeze

    # builtin 別の context_note override (domain note が family に不正確なとき、E325)。
    # DNS builtin は l7 domain に属すが transport は **UDP (:53)** — canonical hook は
    # udp_sendmsg/udp_recvmsg。l7 domain の "tcp_*/SSL_*" は DNS には**積極的な誤誘導**
    # (E325 再検証で author-agent が指摘、emit_dns の summary は既に udp_sendmsg と整合)。
    # designed contract の canonical hook を bounded に名指す (全 kernel catalog ではなく、
    # この family の意図された hook だけ)。dns_correct.rb の実 hook に忠実。
    CONTEXT_NOTE_OVERRIDES = {
      "dns_req_start"  => "kprobe/udp_sendmsg (starts correlation when a :53 query is sent); process-context; not enforced by codegen",
      "dns_resp_stash" => "kprobe/udp_recvmsg entry (stashes the response buffer; after the copy, kretprobe); process-context; not enforced by codegen",
      "dns_emit"       => "kretprobe/udp_recvmsg (correlates the response and emits a span); process-context; not enforced by codegen",
      "emit_dns"       => "kprobe/udp_sendmsg (packed-emits the DNS query; the destination is decided by udp_dport(sk, msg)); process-context; not enforced by codegen",
    }.freeze

    # ===================================================================
    # E322 (ADR-015 投資優先(a)、E321 GAP を畳む): 呼び出しコード例 + 関連 builtin。
    #
    # E321 の clean-room テストは affordance を「打てる手のカタログ」として十分と実証したが、
    # AI が prior knowledge で補った 2 GAP を残した:
    #   GAP-1: builtin ごとの Ruby コード例が皆無 (署名カードのみで呼び出し構文の見本が 0)。
    #   GAP-2: 関連 builtin の暗黙の関係が不明 (pid/tgid/tid のどれが process 粒度か等)。
    # E322 はこの 2 点だけを affordance に足す。
    #
    # 線引き (ADR-015 の thesis: affordance はブリッジ/ABI/合法性、意味論=ロジックは AI):
    #   * example は **構文見本 1 行** であって「使い方の指南」ではない。閾値の選び方・
    #     アルゴリズムの類は載せない (それは Ruby ロジック = AI の領分)。
    #   * related の note も「どれが process 粒度か・対か・ファミリか」という **選択に必要な
    #     事実 1 行** に留め、「いつ使うか」は書かない。
    # ===================================================================

    # 呼び出しコード例 (GAP-1)。原則は機械生成 (下の example_for):
    #   * arity N (params 判明) -> `name(p1, p2, ...)` (params を placeholder に構文を見せる)。
    #   * arity 0             -> `name` (bare 呼出。実 idiom の dominant 形、括弧不要を見せる)。
    #   * opaque kfunc (params 不明) -> nil (嘘の例より省略。opaque と同じ正直さ)。
    # 手書きが要るのは params 名だけでは正しい構文にならない builtin だけ:
    #   symbol 引数 (flow_*)、compile-time string リテラル引数 (path_eq/parent_path_eq/
    #   path_starts_with/path_contains)、struct 名 string 引数 (kfield/kptr/field_exists)。
    EXAMPLE_OVERRIDES = {
      # conntrack: map 名と field を symbol で渡す (E168/E173)
      "flow_get"       => "flow_get(:conn, :backend_ip)",
      "flow_set"       => "flow_set(:conn, :state, 1)",
      "flow_del"       => "flow_del(:conn)",
      # CO-RE: struct 名 + field 名を string で渡す (E099)
      "kfield"         => 'kfield(sk, "sock", "sk_sndbuf")',
      "kptr"           => 'kptr(sk, "sock")',
      # E394: 文字列版。カンマ = ポインタホップ、ドット = 埋め込みメンバ。
      "emit_kfield_str" => 'emit_kfield_str(file, "file", "f_path.dentry", "d_name.name")',
      "kfield_str_eq"  => 'kfield_str_eq(file, "file", "f_path.dentry", "d_name.name", "secret.txt")',
      "field_exists"   => 'field_exists(sk, "tcp_sock", "bytes_acked")',
      # compile-time string リテラル引数 (AOT がバイト列を unroll、E287/E053)
      # E401: the symbol must be one of the handler's DECLARED names -- an unknown
      # one is a compile error, not a comparison that is quietly always false.
      "attached_symbol_eq" => 'attached_symbol_eq("vfs_read")',
      "path_eq"        => 'path_eq(file, "/usr/bin/curl")',
      "path_starts_with" => 'path_starts_with(file, "/etc/secret/")',
      "path_contains"  => 'path_contains(file, "/.ssh/")',
      "parent_path_eq" => 'parent_path_eq("/usr/bin/curl")',
      # E416: the payload/prefix is unrolled at compile time, so it has to be a
      # literal -- a positional placeholder would be a call that does not compile.
      "payload_starts" => 'payload_starts("GET /health ")',
      "tcp_reply_data" => 'tcp_reply_data(seq, ack, "HTTP/1.0 200 OK\\r\\nContent-Length: 3\\r\\n\\r\\nOK\\n")',
      # E396: capability は BIT 番号を定数で渡す (CAP:: パスでも flat CAP_ でも同値)。
      # namespace の key は symbol リテラル (compile 時に kernel の struct member を選ぶ)。
      "has_cap"             => "has_cap(CAP::SYS_ADMIN)",
      "has_cap_permitted"   => "has_cap_permitted(CAP::NET_ADMIN)",
      "has_cap_inheritable" => "has_cap_inheritable(CAP::SYS_PTRACE)",
      "ns_id"               => "ns_id(:mnt)",
      "in_host_ns"          => "in_host_ns(:mnt)",
      "file_type"           => "file_type(file)",
    }.freeze

    # E395: **返り値の単位・バイト順**。record_schema.h が packed record の
    # フィールドごとに note を持つのと同じ役割を builtin に対して果たす
    # (E376 の srtt 1/8us が「生の値と意味のある値はずれる」を示した通り、
    # 値の意味は綴りから読めないので書いてある場所が要る)。
    #
    # ここに載せる基準は「**間違えても静かに通る**」こと。単位/バイト順を取り違えても
    # verifier もコンパイラも何も言わず、出てくる数はそれらしく見える ⇒ 書いて渡すしかない。
    # そうでない値 (pid、カウンタ等) は綴りで読めるので載せない。
    VALUE_SEMANTICS = {
      "sock_sport"      => "source port / host order (the underlying skc_num is host order to begin with = not converted)",
      "sock_dport"      => "destination port / host order (the underlying skc_dport is __be16 = network order, already ntohs'd)",
      "sock_saddr"      => "source IPv4 / host order (already ntohl'd). Meaningful only when sock_family == AF_INET",
      "sock_daddr"      => "destination IPv4 / host order (already ntohl'd). Meaningful only when sock_family == AF_INET",
      "sock_family"     => "AF_INET (2) / AF_INET6 (10)",
      "sock_state"      => "TCP_STATE_* (ESTABLISHED=1 ...)",
      "sock_protocol"   => "IPPROTO_* (TCP=6 / UDP=17)",
      "sock_saddr6_hi"  => "source IPv6 high 64 bits / E080 hi-lo convention, host order. Meaningful only for AF_INET6",
      "sock_saddr6_lo"  => "source IPv6 low 64 bits / E080 hi-lo convention, host order. Meaningful only for AF_INET6",
      "sock_daddr6_hi"  => "destination IPv6 high 64 bits / E080 hi-lo convention, host order. Meaningful only for AF_INET6",
      "sock_daddr6_lo"  => "destination IPv6 low 64 bits / E080 hi-lo convention, host order. Meaningful only for AF_INET6",
      # E428: 値そのものは sock_dport と同じ形 (host order の port) なので、
      # ここに載せる理由は単位ではなく **どの問いに答えているか**。取り違えても
      # 型は合い、connect する sender では同じ数が返り、違いは「未接続の送信が
      # 1 件も報告されない」という**沈黙**としてしか現れない。
      "udp_dport"       => "the destination port **of this send** / host order (msg_name if present, otherwise the connected peer). sock_dport is the socket's peer, 0 when unconnected",
      "udp_daddr"       => "the destination IPv4 **of this send** / host order (as above). 0 when the destination is IPv6",
      # E396: 3 つとも「間違えても静かに通る」の典型。値の形が読めないと、
      # 比較の書き方そのものを間違える (そして小さくもっともらしい数が返る)。
      "cap_effective"   => "a **64-bit bit set** of capabilities (not a number). CAP_X is a bit number, so `& CAP_X` is wrong — decide with has_cap(CAP::X). A value for reporting",
      "ns_id"           => "the namespace's **inode number** (the same N as proc's ns:[N]). Comparable only within one kernel and meaningless alone. Whether it is the host: in_host_ns",
      "file_type"       => "the file type, **already S_IFMT-masked** (compare with == against FileType::REG and so on). Not the raw i_mode, so it holds no permission bits",
    }.freeze

    # 返り値の単位・バイト順 (無ければ nil)。describe / capabilities が印字する。
    def self.value_semantics_for(name)
      VALUE_SEMANTICS[name]
    end

    # 関連 builtin のクロスリンク (GAP-2)。各グループ = {name, members, note}。
    # related: (builtin ごとの相互リンク) はここから導出する (単一の権威、related_for)。
    # note は選択に必要な事実 1 行 (粒度/対/ファミリ) に留める (「いつ使うか」は書かない)。
    # 多フック必須組 (http/ssl/dns/offcpu span 等) は REQUIRED_SETS が持つので重複させない
    # (l7_roundtrip だけは E321 が「対」と名指したので載せ、required_sets を xref する)。
    BUILTIN_GROUPS = [
      { name: "process_thread_identity",
        members: %w[pid tgid tid],
        note: "pid()==tgid()=process granularity (the upper 32 bits of bpf_get_current_pid_tgid); tid()=thread granularity (the lower 32 bits). Choose by whether the grouping key should be per process or per thread." }.freeze,
      { name: "latency_tid_pair",
        members: %w[latency_start latency_end],
        note: "a BEGIN/END pair keyed by tid. start=record the entry ktime (kprobe), end=return the delta ns and delete (kretprobe). Used as a pair." }.freeze,
      { name: "latency_keyed_pair",
        members: %w[lat_start lat_end],
        note: "a BEGIN/END pair with any key (the keyed version of latency_start/end)." }.freeze,
      { name: "histogram",
        members: %w[hist_observe hist_observe_by hist_observe_linear],
        note: "the 3 forms of the log2 hist: hist_observe=no key / hist_observe_by=keyed(key,value) / hist_observe_linear=a slot the caller pre-bucketed." }.freeze,
      { name: "str_emit",
        members: %w[emit_comm emit_path emit_parent_path emit_argv spnl_emit_str emit_kfield_str],
        note: "emit to the str ringbuf: comm / full path (gated) / parent exe path (gated) / argv / a string at any user ptr / a kernel struct's string field (no gate)." }.freeze,
      { name: "kernel_field_read",
        members: %w[kfield kptr emit_kfield_str kfield_str_eq],
        note: "CO-RE reads of kernel struct fields (untrusted pointers allowed): kfield=returns a scalar by value / kptr=a handle for the .field dot accessor / emit_kfield_str=a string to the str ringbuf / kfield_str_eq=whether a string equals a literal (an expression). All four spell hops the same way (comma=pointer hop, dot=embedded member). To read a struct sock *, use the named sock_* (byte order handled) rather than raw kfield." }.freeze,
      { name: "datagram_destination",
        members: %w[udp_dport udp_daddr sock_dport sock_daddr],
        note: "two ways to ask \"where is it sending\" (E428). `udp_dport(sk, msg)`/`udp_daddr(sk, msg)` = the destination **of this send**, correct for an unconnected socket too (one that passes the destination to sendto every time). `sock_dport(sk)`/`sock_daddr(sk)` = **the socket's peer**, 0 when unconnected. For a sender that connects both return the same number, so a mix-up shows only as silence: \"only the unconnected sends report nothing\" — to filter in a UDP send hook, use udp_*." }.freeze,
      { name: "sock_accessor",
        members: %w[sock_sport sock_dport sock_saddr sock_daddr sock_family sock_state sock_protocol
                    sock_saddr6_hi sock_saddr6_lo sock_daddr6_hi sock_daddr6_lo],
        note: "reads a `struct sock *` in any context (kprobe and so on) by name (E395). Underneath is the same CO-RE read as kfield, but **every return value is aligned to host order** — struct sock_common's byte order differs per field (skc_dport=__be16 / skc_num=__u16), and every raw value looks like \"a plausible port/IP\", so any single rule on the caller's side is always quietly wrong for one of them. Read the address fields (saddr/daddr/*6_*) only after branching on sock_family. Different from tcp_sock_*, which reads the trusted sk of struct_ops/tcp_cc (that one is a direct deref; this one is untrusted, so BPF_CORE_READ)." }.freeze,
      { name: "file_selector",
        members: %w[path_eq path_starts_with path_contains file_type],
        note: "predicates on the `struct file *` a hook passes (expressions, so they drive an if). path_* = the full path equals / starts with / contains a literal (bpf_d_path underneath, **kernel-gated** = only some hooks can use them). file_type = the type (reg/dir/lnk/sock/blk/chr/fifo, **no gate** — it reads i_mode with CO-RE rather than bpf_d_path, so it works wherever kfield does. A kprobe cannot get the full path but can get the type). For the file name alone, kfield_str_eq (E394)." }.freeze,
      { name: "task_capability",
        members: %w[has_cap has_cap_permitted has_cap_inheritable cap_effective],
        note: "the current task's capabilities (E396). Decide with has_cap*(CAP::X) = **a bit test**; cap_effective is the 64-bit bit set **itself** (for reporting). effective=usable now / permitted=the ceiling it can be raised to / inheritable=carried across exec. **`cap_effective & CAP_X` is always wrong** — CAP_X is a bit number (SYS_ADMIN=21), not a mask, so it returns the same number whether the task holds it or not (E396 m01 measured). Process-context hooks only." }.freeze,
      { name: "task_namespace",
        members: %w[ns_id in_host_ns],
        note: "the current task's namespaces (E396). ns_id(:mnt) = the inode number (for correlation, meaningless alone), in_host_ns(:mnt) = whether it is in the initial namespace (0/1). key is :mnt :net :uts :ipc :cgroup :time :user :pid. :pid follows thread_pid (nsproxy->pid_ns_for_children is the namespace \"children enter\", a different thing, E396 m02). The initial namespace's inode is read from untyped ksyms — /proc/1/ns cannot be used, because inside a container it points to the container's init. For container membership alone, cgroup_id (E302) leads to k8s more directly. Process-context hooks only." }.freeze,
      { name: "scalar_emit",
        members: %w[spnl_emit spnl_emit_pair spnl_emit3 spnl_emit4],
        note: "scalar ringbuf emit: 1/2/3/4 values per event (a common 16B hdr)." }.freeze,
      { name: "stack_trace",
        members: %w[stack_id user_stack_id],
        note: "STACK_TRACE map ids: stack_id=kernel stack / user_stack_id=user stack." }.freeze,
      { name: "off_cpu_profile",
        members: %w[off_cpu_start off_cpu_observe],
        note: "the off-CPU profile pair (E091): start=stash ktime+stack at sched_switch, observe=on return, the delta into a keyed hist. Different from the multi-hook span's offcpu_*." }.freeze,
      { name: "task_storage",
        members: %w[task_load task_store task_incr task_swap],
        note: "per-task storage: load/store/incr(RMW)/swap. Freed automatically when the task ends; no explicit key needed." }.freeze,
      { name: "l7_roundtrip",
        members: %w[req_start emit_l7],
        note: "the L7 round-trip latency pair (E297): req_start=record the start time at sendmsg, emit_l7=emit the round-trip span at cleanup_rbuf. For the required set, see required_sets.l7_latency." }.freeze,
      { name: "pkt_fields",
        members: (PKT_FIELD_BUILTINS + %w[pkt_dynptr_byte_at]),
        note: "XDP/TC packet field accessors (no arguments, host order). The pkt.* chain accessors such as pkt.l4.proto give the same values. " \
              "**Only pkt_dynptr_byte_at(off) is different**: one argument, a run-time offset, XDP only, and it returns a byte (0-255) or -1 (E060/E410). " \
              "To read a fixed place in a header, use the fixed-offset readers; for any place, the dynptr." }.freeze,
      { name: "tcp_sock_accessors",
        members: (TCP_SOCK_READER_BUILTINS + TCP_SOCK_WRITER_BUILTINS + TCP_SOCK_ADDER_BUILTINS),
        note: "tcp_sock fields in tcp_cc context: reader(sk) / writer(sk,value)_set / adder(sk,delta)_add. The dot accessors such as sk.snd_cwnd do the same." }.freeze,
      { name: "arena",
        members: %w[arena_set arena_get arena_hash_set arena_hash_get arena_hash_del arena_list_push arena_list_sum],
        note: "data structures in bpf_arena shared memory: flat array (set/get) / hash (set/get/del) / linked list (push/sum). Shared with userspace by mmap." }.freeze,
      { name: "skb_rewrite",
        members: %w[skb_load_byte skb_load_u16 skb_load_u32 skb_store_byte skb_store_u16 skb_store_u32 l3_csum_replace l3_csum_replace_ip l4_csum_replace l4_csum_replace_ip l4_offset],
        note: "TC skb reads and writes + checksum fixes: load/store (byte/u16/u32) + l3/l4_csum_replace(_ip) + l4_offset (the L4 start, handles IP options). Parts for NAT." }.freeze,
    ].freeze

    # attach-kind の作法一覧。codegen の ATTACH_PATTERNS と 1:1 (kind 集合の一致は
    # capabilities_test.rb が機械強制)。args_convention = 宣言 param がどの ABI で
    # attach context から取り出されるか (codegen の extract_attach_args)。
    # E401 (P011 S12): the symbol count at which `on :kprobe, %w[...]` stops
    # expanding into N programs and becomes one SEC("kprobe.multi") link.
    #
    # THE NUMBER LIVES IN TWO LANGUAGES AND THAT IS A HAZARD, so it is gated:
    # tests/spinel_ebpf/attach_multi_test.rb reads
    # `#define CC_MULTI_AUTO_THRESHOLD` out of src/codegen_c/spinel_ebpf_cc.c and
    # asserts it equals this. MEASURED, not chosen: 16 is the smallest N at which
    # the multi lowering won load+attach time in every repetition
    # (docs/experiments/results/E401/crossover.tsv). Below it, expansion is both
    # faster AND has the lower kernel floor, so `auto` never raises a probe's
    # floor from 5.2 to 5.18 for a mechanism that is not yet paying for itself.
    ATTACH_MULTI_THRESHOLD = 16

    # E461/ADR-019 Phase B: attach 語彙の**機械軸** (kind 集合 / sec / ctx_type / kname /
    # facet) の正本は src/codegen_c/attach_schema.h — cc_detect_attach() が歩くのと
    # 同じ宣言テーブルを `make -C src/codegen_c attach-schema` が JSON に描画し、
    # ここはそれを読む (record_schema_gen.json と同じ「C ヘッダ正本 + Ruby は生成物を
    # 読むだけ」の形)。下の ATTACH_KINDS は `sec:` をこの表から引く — 値を 2 箇所に
    # 書かないため (E460: 照合の無い軸だけがドリフトした)。散文 (args_convention /
    # context_note) は意図的にここに残る: 機械軸ではなく、E406-E426 のドリフトは
    # どれも散文では起きていない。stale/手編集は tools/attach_gate.rb が落とす。
    ATTACH_SCHEMA = begin
      require "json"
      path = File.expand_path("attach_schema_gen.json", __dir__)
      unless File.exist?(path)
        raise "attach schema artifact missing: #{path} " \
              "(run: make -C src/codegen_c attach-schema)"
      end
      JSON.parse(File.read(path)).map { |r| [r.fetch("kind"), r.freeze] }.to_h.freeze
    end

    ATTACH_KINDS = [
      { kind: :kprobe,        method_prefix: "kprobe__<func>",           sec: ATTACH_SCHEMA.fetch("kprobe")["sec"],         ctx_type: "struct pt_regs *", args_convention: "PT_REGS_PARM<N>(ctx) — kernel func arguments (names resolved by BTF)", context_note: "kernel function entry" },
      { kind: :kprobe_multi,  method_prefix: "on :kprobe, %w[<func> <func> ...] (reactor form only)", sec: ATTACH_SCHEMA.fetch("kprobe_multi")["sec"], ctx_type: "struct pt_regs *", args_convention: "PT_REGS_PARM<N>(ctx) — the same as kprobe. In addition attached_symbol_eq(\"<func>\") / attached_index ask \"which symbol is this now\" (**one spelling**: a literal when expanded, lowered to bpf_get_attach_cookie for kprobe_multi)", context_note: "E401 (P011 S12): one definition → several attachments. **There are two underlying forms, and codegen chooses** — with fewer symbols than ATTACH_MULTI_THRESHOLD it expands into N SEC(\"kprobe/<func>\"); otherwise one SEC(\"kprobe.multi\") + a per-symbol cookie (the glue attaches with a symbol array). `via: :expand` / `via: :multi` name one — this is for **deployment**, not for the body, since kprobe_multi raises the kernel floor to 5.18. ⚠ There is no flat `def` form: a method name cannot hold a list, and `%w[].each { define_method }` does not work because the partition walks the AST" },
      { kind: :kretprobe,     method_prefix: "kretprobe__<func>",        sec: ATTACH_SCHEMA.fetch("kretprobe")["sec"],      ctx_type: "struct pt_regs *", args_convention: "a single param = the return value (PT_REGS_RC)", context_note: "kernel function return" },
      { kind: :uprobe,        method_prefix: "uprobe__<func>",           sec: ATTACH_SCHEMA.fetch("uprobe")["sec"],                ctx_type: "struct pt_regs *", args_convention: "PT_REGS_PARM<N>(ctx); target binary/pid from env (SPNL_UPROBE_*)", context_note: "userspace function entry" },
      { kind: :uretprobe,     method_prefix: "uretprobe__<func>",        sec: ATTACH_SCHEMA.fetch("uretprobe")["sec"],             ctx_type: "struct pt_regs *", args_convention: "ret param; target from env (SPNL_UPROBE_*)", context_note: "userspace function return" },
      { kind: :usdt,          method_prefix: "usdt__<provider>__<probe>", sec: ATTACH_SCHEMA.fetch("usdt")["sec"],                 ctx_type: "struct pt_regs *", args_convention: "bpf_usdt_arg(ctx, i, &v); target from env (SPNL_USDT_*)", context_note: "USDT static probe. E409 measured: it includes usdt.bpf.h, so **3 more maps appear** (__bpf_usdt_specs 256 / __bpf_usdt_ip_to_spec_id 1024 / .kconfig; the generated C has no declaration of them)" },
      { kind: :tracepoint,    method_prefix: "tracepoint__<cat>__<event>", sec: ATTACH_SCHEMA.fetch("tracepoint")["sec"], ctx_type: "void *", args_convention: "syscalls: positional arguments ctx->args[i]; named-field TP: param name→struct field (E024)", context_note: "kernel tracepoint" },
      { kind: :fentry,        method_prefix: "fentry__<func>",           sec: ATTACH_SCHEMA.fetch("fentry")["sec"],         ctx_type: "__u64 *", args_convention: "ctx[i] = func arguments (names resolved by BTF)", context_note: "BPF trampoline entry (~50ns)" },
      { kind: :fexit,         method_prefix: "fexit__<func>",            sec: ATTACH_SCHEMA.fetch("fexit")["sec"],          ctx_type: "__u64 *", args_convention: "ctx[i] = func arguments, the last param = the return value", context_note: "BPF trampoline exit" },
      { kind: :lsm,           method_prefix: "lsm__<hook>",              sec: ATTACH_SCHEMA.fetch("lsm")["sec"],            ctx_type: "__u64 *", args_convention: "ctx[i] = hook arguments, the last param = the prior verdict", context_note: "LSM security hook; deny = a negative errno / allow = return the last param (prior verdict) — do not overwrite it with a literal 0 (this keeps a prior deny, and also avoids the verifier state explosion (E328, 1M insn) that returning a literal constant for allow causes together with a path_eq gate). ⚠ Enforcement needs bpf on the boot cmdline (lsm=…,bpf). Without it, attaching succeeds but it never fires, a silent no-op → for an environment-independent deny use fmod_ret/security_* (E328)" },
      { kind: :fmod_ret,      method_prefix: "fmod_ret__<func>",         sec: ATTACH_SCHEMA.fetch("fmod_ret")["sec"],       ctx_type: "__u64 *", args_convention: "ctx[i] = func arguments, the last param = ret. The handler's arity is the hook function's argument count + 1 (ret). Example: security_file_open takes 1 argument, file, so `def fmod_ret__security_file_open(file, ret)`", context_note: "BPF_MODIFY_RETURN; replaces the target function's ret (deny = a negative errno / allow = return the last param, ret). Attached to security_*, it is a portable deny that does not depend on the boot lsm= setting (it avoids the lsm hook's silent no-op, E328) = the default for an enforcement deny" },
      { kind: :sock_ops,      method_prefix: "sock_ops__<name>",         sec: ATTACH_SCHEMA.fetch("sock_ops")["sec"],               ctx_type: "struct bpf_sock_ops *", args_convention: "no declared param; read ctx with sock_ops_op / sock_ops_state", context_note: "cgroup-scoped TCP state observation. The glue attaches to $SPNL_CGROUP_PATH (E065). The return value is not a verdict (the wrapper returns 0). Ported to the C codegen in E407 (before that it did not become SEC(\"sockops\") and was silent)" },
      { kind: :cgroup_connect4, method_prefix: "cgroup__connect4__<name>", sec: ATTACH_SCHEMA.fetch("cgroup_connect4")["sec"],     ctx_type: "struct bpf_sock_addr *", args_convention: "no declared param; read ctx with sock_addr_ip4/sock_addr_port", context_note: "outbound connect control; returns 1=allow/0=deny" },
      { kind: :cgroup_bind4,  method_prefix: "cgroup__bind4__<name>",    sec: ATTACH_SCHEMA.fetch("cgroup_bind4")["sec"],          ctx_type: "struct bpf_sock_addr *", args_convention: "no declared param; read ctx with sock_addr_*", context_note: "bind control; returns 1=allow/0=deny" },
      { kind: :iter_task,     method_prefix: "iter__task__<name>",       sec: ATTACH_SCHEMA.fetch("iter_task")["sec"],             ctx_type: "struct bpf_iter__task *", args_convention: "no declared param; the task ptr from iter_task()", context_note: "task enumeration; driven by userspace (glue create+read)" },
      { kind: :raw_tp,        method_prefix: "raw_tp__<event>",          sec: ATTACH_SCHEMA.fetch("raw_tp")["sec"],        ctx_type: "struct bpf_raw_tracepoint_args *", args_convention: "ctx->args[i]", context_note: "raw tracepoint (low overhead)" },
      { kind: :socket_filter, method_prefix: "socket_filter__<name>",    sec: ATTACH_SCHEMA.fetch("socket_filter")["sec"],                ctx_type: "struct __sk_buff *", args_convention: "no declared param", context_note: "classic SO_ATTACH_BPF; returns the number of bytes to keep" },
      { kind: :flow_dissector, method_prefix: "flow_dissector__<name>",  sec: ATTACH_SCHEMA.fetch("flow_dissector")["sec"],        ctx_type: "struct __sk_buff *", args_convention: "no declared param", context_note: "returns BPF_OK/BPF_DROP" },
      { kind: :sk_lookup,     method_prefix: "sk_lookup__<name>",        sec: ATTACH_SCHEMA.fetch("sk_lookup")["sec"],             ctx_type: "struct bpf_sk_lookup *", args_convention: "no declared param", context_note: "listener selection; SEC takes no sub-name; returns SK_PASS/SK_DROP" },
      { kind: :tcp_cc,        method_prefix: "class <N> < BPF::TcpCC (def <member>)", sec: ATTACH_SCHEMA.fetch("tcp_cc")["sec"],   ctx_type: nil, args_convention: "struct_ops through class inheritance (`class N < BPF::TcpCC` + `def init(sk)`/`def cong_avoid(sk,ack,acked)` and so on) is recommended — the right Ruby form. A flat `def tcp_cc__<member>` also registers (E330-2). Member arguments (sk and so on) arrive as __s64 and are read and written with the tcp_sock_* builtins (dot accessors such as sk.snd_cwnd also work, E330)", context_note: "struct_ops/tcp_congestion_ops member. Class inheritance recommended (flat also works)" },
      { kind: :sched_ext,     method_prefix: "class <N> < BPF::SchedExt (def <member>)", sec: ATTACH_SCHEMA.fetch("sched_ext")["sec"], ctx_type: nil, args_convention: "struct_ops through class inheritance (`class N < BPF::SchedExt` + `def <member>`) is recommended. A flat `def sched_ext__<member>` also registers (E330-2). Member arguments (task and so on) arrive as __s64 and are passed to the scx_* builtins", context_note: "struct_ops/sched_ext_ops member (CPU scheduler). Class inheritance recommended (flat also works)" },
      { kind: :qdisc,         method_prefix: "class <N> < BPF::Qdisc (def <member>)", sec: ATTACH_SCHEMA.fetch("qdisc")["sec"],   ctx_type: nil, args_convention: "struct_ops through class inheritance (`class N < BPF::Qdisc` + `def <member>`) is recommended. A flat `def qdisc__<member>` also registers (E330-2). Required members and signatures: init(sch,opt,extack) / enqueue(skb,sch,to_free) / dequeue(sch) / reset(sch) / destroy(sch). ⚠ enqueue must always release the skb ref — qdisc_skb_drop(skb,to_free) to drop, queue_push(skb,to_free) to forward. Without the release the verifier rejects it for a reference leak", context_note: "struct_ops/Qdisc_ops member (attached as spnl_qdisc through tc). Class inheritance recommended (flat also works)" },
      { kind: :xdp,           method_prefix: "xdp__<name>",              sec: ATTACH_SCHEMA.fetch("xdp")["sec"],                   ctx_type: "struct xdp_md *", args_convention: "no declared param; the pkt_*/pkt.* builtins", context_note: "returns XDP_PASS/DROP/TX/REDIRECT; env SPNL_XDP_IFACE" },
      { kind: :xdp_tail,      method_prefix: "xdp_tail__<name>",         sec: ATTACH_SCHEMA.fetch("xdp_tail")["sec"],                   ctx_type: "struct xdp_md *", args_convention: "no declared param; the pkt_*/pkt.* builtins (the same as ordinary XDP)", context_note: "E063 / **ported to the C codegen in E412** (before that it was silently a SEC(\"syscall\") wrapper = not even an XDP program). **A tail-call target**: the emitted program is an ordinary SEC(\"xdp\"); the difference is **only in how the loader treats it** — it is not attached to an interface, and its fd is written into `spnl_prog_array` at **the slot of its declaration order** (0,1,...) (`_spnl_prog_array_populate`, E065). The jumping side calls `tail_call_to(slot)` (from a `def xdp__<name>` or from another `def xdp_tail__<name>`; the kernel limit is 33 levels). **The motive is that the 1M instruction budget is per program** (E063 = the only way to split XDP). ⚠ **A failure is silent** — a jump to an empty slot just falls through, so if slot numbers and declaration order drift apart, the result is not \"jumps to another program\" but \"does not jump and the rest runs\" = quietly different behaviour. An integer-literal slot is range-checked at compile time, but a computed slot cannot be. `spinel-ebpf describe` prints the slot → method table. ⚠ A unit that declares only targets and never jumps is **legal** (the map is emitted and the loader populates it) — so that \"no dispatcher written yet\" is not rejected. ⚠ **The kernel floor is not \"4.2\"** — bpf_tail_call + PROG_ARRAY themselves are 4.2, but the generated dispatcher issues the tail call from inside `<name>_inner` (a BPF-to-BPF **subprogram**) (E412 confirmed it in the kernel's xlated dump: after `call pc+2#..._inner`, `call bpf_tail_call` at insn 39). **A tail call from a subprogram is a separate, later feature that needs per-architecture JIT support**, and **its floor was not measured** ⇒ `portability` reports 4.2 as the feature's floor and declares \"floor not settled\" on a separate line (measured working on 7.1.5/aarch64). The effective floor is at least SEC(\"xdp\")'s **5.9**" },
      { kind: :xdp_tcp_slice, method_prefix: "xdp__tcp_slice__<name>", sec: ATTACH_SCHEMA.fetch("xdp_tcp_slice")["sec"], ctx_type: "struct xdp_md *", args_convention: "**no declared param, and the body is not used either** — the method body is a marker, and codegen replaces it wholesale with generated code", body: :discarded, emits: "spnl_tcp_slice_main", context_note: "E051-E054 (M004's strict achievement) / **ported to the C codegen in E416** (E407-E416 rejected it at compile time with `WITHDRAWN_ATTACH`). **An HTTP reply without the kernel's TCP stack**: no listen socket on port 8080; SYN / handshake ACK / GET / FIN are all completed in XDP. It sets up the 3-way handshake statelessly with `bpf_tcp_raw_gen_syncookie_ipv4`, keeps ESTABLISHED / RESP_SENT / CLOSED in a 4-tuple-keyed `bpf_conntab` (LRU_HASH), and answers `GET /health ` with `HTTP/1.0 200 OK` by XDP_TX. It includes E057's retransmission handling (GET again in RESP_SENT → resend the reply / FIN again in CLOSED → resend FIN-ACK) and per-state TTL `bpf_timer`s. ⚠ **The body is discarded** — the `XDP_PASS` in `def xdp__tcp_slice__health; XDP_PASS; end` appears nowhere in the generated C. Logic written there **does nothing, and no diagnostic appears** (the marker's definition does not depend on spelling, so rejecting non-markers was judged to cause more errors). ⚠ **Port 8080 and `/health` are fixed** (as in E054; making them variable is homework for E055+). ⚠ **One slice per unit** — the generated symbol names are fixed, so a second one dies at compile time. ⚠ There is no reactor form `on :xdp_tcp_slice` (there is no body to synthesize). ⚠ **`bpf_timer` is a different mechanism from `on :timer` (E079/E411)**: that is a periodic timer in one slot of an ARRAY map, armed once at load; this is **a per-connection timer embedded in the LRU_HASH value, armed per connection from the BPF side** (the callback deletes its own map entry). They share only `struct bpf_timer` and the 5.15 floor" },
      { kind: :tc_ingress,    method_prefix: "tc__ingress__<name>",      sec: ATTACH_SCHEMA.fetch("tc_ingress")["sec"],         ctx_type: "struct __sk_buff *", args_convention: "no declared param; the pkt_*/skb_* builtins", context_note: "returns TC_ACT_*; env SPNL_TCX_IFACE" },
      { kind: :tc_egress,     method_prefix: "tc__egress__<name>",       sec: ATTACH_SCHEMA.fetch("tc_egress")["sec"],            ctx_type: "struct __sk_buff *", args_convention: "no declared param; the pkt_*/skb_* builtins", context_note: "returns TC_ACT_*; env SPNL_TCX_IFACE" },
      { kind: :sk_reuseport,  method_prefix: "sk_reuseport__<name>",     sec: ATTACH_SCHEMA.fetch("sk_reuseport")["sec"],          ctx_type: "struct sk_reuseport_md *", args_convention: "no declared param", context_note: "decides **which listen socket gets** a SYN that reached the SO_REUSEPORT group. Returning `SK_PASS` = adopt this decision (without a `worker_select` call, **the kernel's default 5-tuple spread**) / `SK_DROP` = drop the SYN. **E413 ported `reuseport_hash` / `worker_select` to the C codegen**, so the BPF side can name a worker (before that, after E406's demotion, it could only confirm the default selection or drop). It attaches with setsockopt(SO_ATTACH_REUSEPORT_EBPF): call the glue's `sp_bpf_reuseport_attach(listen_fd, \"sk_reuseport__<name>\")` from the probe's userspace side (not auto-attached — the probe creates the listen socket, so the loader does not know it). ⚠ **A failed selection is silent** (see worker_select below)" },
      { kind: :sk_msg,        method_prefix: "sk_msg__<name>",           sec: ATTACH_SCHEMA.fetch("sk_msg")["sec"],                ctx_type: "struct sk_msg_md *", args_convention: "no declared param", context_note: "sockmap; attached with BPF_SK_MSG_VERDICT. ⚠ E409 measured: **spinel-ebpf does not create the sockmap itself** (BPF_MAP_TYPE_SOCKMAP/SOCKHASH appear nowhere in codegen) — userspace provides the map to attach to" },
      { kind: :sk_skb_verdict, method_prefix: "sk_skb__verdict__<name>", sec: ATTACH_SCHEMA.fetch("sk_skb_verdict")["sec"], ctx_type: "struct __sk_buff *", args_convention: "no declared param", context_note: "sockmap stream verdict. ⚠ E409 measured: codegen does not create the sockmap (userspace provides it)" },
      { kind: :sk_skb_parser, method_prefix: "sk_skb__parser__<name>",   sec: ATTACH_SCHEMA.fetch("sk_skb_parser")["sec"],  ctx_type: "struct __sk_buff *", args_convention: "no declared param", context_note: "sockmap stream parser. ⚠ E409 measured: codegen does not create the sockmap (userspace provides it)" },
      { kind: :perf_event,    method_prefix: "perf_event__<name> / on :perf_event, hz: N", sec: ATTACH_SCHEMA.fetch("perf_event")["sec"], ctx_type: "struct bpf_perf_event_data *", args_convention: "no declared param; pair with stack_id()", context_note: "per-CPU sampling profiler" },
      # E061/E414: the ONE attach kind that emits no program. `sec:` would be a
      # lie in either direction (there is no SEC, and "syscall" is precisely the
      # string the silent degradation produced before E407 refused this name), so
      # the entry declares `emits:` instead -- the C symbol its promise names.
      # tools/affordance_gate.rb reads whichever of the two the entry carries, so
      # the expected string still lives here and not in the gate.
      { kind: :user_ringbuf,  method_prefix: "user_ringbuf__<name>(value) / on :user_cmd do |cmd| ... end", sec: ATTACH_SCHEMA.fetch("user_ringbuf")["sec"],
        emits: "static long spnl_user_ringbuf_cb_<name>(struct bpf_dynptr *dynptr, void *_uctx)",
        ctx_type: "struct bpf_dynptr * (record) + void * (unused)",
        args_convention: "**exactly one** declared param — the value the host pushed. Reads the record's first 8 bytes with `bpf_dynptr_read`",
        context_note: "E061 / **ported to the C codegen in E414** (before that it was silently a SEC(\"syscall\") wrapper = a \"callback\" nobody drains; E407 pinned it with negative fixture 143). **The only general host → kernel channel** (the ringbuf is one-way kernel → host. Writing a map directly is \"updating a value\", not \"sending an event\", and has no FIFO order, spinel-ebpf ADR-002, issue 3). **It is not a program**: there is no SEC and no attach; it runs once per record inside the handler that called `user_ringbuf_drain`. ⇒ The context is **the draining program's**, and current-task reads (`has_cap` / `ns_id` / `in_host_ns`) are rejected here (their meaning depends on whether the drainer is XDP or a kprobe, which codegen cannot decide) — read the task in the draining handler. ⚠ **One callback per unit** (the drain names it by symbol, so a second one dies at compile time). ⚠ **A callback without a drain dies at compile time** — it is `static` with no caller, so clang drops the whole function, and the host could push any amount with nothing running (the opposite judgement from E412 making \"declare only targets\" legal; the reason is that **that one is a program and this one is not**). ⚠ **A record is a fixed 8 bytes** (`sp_bpf_user_cmd_push` is the sender). If you send a shorter record yourself, **it fires and the count is right, but the value is 0** (E414 measured). Kernel floor **6.1** (bpf_user_ringbuf_drain) = one of the few surfaces that raise the 5.2 base" },
      { kind: :timer,         method_prefix: "on :timer, every: N.<unit> (reactor form only, synthesized name spnl_timer__main)", sec: ATTACH_SCHEMA.fetch("timer")["sec"], ctx_type: "__u64 * (the arm prog only; the callback is (void *map, int *key, struct spnl_timer_value *v))", args_convention: "no declared param. **The interval is a compile-time constant** — an integer literal + unit such as `every: 5.seconds` / `500.ms` / `1000.ns`; neither an expression nor `param` (it is folded into bpf_timer_start)", context_note: "E079 / **ported to the C codegen in E411** (before that the C reactor table had no :timer and unknown kinds were skipped, so **the body never appeared in the output** — and the advertised SEC was \"syscall\" = the same string as the silent degradation, so an audit comparing only SECs saw it as ok). Three things are emitted: `spnl_timer_map` (ARRAY, 1 slot) / the SEC-less callback `spnl_timer_cb_main` (the handler body + re-arming itself) / `SEC(\"syscall\") spnl_timer_arm_main`, which the glue fires once at load with `bpf_prog_test_run` (E079's `_spnl_timer_arm_all`). ⚠ **One timer per unit** (the callback name is fixed, so a second one dies at compile time). ⚠ **The return value is ignored** — the verifier requires a literal `return 0` in the callback (remeasured on 7.1.5, E411). ⚠ **It is not process context**, so current-task reads such as `has_cap`/`pid` are rejected, and it cannot coexist with `filter_by` (both would point at \"the task on the CPU now\"). Kernel floor **5.15** (bpf_timer)" },
    ].freeze


    # =====================================================================
    # E409: map 語彙。**沈黙も affordance の欠陥である。**
    #
    # E406 (builtin) / E407 (attach kind) / E408 (surface sugar) は「宣伝して
    # いるのに動かない」= 嘘の監査だった。map は逆で、実装は健全なのに
    # **capabilities が 1 語も言っていなかった** (MAP 関連定数 0 個)。ADR-015 では
    # AI は affordance を読んで何を書いてよいか決めるので、map について何も無ければ
    # **容量・キー/値の形・per-CPU 意味論・どの surface がどの map を作るか**を
    # 推論できない。E393 が実測したとおり **ringbuf は溢れると黙って捨てる** —
    # 容量は「知らなくてよい性質」ではない。
    #
    # **監査の単位は map 型ではない。** 利用者は `BPF_MAP_TYPE_HASH` とは書かず、
    # `@x += 1` や `hist_observe(v)` と書く。だから 1 エントリ = **「どの surface が、
    # どの map を、どんな形で作るか」** の対応で、型はその属性でしかない
    # (E408 の教訓「全数監査は語彙をどう切るかに相対的」)。
    #
    # 表の中身は**生成物から機械的に導出**した (手書きの表は drift の元):
    # 各 surface の最小 probe と、その surface を抜いた双子を本番 codegen にかけ、
    # 差分に現れた宣言を属性ごと写した (docs/experiments/results/E409/census.rb)。
    # 散文 (role / when_full / note) だけが人間の追加で、それ以外は測定値である。
    #
    #   map          生成される symbol。<unit> は unit 名、<ivar>/<class>/<N> も置換
    #   type         BPF_MAP_TYPE_ を落とした型名
    #   declared_as  :maps          -- `SEC(".maps")` の宣言 (gate が属性まで照合)
    #                :struct_ops    -- `SEC(".struct_ops[.link]")`
    #                :rodata        -- `volatile const` グローバル (map を作るのは libbpf)
    #                :data_section  -- `private(A)` マクロ → `SEC(".data.A")`
    #                :libbpf_header -- include した libbpf ヘッダが持ち込む
    #                :maps 以外は **弱い tier**。gate は witness までしか見られないので
    #                `measured` (kernel 側で確かめた出典) を test が必須にする
    #   created_by   この map を作る surface 全部 (実測)
    #   probe        gate がコンパイルする代表 1 個 (created_by の要素)
    #   when_full    **溢れたときに何が起きるか**。ここが本 Edoc の主眼で、
    #                「黙って捨てる」「黙って古いのを追い出す」「戻り値で分かる」は
    #                AI にとって別の判断になる
    # =====================================================================
    MAPS = [
      { id: :arena,
        map: "<unit>_arena",
        type: "ARENA",
        declared_as: :maps,
        max_entries: "1",
        flags: "BPF_F_MMAPABLE",
        created_by: %w[arena_get arena_hash_del arena_hash_get arena_hash_set arena_list_push arena_list_sum arena_set],
        probe: "arena_get",
        probe_kind: :builtin,
        role: "bpf_arena shared memory (shared with userspace by mmap)",
        when_full: "**1 page = 512 __u64 slots**. The index is masked with `& 511`, so an out-of-range index **silently wraps** (and corrupts another slot)",
        note: "map_extra (the user mmap base) varies by arch (arm64 1<<32 / x86-64 1<<44), so the gate does not compare it",
        edoc: "E167", }.freeze,
      { id: :hist,
        map: "bpf_hist",
        type: "ARRAY",
        declared_as: :maps,
        max_entries: "64",
        key: "__u32",
        value: "__u64",
        created_by: %w[hist_observe hist_observe_by off_cpu_observe off_cpu_start],
        probe: "hist_observe",
        probe_kind: :builtin,
        role: "log2 histogram (64 buckets)",
        when_full: "an ARRAY, so it does not overflow. The log2 slot is clamped to 0..63 = huge values gather in the top bucket",
        edoc: "E082", }.freeze,
      { id: :hist_linear,
        map: "bpf_hist_lin",
        type: "ARRAY",
        declared_as: :maps,
        max_entries: "256",
        key: "__u32",
        value: "__u64",
        created_by: %w[hist_observe_linear],
        probe: "hist_observe_linear",
        probe_kind: :builtin,
        role: "linear histogram (256 slots; the caller buckets)",
        when_full: "an ARRAY, so it does not overflow. slot >= 256 is clamped to 255 (measured: hist_linear.template.c)",
        edoc: "E085", }.freeze,
      { id: :map_in_map_inner,
        map: "bpf_mim_inner<N>",
        type: "ARRAY",
        count: 4,
        declared_as: :maps,
        max_entries: "64",
        key: "__u32",
        value: "__s64",
        created_by: %w[mim_get mim_inc],
        probe: "mim_get",
        probe_kind: :builtin,
        role: "the inner maps of map-in-map (**4 of them**)",
        when_full: "an ARRAY, so it does not overflow",
        edoc: "E104", }.freeze,
      { id: :map_in_map_outer,
        map: "bpf_mim_outer",
        type: "ARRAY_OF_MAPS",
        declared_as: :maps,
        max_entries: "4",
        key: "__u32",
        values_of: "struct mim_inner_t",
        created_by: %w[mim_get mim_inc],
        probe: "mim_get",
        probe_kind: :builtin,
        role: "the outer map of map-in-map (libbpf populates the inner maps at load)",
        when_full: "fixed at index 4",
        edoc: "E104", }.freeze,
      { id: :user_ringbuf,
        map: "bpf_user_cmds",
        type: "USER_RINGBUF",
        declared_as: :maps,
        max_entries: "262144",
        created_by: %w[user_ringbuf user_ringbuf_drain],
        probe: "user_ringbuf",
        probe_kind: :attach,
        role: "the **host → kernel** command channel (the only general means in spinel-ebpf ADR-002, issue 3). Userspace writes it (libbpf's reserve/submit, the glue's `sp_bpf_user_cmd_push`), `user_ringbuf_drain` reads it, and 1 record = 1 call of `def user_ringbuf__<name>(value)`. **FIFO order is guaranteed** (a property that writing a HASH map directly lacks)",
        when_full: "**the push side fails** — `user_ring_buffer__reserve` returns NULL and the glue's `sp_bpf_user_cmd_push` **returns -5** (the opposite of the kernel ringbuf's \"silently drop\": the overflow is visible to the sender). But **the caller's Ruby is what looks at the return value**, so discarding the value of `M.sp_bpf_user_cmd_push(v)` gives the same silence. ⚠ max_entries is **a number of bytes** (a 256 KB ring), not a number of records. ⚠ **A record is a fixed 8 bytes**: if your own pusher sends a shorter record, the callback fires and the count grows, but `bpf_dynptr_read` returns -E2BIG and **only the value becomes 0** (E414 measured, `d1_recordsize.txt`)",
        note: "**neither of the two `created_by` alone compiles** — a unit with only the callback dies with \"nobody drains\", and a unit with only the drain dies with \"no callback to call\". ⇒ When this map appears, both are always present (in contrast with PROG_ARRAY, which makes one side alone legal)",
        edoc: "E061/E414", }.freeze,
      { id: :tcp_slice_conntab,
        map: "bpf_conntab",
        type: "LRU_HASH",
        declared_as: :maps,
        max_entries: "65536",
        key: "struct spnl_tcp_slice_key",
        value: "struct spnl_tcp_slice_state",
        created_by: %w[xdp_tcp_slice],
        probe: "xdp_tcp_slice",
        probe_kind: :attach,
        role: "the pure-XDP TCP slice's **connection table**. Per 4-tuple it holds the post-handshake seq/ack and the state (1=ESTABLISHED / 2=RESP_SENT / 3=CLOSED). **Userspace does not touch it** — the XDP program and the callback of the per-connection `bpf_timer` embedded in the value write and delete it (E057)",
        when_full: "**an LRU, so overflowing does not fail** — the oldest connection's entry is silently evicted. The next packet of an evicted connection is treated as unknown state: **a GET gets no reply and a FIN gets no FIN-ACK** (the client retransmits and eventually times out). 65536 is the limit on concurrent connections itself, so load beyond it shows as a lower success rate (not as an error)",
        note: "key = 4-tuple (saddr, daddr, sport, dport), value = server_seq / client_seq / mss / state / an embedded `struct bpf_timer`. E057's TTLs (ESTABLISHED 30s / RESP_SENT 30s / CLOSED 60s) delete entries automatically, so the steady-state occupancy is \"concurrent connections\", not \"total connections\"",
        edoc: "E052-E054/E057/E416", }.freeze,
      { id: :tcp_slice_counters,
        map: "bpf_ts_counters",
        type: "ARRAY",
        declared_as: :maps,
        max_entries: "17",
        key: "__u32",
        value: "__u64",
        created_by: %w[xdp_tcp_slice],
        probe: "xdp_tcp_slice",
        probe_kind: :attach,
        role: "the slice's **observation counters** (key = slot number) (SYN received / SYN-ACK sent / cookie verified / data reply / FIN / RST / DROP / PASS / ABORTED / timer fired …). The slot numbers are in the same order as E053's PoC. Read them with `bpftool map dump name bpf_ts_counters`",
        when_full: "**does not overflow** (an ARRAY with a fixed 17 slots; the index is a literal codegen emits). The counters themselves use `__sync_fetch_and_add`, so they miss nothing",
        note: "even for a probe that uses no spnl_emit*, this map lets you check from outside the state \"running, but nobody is watching\". Note that it does not drain a ringbuf, so it is outside the channel balance report (E386)",
        edoc: "E053/E054/E416", }.freeze,
      { id: :prog_array,
        map: "spnl_prog_array",
        type: "PROG_ARRAY",
        declared_as: :maps,
        max_entries: "32",
        key_size: "sizeof(__u32)",
        value_size: "sizeof(__u32)",
        created_by: %w[xdp_tail tail_call_to],
        probe: "xdp_tail",
        probe_kind: :attach,
        role: "the tail-call target table. slot i = the i-th `def xdp_tail__<name>` (**declaration order**). The values are prog fds, written by the loader (`_spnl_prog_array_populate`, E065) — neither the probe nor userspace code touches it",
        when_full: "**does not overflow** (max_entries is max(number of targets, 32), so the declared number always fits). The danger is the reverse: **`tail_call_to` on an empty slot returns no failure and silently does a fall through** (the caller continues from the next statement) ⇒ not \"jumped to another program\" but \"did not jump\" happens in a way that cannot be observed. An integer-literal slot is range-checked at compile time, but a computed slot cannot be",
        note: "the map appears **with either of the two `created_by`**: a unit with only targets is unreachable unless the loader populates it, and a unit that only jumps cannot compile without the map",
        edoc: "E063/E412", }.freeze,
      { id: :reuseport_sockarray,
        map: "bpf_worker_socks",
        type: "REUSEPORT_SOCKARRAY",
        declared_as: :maps,
        max_entries: "64",
        key: "__u32",
        value: "__u64",
        created_by: %w[worker_select],
        probe: "worker_select",
        probe_kind: :builtin,
        role: "the SO_REUSEPORT worker table. slot i = the listen socket of the worker that called `sp_bpf_reuseport_register(listen_fd, i)`. **The probe's own userspace writes it** (the glue provides an FFI that passes the map fd) — codegen does not know the number of workers",
        when_full: "**does not overflow** (max_entries fixed at 64; the author's indexes are below it). The danger is the reverse: **`worker_select` on an empty slot does not fail** — the helper returns -ENOENT, which is discarded, and the kernel **silently falls back to the default 5-tuple spread** ⇒ \"BPF chose\" and \"BPF did not choose\" cannot be told apart from the probe's output. If the number of registered workers < the N in `% N`, the SYNs for the difference quietly get the default selection",
        note: "in a unit that uses only `reuseport_hash`, **this map does not appear** — a prog that only reads the hash (dropping SYNs by hash and so on) does not index the table, so no table is made that is populated and read by nobody",
        edoc: "E043/E413", }.freeze,
      { id: :cpumap,
        map: "spnl_cpumap",
        type: "CPUMAP",
        declared_as: :maps,
        max_entries: "64",
        key_size: "sizeof(__u32)",
        value_size: "sizeof(struct bpf_cpumap_val)",
        created_by: %w[cpumap_redirect],
        probe: "cpumap_redirect",
        probe_kind: :builtin,
        role: "XDP's per-CPU fanout targets (userspace populates)",
        when_full: "cpumap_redirect to an unregistered index returns **flags=0 = XDP_ABORTED** (the value codegen passes)",
        edoc: "E066", }.freeze,
      { id: :devmap,
        map: "bpf_devmap",
        type: "DEVMAP",
        declared_as: :maps,
        max_entries: "64",
        key_size: "sizeof(__u32)",
        value_size: "sizeof(__u32)",
        created_by: %w[dev_redirect],
        probe: "dev_redirect",
        probe_kind: :builtin,
        role: "the netdevs XDP redirects to (userspace populates)",
        when_full: "the kernel side only refers by index. dev_redirect to an unregistered index returns **flags=0 = XDP_ABORTED** (the value codegen passes)",
        edoc: "E108", }.freeze,
      { id: :dns_recv_stash,
        map: "<unit>_dns_recv_stash",
        type: "HASH",
        declared_as: :maps,
        max_entries: "4096",
        key: "__u32",
        value: "struct <unit>_dns_recv_stash_st",
        created_by: %w[dns_emit dns_req_start dns_resp_stash],
        probe: "dns_emit",
        probe_kind: :builtin,
        role: "tid stash of the DNS response buffer",
        when_full: "even when full (-E2BIG) codegen does not look at update's return value (measured: all 22 sites) ⇒ **that one entry is silently not recorded**. The partner's later lookup finds nothing, and one span is simply missing",
        edoc: "E311", }.freeze,
      { id: :go_recv_stash,
        map: "<unit>_go_recv_stash",
        type: "HASH",
        declared_as: :maps,
        max_entries: "4096",
        key: "__u64",
        value: "struct <unit>_http_stash_st",
        created_by: %w[go_tls_emit go_tls_resp_stash],
        probe: "go_tls_emit",
        probe_kind: :builtin,
        role: "Go TLS receive stash (keyed by the goroutine's g pointer)",
        when_full: "even when full (-E2BIG) codegen does not look at update's return value (measured: all 22 sites) ⇒ **that one entry is silently not recorded**. The partner's later lookup finds nothing, and one span is simply missing",
        edoc: "E347", }.freeze,
      { id: :http_pending,
        map: "<unit>_http_pending",
        type: "HASH",
        declared_as: :maps,
        max_entries: "65536",
        key: "__u64",
        value: "struct <unit>_http_pending_st",
        created_by: %w[go_tls_emit go_tls_req go_tls_resp_stash go_tls_write http_emit http_req_start http_resp_stash ssl_emit ssl_req_start ssl_resp_stash],
        probe: "go_tls_emit",
        probe_kind: :builtin,
        role: "HTTP request correlation state (sock key)",
        when_full: "even when full (-E2BIG) codegen does not look at update's return value (measured: all 22 sites) ⇒ **that one entry is silently not recorded**. The partner's later lookup finds nothing, and one span is simply missing",
        edoc: "E298", }.freeze,
      { id: :http_recv_stash,
        map: "<unit>_http_recv_stash",
        type: "HASH",
        declared_as: :maps,
        max_entries: "4096",
        key: "__u32",
        value: "struct <unit>_http_stash_st",
        created_by: %w[go_tls_emit go_tls_req go_tls_resp_stash go_tls_write http_emit http_req_start http_resp_stash ssl_emit ssl_req_start ssl_resp_stash],
        probe: "go_tls_emit",
        probe_kind: :builtin,
        role: "tid stash of the receive buffer (the response exists only after the copy)",
        when_full: "even when full (-E2BIG) codegen does not look at update's return value (measured: all 22 sites) ⇒ **that one entry is silently not recorded**. The partner's later lookup finds nothing, and one span is simply missing",
        edoc: "E298", }.freeze,
      { id: :offcpu_stash,
        map: "<unit>_offcpu_stash",
        type: "HASH",
        declared_as: :maps,
        max_entries: "4096",
        key: "__u32",
        value: "struct <unit>_offcpu_stash_st",
        created_by: %w[offcpu_account offcpu_begin offcpu_emit offcpu_recv_stash],
        probe: "offcpu_account",
        probe_kind: :builtin,
        role: "off-CPU receive buffer stash (tid key)",
        when_full: "even when full (-E2BIG) codegen does not look at update's return value (measured: all 22 sites) ⇒ **that one entry is silently not recorded**. The partner's later lookup finds nothing, and one span is simply missing",
        edoc: "E300", }.freeze,
      { id: :offcpu_window,
        map: "<unit>_offcpu_win",
        type: "HASH",
        declared_as: :maps,
        max_entries: "4096",
        key: "__u32",
        value: "struct <unit>_offcpu_win",
        created_by: %w[offcpu_account offcpu_begin offcpu_emit offcpu_recv_stash],
        probe: "offcpu_account",
        probe_kind: :builtin,
        role: "off-CPU window (tid key)",
        when_full: "even when full (-E2BIG) codegen does not look at update's return value (measured: all 22 sites) ⇒ **that one entry is silently not recorded**. The partner's later lookup finds nothing, and one span is simply missing",
        edoc: "E300", }.freeze,
      { id: :redis_pending,
        map: "<unit>_redis_pending",
        type: "HASH",
        declared_as: :maps,
        max_entries: "65536",
        key: "__u64",
        value: "struct <unit>_redis_pending_st",
        created_by: %w[redis_emit redis_req_start redis_resp_stash],
        probe: "redis_emit",
        probe_kind: :builtin,
        role: "Redis request correlation state (sock key)",
        when_full: "even when full (-E2BIG) codegen does not look at update's return value (measured: all 22 sites) ⇒ **that one entry is silently not recorded**. The partner's later lookup finds nothing, and one span is simply missing",
        edoc: "E341", }.freeze,
      { id: :redis_recv_stash,
        map: "<unit>_redis_recv_stash",
        type: "HASH",
        declared_as: :maps,
        max_entries: "4096",
        key: "__u32",
        value: "struct <unit>_redis_stash_st",
        created_by: %w[redis_emit redis_req_start redis_resp_stash],
        probe: "redis_emit",
        probe_kind: :builtin,
        role: "tid stash of the Redis receive buffer",
        when_full: "even when full (-E2BIG) codegen does not look at update's return value (measured: all 22 sites) ⇒ **that one entry is silently not recorded**. The partner's later lookup finds nothing, and one span is simply missing",
        edoc: "E341", }.freeze,
      { id: :req_state,
        map: "<unit>_req_start",
        type: "HASH",
        declared_as: :maps,
        max_entries: "65536",
        key: "__u64",
        value: "struct <unit>_req_state",
        created_by: %w[emit_l7 req_start],
        probe: "emit_l7",
        probe_kind: :builtin,
        role: "the start time for send→recv correlation + a multiplexing guard (sock key)",
        when_full: "even when full (-E2BIG) codegen does not look at update's return value (measured: all 22 sites) ⇒ **that one entry is silently not recorded**. The partner's later lookup finds nothing, and one span is simply missing",
        edoc: "E297", }.freeze,
      { id: :sock_owner,
        map: "<unit>_sock_owner",
        type: "HASH",
        declared_as: :maps,
        max_entries: "65536",
        key: "__u64",
        value: "struct <unit>_sock_owner_info",
        created_by: %w[sock_owner_set],
        probe: "sock_owner_set",
        probe_kind: :builtin,
        role: "sock → {pid, comm} (restores the process lost in softirq)",
        when_full: "even when full (-E2BIG) codegen does not look at update's return value (measured: all 22 sites) ⇒ **that one entry is silently not recorded**. The partner's later lookup finds nothing, and one span is simply missing",
        edoc: "E296", }.freeze,
      { id: :top_ivar,
        map: "<unit>_top_<ivar>",
        type: "HASH",
        declared_as: :maps,
        max_entries: "1",
        key: "__u32",
        value: "__s64",
        created_by: %w[top_ivar],
        probe: "top_ivar",
        probe_kind: :syntax,
        role: "one map per top-level ivar",
        when_full: "fixed at 1 key, so it does not overflow",
        note: "the map name follows the ivar. <unit> is the unit name",
        edoc: "E022", }.freeze,
      { id: :leak_track,
        map: "bpf_allocs",
        type: "HASH",
        declared_as: :maps,
        max_entries: "262144",
        key: "__u64",
        value: "struct spnl_alloc_info",
        created_by: %w[leak_forget leak_record],
        probe: "leak_forget",
        probe_kind: :builtin,
        role: "tracking unfreed allocs (ptr → size+stack)",
        when_full: "even when full (-E2BIG) codegen does not look at update's return value (measured: all 22 sites) ⇒ **that one entry is silently not recorded**. The partner's later lookup finds nothing, and one span is simply missing",
        edoc: "E117", }.freeze,
      { id: :blocklist,
        map: "bpf_blocklist",
        type: "HASH",
        declared_as: :maps,
        max_entries: "8192",
        key: "__u32",
        value: "__u8",
        created_by: %w[blocklist_match],
        probe: "blocklist_match",
        probe_kind: :builtin,
        role: "exact-IP blocklist (userspace adds/deletes; the kernel only looks up)",
        when_full: "the kernel side only looks up, so it does not overflow. When full, **userspace's add fails**",
        edoc: "E038", }.freeze,
      { id: :depth,
        map: "bpf_depth",
        type: "HASH",
        declared_as: :maps,
        max_entries: "65536",
        key: "__u64",
        value: "__s64",
        created_by: %w[depth_dec depth_inc],
        probe: "depth_dec",
        probe_kind: :builtin,
        role: "recursion depth (--instrument depth-collapse)",
        when_full: "even when full (-E2BIG) codegen does not look at update's return value (measured: all 22 sites) ⇒ **that one entry is silently not recorded**. The partner's later lookup finds nothing, and one span is simply missing",
        edoc: "E249", }.freeze,
      { id: :hist_keyed,
        map: "bpf_hist_keyed",
        type: "HASH",
        declared_as: :maps,
        max_entries: "1024",
        key: "__u64",
        value: "struct spnl_hist_struct",
        created_by: %w[hist_observe_by off_cpu_observe off_cpu_start],
        probe: "hist_observe_by",
        probe_kind: :builtin,
        role: "a log2 histogram per key",
        when_full: "even when full (-E2BIG) codegen does not look at update's return value (measured: all 22 sites) ⇒ **that one entry is silently not recorded**. The partner's later lookup finds nothing, and one span is simply missing. Here **the distribution of every new key from the 1024th on is lost entirely**",
        edoc: "E085", }.freeze,
      { id: :keyed_latency,
        map: "bpf_keyed_lat",
        type: "HASH",
        declared_as: :maps,
        max_entries: "65536",
        key: "__u64",
        value: "__u64",
        created_by: %w[lat_end lat_start],
        probe: "lat_end",
        probe_kind: :builtin,
        role: "start time with any key for lat_start/lat_end",
        when_full: "even when full (-E2BIG) codegen does not look at update's return value (measured: all 22 sites) ⇒ **that one entry is silently not recorded**. The partner's later lookup finds nothing, and one span is simply missing",
        edoc: "E120", }.freeze,
      { id: :latency_starts,
        map: "bpf_lat_starts",
        type: "HASH",
        declared_as: :maps,
        max_entries: "10240",
        key: "__u32",
        value: "__u64",
        created_by: %w[latency_end latency_start],
        probe: "latency_end",
        probe_kind: :builtin,
        role: "start time keyed by tid for latency_start/end",
        when_full: "even when full (-E2BIG) codegen does not look at update's return value (measured: all 22 sites) ⇒ **that one entry is silently not recorded**. The partner's later lookup finds nothing, and one span is simply missing",
        edoc: "E083", }.freeze,
      { id: :lock_edges,
        map: "bpf_lock_edges",
        type: "HASH",
        declared_as: :maps,
        max_entries: "65536",
        key: "struct spnl_lock_edge",
        value: "__u64",
        created_by: %w[lock_edge],
        probe: "lock_edge",
        probe_kind: :builtin,
        role: "lock-acquisition-order edges (deadlock detection)",
        when_full: "even when full (-E2BIG) codegen does not look at update's return value (measured: all 22 sites) ⇒ **that one entry is silently not recorded**. The partner's later lookup finds nothing, and one span is simply missing",
        edoc: "E118", }.freeze,
      { id: :off_cpu,
        map: "bpf_off_cpu",
        type: "HASH",
        declared_as: :maps,
        max_entries: "10240",
        key: "__u32",
        value: "struct spnl_off_cpu_entry",
        created_by: %w[off_cpu_observe off_cpu_start],
        probe: "off_cpu_observe",
        probe_kind: :builtin,
        role: "off-CPU start time + stack id (pid key)",
        when_full: "even when full (-E2BIG) codegen does not look at update's return value (measured: all 22 sites) ⇒ **that one entry is silently not recorded**. The partner's later lookup finds nothing, and one span is simply missing",
        edoc: "E091", }.freeze,
      { id: :path_counter,
        map: "bpf_path_counts",
        type: "HASH",
        declared_as: :maps,
        max_entries: "128",
        key: "__u32",
        value: "__s64",
        created_by: %w[path_counter_inc],
        probe: "path_counter_inc",
        probe_kind: :builtin,
        role: "key→count of path_counter_inc",
        when_full: "even when full (-E2BIG) codegen does not look at update's return value (measured: all 22 sites) ⇒ **that one entry is silently not recorded**. The partner's later lookup finds nothing, and one span is simply missing. **There are only 128 keys**, so a wide key space (cgroup_id and so on) fills it early",
        edoc: "E039", }.freeze,
      { id: :class_ivar,
        map: "<class>_at_<ivar>",
        type: "HASH",
        declared_as: :maps,
        max_entries: "1",
        key: "__u32",
        value: "__s64",
        created_by: %w[class_ivar],
        probe: "class_ivar",
        probe_kind: :syntax,
        role: "one map per instance ivar of an eBPF class",
        when_full: "fixed at 1 key, so it does not overflow",
        note: "the map name is <class>_at_<ivar> (the class name is lowercased)",
        edoc: "E009", }.freeze,
      { id: :cidr_blocklist,
        map: "bpf_cidr_block",
        type: "LPM_TRIE",
        declared_as: :maps,
        max_entries: "8192",
        key: "struct spnl_cidr_key",
        value: "__u8",
        flags: "BPF_F_NO_PREALLOC",
        created_by: %w[cidr_blocklist_match],
        probe: "cidr_blocklist_match",
        probe_kind: :builtin,
        role: "CIDR blocklist (LPM longest-prefix match)",
        when_full: "as above (the kernel only looks up)",
        edoc: "E100", }.freeze,
      { id: :dns_pending,
        map: "<unit>_dns_pending",
        type: "LRU_HASH",
        declared_as: :maps,
        max_entries: "65536",
        key: "__u64",
        value: "__u64",
        created_by: %w[dns_emit dns_req_start dns_resp_stash],
        probe: "dns_emit",
        probe_kind: :builtin,
        role: "DNS query correlation state ((sock<<16|txid) key)",
        when_full: "does not fail when full — **it evicts the least recently used entry**. When the number of entries exceeds capacity, old in-flight correlation state silently disappears",
        edoc: "E311", }.freeze,
      { id: :conntrack,
        map: "spnl_flow_<unit>_conn",
        type: "LRU_HASH",
        declared_as: :maps,
        max_entries: "65536",
        key: "struct spnl_flow_<unit>_conn_k",
        value: "struct spnl_flow_<unit>_conn_v",
        created_by: %w[flow_del flow_get flow_set],
        probe: "flow_del",
        probe_kind: :builtin,
        role: "4-tuple conntrack (stateful L4 LB)",
        when_full: "does not fail when full — **it evicts the least recently used entry**. When the number of entries exceeds capacity, old in-flight correlation state silently disappears",
        edoc: "E168", }.freeze,
      { id: :ringbuf_lost,
        map: "<unit>_lost",
        type: "PERCPU_ARRAY",
        declared_as: :maps,
        max_entries: "1",
        key_size: "sizeof(__u32)",
        value_size: "sizeof(__u64)",
        per_cpu: true,
        created_by: %w[dns_emit emit_argv emit_comm emit_connect emit_dns emit_kfield_str emit_l7 emit_parent_path emit_path emit_tcp_payload emit_tcp_stream go_tls_emit go_tls_req go_tls_resp_stash go_tls_write http_emit http_req_start http_resp_stash offcpu_account offcpu_begin offcpu_emit offcpu_recv_stash redis_emit redis_req_start redis_resp_stash spnl_emit spnl_emit3 spnl_emit4 spnl_emit_pair spnl_emit_str ssl_emit ssl_req_start ssl_resp_stash],
        probe: "dns_emit",
        probe_kind: :builtin,
        role: "the number of records dropped because the ring was full (one for the whole unit)",
        when_full: "fixed at 1 slot",
        note: "**per-CPU**: userspace sums every CPU (the runtime does it). A unit total, not per channel",
        edoc: "E393", }.freeze,
      { id: :path_scratch,
        map: "<unit>_path_scratch",
        type: "PERCPU_ARRAY",
        declared_as: :maps,
        max_entries: "1",
        key: "__u32",
        value: "char[4096]",
        per_cpu: true,
        created_by: %w[path_contains path_starts_with],
        probe: "path_contains",
        probe_kind: :builtin,
        role: "bpf_d_path's 4096B scratch (it does not fit on the BPF stack)",
        when_full: "fixed at 1 slot",
        note: "per-CPU. The value is the helper's output buffer, read only by the same handler",
        edoc: "E332", }.freeze,
      { id: :hist_keyed_zero,
        map: "bpf_hist_keyed_zero",
        type: "PERCPU_ARRAY",
        declared_as: :maps,
        max_entries: "1",
        key: "__u32",
        value: "struct spnl_hist_struct",
        per_cpu: true,
        created_by: %w[hist_observe_by off_cpu_observe off_cpu_start],
        probe: "hist_observe_by",
        probe_kind: :builtin,
        role: "keyed hist's 512B zero template (it cannot be on the BPF stack, so it is in a map)",
        when_full: "fixed at 1 slot",
        note: "per-CPU, but **the value is never read** (an initialization template only), so no summing is needed",
        edoc: "E085", }.freeze,
      { id: :fifo,
        map: "bpf_fifo",
        type: "QUEUE",
        declared_as: :maps,
        max_entries: "1024",
        value: "__s64",
        created_by: %w[fifo_pop fifo_push],
        probe: "fifo_pop",
        probe_kind: :builtin,
        role: "QUEUE (FIFO)",
        when_full: "a push when full **returns -E2BIG as its return value** (that is what fifo_push returns). pop returns 0 when empty, so **it cannot be told from a stored 0**",
        edoc: "E107", }.freeze,
      { id: :conn_events,
        map: "<unit>_conn_events",
        type: "RINGBUF",
        declared_as: :maps,
        max_entries: "256 * 1024",
        created_by: %w[emit_connect],
        probe: "emit_connect",
        probe_kind: :builtin,
        role: "packed record channel: conn",
        when_full: "when the consumer falls behind, bpf_ringbuf_reserve returns NULL and **the record is dropped and <unit>_lost goes +1** (E393). At exit the runtime reports it with the fourth wording of the balance report (dropped by the kernel — ring full)",
        edoc: "E294", }.freeze,
      { id: :dns_events,
        map: "<unit>_dns_events",
        type: "RINGBUF",
        declared_as: :maps,
        max_entries: "256 * 1024",
        created_by: %w[dns_emit emit_dns],
        probe: "dns_emit",
        probe_kind: :builtin,
        role: "packed record channel: dns",
        when_full: "when the consumer falls behind, bpf_ringbuf_reserve returns NULL and **the record is dropped and <unit>_lost goes +1** (E393). At exit the runtime reports it with the fourth wording of the balance report (dropped by the kernel — ring full)",
        edoc: "E295", }.freeze,
      { id: :emit3_events,
        map: "<unit>_emit3_events",
        type: "RINGBUF",
        declared_as: :maps,
        max_entries: "256 * 1024",
        created_by: %w[spnl_emit3],
        probe: "spnl_emit3",
        probe_kind: :builtin,
        role: "spnl_emit3's channel",
        when_full: "when the consumer falls behind, bpf_ringbuf_reserve returns NULL and **the record is dropped and <unit>_lost goes +1** (E393). At exit the runtime reports it with the fourth wording of the balance report (dropped by the kernel — ring full)",
        edoc: "E080", }.freeze,
      { id: :emit4_events,
        map: "<unit>_emit4_events",
        type: "RINGBUF",
        declared_as: :maps,
        max_entries: "256 * 1024",
        created_by: %w[spnl_emit4],
        probe: "spnl_emit4",
        probe_kind: :builtin,
        role: "spnl_emit4's channel",
        when_full: "when the consumer falls behind, bpf_ringbuf_reserve returns NULL and **the record is dropped and <unit>_lost goes +1** (E393). At exit the runtime reports it with the fourth wording of the balance report (dropped by the kernel — ring full)",
        edoc: "E080", }.freeze,
      { id: :emit_events,
        map: "<unit>_events",
        type: "RINGBUF",
        declared_as: :maps,
        max_entries: "256 * 1024",
        created_by: %w[spnl_emit],
        probe: "spnl_emit",
        probe_kind: :builtin,
        role: "spnl_emit's int channel",
        when_full: "when the consumer falls behind, bpf_ringbuf_reserve returns NULL and **the record is dropped and <unit>_lost goes +1** (E393). At exit the runtime reports it with the fourth wording of the balance report (dropped by the kernel — ring full)",
        edoc: "E012", }.freeze,
      { id: :http_events,
        map: "<unit>_http_events",
        type: "RINGBUF",
        declared_as: :maps,
        max_entries: "256 * 1024",
        created_by: %w[go_tls_emit go_tls_req go_tls_resp_stash go_tls_write http_emit http_req_start http_resp_stash ssl_emit ssl_req_start ssl_resp_stash],
        probe: "go_tls_emit",
        probe_kind: :builtin,
        role: "packed record channel: http (shared by tcp / SSL plaintext / Go TLS)",
        when_full: "when the consumer falls behind, bpf_ringbuf_reserve returns NULL and **the record is dropped and <unit>_lost goes +1** (E393). At exit the runtime reports it with the fourth wording of the balance report (dropped by the kernel — ring full)",
        edoc: "E298", }.freeze,
      { id: :l7_events,
        map: "<unit>_l7_events",
        type: "RINGBUF",
        declared_as: :maps,
        max_entries: "256 * 1024",
        created_by: %w[emit_l7],
        probe: "emit_l7",
        probe_kind: :builtin,
        role: "packed record channel: l7",
        when_full: "when the consumer falls behind, bpf_ringbuf_reserve returns NULL and **the record is dropped and <unit>_lost goes +1** (E393). At exit the runtime reports it with the fourth wording of the balance report (dropped by the kernel — ring full)",
        edoc: "E297", }.freeze,
      { id: :l7stream_events,
        map: "<unit>_l7stream_events",
        type: "RINGBUF",
        declared_as: :maps,
        max_entries: "256 * 1024",
        created_by: %w[emit_tcp_stream],
        probe: "emit_tcp_stream",
        probe_kind: :builtin,
        role: "packed record channel: l7stream",
        when_full: "when the consumer falls behind, bpf_ringbuf_reserve returns NULL and **the record is dropped and <unit>_lost goes +1** (E393). At exit the runtime reports it with the fourth wording of the balance report (dropped by the kernel — ring full)",
        edoc: "E339", }.freeze,
      { id: :offcpu_events,
        map: "<unit>_offcpu_events",
        type: "RINGBUF",
        declared_as: :maps,
        max_entries: "256 * 1024",
        created_by: %w[offcpu_account offcpu_begin offcpu_emit offcpu_recv_stash],
        probe: "offcpu_account",
        probe_kind: :builtin,
        role: "packed record channel: offcpu",
        when_full: "when the consumer falls behind, bpf_ringbuf_reserve returns NULL and **the record is dropped and <unit>_lost goes +1** (E393). At exit the runtime reports it with the fourth wording of the balance report (dropped by the kernel — ring full)",
        edoc: "E300", }.freeze,
      { id: :emit_pair_events,
        map: "<unit>_pair_events",
        type: "RINGBUF",
        declared_as: :maps,
        max_entries: "256 * 1024",
        created_by: %w[spnl_emit_pair],
        probe: "spnl_emit_pair",
        probe_kind: :builtin,
        role: "spnl_emit_pair's channel",
        when_full: "when the consumer falls behind, bpf_ringbuf_reserve returns NULL and **the record is dropped and <unit>_lost goes +1** (E393). At exit the runtime reports it with the fourth wording of the balance report (dropped by the kernel — ring full)",
        edoc: "E025", }.freeze,
      { id: :redis_events,
        map: "<unit>_redis_events",
        type: "RINGBUF",
        declared_as: :maps,
        max_entries: "256 * 1024",
        created_by: %w[redis_emit redis_req_start redis_resp_stash],
        probe: "redis_emit",
        probe_kind: :builtin,
        role: "packed record channel: redis",
        when_full: "when the consumer falls behind, bpf_ringbuf_reserve returns NULL and **the record is dropped and <unit>_lost goes +1** (E393). At exit the runtime reports it with the fourth wording of the balance report (dropped by the kernel — ring full)",
        edoc: "E341", }.freeze,
      { id: :emit_str_events,
        map: "<unit>_str_events",
        type: "RINGBUF",
        declared_as: :maps,
        max_entries: "256 * 1024",
        created_by: %w[emit_argv emit_comm emit_kfield_str emit_parent_path emit_path emit_tcp_payload spnl_emit_str],
        probe: "emit_argv",
        probe_kind: :builtin,
        role: "string channel (shared by emit_comm/emit_path/emit_argv/...)",
        when_full: "when the consumer falls behind, bpf_ringbuf_reserve returns NULL and **the record is dropped and <unit>_lost goes +1** (E393). At exit the runtime reports it with the fourth wording of the balance report (dropped by the kernel — ring full)",
        edoc: "E021", }.freeze,
      { id: :lifo,
        map: "bpf_lifo",
        type: "STACK",
        declared_as: :maps,
        max_entries: "1024",
        value: "__s64",
        created_by: %w[lifo_pop lifo_push],
        probe: "lifo_pop",
        probe_kind: :builtin,
        role: "STACK (LIFO)",
        when_full: "a push when full **returns -E2BIG as its return value**. pop returns 0 when empty, so **it cannot be told from a stored 0**",
        edoc: "E107", }.freeze,
      { id: :stacks,
        map: "bpf_stacks",
        type: "STACK_TRACE",
        declared_as: :maps,
        max_entries: "16384",
        key_size: "sizeof(__u32)",
        value_size: "127 * sizeof(__u64)",
        created_by: %w[off_cpu_observe off_cpu_start offcpu_account stack_id user_stack_id],
        probe: "off_cpu_observe",
        probe_kind: :builtin,
        role: "stack traces (16384 × 127 frames)",
        when_full: "when full or on a hash collision bpf_get_stackid returns **a negative errno**. stack_id()/user_stack_id() return it to Ruby as it is, so **a negative value = not obtained**",
        edoc: "E088", }.freeze,
      { id: :task_storage,
        map: "bpf_task_store",
        type: "TASK_STORAGE",
        declared_as: :maps,
        max_entries: nil,
        key: "int",
        value: "__s64",
        flags: "BPF_F_NO_PREALLOC",
        created_by: %w[task_incr task_load task_store task_swap],
        probe: "task_incr",
        probe_kind: :builtin,
        role: "one scalar per task",
        when_full: "has no max_entries (allocated per task, freed automatically when the task ends). An allocation failure is NULL-checked and a no-op",
        edoc: "E103", }.freeze,
      { id: :xskmap,
        map: "bpf_xskmap",
        type: "XSKMAP",
        declared_as: :maps,
        max_entries: "64",
        key_size: "sizeof(__u32)",
        value_size: "sizeof(__u32)",
        created_by: %w[xsk_redirect],
        probe: "xsk_redirect",
        probe_kind: :builtin,
        role: "AF_XDP sockets (userspace populates)",
        when_full: "xsk_redirect to an unregistered index returns **flags=XDP_PASS** = the packet passes through (the value codegen passes; unlike dev/cpumap)",
        edoc: "E108", }.freeze,
      { id: :timer_slot,
        map: "spnl_timer_map",
        type: "ARRAY",
        declared_as: :maps,
        max_entries: "1",
        key: "__u32",
        value: "struct spnl_timer_value",
        created_by: %w[timer],
        probe: "timer",
        probe_kind: :attach,
        role: "the single bpf_timer of `on :timer` (one slot of an ARRAY; the value is `struct { struct bpf_timer t; }`)",
        when_full: "**there is no room to overflow** — one timer per unit, so there is always one slot, and a second `on :timer` dies at compile time. **The map name does not contain the unit name**, the only exception, inherited from E079; loading 2 units into one process makes the names collide " \
                   "(this tree's build is 1 binary per unit, so it does not show)",
        note: "**seeing this map from userspace is meaningless** — its content is the kernel's timer state, and reading the value does not tell the period. The period is a constant folded into bpf_timer_start in the generated C",
        edoc: "E079/E411", }.freeze,

      # --- ここから下は `SEC(".maps")` に現れない map ------------------------
      # 生成 C を読んでも map に見えないが、kernel には実在する (E409 が libbpf の
      # load 後 view で実測。docs/experiments/results/E409/loadmatrix.txt)。
      # `declared_as` が :maps 以外のエントリは **弱い tier**: gate は「その形の
      # witness が出たか」までしか見られず、容量や value_size は `measured` が出典。
      # 黙って弱められないよう、test が :maps 以外に `measured` を必須にする。
      { id: :struct_ops_tcp_cc,
        map: "spnl_tcp_cc_ops",
        type: "STRUCT_OPS",
        declared_as: :struct_ops,
        max_entries: nil,
        created_by: %w[tcp_cc],
        probe: "tcp_cc",
        probe_kind: :attach,
        role: "the map that registers a TCP CC written in Ruby with the kernel (one per program)",
        when_full: "no notion of capacity (one map)",
        note: "declared with `SEC(\".struct_ops\")`. That it is a map cannot be seen from the generated C",
        measured: "E409 loadmatrix: 114_tcp_cc_reno has one BPF_MAP_TYPE_STRUCT_OPS, fd obtained",
        edoc: "E067" }.freeze,
      { id: :struct_ops_sched_ext,
        map: "spnl_sched_ext_ops",
        type: "STRUCT_OPS",
        declared_as: :struct_ops,
        max_entries: nil,
        created_by: %w[sched_ext],
        probe: "sched_ext",
        probe_kind: :attach,
        role: "the map that registers a CPU scheduler (sched_ext_ops) written in Ruby",
        when_full: "no notion of capacity (one map)",
        note: "`SEC(\".struct_ops.link\")` (with a link, the loader owns the lifetime)",
        measured: "E409 loadmatrix: 53_scx_simple has one STRUCT_OPS",
        edoc: "E068/E094" }.freeze,
      { id: :struct_ops_qdisc,
        map: "spnl_qdisc_ops",
        type: "STRUCT_OPS",
        declared_as: :struct_ops,
        max_entries: nil,
        created_by: %w[qdisc],
        probe: "qdisc",
        probe_kind: :attach,
        role: "the map that registers a qdisc (Qdisc_ops) written in Ruby",
        when_full: "no notion of capacity (one map)",
        note: "`SEC(\".struct_ops.link\")`. Attached as spnl_qdisc through tc",
        measured: "E409 loadmatrix: 55_qdisc_fifo has one STRUCT_OPS",
        edoc: "E095" }.freeze,
      { id: :rodata,
        map: ".rodata",
        type: "ARRAY",
        declared_as: :rodata,
        max_entries: "1",
        created_by: %w[param filter_by],
        probe: "param",
        probe_kind: :syntax,
        role: "the values of param / filter_by. The loader writes them before load, and the kernel freezes them",
        when_full: "1 slot. value_size is the sum of the declared constants, so it is not a fixed value",
        note: "the generated C shows only `volatile const __s64 spnl_param_<name>` — **libbpf creates the map**. " \
              "So adding a `param` adds one map, though no code anywhere says map",
        measured: "E409 loadmatrix: in 126_runtime_param / 129_common_filter / 130_common_filter_all " \
                  "the .rodata ARRAY exists (value_size 16 / 24 / 56 = the sum of the declared constants)",
        edoc: "E392/E399" }.freeze,
      { id: :data_section,
        map: ".data.A",
        type: "ARRAY",
        declared_as: :data_section,
        max_entries: "1",
        created_by: %w[queue_push queue_pop],
        probe: "queue_push",
        probe_kind: :builtin,
        role: "the BPF qdisc's spin lock + list head (a private global holding bpf_list)",
        when_full: "1 slot (holds the list head and the lock)",
        note: "`private(A) …` expands to `SEC(\".data.A\")`. **It is a macro, so a string search of the generated C does not find it** — " \
              "E409's text scanner missed only this one, and it was found in the kernel-side view",
        measured: "E409 loadmatrix: 55_qdisc_fifo has a .data.A ARRAY (value_size 24)",
        edoc: "E096" }.freeze,
      { id: :usdt_specs,
        map: "__bpf_usdt_specs",
        type: "ARRAY",
        declared_as: :libbpf_header,
        max_entries: "256",
        created_by: %w[usdt],
        probe: "usdt",
        probe_kind: :attach,
        role: "libbpf's USDT spec table (how to extract arguments). Brought in by `#include <bpf/usdt.bpf.h>`",
        when_full: "256 USDT probes per program (libbpf's default BPF_USDT_MAX_SPEC_CNT)",
        note: "**writing one probe adds 3 maps** (specs / ip_to_spec_id / .kconfig). The generated C has no declaration of them",
        measured: "E409 loadmatrix: 39_usdt_basic and 3 others have an ARRAY of 256 entries × 208 B",
        edoc: "E081" }.freeze,
      { id: :usdt_ip_to_spec_id,
        map: "__bpf_usdt_ip_to_spec_id",
        type: "HASH",
        declared_as: :libbpf_header,
        max_entries: "1024",
        created_by: %w[usdt],
        probe: "usdt",
        probe_kind: :attach,
        role: "libbpf's USDT attach site (ip) → spec id",
        when_full: "1024 attach sites (libbpf's default BPF_USDT_MAX_IP_CNT)",
        note: "as above (from usdt.bpf.h)",
        measured: "E409 loadmatrix: 39_usdt_basic and others have a HASH of 1024 entries",
        edoc: "E081" }.freeze,
      { id: :usdt_kconfig,
        map: ".kconfig",
        type: "ARRAY",
        declared_as: :libbpf_header,
        max_entries: "1",
        created_by: %w[usdt],
        probe: "usdt",
        probe_kind: :attach,
        role: "the kconfig extern usdt.bpf.h refers to (whether bpf_cookie exists)",
        when_full: "1 slot",
        note: "as above (from usdt.bpf.h)",
        measured: "E409 loadmatrix: 39_usdt_basic and others have an ARRAY of 1 entry × 1 B",
        edoc: "E081" }.freeze,
    ].freeze

    # 退役した Ruby oracle (codegen_bpf.rb) は 18 種の map を宣言していたが、
    # 本番 C codegen は 15 種しか出さない。差の 3 種は **E406/E407 で降ろした
    # surface が連れて行った** もので、単独で復活させても使い道が無い。
    # gate はこの 3 種が sweep のどこにも現れないことを毎回確かめる
    # (= 「相方だけ移植して map だけ戻す」半端な復活の検出)。
    WITHDRAWN_MAPS = {
      # "PROG_ARRAY" は E409 でここに入り **E412 (P011 A3) で戻した** — 飛び先
      # (xdp_tail) も呼び出し側 (tail_call_to) も同時に移植したので、E409 の
      # 降格理由「map だけあっても書きようがない」が消えた。
      # "USER_RINGBUF" は E409 でここに入り **E414 (P011 A5) で戻した** — callback
      # (SEC 無しの user_ringbuf__*) と drain の両方を同時に移植し、送り手
      # (`sp_bpf_user_cmd_push`) を新たに書いたので、E409 の降格理由
      # 「両方降ろされているので map だけあっても書きようがない」が消えた。
      # これで本表は**空**になる。**空のまま**が正解で、ゲートを armed に保つために
      # 何かを残すことはしない — 不在の検出は self-check の仕事だと決めたのが E415。
      # "REUSEPORT_SOCKARRAY" は E409 でここに入り **E413 (P011 A4) で戻した** —
      # 選ぶ builtin (worker_select) を同時に移植したので、E409 の降格理由
      # 「選ぶ手段が無いので表だけあっても書きようがない」が消えた。
    }.freeze

    # Ruby サブセット (書ける/書けない)。rejected は partition の loud-failure
    # (即エラー) を写像 — flag 名は partition.rb の MethodFlags と一致 (test が守る)。
    RUBY_SUBSET = {
      # **⚠ この 14 行は人間向けの要約であって正本ではない (E426)。**
      # 正本は `Capabilities::SYNTAX` (1 主張 = 1 構文 + `lowers_to` + twin) で、
      # tools/affordance_gate.rb --section syntax が毎回実測する。
      # 散文が正本だった間に **2 つの構文が死んだまま宣伝され続けた** —
      # 5 行目の「literal N は open-coded」(E426 S0) と 3 行目の「(式値も)」
      # = `x = if ... end` (E426 S1)。どちらも行の**一部**が真だったので、
      # 行の代表例をコンパイルする程度の検査では絶対に落ちない。
      supported: [
        "Integer literals / arithmetic (+ - * / %) / comparison (== != < > <= >=)",
        "underscore separators in Integer literals (5_000_000 == 5000000, readability only, the value is unchanged) (E320/E319 GAP-4)",
        "if / elsif / else (also as a value) / boolean short-circuit (|| &&) / bitwise (& | ^ << >>) / parentheses",
        "local variables / method definitions, arguments, return values / BPF-to-BPF calls",
        "n.times { |i| ... } (closure capture included; a literal N is open-coded, a dynamic N uses bpf_loop)",
        "instance variables (int) / top-level ivar → per-unit HASH map (@x += n / @x = n)",
        "attach: def <prefix>__<name> (kprobe/tracepoint/xdp/tc/lsm/fmod_ret/... the attach_kinds above)",
        "an attach handler declares 0..N arguments — unused kernel function arguments may be omitted (a 0-argument kprobe is legal too), and the declared ones map by position onto args_convention (PT_REGS_PARM<N>/ctx[i]) (E320/E319 GAP-3)",
        "class inheritance (class C < BPF::XDP) / module + include (BPF::TcpCC) / reactor DSL (include BPF::EventLoop; on :kind). " \
        "The 9 BPF DSL parents × both class/module forms and the 14 reactor kinds are byte-identical to the flat def <prefix><member> " \
        "(measured and gated in E408; before that, 15 of 18 surfaces silently degraded to SEC(\"syscall\"))",
        "module-style constants (XDP::PASS / IP::Proto::TCP and so on) + integer resolution of KNOWN_CONSTANTS (8 path prefixes, the same integers as the flat names)",
        "builtin calls (the builtins registry above; flat names as they are. The count is summary.builtin_count)",
        "comparison with fixed (compile-time) String literals (path_eq / path_starts_with / kfield_str_eq and so on)",
        "kernel field reads with kfield/kptr + dot accessors (sk.snd_cwnd / t = kptr(...); t.field)",
        "pkt.* chain accessors (pkt.l4.proto / pkt.len and so on, E071) — the same 15 as the flat pkt_* readers. " \
        "E407 measured them dead in the production C codegen (no fixture used the chain form, and with text-comparison goldens " \
        "\"a comparison never made cannot fail\", so they were advertised for a year) → **ported in E408**. " \
        "Only the one-argument form `pkt.byte_at(off)` forwards to `pkt_dynptr_byte_at` instead of a reader (XDP only, run-time offset). " \
        "E406 demoted its target, so it was once withdrawn_sugar, but **E410 brought both back** (the 2 spellings are byte-identical, gated)",
        "⚠ every \"alternative spelling\" above appears machine-readably in surface_sugar as **a claim of equivalence** " \
        "(being prose only was the cause of the drift before E408). tools/affordance_gate.rb --section sugar " \
        "measures every time whether \"the 2 spellings become the same C\"",
        "binary-safe FFI (:binstr, NUL-safe) — WebSocket and the like in Ruby",
      ].freeze,
      # 各 flag は partition.rb MethodFlags の impossible flag に対応 (loud failure = 即エラー)。
      #
      # **E426 (D3): 「対応している」は主張であって測定ではなかった。**
      # 10 flag を全部 attach ハンドラに入れて製品 (`bin/spinel-ebpf compile`) に
      # 通したところ **`uses_bignum` だけが exit 0** で、しかも生成 C には
      # `9223372036854775807` が焼かれていた (= 書いた 30 桁が **黙って別の値**に
      # なる)。原因は 2 つ重なっていた: (1) partition が `"bignum"` という文字列を
      # 探していたが **spinel の型名は `bigint`** (`src/types.c`) ⇒ 代入サイトが
      # 到達不能、(2) 判定していたのは signature だけで **local の型を誰も見て
      # いなかった**。しかも >64bit リテラルは spinel のフロントエンドが AST を
      # 書く前に INT64_MAX へ丸めるので、**残っているのは推論された型だけ**である。
      # E426 で両方修正 (partition の `refine_flags_from_locals`)。
      #
      # 以下の `probe` / `refusal` は **gate が読む機械可読な期待値** である
      # (E406 以来の規約: 期待値は affordance が持ち、gate は書かない)。
      # `probe` は attach ハンドラの中に構文を置いた最小の probe —
      # **attach ハンドラには native 実行経路が無い**ので、そこに置いたときだけ
      # 「native に落とす」が「loud に落ちる」と同義になる。
      rejected: [
        { flag: :uses_float, construct: "Float arithmetic", reason: "no FPU in BPF",
          probe: "def kprobe__do_sys_openat2(a)\n  n = 1.5\n  0\nend\n",
          refusal: "uses Float arithmetic" },
        { flag: :uses_regex, construct: "regular expressions", reason: "no regex helper in BPF",
          probe: "def kprobe__do_sys_openat2(a)\n  n = (\"x\" =~ /y/)\n  0\nend\n",
          refusal: "uses regex" },
        { flag: :uses_io, construct: "any I/O", reason: "host side only",
          probe: "def kprobe__do_sys_openat2(a)\n  puts a\n  0\nend\n",
          refusal: "performs I/O" },
        { flag: :uses_thread, construct: "creating a Thread", reason: "the kernel cannot create threads",
          probe: "def kprobe__do_sys_openat2(a)\n  t = Thread.new { 1 }\n  0\nend\n",
          refusal: "creates Thread" },
        { flag: :uses_fiber, construct: "Fiber", reason: "BPF has no notion of fibers",
          probe: "def kprobe__do_sys_openat2(a)\n  f = Fiber.new { 1 }\n  0\nend\n",
          refusal: "uses Fiber" },
        { flag: :uses_closure, construct: "unsupported closures (capturing outer variables)", reason: "general closures other than n.times",
          probe: "def kprobe__do_sys_openat2(a)\n  f = ->(x) { x }\n  0\nend\n",
          refusal: "uses closure",
          note: "**the layer changes with the spelling (E426 measured)**: `->(x){}` is a LambdaNode, so this flag is set, but " \
                "`lambda { |x| x }` is a **CallNode**, so the partition passes it and codegen " \
                "fails with `CallNode not yet ported (Stage 1): lambda`. Both are loud, but " \
                "**this flag catches only the former**" },
        { flag: :uses_recursion, construct: "recursive calls", reason: "the BPF call graph is a DAG",
          probe: "def kprobe__do_sys_openat2(a)\n  n = rec(a)\n  0\nend\n\n" \
                 "def rec(x)\n  if x > 0\n    rec(x - 1)\n  else\n    0\n  end\nend\n",
          refusal: "recursiv" },
        { flag: :uses_bignum, construct: "bignum", reason: "BPF integers top out at 64 bits",
          probe: "def kprobe__do_sys_openat2(a)\n  n = 123456789012345678901234567890\n  0\nend\n",
          refusal: "uses bignum",
          note: "**the only flag that exited 0 until E426**. For a >64-bit literal spinel rounds to " \
                "INT64_MAX before writing the AST, so a different value was burned into the generated C" },
        { flag: :uses_unbounded_loop, construct: "unbounded loops", reason: "the verifier requires a loop bound",
          probe: "def kprobe__do_sys_openat2(a)\n  x = 0\n  while x < 3\n    x = x + 1\n  end\n  0\nend\n",
          refusal: "without static upper bound" },
        { flag: :uses_unsupported_type, construct: "non-int type signatures (string/array/hash/...)",
          reason: "only int types are eBPF-eligible",
          probe: "def kprobe__do_sys_openat2(a)\n  \"str\"\nend\n",
          refusal: "non-int type" },
      ].freeze,
      note: "a partition failure is an immediate error (no silent fallback, ADR-003). inherits_unsupported propagates to methods that call the above.",
    }.freeze

    # =====================================================================
    # E408: surface sugar — 代替の綴りと、その flat な等価物。
    #
    # RUBY_SUBSET[:supported] は **14 個の散文文字列**である。散文は gate に
    # かけられない。`pkt.l4.proto` が ADR-011 Stage 2 の C 移植で死んでから
    # 1 年間「対応」と宣伝され続けられたのは、まさにこれが理由だった
    # (E407 が実測)。E406 の builtin は `example_for` を、E407 の attach kind は
    # `sec:` を **機械可読な期待値として自分で持っていた**。sugar は持っていなかった。
    #
    # ここに書く 1 エントリは **等価性の主張** である: 2 つの綴りが同じ C に
    # 到達しなければならない。E070/E071/E072/E073/E074 はいずれも自分の Edoc で
    # 「生成 .bpf.c は **byte-identical**」と書いている。これは「コンパイルが
    # 通る」より強く、かつ有用な基準で、「**sugar は通るが別のものに lower される**」
    # という沈黙する誤り (E394/E395 で繰り返し出た class) まで捕まえる。
    #
    #   form   :expr    sugar/flat は**式**。harness が shape の最小 handler の中に
    #                   `n = <it>` として書く
    #          :stmt    ...**文**。そのまま挿入する
    #          :attach  ...`<BODY>` を含む**probe 断片全体** (class/module/reactor の
    #                   表面は「式」ではなく「ファイルの形」なので)
    #   equiv  :identical  2 つは byte-identical な C を出さなければならない
    #          :compiles   両方通ればよい。C が正当に違う場合のみ (理由を note に
    #                      **必ず**書く。暗黙に落とさない)
    #
    # 派生している族 (pkt.* chain / 定数パス / DSL 親 / reactor kind) は
    # **実装と同じ規則から導出**する。族にメンバを足せば主張が増え、gate の
    # 要求も自動で増える (E407 の「期待値は gate に書かない」と同じ設計)。

    # E071: `pkt.<a>[.<b>]` は `pkt_<a>[_<b>]` と同じ reader。flat 名の一覧を
    # 権威にしているので、chain 側だけが知っている reader は存在し得ない。
    SUGAR_PKT_CHAIN = %w[
      pkt.len pkt.eth.proto
      pkt.l4.proto pkt.l4.sport pkt.l4.dport pkt.l4.payload_len
      pkt.ip4.src pkt.ip4.dst
      pkt.ip6.src_hi pkt.ip6.src_lo pkt.ip6.dst_hi pkt.ip6.dst_lo
      pkt.tcp.flags pkt.tcp.seq pkt.tcp.ack
    ].freeze

    # E072: module-style 定数。8 個の path prefix → flat prefix (codegen の
    # cc_const_path_value と同じ表)。代表を 1 個ずつ載せる — 個々の定数値の
    # 全数監査は別 Edoc (E408 スコープ外)、ここで守るのは**解決規則**の方。
    SUGAR_CONST_PATHS = {
      "XDP::PASS"                => { flat: "XDP_PASS",                shape: :xdp },
      "IP::Proto::TCP"           => { flat: "IPPROTO_TCP",             shape: :xdp },
      "Eth::P::IP"               => { flat: "ETH_P_IP",                shape: :xdp },
      "TCP::Flag::RST"           => { flat: "TCP_FLAG_RST",            shape: :xdp },
      "TC::Act::SHOT"            => { flat: "TC_ACT_SHOT",             shape: :tc_ingress },
      "SK::PASS"                 => { flat: "SK_PASS",                 shape: :sk_reuseport },
      "TCP::State::ESTABLISHED"  => { flat: "TCP_STATE_ESTABLISHED",   shape: :kprobe },
      "BPF::SockOps::STATE_CB"   => { flat: "BPF_SOCK_OPS_STATE_CB",   shape: :sock_ops },
    }.freeze

    # E073 (class 継承) / E074 (module + include)。どちらも「この module/class の
    # メソッドは全部この attach kind」という宣言で、flat な `def <prefix><member>`
    # と等価。struct_ops の 3 種 (TcpCC/SchedExt/Qdisc) も同じ規則で並んでいる。
    SUGAR_DSL_PARENTS = {
      "BPF::XDP"         => { prefix: "xdp__",          member: "probe",      params: [],                    ret: "XDP_PASS" },
      "BPF::SockOps"     => { prefix: "sock_ops__",     member: "probe",      params: [],                    ret: "0" },
      "BPF::TcIngress"   => { prefix: "tc__ingress__",  member: "probe",      params: [],                    ret: "TC_ACT_OK" },
      "BPF::TcEgress"    => { prefix: "tc__egress__",   member: "probe",      params: [],                    ret: "TC_ACT_OK" },
      "BPF::SkReuseport" => { prefix: "sk_reuseport__", member: "probe",      params: [],                    ret: "SK_PASS" },
      "BPF::SkMsg"       => { prefix: "sk_msg__",       member: "probe",      params: [],                    ret: "SK_PASS" },
      "BPF::TcpCC"       => { prefix: "tcp_cc__",       member: "cong_avoid", params: %w[sk ack acked],      ret: "0" },
      "BPF::SchedExt"    => { prefix: "sched_ext__",    member: "dispatch",   params: %w[cpu prev],          ret: "0" },
      "BPF::Qdisc"       => { prefix: "qdisc__",        member: "enqueue",    params: %w[skb sch to_free],   ret: "0" },
    }.freeze

    # E076-E090: reactor DSL。`on :<kind>[, targets]` は flat な
    # `def <prefix><target>` と等価 (合成される method 名がまさにそれ)。
    # uprobe/uretprobe/go_uret/usdt は target を method 名に入れられないので
    # `<prefix><N>` (宣言順) を合成する — flat 側もその名前で書けば等価。
    # `:timer` は reactor 形しか無いので (interval が keyword で来る) ここに無い。
    SUGAR_REACTOR = [
      { on: "on :xdp",                                          flat: "xdp__main",          params: [], ret: "XDP_PASS" },
      { on: "on :sock_ops",                                     flat: "sock_ops__main",     params: [], ret: "0" },
      { on: "on :tc_ingress",                                   flat: "tc__ingress__main",  params: [], ret: "TC_ACT_OK" },
      { on: "on :tc_egress",                                    flat: "tc__egress__main",   params: [], ret: "TC_ACT_OK" },
      { on: 'on :kprobe, "do_sys_openat2"',                     flat: "kprobe__do_sys_openat2",    params: [],       ret: "0" },
      { on: 'on :kretprobe, "do_sys_openat2"',                  flat: "kretprobe__do_sys_openat2", params: %w[ret],  ret: "0" },
      { on: 'on :fentry, "tcp_v4_rcv"',                         flat: "fentry__tcp_v4_rcv",        params: %w[skb],  ret: "0" },
      { on: 'on :fexit, "tcp_v4_rcv"',                          flat: "fexit__tcp_v4_rcv",         params: %w[skb ret], ret: "0" },
      { on: 'on :tracepoint, "syscalls", "sys_enter_openat"',   flat: "tracepoint__syscalls__sys_enter_openat", params: %w[dfd], ret: "0" },
      { on: 'on :uprobe, "/usr/bin/bash:readline"',             flat: "uprobe__react0",     params: [], ret: "0" },
      { on: 'on :uretprobe, "/usr/bin/bash:readline"',          flat: "uretprobe__react0",  params: %w[ret], ret: "0" },
      { on: 'on :go_uret, "/usr/bin/app:main.handle"',          flat: "uprobe__react0",     params: %w[ret], ret: "0" },
      { on: 'on :usdt, "/usr/lib/libfoo.so", "libfoo", "throw"', flat: "usdt__react__0",    params: %w[obj], ret: "0" },
      { on: "on :perf_event, hz: 99",                           flat: "perf_event__main",   params: [], ret: "0" },
      # E061/E078/E414: the one reactor kind whose handler is NOT a program, so it
      # cannot stand alone -- a USER_RINGBUF callback with no `user_ringbuf_drain`
      # is refused at compile time (a `static` function with no caller; the host
      # could push forever with nothing on the other end). The companion below is
      # therefore part of the CLAIM, not scaffolding the gate invented: both
      # spellings carry the same drain site, and the two must still reach the same
      # C. It doubles as evidence that `on :xdp` and `def xdp__main` agree in the
      # same unit -- which is the equivalence the row above already asserts.
      { on: "on :user_cmd",                                     flat: "user_ringbuf__cmd_handler", params: %w[cmd], ret: "0",
        companion_sugar: "\n\n  on :xdp do\n    user_ringbuf_drain\n    XDP_PASS\n  end",
        companion_flat:  "\n\ndef xdp__main\n  user_ringbuf_drain\n  XDP_PASS\nend" },
    ].freeze

    # 上の族に載らない単発の sugar。
    SUGAR_SINGLES = [
      { id: :int_underscore, edoc: "E320", family: "underscore separators in Integer literals",
        form: :expr, shape: :kprobe, equiv: :identical,
        sugar: "5_000_000", flat: "5000000",
        note: "readability only. The whole claim is that neither the value nor the generated C changes" },
      { id: :dot_read, edoc: "E070", family: "receiver dot accessor (tcp_cc)",
        form: :expr, shape: :tcp_cc, equiv: :identical,
        sugar: "sk.snd_cwnd", flat: "tcp_sock_snd_cwnd(sk)",
        note: "a direct deref of the trusted `sk` in tcp_cc context. The gate is the method-name prefix + a fixed field table; it does not look at the receiver" },
      { id: :dot_write, edoc: "E070", family: "receiver dot accessor (tcp_cc)",
        form: :stmt, shape: :tcp_cc, equiv: :identical,
        sugar: "sk.snd_cwnd = 10", flat: "tcp_sock_snd_cwnd_set(sk, 10)" },
      { id: :dot_add, edoc: "E070", family: "receiver dot accessor (tcp_cc)",
        form: :stmt, shape: :tcp_cc, equiv: :identical,
        sugar: "sk.snd_cwnd += 1", flat: "tcp_sock_snd_cwnd_add(sk, 1)" },
      # E060/E071/E410: the one pkt.* chain member that is NOT in SUGAR_PKT_CHAIN,
      # because that family is derived by `s.tr(".", "_")` and this one's flat
      # spelling is a different word (`pkt_dynptr_byte_at`, not `pkt_byte_at`) and
      # takes an argument. It is still the same claim: two spellings, one C.
      # It was the sole WITHDRAWN_SUGAR entry until E410 re-ported the builtin.
      { id: :pkt_chain_pkt_byte_at, edoc: "E060/E071/E410", family: "pkt.* chain accessor",
        form: :expr, shape: :xdp, equiv: :identical,
        sugar: "pkt.byte_at(14)", flat: "pkt_dynptr_byte_at(14)",
        note: "the chain's only one-argument member. Its flat name is not `pkt_byte_at`, so it is not covered by SUGAR_PKT_CHAIN's " \
              "mechanical derivation (dot → underscore) and sits here on its own" },
      # E011/E426: two alternative spellings of `if` that E426 measured to be
      # byte-identical to the canonical block form. They are claimed HERE and not
      # in Capabilities::SYNTAX on purpose: node-type coverage (E426 D2) cannot
      # tell them apart from `if ... end` -- prism gives all three the same
      # IfNode -- so the only statement worth making about them is the pair
      # equivalence, which is E408's criterion and is stronger.
      { id: :ternary, edoc: "E011/E426", family: "another spelling of if",
        form: :expr, shape: :kprobe_arg, equiv: :identical,
        sugar: "a > 1 ? 1 : 2", flat: "if a > 1\n    1\n  else\n    2\n  end",
        note: "ternary is an IfNode too. It came alive together when E426 ported the IfNode **in expression position** " \
              "(before that, `x = if ... end` failed as a whole)" },
      { id: :postfix_if, edoc: "E011", family: "another spelling of if",
        form: :stmt, shape: :kprobe_arg, equiv: :identical,
        sugar: "@h = @h + 1 if a > 1", flat: "if a > 1\n    @h = @h + 1\n  end" },
      { id: :kptr_dot, edoc: "E099", family: "kptr binding + dot accessor",
        form: :stmt, shape: :kprobe_sk, equiv: :compiles,
        sugar: "t = kptr(sk, \"sock\")\n  n = t.sk_sndbuf",
        flat: "n = kfield(sk, \"sock\", \"sk_sndbuf\")",
        note: "**not identical (measured)**: the sugar side keeps the declaration of local `t` and `t = ((__s64)(sk))` " \
              "(the binding is a compile-time one, but the local itself is real). The read expression itself is the same BPF_CORE_READ. " \
              "So for this one entry `diverged` cannot be detected — only that both pass can be said" },
    ].freeze

    # 降ろした sugar。**gate の negative control**でもある (E406/E407 と同じ設計:
    # 「宣伝は全部通る」だけの gate は退化しても永久に緑)。
    #
    # **E410 で中身が入れ替わった**。それまでの唯一のエントリは `pkt.byte_at(off)` で、
    # E410 がそれを戻したので集合が空になり — gate が「sugar 半分に不在の対照が無い」と
    # abort した (E410 が予期していなかった構造的な結合。**巻き戻しは negative control を
    # 消費する**)。代わりに置いたのは `on :user_cmd` = **降格済 attach kind の reactor 綴り**で、
    # これは E407 が flat 側 (`def user_ringbuf__<name>`、負 fixture 143) しか固定していなかった
    # 面。sugar 半分の対照が「不在をまだ検出できるか」であることは変わらず、覆う面は増える。
    # **E414 でこの表は空になった**。E410 が `pkt.byte_at` を戻したときに入れた
    # `on :user_cmd` を、A5 (E414) がまさに移植したためである — 巻き戻しが
    # negative control を消費する構造は変わっていないが、**E415 以降その消費は
    # 問題ではない**: sugar 節の不在検出は合成された self-check
    # (`pkt.zz_e415_absent` → refused / mismatched pair → diverged) が持っており、
    # この表が語るのは在庫だけなので **空なら空が正解**。
    # ゲートは注記を 1 行出して exit 0 する (abort しない)。
    WITHDRAWN_SUGAR = {}.freeze

    # 上の族と単発を 1 本のリストに畳む。gate と audit はこれだけを読む。
    def surface_sugar
      out = []
      SUGAR_PKT_CHAIN.each do |s|
        out << { id: :"pkt_chain_#{s.tr('.', '_')}", edoc: "E071", family: "pkt.* chain accessor",
                 form: :expr, shape: :xdp, equiv: :identical, sugar: s, flat: s.tr(".", "_") }
      end
      SUGAR_CONST_PATHS.each do |path, info|
        out << { id: :"const_path_#{info[:flat].downcase}", edoc: "E072", family: "module-style constants",
                 form: :expr, shape: info[:shape], equiv: :identical, sugar: path, flat: info[:flat] }
      end
      SUGAR_DSL_PARENTS.each do |parent, i|
        sig = i[:params].empty? ? "" : "(#{i[:params].join(', ')})"
        out << { id: :"attach_class_#{i[:prefix].chomp('__').tr('_', '')}", edoc: "E073",
                 family: "class inheritance", form: :attach, equiv: :identical,
                 sugar: "class ProbeK < #{parent}\n  def #{i[:member]}#{sig}\n<BODY>\n  end\nend",
                 flat:  "def #{i[:prefix]}#{i[:member]}#{sig}\n<BODY>\nend", ret: i[:ret] }
        out << { id: :"attach_module_#{i[:prefix].chomp('__').tr('_', '')}", edoc: "E074",
                 family: "module + include", form: :attach, equiv: :identical,
                 sugar: "module ProbeK\n  include #{parent}\n\n  def #{i[:member]}#{sig}\n<BODY>\n  end\nend",
                 flat:  "def #{i[:prefix]}#{i[:member]}#{sig}\n<BODY>\nend", ret: i[:ret] }
      end
      SUGAR_REACTOR.each do |r|
        blk = r[:params].empty? ? "" : " |#{r[:params].join(', ')}|"
        sig = r[:params].empty? ? "" : "(#{r[:params].join(', ')})"
        kind = r[:on][/on :([a-z_]+)/, 1]
        # `companion_*` (E414): a handler that cannot legally stand alone brings
        # its partner along in BOTH spellings. Empty for every other kind.
        out << { id: :"reactor_#{kind}", edoc: "E076-E090", family: "reactor DSL (on :kind)",
                 form: :attach, equiv: :identical,
                 sugar: "module ProbeK\n  include BPF::EventLoop\n\n  #{r[:on]} do#{blk}\n<BODY>\n  end#{r[:companion_sugar]}\nend",
                 flat:  "def #{r[:flat]}#{sig}\n<BODY>\nend#{r[:companion_flat]}", ret: r[:ret] }
      end
      (out + SUGAR_SINGLES).freeze
    end

    # =====================================================================
    # E426: 構文語彙 — 5 つ目の語彙。**`RUBY_SUBSET[:supported]` の散文 14 行が正本だった。**
    #
    # E408 は「散文は gate にかけられない」と診断し、**sugar の分だけ**を機械可読に
    # した。`RUBY_SUBSET[:supported]` そのものは散文のまま残り、その 5 行目
    # 「n.times { |i| ... } (closure capture 含む; literal N は open-coded、動的 N は
    # bpf_loop)」の **literal N が本番 C codegen に無かった** (E426 S0、ADR-011
    # Stage 2 の移植で落ちたまま)。その 3 行上の「if / elsif / else (**式値も**)」の
    # **式値** — `x = if ... end` — も同じ理由で死んでいた (E426 S1)。
    # どちらも builtin でも attach kind でも sugar でも map でもないので、
    # 4 つの gate はどれもこの語彙を掃いていなかった。
    #
    # **1 主張 = 1 構文** (D0)。1 主張 = 1 散文行にしなかったのは実測による:
    # 5 行目は 3 構文を含み **1 つだけ死んでいた**ので、行の代表例
    # (`n.times { |i| ... }`、`n` は変数) は**生きている方の経路**を通り、
    # 行としては通ってしまう。3 行目に至っては 7 構文中 1 つが死んでいた。
    # **行の粒度では、行が真であることと構文が全部生きていることが別物になる。**
    #
    # **合格は 2 段 + twin** (D1):
    #   1. 宣伝した綴りが **compile する** (S0/S1 の 2 件はここで落ちる)
    #   2. 宣言した `lowers_to` が **生成 C に現れる**、かつ
    #      **構文を外した twin (`without`) には現れない**
    # 2 段目が必要なのは、構文にも**沈黙して別物になる**形があるから:
    # `3.times` (リテラル) と `a.times` (動的) は**両方 compile し両方宣伝されている**が
    # 別の機械に落ちなければならない (`bpf_iter_num_*` / `bpf_loop`)。open-coded 経路が
    # 落ちればリテラル N は黙って `bpf_loop` になる — exit 0・同じ意味論・違う機械・
    # **違うカーネル下限** (6.4 / 5.17、E426 S0 が実測)。1 段目には見えない。
    # twin は needle を **load-bearing** にする: `%` も `else` も `if (` も
    # 生成 C の定型に出るので、twin に無いことを要求しないと定型で満たされてしまう。
    #
    # `lowers_to` は「この Ruby はこの C になる」という**出荷して有用な事実**でもある
    # (AI が読む面に「`5_000_000` は `5000000` に、`3.times` は `bpf_iter_num_new` に、
    # `@h` は map lookup に落ちる」と書いてある)。gate は期待値を持たない — E406 以来の規約。
    #
    #   form  :expr / :stmt / :attach  … **sugar と同じ harness** (SUGAR_SHAPES)。
    #                                     これが D5 (同じファイルに置く) の実測根拠の 1 つ。
    #   shape :expr/:stmt のとき、probe を書く context
    #
    # **代替の綴り (ternary / 後置 if / `@x += 1`) はここではなく sugar 側**に置く —
    # 2 綴りが同じ C になるという主張は E408 の基準の方が強いため。
    SYNTAX = [
      # ---- 整数リテラルと算術 (E010) ------------------------------------
      { id: :int_literal, edoc: "E010", family: "integer literals",
        form: :expr, shape: :kprobe_arg, syntax: "7", without: "8", lowers_to: "= 7;" },
      { id: :op_add, edoc: "E010", family: "integer arithmetic", form: :expr, shape: :kprobe_arg,
        syntax: "a + 3", without: "a", lowers_to: "a + 3" },
      { id: :op_sub, edoc: "E010", family: "integer arithmetic", form: :expr, shape: :kprobe_arg,
        syntax: "a - 3", without: "a", lowers_to: "a - 3" },
      { id: :op_mul, edoc: "E010", family: "integer arithmetic", form: :expr, shape: :kprobe_arg,
        syntax: "a * 3", without: "a", lowers_to: "a * 3" },
      { id: :op_div, edoc: "E010", family: "integer arithmetic", form: :expr, shape: :kprobe_arg,
        syntax: "a / 3", without: "a", lowers_to: "a / 3",
        note: "the verifier may reject signed division. If unsigned is needed, divu(a, b)" },
      { id: :op_mod, edoc: "E010", family: "integer arithmetic", form: :expr, shape: :kprobe_arg,
        syntax: "a % 3", without: "a", lowers_to: "a % 3" },
      # ---- 比較 (E010) ---------------------------------------------------
      { id: :cmp_eq, edoc: "E010", family: "comparison", form: :expr, shape: :kprobe_arg,
        syntax: "(a == 3)", without: "a", lowers_to: "(a == 3)" },
      { id: :cmp_ne, edoc: "E010", family: "comparison", form: :expr, shape: :kprobe_arg,
        syntax: "(a != 3)", without: "a", lowers_to: "(a != 3)" },
      { id: :cmp_lt, edoc: "E010", family: "comparison", form: :expr, shape: :kprobe_arg,
        syntax: "(a < 3)", without: "a", lowers_to: "(a < 3)" },
      { id: :cmp_gt, edoc: "E010", family: "comparison", form: :expr, shape: :kprobe_arg,
        syntax: "(a > 3)", without: "a", lowers_to: "(a > 3)" },
      { id: :cmp_le, edoc: "E010", family: "comparison", form: :expr, shape: :kprobe_arg,
        syntax: "(a <= 3)", without: "a", lowers_to: "(a <= 3)" },
      { id: :cmp_ge, edoc: "E010", family: "comparison", form: :expr, shape: :kprobe_arg,
        syntax: "(a >= 3)", without: "a", lowers_to: "(a >= 3)" },
      # ---- bitwise (E050) ------------------------------------------------
      { id: :bit_and, edoc: "E050", family: "bitwise", form: :expr, shape: :kprobe_arg,
        syntax: "(a & 3)", without: "a", lowers_to: "(a & 3)" },
      { id: :bit_or, edoc: "E050", family: "bitwise", form: :expr, shape: :kprobe_arg,
        syntax: "(a | 3)", without: "a", lowers_to: "(a | 3)" },
      { id: :bit_xor, edoc: "E050", family: "bitwise", form: :expr, shape: :kprobe_arg,
        syntax: "(a ^ 3)", without: "a", lowers_to: "(a ^ 3)" },
      { id: :bit_shl, edoc: "E085", family: "bitwise", form: :expr, shape: :kprobe_arg,
        syntax: "(a << 3)", without: "a", lowers_to: "(a << 3)" },
      { id: :bit_shr, edoc: "E085", family: "bitwise", form: :expr, shape: :kprobe_arg,
        syntax: "(a >> 3)", without: "a", lowers_to: "(a >> 3)" },
      # ---- 短絡論理・括弧 (E037/E050) ------------------------------------
      { id: :bool_or, edoc: "E037", family: "short-circuit logic", form: :expr, shape: :kprobe_arg,
        syntax: "(a == 1 || a == 2)", without: "a", lowers_to: "(a == 1 || a == 2)" },
      { id: :bool_and, edoc: "E037", family: "short-circuit logic", form: :expr, shape: :kprobe_arg,
        syntax: "(a > 1 && a < 9)", without: "a", lowers_to: "(a > 1 && a < 9)" },
      { id: :paren, edoc: "E050", family: "explicit parentheses", form: :expr, shape: :kprobe_arg,
        syntax: "(a + 1) * 2", without: "a * 2", lowers_to: "(a + 1) * 2",
        note: "required for bitwise precedence — `(flags & TCP_FLAG_RST) != 0`" },
      # ---- 制御構造 (E011) ------------------------------------------------
      { id: :if_then, edoc: "E011", family: "if / elsif / else", form: :stmt, shape: :kprobe_arg,
        syntax: "if a > 1\n    @h = @h + 1\n  end", without: "@h = @h + 1",
        lowers_to: "if (a > 1) {" },
      { id: :if_else, edoc: "E011", family: "if / elsif / else", form: :stmt, shape: :kprobe_arg,
        syntax: "if a > 1\n    @h = @h + 1\n  else\n    @h = @h + 2\n  end",
        without: "if a > 1\n    @h = @h + 1\n  end", lowers_to: "} else {" },
      { id: :if_elsif, edoc: "E011", family: "if / elsif / else", form: :stmt, shape: :kprobe_arg,
        syntax: "if a > 1\n    @h = @h + 1\n  elsif a > 0\n    @h = @h + 2\n  else\n    @h = @h + 3\n  end",
        without: "if a > 1\n    @h = @h + 1\n  else\n    @h = @h + 2\n  end",
        lowers_to: "if (a > 0) {",
        note: "elsif expands into a nested if/else + nested temps (E011). Redundant, but clang -O2 folds it" },
      # **E426 の 2 件目の発見**。E011 が temp 変数の lowering を作ったのは
      # まさにこの形のためで (「if 式の値 は temp 変数で受け」)、退役 Ruby codegen も
      # `if_node` を「**式位置の if**(`x = if ... end` 等)」と名指して持っていた。
      # C 移植は IfNode を文の lowering にしか繋がず、**値の形だけが死んだ** —
      # 文の形・戻り値の形・括弧で包んだ形 (ParenthesesNode → StatementsNode 経由) は
      # 生きていたので、散文行「if / elsif / else (式値も)」は 7 構文中 6 つが真だった。
      { id: :if_value, edoc: "E011/E426", family: "if / elsif / else", form: :expr, shape: :kprobe_arg,
        syntax: "if a > 1\n    1\n  else\n    2\n  end", without: "1",
        lowers_to: "_if1;",
        note: "if in expression position. Declares __s64 _ifN, assigns it in both branches, and returns _ifN as the value. " \
              "`@x = if ... end` / operands of larger expressions take the same path" },
      # **E435 の発見** (記事の全数監査から)。判断を書く probe で最初に手が伸びる形 —
      # `if ... return -1 ... end` — が `node type not yet ported (Stage 1): ReturnNode`
      # で死んでいた。prism のクラス名を見せて直し方を言わないエラーの実例そのもので、
      # かつ「/etc/shadow を拒否」という本 project の看板デモの最短の書き方である。
      # 機構は既に在った (verdict hook の wrapper は _inner の戻り値をそのまま返す)。
      { id: :early_return, edoc: "E435", family: "early return", form: :stmt, shape: :kprobe_arg,
        syntax: "if a > 1\n    return 7\n  end", without: "if a > 1\n    @h = 7\n  end",
        lowers_to: "return 7;",
        note: "an early return in statement position. _inner's return type is already the method's type, so it is C's return itself. " \
              "`return <value>` in a method that has no value (returns nil) dies loudly (there is nothing to receive it)" },
      # ---- ローカル変数 / メソッド (E014/E015) ---------------------------
      { id: :local_var, edoc: "E014", family: "local variables", form: :stmt, shape: :kprobe_arg,
        syntax: "x = a + 1\n  n = x * 2", without: "n = a", lowers_to: "x = a + 1;",
        note: "locals are declared together as `__s64 x = 0;` at the top of the function" },
      { id: :bpf_to_bpf, edoc: "E015", family: "BPF-to-BPF call", form: :attach,
        syntax: "def helper(x)\n  x * 2\nend\n\ndef kprobe__do_sys_openat2(a)\n<BODY>\n  helper(a)\nend",
        without: "def helper(x)\n  x * 2\nend\n\ndef kprobe__do_sys_openat2(a)\n<BODY>\n  a\nend",
        ret: "0", lowers_to: "helper_inner(a)",
        note: "calls the `_inner` of another :ebpf method in the same unit directly (eBPF cannot recurse)" },
      # ---- attach ハンドラの引数宣言 0..N (E320/E319 GAP-3) --------------
      { id: :attach_args_0, edoc: "E319", family: "attach handler argument declarations", form: :attach,
        syntax: "def kprobe__do_sys_openat2\n<BODY>\nend", ret: "0",
        without: "def kprobe__do_sys_openat2(a)\n<BODY>\nend",
        lowers_to: "_inner();",
        note: "unused kernel function arguments may be left undeclared (a 0-argument kprobe is legal too)" },
      { id: :attach_args_n, edoc: "E020", family: "attach handler argument declarations", form: :attach,
        syntax: "def kprobe__do_sys_openat2(a, b)\n<BODY>\n  a + b\nend", ret: "0",
        without: "def kprobe__do_sys_openat2\n<BODY>\nend",
        lowers_to: "PT_REGS_PARM2(ctx)",
        note: "the declared ones map by position onto args_convention (PT_REGS_PARM<N> for kprobe)" },
      # ---- インスタンス変数 (E009/E022) ----------------------------------
      { id: :ivar_read, edoc: "E009", family: "instance variables", form: :expr, shape: :kprobe_arg,
        syntax: "@h", without: "a", lowers_to: "bpf_map_lookup_elem(&u_top_h" },
      { id: :ivar_write, edoc: "E009", family: "instance variables", form: :stmt, shape: :kprobe_arg,
        syntax: "@h = 7", without: "n = 7", lowers_to: "bpf_map_update_elem(&u_top_h" },
      { id: :ivar_opwrite, edoc: "E009", family: "instance variables", form: :stmt, shape: :kprobe_arg,
        syntax: "@h += 7", without: "n = 7", lowers_to: "bpf_map_update_elem(&u_top_h",
        note: "`@x += n` is a read-modify-write. **It is not byte-identical to `@x = @x + n`** " \
              "(E426 measured: extra parentheses and shifted temp numbers). The meaning is the same" },
      { id: :top_ivar, edoc: "E022", family: "top-level ivar", form: :attach,
        syntax: "@h = 0\n\ndef kprobe__do_sys_openat2(a)\n<BODY>\n  @h\nend",
        without: "def kprobe__do_sys_openat2(a)\n<BODY>\n  a\nend", ret: "0",
        lowers_to: "u_top_h SEC(\".maps\")",
        note: "1 top-level ivar = 1 per-unit HASH map. Shared between attach handlers" },
      { id: :class_ivar, edoc: "E009", family: "class ivars", form: :attach,
        syntax: "class C\n  def incr(d)\n<BODY>\n    @x = @x + d\n    @x\n  end\nend",
        without: "class C\n  def incr(d)\n<BODY>\n    d\n  end\nend", ret: "0",
        lowers_to: "c_at_x SEC(\".maps\")",
        note: "1 ivar = 1 HASH map (a singleton with a __u32 key)" },
      # ---- ループ (E016/E017/E062) ---------------------------------------
      # この 2 つが D1 の 2 段目が要る理由である: **両方 compile し両方宣伝されて
      # いるのに、別の機械に落ちなければならない**。open-coded 経路が落ちれば
      # リテラル N は黙って bpf_loop になる (exit 0、同じ意味論、違うカーネル下限)。
      { id: :times_literal, edoc: "E062", family: "n.times", form: :stmt, shape: :kprobe_arg,
        syntax: "3.times do |i|\n    @h = @h + i\n  end", without: "@h = @h + 1",
        lowers_to: "bpf_iter_num_new",
        note: "a literal N is inlined into the caller as an open-coded iterator " \
              "(no callback and no capture struct). **Kernel floor 6.4**" },
      { id: :times_dynamic, edoc: "E016", family: "n.times", form: :stmt, shape: :kprobe_arg,
        syntax: "a.times do |i|\n    @h = @h + i\n  end", without: "@h = @h + 1",
        lowers_to: "bpf_loop(",
        note: "a dynamic N is bpf_loop + a generated callback. Kernel floor 5.17" },
      { id: :times_capture, edoc: "E017", family: "n.times", form: :stmt, shape: :kprobe_arg,
        syntax: "t = 0\n  a.times do |i|\n    t = t + i\n  end\n  n = t", without: "n = a",
        lowers_to: "_caps",
        note: "when the block captures outer locals, a per-loop caps struct is passed by pointer" },
      # ---- 定数 (E029/E072/E094) -----------------------------------------
      { id: :const_read, edoc: "E029", family: "constants", form: :expr, shape: :kprobe_arg,
        syntax: "IPPROTO_TCP", without: "0", lowers_to: "= 6;",
        note: "KNOWN_CONSTANTS names resolve to literal integers (no run-time lookup)" },
      { id: :const_path, edoc: "E072", family: "constants", form: :expr, shape: :kprobe_arg,
        syntax: "IP::Proto::TCP", without: "0", lowers_to: "= 6;",
        note: "module-form paths resolve to the same integers too (8 prefixes). The equivalence of spellings is on the sugar side" },
      # ---- 固定 String リテラル (E099/E394) ------------------------------
      { id: :string_literal, edoc: "E099", family: "fixed String literals", form: :expr,
        shape: :kprobe_sk, syntax: "kfield(sk, \"sock\", \"sk_sndbuf\")",
        without: "kfield(sk, \"sock\", \"sk_rcvbuf\")", lowers_to: "sk_sndbuf",
        note: "Strings are compile-time only (BPF has no string heap). Field names, paths and " \
              "comparison literals are all burned in AOT" },
      # ---- receiver への複合代入 (E070) ----------------------------------
      { id: :dot_op_assign, edoc: "E070", family: "receiver dot accessor", form: :stmt,
        shape: :tcp_cc, syntax: "sk.snd_cwnd += 1", without: "sk.snd_cwnd = 1",
        lowers_to: "->snd_cwnd += ",
        note: "CallOperatorWriteNode. tcp_sock fields in tcp_cc context only" },
    ].freeze

    # 降ろした構文。空なら空が正解 (E415: 在庫についての言明であって検出力ではない)。
    WITHDRAWN_SYNTAX = {}.freeze

    # E426 (D2): **向きが逆の検査の権威**。
    #
    # E409 が「claim 側だけ見る gate は affordance が空でも緑になる」と実測した。
    # 構文でそれに当たるのは「本番 codegen が受理する AST ノード型」で、
    # 権威は `src/codegen_c/spinel_ebpf_cc.c` の **2 つの lowering dispatcher**
    # (`cc_lower_expr` / `cc_lower_stmt`) の `strcmp(ty, "XxxNode")` 群である。
    # gate はこれをソースから読み、**どの claim の probe にも現れないノード型**を
    # uncovered として報告する (`WhileNode` を受理し始めたら、その日に出る)。
    #
    # **粒度の限界を明記する** (実測): ノード型は「構文」より粗い。
    # ternary `a > 1 ? 1 : 2` と `if ... else ... end` は**同じ IfNode** なので、
    # ノード型の coverage では区別できない。CallNode に至っては builtin (E406) も
    # sugar (E408) も演算子も全部同じ型である。⇒ CallNode の演算子メンバだけは
    # 2 つ目の権威 `cc_is_binary_op()` の表 (16 個) で**演算子粒度**まで見る。
    # 残りの CallNode メンバ (builtin / sugar) は E406/E408 が名前粒度で見ている。
    SYNTAX_COVERAGE_AUTHORITIES = {
      node_types: { file: "src/codegen_c/spinel_ebpf_cc.c",
                    functions: %w[cc_lower_expr cc_lower_stmt],
                    what: "the accepted AST node types (strcmp(ty, \"XxxNode\"))" },
      binary_ops: { file: "src/codegen_c/spinel_ebpf_cc.c",
                    functions: %w[cc_is_binary_op],
                    what: "the table of binary operators" },
    }.freeze

    # E463 (ADR-019 Phase C stage 2): **builtin の existence 軸の逆向き coverage の権威座標**。
    # codegen が builtin 名を認識する機構は 1 つではない — lower 2 関数の strcmp チェーンの
    # ほかに、文字列テーブル (PKT_BUILTINS)、name 先頭の struct テーブル (CC_SOCK_ACC /
    # QDISC_KFUNCS)、strcmp を束ねた helper 関数 (tcp_sock_* 3 本 / cc_cap_set) がある。
    # affordance_gate はここに宣言された座標**だけ**から名前を抽出し、
    #   逆向き: 抽出 − claim − WITHDRAWN − 除外 = 0 (実装されて宣伝されていない builtin は無い)
    #   順向き: claim − 抽出 = 0 (この権威リスト自体が完全である — 新しい認識機構を
    #           登録し忘れると、その機構の builtin が「claim にあるのに見つからない」で出る)
    # を毎回検査する。座標に無い機構は掃けない — それが残余であり、順向きの検査が
    # その残余を可視化する (E426 の syntax coverage と同じ割り切り)。
    BUILTIN_COVERAGE_AUTHORITIES = {
      lower_fns:     { file: "src/codegen_c/spinel_ebpf_cc.c",
                       functions: %w[cc_lower_expr cc_lower_stmt],
                       what: "a serial chain of strcmp(name|nm, \"...\") (the g_gpu rows are target vocabulary, so excluded)" },
      string_tables: { file: "src/codegen_c/spinel_ebpf_cc.c",
                       arrays: %w[PKT_BUILTINS],
                       what: "a string array of builtin names" },
      name_tables:   { file: "src/codegen_c/spinel_ebpf_cc.c",
                       arrays: %w[CC_SOCK_ACC QDISC_KFUNCS],
                       what: "a struct array whose rows start with a builtin name" },
      helper_fns:    { file: "src/codegen_c/spinel_ebpf_cc.c",
                       functions: %w[cc_tcp_sock_reader_field cc_tcp_sock_writer_field
                                     cc_tcp_sock_adder_field cc_cap_set],
                       what: "a name→member resolution helper that bundles strcmp" },
    }.freeze

    # 抽出には現れるが builtin ではない名前。黙って引き算せず、理由ごと宣言する
    # (opaqueness must be explicit、ADR-019 原則 2)。
    BUILTIN_COVERAGE_EXCLUSIONS = {
      "times" => "iterator syntax — owned by Capabilities::SYNTAX (lowers_to bpf_loop / open-coded, E426). " \
                 "Not a builtin, but the lowering function strcmps it as a CallNode name",
    }.freeze

    # E465 (ADR-019 Phase C stage 4 / P013): per-target existence。正本は
    # src/codegen_c/builtin_schema.h の cc_builtin_targets — C backstop
    # (amp/gpu_scan_supported) が同じ表を歩き、TargetProfile の call_allowlist も
    # 同じ生成 JSON から読む。表に無い builtin は linux のみ (default)。
    BUILTIN_SCHEMA_JSON = begin
      require "json"
      path = File.expand_path("builtin_schema_gen.json", __dir__)
      unless File.exist?(path)
        raise "builtin schema artifact missing: #{path} " \
              "(run: make -C src/codegen_c builtin-schema)"
      end
      JSON.parse(File.read(path)).freeze
    end
    BUILTIN_TARGETS = BUILTIN_SCHEMA_JSON.fetch("targets")
                                         .map { |r| [r.fetch("name"), r.fetch("targets").freeze] }
                                         .to_h.freeze
    DEFAULT_BUILTIN_TARGETS = BUILTIN_SCHEMA_JSON.fetch("default_targets").freeze

    def valid_targets_for(name)
      BUILTIN_TARGETS[name] || DEFAULT_BUILTIN_TARGETS
    end

    # linux の builtin surface に居ない、target 専用の builtin (現在は gpu の 4 つ)。
    # affordance の `builtins` (linux の claim) には混ぜず、別 key で出す。
    def target_only_builtins
      BUILTIN_TARGETS.reject { |_, ts| ts.include?("linux") }
                     .each_with_object({}) { |(n, ts), h| ts.each { |t| (h[t] ||= []) << n } }
                     .transform_values(&:sort)
    end

    # E468 (stage 5): target 専用 builtin の**構文見本** (E322 と同じ規律 — 構文のみ、
    # ロジック指南はしない)。affordance_gate の target-claims probe (target の CC で
    # claim が本当に compile するかの正方向) がこれを call text に使い、AI が GPU kernel を
    # 書くときの見本にもなる。**見本の無い target 行は gate が abort する** (E407: gate が
    # 書けない claim は誰も検査していない claim)。:declaration は「top-level 宣言形なので
    # 全 probe の preamble が使う」印 — gate は宣言を抜いた負の対照で load-bearing を証す。
    TARGET_BUILTIN_EXAMPLES = {
      "gpu_global_id"    => "i = gpu_global_id",
      "gpu_local_id"     => "l = gpu_local_id",
      "gpu_group_id"     => "g = gpu_group_id",
      "gpu_group_size"   => "z = gpu_group_size",
      "gpu_load"         => "v = gpu_load(:x, gpu_global_id)",
      "gpu_store"        => "gpu_store(:y, gpu_global_id, 2.0)",
      "gpu_barrier"      => "gpu_barrier",
      "gpu_shared_load"  => "v = gpu_shared_load(:acc, 0)",
      "gpu_shared_store" => "gpu_shared_store(:acc, 0, 1.0)",
      "gpu_buffer"       => :declaration,
      "gpu_shared"       => :declaration,
      "gpu_atomic_add"   => "gpu_atomic_add(:h, 0, 1)",
    }.freeze

    # ===================================================================
    # E419: **内省が sugar の綴りを見えるようにするための導出**。
    #
    # `describe` / `capabilities <file>` の capability domain は flat な builtin 名の
    # text scan で、しかも `(?<![\w.])` で **ドットの後ろを意図的に除外**している
    # (`sk.foo` の receiver を builtin と読まないため)。結果、E071 の chain 綴り
    # `pkt.l4.proto` は 1 個も hit せず、**プロジェクトが推奨している綴りの方が
    # affordance が空** になっていた (E410 が副産物として記録、E419 で実測・修正)。
    # 生成 C は同じ — E408 が 60 主張で毎回実測している — ので、
    # **食い違っていたのは内省だけ**だった。
    #
    # 2 つ目の表は作らない (E408 の設計判断:「chain 側だけが知っている reader は
    # 構造的に存在し得ない」)。ここは gate が読むのと同じ唯一の権威 `surface_sugar`
    # から **構造的に**選ぶ:
    #   * form が :expr / :stmt (attach 形は綴りが method 名なので対象外)
    #   * sugar が **1 個のドット付き識別子連鎖** — 末尾に `(...)` 引数、
    #     または ` = <値>` / ` += <値>` を許す
    #   * flat 側の先頭識別子が **登録済 builtin** であること
    # ⇒ `XDP::PASS` (定数であって builtin でない) / `5_000_000` (ドット無し) /
    #    `t = kptr(...)` の複文 (先頭識別子が `t`) は自動的に外れる。族にメンバが
    #    増えれば、ここも gate も同時に増える。
    # ===================================================================
    SUGAR_ALIAS_RE = /\A([a-z_]\w*(?:\.[a-z_]\w*)+)(?:\([^)]*\))?(?:\s*(\+?=)\s*\S+)?\z/.freeze

    def sugar_builtin_aliases
      bs = all_builtins
      surface_sugar.filter_map do |s|
        next unless %i[expr stmt].include?(s[:form])
        m = SUGAR_ALIAS_RE.match(s[:sugar].to_s.strip) or next
        flat = s[:flat].to_s[/\A[a-z_]\w*/]
        next unless flat && bs.include?(flat)
        { id: s[:id], sugar: s[:sugar], dotted: m[1], op: m[2], flat: flat }
      end
    end

    # alias を source text に当てる正規表現。**読み形と書き形を取り違えない**のが
    # 唯一の非自明な点: `sk.snd_cwnd` (reader) と `sk.snd_cwnd = 10` (writer) は
    # 別 builtin に落ちるので、読み形は後続の代入を負の先読みで外す。
    # `==` は比較なので外さない (`(?!=)` の内側の先読みがそれを担う)。
    def sugar_alias_regexp(a)
      base = "(?<![\\w.])#{Regexp.escape(a[:dotted])}(?![\\w])"
      case a[:op]
      when "="  then /#{base}\s*=(?!=)/
      when "+=" then /#{base}\s*\+=/
      else           /#{base}(?!\s*\+?=(?!=))/
      end
    end

    # コメント除去済の source が使っている sugar 綴りの **flat builtin 名** (uniq)。
    def sugar_alias_hits(code)
      sugar_builtin_aliases.filter_map { |a| a[:flat] if code =~ sugar_alias_regexp(a) }.uniq
    end

    # 層2 enricher (参考、ADR-014 層2 / E313-E315)。probe (.rb) を **変えず** に
    # runtime が env-gate で属性を足す。AI は「pod 帰属は probe でなく env で付く」を読める。
    ENRICHERS = [
      { name: "k8s",  experiment: "E304", layer: 2, signal_scope: "all",
        attributes: %w[k8s.pod.name k8s.namespace.name k8s.pod.uid k8s.container.name],
        gate: "cgroup_id() builtin + kubepods cgroup resolution (env)",
        note: "adds pod membership without changing the probe (a no-op when unset)" },
      { name: "cri",  experiment: "E315", layer: 2, signal_scope: "all",
        attributes: %w[k8s.container.name],
        gate: "CRIMAP (env)",
        note: "overwrites the container id with the real container name (last-writer-wins; a no-op when unset)" },
      { name: "peer", experiment: "E310", layer: 2, signal_scope: "conn",
        attributes: %w[peer.address peer.pod peer.service peer.external],
        gate: "destination IP resolution (env)",
        note: "conn spans only (the path that has the destination address)" },
    ].freeze

    # ===================================================================
    # E317 (ADR-015 原則2「loud failure」+ 投資優先(b)): 必須組 (multi-hook)
    # の contract。
    #
    # いくつかの builtin は **単独では意味を持たず**、相方 (別 SEC の別メソッド)
    # と組んで初めて 1 本の span を生む。片方だけ書くと **silent に壊れた program**
    # になる (record を貯めるが誰も読まない → span が出ない、exit 0)。これは
    # ADR-015 原則2 に反する最悪ケース。ここに contract を **純データ**で持ち、
    #   * compile 時の loud 検査 (SpinelEbpf::Validate) がこれを参照して落とす、
    #   * E316 affordance (`--json` の `required_sets`) にも載る (相方が読める)、
    # を両立する。E316 残課題「組み合わせ recipe」への回答。
    #
    # mode:
    #   :all      -- members のどれか 1 つでも使えば **全員** 必須 (相互依存)。
    #   :requires -- trigger を使ったら requires を **全部** 必須 (一方向)。
    #                相方は trigger 無しでも単独で valid (後方互換)。
    #
    # 契約は実測に忠実 (2 軸ハーネス: 締めすぎない):
    #   * emit_connect / emit_dns は **単独で valid** (E294/E295) ⇒ ここに載せない。
    #   * sock_owner_set は emit_connect が読む相方が無いと無意味 ⇒ 一方向 requires。
    #   examples/observability/otlp/ の完全 probe は全て本契約を満たす (E317 で実測)。
    #
    # E325 (ADR-015 原則「穴はハーネスに畳み込む」): span を生む組には **もう半分**
    # がある。上の members は **kernel 側 builtin** で、これらは span record を map に
    # **貯めるだけ**。userspace が `ffi_func` 宣言 + drain ループ (`Otlp.<push>(endpoint)`)
    # を書いて初めて OTLP に export される。この userspace-export 半分が affordance から
    # **完全に不可視**だったため (E325: 2 モデルが正しい kernel probe を書いたが drain を
    # 落とし → compile+verify は green でも span 0 本 = thesis が消したはずの kernel/userspace
    # ブリッジ bug class の再来)。各 span 組に `userspace_export` companion を **純データ**で
    # 載せ、相方 FFI 名と drain-loop の **構文見本** (interval は author が決める、
    # E322 の「構文見本に留めロジック指南はしない」) を読めるようにする。push 関数の実体は
    # bin/spinel-ebpf で定義 (全て `[:str], :int` = endpoint のみ)。
    # endpoint は **env `OTLP_ENDPOINT` を読むのが harness 慣行** (E327: 裸の placeholder
    # だと author が hardcode してポート違いで 0 span → env-fallback を pattern で教える。
    # 値の決定はなお author/env の仕事 = ロジック指南ではなく可搬性の構文)。
    REQUIRED_SETS = [
      { name: "http_span", mode: :all, experiment: "E298",
        members: %w[http_req_start http_resp_stash http_emit],
        why: "req records into http_pending, resp_stash stashes the receive buffer, and emit correlates them into a span. If any one is missing, no span appears.",
        userspace_export: {
          fn: "spnl_otlp_http_span_push",
          ffi_decl: "ffi_func :spnl_otlp_http_span_push, [:str], :int",
          pattern: "module Otlp\n  ffi_func :spnl_otlp_http_span_push, [:str], :int\nend\n# ... kernel handlers (members) ...\nep = ENV[\"OTLP_ENDPOINT\"] || \"http://127.0.0.1:4318\"\nloop { sleep n; Otlp.spnl_otlp_http_span_push(ep) }",
          why: "the kernel builtin only stores span records in a map. They are exported to OTLP only when userspace drains them with this FFI. Without it, compile+verify are green but there are 0 spans (E325).",
        }.freeze }.freeze,
      { name: "redis_span", mode: :all, experiment: "E341",
        members: %w[redis_req_start redis_resp_stash redis_emit],
        why: "req records into redis_pending, resp_stash stashes the receive buffer, and emit correlates them into a span (db.system=redis, command/-ERR/duration). If any one is missing, no span appears.",
        userspace_export: {
          fn: "spnl_otlp_redis_span_push",
          ffi_decl: "ffi_func :spnl_otlp_redis_span_push, [:str], :int",
          pattern: "module Otlp\n  ffi_func :spnl_otlp_redis_span_push, [:str], :int\nend\n# ... kernel handlers (members) ...\nep = ENV[\"OTLP_ENDPOINT\"] || \"http://127.0.0.1:4318\"\nloop { sleep n; Otlp.spnl_otlp_redis_span_push(ep) }",
          why: "the kernel builtin only stores span records in a map. They are exported to OTLP only when userspace drains them with this FFI. Without it, compile+verify are green but there are 0 spans (E325).",
        }.freeze }.freeze,
      { name: "ssl_span", mode: :all, experiment: "E299",
        members: %w[ssl_req_start ssl_resp_stash ssl_emit],
        why: "one span from the 3 hooks req/resp/emit on the SSL plaintext. If any is missing, no plaintext span appears.",
        userspace_export: {
          fn: "spnl_otlp_http_span_push",
          ffi_decl: "ffi_func :spnl_otlp_http_span_push, [:str], :int",
          pattern: "module Otlp\n  ffi_func :spnl_otlp_http_span_push, [:str], :int\nend\n# ... kernel handlers (members) ...\nep = ENV[\"OTLP_ENDPOINT\"] || \"http://127.0.0.1:4318\"\nloop { sleep n; Otlp.spnl_otlp_http_span_push(ep) }",
          why: "E299 reuses E298's HTTP push (there is no dedicated ssl push). The kernel builtin only stores span records in a map; they are exported to OTLP only when drained with this FFI. Without it, compile+verify are green but there are 0 spans (E325).",
        }.freeze }.freeze,
      { name: "dns_span", mode: :all, experiment: "E295",
        members: %w[dns_req_start dns_resp_stash dns_emit],
        why: "one span (with latency) from the 3 DNS correlation hooks req/resp/emit.",
        userspace_export: {
          fn: "spnl_otlp_dns_span_push",
          ffi_decl: "ffi_func :spnl_otlp_dns_span_push, [:str], :int",
          pattern: "module Otlp\n  ffi_func :spnl_otlp_dns_span_push, [:str], :int\nend\n# ... kernel handlers (members) ...\nep = ENV[\"OTLP_ENDPOINT\"] || \"http://127.0.0.1:4318\"\nloop { sleep n; Otlp.spnl_otlp_dns_span_push(ep) }",
          why: "the kernel builtin only stores span records in a map. They are exported to OTLP only when userspace drains them with this FFI. Without it, compile+verify are green but there are 0 spans (E325).",
        }.freeze }.freeze,
      { name: "l7_latency", mode: :all, experiment: "E297",
        members: %w[req_start emit_l7],
        why: "req_start records the send time, and emit_l7 reads the round-trip latency into a span. With only one of them there is no duration.",
        userspace_export: {
          fn: "spnl_otlp_l7_span_push",
          ffi_decl: "ffi_func :spnl_otlp_l7_span_push, [:str], :int",
          pattern: "module Otlp\n  ffi_func :spnl_otlp_l7_span_push, [:str], :int\nend\n# ... kernel handlers (members) ...\nep = ENV[\"OTLP_ENDPOINT\"] || \"http://127.0.0.1:4318\"\nloop { sleep n; Otlp.spnl_otlp_l7_span_push(ep) }",
          why: "the kernel builtin only stores span records in a map. They are exported to OTLP only when userspace drains them with this FFI. Without it, compile+verify are green but there are 0 spans (E325).",
        }.freeze }.freeze,
      { name: "offcpu_span", mode: :all, experiment: "E300",
        members: %w[offcpu_recv_stash offcpu_begin offcpu_account offcpu_emit],
        why: "recv_stash/begin open the off-CPU window, account accumulates the waits, and emit closes the window into a span. One set of 4 hooks.",
        userspace_export: {
          fn: "spnl_otlp_offcpu_span_push",
          ffi_decl: "ffi_func :spnl_otlp_offcpu_span_push, [:str], :int",
          pattern: "module Otlp\n  ffi_func :spnl_otlp_offcpu_span_push, [:str], :int\nend\n# ... kernel handlers (members) ...\nep = ENV[\"OTLP_ENDPOINT\"] || \"http://127.0.0.1:4318\"\nloop { sleep n; Otlp.spnl_otlp_offcpu_span_push(ep) }",
          why: "the kernel builtin only stores span records in a map. They are exported to OTLP only when userspace drains them with this FFI. Without it, compile+verify are green but there are 0 spans (E325).",
        }.freeze }.freeze,
      { name: "sock_owner_correlation", mode: :requires, experiment: "E296",
        trigger: "sock_owner_set", requires: %w[emit_connect],
        why: "sock_owner_set only records sock→process; the correlation works only when emit_connect looks it up by the same sock.",
        userspace_export: {
          fn: "spnl_otlp_conn_span_push",
          ffi_decl: "ffi_func :spnl_otlp_conn_span_push, [:str], :int",
          pattern: "module Otlp\n  ffi_func :spnl_otlp_conn_span_push, [:str], :int\nend\n# ... kernel handlers (sock_owner_set + emit_connect) ...\nep = ENV[\"OTLP_ENDPOINT\"] || \"http://127.0.0.1:4318\"\nloop { sleep n; Otlp.spnl_otlp_conn_span_push(ep) }",
          why: "this correlation is exported in the conn span emit_connect produces (there is no dedicated push). The kernel builtin only stores records in a map; they are exported to OTLP only when drained with this FFI (E325).",
        }.freeze }.freeze,
    ].freeze

    # --- query API (E316: 機械可読 affordance) ---

    # builtin -> signature hash ({arity:, params:, opaque:, summary:})。
    def signature_for(name)
      SIGNATURES[name] || { arity: nil, params: nil, opaque: true, summary: nil }
    end

    # builtin -> context 要件 ({secs:}|{kinds:}) or nil (codegen 非強制)。
    def context_for(name)
      CONTEXT_REQUIREMENTS[name]
    end

    # builtin -> valid context 文字列配列 (JSON 用)。gate 無しは nil。
    # E435: `valid_contexts` は「ここに書ける」という**主張**であって、書けることの
    # 測定ではなかった。path_eq / path_starts_with / path_contains は 32 hook を
    # 並べていたが、同じ JSON の `dpath_no_select` が同時に 4 SEC を「この 3 つは
    # 拒否する」と宣言しており、実際 `fentry__dentry_open` で `path_eq` を書くと
    # compile 時に die する ⇒ **開示チャネル自身が自分と矛盾していた** (28 が正しい)。
    # しかも同じ 32 個は誤った hook で使ったときの**エラーメッセージの直し方**にも
    # 出ていたので、「actionable なメッセージが、実際には直らない直し方を名指す」
    # という形になっていた。1 箇所で引くことで、JSON と die() が同じ集合を見る。
    def context_strings(name)
      req = CONTEXT_REQUIREMENTS[name]
      return nil unless req
      return req[:kinds].map(&:to_s) unless req[:secs]

      secs = req[:secs]
      secs -= DPATH_NO_SELECT_SECS if DPATH_SELECT_BUILTINS.include?(name)
      secs
    end

    # builtin -> context の人間可読ノート (gate 有=強制、無=best-effort)。
    def context_note(name)
      return "enforced by codegen at compile time (dies outside this hook)" if CONTEXT_REQUIREMENTS[name]
      CONTEXT_NOTE_OVERRIDES[name] || DOMAIN_CONTEXT_NOTE[domain_of(name)] || "not enforced by codegen"
    end

    # builtin -> 1 行の Ruby 呼び出しコード例 (構文見本、E322 GAP-1)。opaque は nil
    # (params 不明なので嘘の例より省略 = opaque と同じ正直さ)。
    def example_for(name)
      sig = signature_for(name)
      return nil if sig[:opaque]              # 省略は意図的 (example.nil? iff opaque)
      ov = EXAMPLE_OVERRIDES[name]
      return ov if ov
      params = sig[:params]
      return name if params.nil? || params.empty?   # arity 0 = bare 呼出 (dominant idiom)
      "#{name}(#{params.join(', ')})"
    end

    # builtin -> 関連 builtin (BUILTIN_GROUPS の同一グループの他メンバ、sorted、E322 GAP-2)。
    # どのグループにも属さなければ [] (単一の権威 = BUILTIN_GROUPS)。
    def related_for(name)
      BUILTIN_GROUPS.each_with_object([]) do |g, acc|
        acc.concat(g[:members] - [name]) if g[:members].include?(name)
      end.uniq.sort
    end

    # 1 builtin の完全 affordance entry。
    def builtin_entry(name)
      sig = signature_for(name)
      chan = record_channel_for(name)   # E370 (S3): packed record を書く builtin だけ非 nil
      {
        name: name,
        domain: domain_of(name),
        arity: sig[:arity],
        params: sig[:params],
        opaque: sig[:opaque],
        example: example_for(name),   # E322 GAP-1: 呼び出し構文見本 (opaque は null)
        related: related_for(name),   # E322 GAP-2: 関連 builtin (BUILTIN_GROUPS 由来)
        gated: !CONTEXT_REQUIREMENTS[name].nil?,
        valid_contexts: context_strings(name),
        context_note: context_note(name),
        summary: sig[:summary],
        # E395: 返り値の単位・バイト順 (取り違えても静かに通る値だけ非 nil)。
        # 散文の summary と別に持つのは、機械が読むのはこちらだから。
        value_semantics: value_semantics_for(name),
        # E370 (S3): この builtin が ringbuf に書く record と、それが最終的に何の span に
        # なるか (フィールド/offset は生成器の layout() 由来、属性は egress 宣言由来)。
        record_channel: chan && chan[:id],
        record_schema: chan,
        # E465: この builtin が存在する target (正本 = builtin_schema.h、default linux)
        valid_targets: valid_targets_for(name),
      }
    end

    # 機械可読 affordance ドキュメント全体 (Ruby Hash)。CLI が JSON 化する。
    def affordance
      {
        schema: "spinel-ebpf.affordance/1",
        adr: "ADR-015",
        note: "the AI-authoring contract (introspection; codegen output is unchanged). " \
              "Builtins stay flat (ADR-014: no mandatory dotted names).",
        summary: {
          builtin_count: all_builtins.length,
          opaque_builtins: all_builtins.count { |b| signature_for(b)[:opaque] },
          attach_kind_count: ATTACH_KINDS.length,
          domains: DOMAINS.keys,
          record_channel_count: record_channels.length,
          record_value_map_count: record_value_maps.length,
          # E400: how many metrics are declared, and the CEILING on the number of
          # time series they can ever produce. The second number is the one a
          # reviewer wants and no other artifact carries: it is computed from the
          # label declarations, so it holds for traffic nobody has measured.
          record_metric_count: record_metrics.length,
          record_metric_series_bound: record_metrics.sum { |m| m[:series_bound].to_i },
          map_count: MAPS.length,
          map_type_count: MAPS.map { |m| m[:type] }.uniq.length,
          # E426: the fifth vocabulary. Until now the Ruby subset was fourteen
          # prose strings, and two of the constructs they advertised were dead.
          syntax_count: SYNTAX.length,
          syntax_rejected_count: RUBY_SUBSET[:rejected].length,
        },
        domains: DOMAINS.each_with_object({}) { |(d, s), h|
          h[d] = { summary: s[:summary], attach_kinds: s[:attach_kinds] }
        },
        builtins: all_builtins.map { |b| builtin_entry(b) },
        # E322 GAP-2: 関連 builtin のクロスリンク (pack 関係/対/ファミリ、選択に必要な事実)。
        builtin_groups: BUILTIN_GROUPS,
        # E419: **降ろした builtin**。Ruby 定数としては E406 から在り
        # tools/affordance_gate.rb はそれを直読していたが、**JSON には出ていなかった**
        # (`withdrawn_sugar` / `withdrawn_maps` は在るのに)。JSON だけを読む消費者から
        # 見ると「宣伝されていない名前」と「宣伝を取り下げた名前」が区別できず、
        # 後者は Edoc に残っている以上 AI が拾ってくる。E409 が map で見つけた
        # 「affordance の沈黙」と同型なので、同じ形で口を開けた。
        # `why` (なぜ降ろしたか) と `instead` (代わりに何を書くか) が一緒に出る。
        withdrawn: WITHDRAWN,
        attach_kinds: ATTACH_KINDS,
        # E419: 降ろした attach kind (同上)。builtin と別表なのは沈黙の質が違うため
        # (未移植 builtin は die、未移植 attach は exit 0 で SEC("syscall") に劣化する)。
        withdrawn_attach: WITHDRAWN_ATTACH,
        context_gates: CONTEXT_GATES.map { |n, g|
          { builtin: n, domain: g[:domain], valid_secs: g[:valid_secs] }
        },
        # E435 D5: pairs where picking the wrong one is silent. `gate` names the
        # codegen function that refuses it, or is null — and a null gate carries
        # `why_ungated`, so "we cannot check this" is never spelled the same way
        # as "there is nothing to check" (E434's unexpressible).
        confusable: CONFUSABLE.map { |c|
          { id: c[:id], a: c[:a], b: c[:b], also: c[:also],
            question_a: c[:question_a], question_b: c[:question_b],
            agree_when: c[:agree_when], disagree_when: c[:disagree_when],
            wrong_answer: c[:wrong_answer],
            gate: c[:gate], why_ungated: c[:why_ungated],
            evidence: c[:evidence], experiment: c[:experiment] }
        },
        # E418: `valid_secs` は「compile が通る hook」でしかない。**通ることと発火する
        # ことは別**なので (E390 は 32 本中 4 本しか発火を測っていなかった)、hook ごとに
        # 「何をすれば踏めるか」「戻り値が効くか」「素直な操作では踏めないか」を出す。
        # AI にとってはここが「書いたポリシーが沈黙しないか」の唯一の機械可読な根拠になる。
        dpath_hooks: DPATH_HOOKS.map { |sec, h|
          { sec: sec, form: h[:form], guard: h[:guard], load_measured: h[:measured],
            fire: h[:fire], fired_by: h[:by], fire_measured: h[:fired],
            caveat: h[:caveat],
            # E420: 非 nil = パス**選別**が構造的に不可 ⇒ path_eq/path_starts_with/
            # path_contains は compile 時に die。`emit_path` / `parent_path_eq` は通る。
            no_select: h[:no_select],
            lsm_active_required: lsm_active_required?(sec) }
        },
        # E420: 上の `no_select` の要約 (拒否される綴り / 同じ hook で許される綴り)。
        # 非対称であることが主張なので、片側だけを JSON に出さない。
        dpath_no_select: { secs: DPATH_NO_SELECT_SECS,
                           refused_builtins: DPATH_SELECT_BUILTINS,
                           allowed_builtins: DPATH_NONSELECT_BUILTINS,
                           measured: "E418 (h25-h28) → dies at compile time since E420" },
        dpath_rejected: DPATH_MEASURED_REJECTED,
        ruby_subset: RUBY_SUBSET,
        # E408: surface sugar。ruby_subset は散文なので「pkt.l4.proto は書けるのか」に
        # 機械的に答えられない (それが `pkt.*` を 1 年間宣伝し続けられた理由)。ここは
        # **等価性の主張**の一覧で、tools/affordance_gate.rb --section sugar が毎回
        # 「2 つの綴りが同じ C になるか」を実測する。withdrawn は降ろした綴り。
        surface_sugar: surface_sugar.map { |s|
          s.merge(sugar: s[:sugar].to_s.gsub("<BODY>", "    ..."),
                  flat:  s[:flat].to_s.gsub("<BODY>", "  ..."))
        },
        withdrawn_sugar: WITHDRAWN_SUGAR,
        # E426: 構文語彙。`ruby_subset[:supported]` の散文はそのまま残してあるが
        # **正本ではない** — 1 主張 = 1 構文で、それぞれが「何に lower されるか」
        # (`lowers_to`) と「その構文を外した twin」(`without`) を持つ。
        # tools/affordance_gate.rb --section syntax が毎回、宣伝どおり compile して
        # 宣伝どおりの C になるか (かつ needle が定型で満たされていないか) を実測し、
        # **逆向きに** codegen が受理するノード型・演算子が全部宣伝されているかを測る。
        syntax: SYNTAX,
        withdrawn_syntax: WITHDRAWN_SYNTAX,
        syntax_coverage_authorities: SYNTAX_COVERAGE_AUTHORITIES,
        builtin_coverage_authorities: BUILTIN_COVERAGE_AUTHORITIES,
        builtin_coverage_exclusions: BUILTIN_COVERAGE_EXCLUSIONS,
        # E465: target 専用 builtin (linux surface 外)。linux の `builtins` とは別掲。
        target_only_builtins: target_only_builtins,
        # E468: target 専用 builtin の構文見本 (AI が GPU kernel を書くときの affordance)
        target_builtin_examples: TARGET_BUILTIN_EXAMPLES.transform_values { |v| v == :declaration ? "declaration" : v },
        # E466: per-target の構文事実 (times 等)。正本は builtin_schema.h の cc_syntax_targets
        syntax_targets: BUILTIN_SCHEMA_JSON.fetch("syntax_targets"),
        # E409: map 語彙。ここが空だった間、AI は「@x += 1 と書くと map が 1 本
        # 出来る」ことも「ringbuf は 256 KiB で、溢れたら黙って捨てる」ことも
        # affordance からは知りようがなかった (実装は健全だったので、嘘ではなく沈黙)。
        maps: MAPS,
        withdrawn_maps: WITHDRAWN_MAPS,
        enrichers: ENRICHERS,
        krew_probes: KREW_PROBE_DOMAINS,
        # E317: 必須組 (multi-hook) の contract。単独では span を生まない builtin 群。
        # compile 時に SpinelEbpf::Validate が loud に強制する。
        required_sets: REQUIRED_SETS,
        # E370 (S3): packed-record チャネルの契約 (ringbuf に書く byte 像 + そこから
        # 出る OTLP 属性)。src/codegen_c/record_schema.h の生成物を読んでいるだけで、
        # offset をここで計算はしていない (単一の layout 実装 = 生成器)。
        record_channels: record_channels,
        # E397 (P011 S8): 型駆動 derived の閉じた集合。`record_channels[].consumer.
        # properties[].value_map` と `egress.attributes[].source` がここを指す。
        # これが無いと「spnl.conn.tcp_state に何が入りうるか」は probe を走らせて
        # 1 個見るまで分からず、それは `error=2` を読まされるのと同じ状態。
        record_value_maps: record_value_maps,
        # E400: histogram bucket boundaries, declared once and shared. Published so
        # that "are these comparable with an OBI / SDK histogram" is answerable
        # here instead of by diffing two C files (E272 aligned to OBI's default
        # buckets; the array is now one declaration both readers use).
        record_bounds_sets: record_bounds_sets,
        # E433: the same layouts, published in the OBJECT rather than here.
        # `record_channels` above is what a reader gets if it can run this Ruby;
        # RECORD_BTF is what it gets if all it has is the .bpf.o. Both are
        # derived from record_schema.h, so they cannot disagree -- but only one
        # of them travels with the object, and a reader that has to copy a
        # layout by hand gets it wrong silently (E432: a Go struct with every
        # field name, type and order correct read cgid = 764504178688 instead of
        # 178 on 5/5 records, because encoding/binary does not reproduce C's
        # internal padding; 29 of 64 declared fields shift that way).
        record_btf: RECORD_BTF,
        # E374 (ADR-017 D3-5): userspace consumer DSL の語彙と `to_span` の解決規則。
        # typed_channels = `on_emit :<id>` が型付き consumer になる id (それ以外は E242 named event)。
        consumer_dsl: { typed_channels: typed_record_channel_ids, verbs: CONSUMER_DSL },
        # E392 (P011 S3): the `param` surface — how a probe is narrowed WITHOUT
        # being rewritten. A probe's own parameters are per-file and live in
        # `spinel-ebpf describe`; this is the vocabulary.
        runtime_params: RUNTIME_PARAMS,
        # E399 (P011 S10): the `filter_by` surface — one declaration that narrows
        # every handler in the unit. Sits next to runtime_params because it is the
        # same .rodata mechanism with a fixed vocabulary instead of user names.
        common_filter: COMMON_FILTER,
        # E398 (P011 S9): the `keep_if` surface — the userspace half. Placed
        # immediately after common_filter because the first thing a reader (or a
        # model) has to decide is which of the two it is holding, and
        # consumer_filter.line is the answer.
        consumer_filter: CONSUMER_FILTER,
      }
    end

    # affordance を JSON 文字列 (pretty) に。
    def affordance_json
      require "json"
      JSON.pretty_generate(affordance)
    end

    # --- query API (E317: 必須組 contract) ---

    # 使用中の builtin 名集合を与え、各 REQUIRED_SET 契約の**欠けている相方**を返す。
    # 返り値: [ { name:, mode:, experiment:, present: [...], missing: [...], why: } , ... ]
    # 契約を満たす (missing 空) セットは含めない。Validate と affordance が共有。
    def missing_companions(used_names)
      used = used_names.to_a.to_set
      REQUIRED_SETS.filter_map do |rule|
        case rule[:mode]
        when :all
          present = rule[:members].select { |m| used.include?(m) }
          next if present.empty?
          missing = rule[:members] - present
          next if missing.empty?
          { name: rule[:name], mode: :all, experiment: rule[:experiment],
            present: present, missing: missing, why: rule[:why] }
        when :requires
          next unless used.include?(rule[:trigger])
          missing = rule[:requires].reject { |m| used.include?(m) }
          next if missing.empty?
          { name: rule[:name], mode: :requires, experiment: rule[:experiment],
            trigger: rule[:trigger], present: [rule[:trigger]], missing: missing, why: rule[:why] }
        end
      end
    end
  end
end
