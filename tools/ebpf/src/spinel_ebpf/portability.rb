# frozen_string_literal: true

# ADR-018 / E387: the portability contract, stated per partition.
#
# Upstream spinel's promise is "emit one self-contained .c, ship it, build it
# anywhere with any cc" (README "Portability"). Adding eBPF narrows that -- but
# it narrows it only for the *eBPF partition*. The native partition keeps the
# upstream contract verbatim (`--native-only` output is byte-identical to
# `spinel -c`; tools/form_verify.sh gates it).
#
# So the contract is not a property of the program, it is a property of each
# side of the partition. This module computes it and states it out loud, in the
# same spirit as the partition table: the reader never has to guess where a
# probe will run.
#
# The kernel floor is derived from what the generated .bpf.c actually uses.
# Entries live in MIN_KERNEL only when we are confident about the version;
# anything else lands in `undeclared` instead of inventing a number (ADR-003
# fail loud: an unknown is reported as unknown, never as a guess).
#
# The same rule governs *where the artifact can travel* (ARCH_NOTE /
# ENDIAN_NOTE below): we state the endianness the skeleton was built for, and
# we call a big-endian target untested rather than supported or broken.
module SpinelEbpf
  module Portability
    # CO-RE relocation + BTF. Every eBPF partition we emit goes through
    # BPF_CORE_READ / libbpf CO-RE, so this is the floor under all of them.
    BASE_EBPF_KERNEL = "5.2"

    # Endianness is the one axis on which eBPF bytecode is *not* neutral, and
    # the contract used to claim it was ("アーキテクチャ非依存", unqualified).
    #
    # 訂正 (2026-08-03, E403 / docs/research/ebpf_go_expressiveness_gaps.md
    # §b-8): clang has three BPF targets -- `bpf` (host byte order), `bpfel`,
    # `bpfeb` -- and upstream tooling treats the choice as a build-time axis:
    # bpf2go's default target is "bpfel,bpfeb", i.e. it always emits one object
    # per endianness (third_party/ebpf-go/cmd/bpf2go/main.go:115), and its
    # GOARCH table routes s390x / mips / mips64 / ppc64 to bpfeb
    # (third_party/ebpf-go/cmd/bpf2go/gen/target.go:16-30).
    #
    # We build with `clang -target bpf` (bin/spinel-ebpf, bpf_clang_argv), so
    # the skeleton we ship carries bytecode in the BUILD HOST's byte order.
    #
    # What we say is therefore bounded by what we know: neutrality holds within
    # one endianness, and crossing endianness is *untested* -- not "broken",
    # not "fine". That is the same discipline as UNDECLARED above: an unknown is
    # reported as unknown rather than resolved by guessing (ADR-003 fail loud).
    ARCH_NOTE = "eBPF bytecode is architecture-independent **within one endianness** " \
                "(what CO-RE absorbs at run time is the layout of kernel structs, " \
                "not the byte order of the instructions). Within that range, bundling the generated skeleton " \
                "means the target needs no clang / bpftool"

    ENDIAN_NOTE = "this skeleton is burned with `clang -target bpf` = **the build host's endianness** " \
                  "(clang's BPF targets are bpf / bpfel / bpfeb, and upstream tools " \
                  "build one per endianness — bpf2go's default target is `bpfel,bpfeb`). " \
                  "The hosts spinel-ebpf has built and run on are arm64 / x86_64 = both little-endian, and " \
                  "**distribution across endianness (big-endian s390x / mips / ppc64 and so on) is unverified** " \
                  "(not known to break, just not checked)"

    # --- arch binding (E404) -------------------------------------------------
    #
    # The endianness bound above was still not the whole story: for a subset of
    # probes portability breaks *before* endianness ever comes up, between two
    # little-endian architectures.
    #
    # Measured (E404 Step 1, arm64 host / kernel 7.1.5-ebpf / clang 19.1.7, over
    # all 118 goldens; raw data in docs/experiments/results/E404/):
    #
    #   PT_REGS_PARM or USDT   35 + 2 = 37 units   -D__TARGET_ARCH_x86 -> 0 compile
    #   neither                     81 units       -D__TARGET_ARCH_x86 -> 80 compile,
    #                                              all 80 instruction-identical to
    #                                              the arm64 build (the 81st fails
    #                                              under BOTH macros, for an
    #                                              arch-independent reason)
    #
    # Why: vmlinux.h is generated from the RUNNING kernel's BTF, so on arm64
    # `struct pt_regs` carries `regs[]` and has no `di` / `si` / `dx`.
    # PT_REGS_PARM<N> picks a FIELD NAME at preprocessing time, and CO-RE
    # relocates a field's *offset* -- it cannot conjure a field that the struct
    # does not have. So the choice is baked at compile time, not at load time.
    #
    # Two refinements the measurement forced on the initial hypothesis, both of
    # which the predicate below encodes:
    #
    #   * it is not "kprobe" that binds the arch, it is READING ARGUMENTS FROM
    #     REGISTERS. A handler on the same attach point with no parameters emits
    #     no PT_REGS_PARM and builds BYTE-IDENTICAL under both macros (measured
    #     with a matched pair through the real pipeline:
    #     results/E404/step1_noarg_kprobe.txt).
    #   * the dependency is not always visible as PT_REGS_PARM in our own
    #     output. USDT pulls in <bpf/usdt.bpf.h>, which reads `pt_regs.ip`
    #     itself, so two USDT goldens with zero PT_REGS_PARM still fail under
    #     the foreign macro.
    #
    # What we deliberately do NOT say: "this will not work on another arch".
    # What was measured is "THIS HOST cannot build it for that arch" -- the
    # behaviour of a correctly built object on its own architecture was not
    # measured, and E189 shipped a probe to a foreign machine by supplying that
    # machine's BTF (SPNL_BTF_PATH). Same discipline as UNDECLARED and
    # ENDIAN_NOTE: report the bound that was measured, not the one that would
    # sound decisive.
    ARCH_BOUND_MARKERS = {
      "PT_REGS_PARM" =>
        "reading kprobe / uprobe handler arguments from registers (`PT_REGS_PARM<N>`)",
      # Both markers describe the same binding, worded identically so that a
      # unit hitting both reports it once (the values are uniq'd, not the keys).
      "bpf_usdt_arg" =>
        "reading USDT arguments (`<bpf/usdt.bpf.h>` itself reads `pt_regs.ip`)",
      "usdt.bpf.h" =>
        "reading USDT arguments (`<bpf/usdt.bpf.h>` itself reads `pt_regs.ip`)",
    }.freeze

    # Stated when the unit IS bound: names the arch it was built for, says what
    # binds it, and says what it costs to target another one.
    def self.arch_bound_note(arch, reasons)
      "this unit is **built and verified only on #{arch}** (architecture-bound). " \
      "It uses #{reasons.join(" / ")}, which " \
      "**chooses `struct pt_regs` field names at compile time** (`vmlinux.h` comes from the running kernel's BTF. " \
      "What CO-RE can fix at run time is a field's offset; **it cannot create a field that is not there**). " \
      "Measured (E404, arm64 host): building the same source with `-D__TARGET_ARCH_x86` " \
      "**does not compile**: `no member named '…' in 'struct pt_regs'` (di/si/dx for `PT_REGS_PARM`, ip for USDT). " \
      "To distribute it for another architecture, **rebuild it with that architecture's BTF**. " \
      "**It is not known not to run on another architecture** — what was measured is only \"it cannot be built on this host\", " \
      "and the behaviour with the right BTF was not measured (E189 demonstrated distribution that brings " \
      "another machine's BTF with `SPNL_BTF_PATH`)"
    end

    # Stated when it is NOT bound: the same portability the contract used to
    # claim for everything, now claimed only where it was measured.
    ARCH_FREE_NOTE = "this unit **does not read arguments through registers** " \
                     "(no `PT_REGS_PARM` / USDT) ⇒ it is not bound to an architecture. " \
                     "Measured: all 80 applicable goldens **built with both `-D__TARGET_ARCH_arm64` and " \
                     "`-D__TARGET_ARCH_x86`, with identical instructions** (E404). " \
                     "The only remaining limit is the endianness below"

    Feature = Struct.new(:key, :kernel, :why, keyword_init: true)

    # marker (matched against the generated .bpf.c) => Feature
    MIN_KERNEL = {
      "bpf_ringbuf_reserve" =>
        Feature.new(key: "ringbuf", kernel: "5.8", why: "BPF ring buffer (the carrier of spnl_emit*)"),
      'SEC("xdp' =>
        Feature.new(key: "xdp", kernel: "5.9", why: "attaching XDP with bpf_link (does not replace an existing program; detached automatically even on SIGKILL)"),
      'SEC("tcx/' =>
        Feature.new(key: "tcx", kernel: "6.6", why: "TC attach with tcx (bpf_mprog) — coexists with existing programs"),
      'SEC("fentry/' =>
        Feature.new(key: "fentry", kernel: "5.5", why: "fentry through the BPF trampoline"),
      'SEC("fexit/' =>
        Feature.new(key: "fexit", kernel: "5.5", why: "fexit through the BPF trampoline"),
      'SEC("fmod_ret/' =>
        Feature.new(key: "fmod_ret", kernel: "5.6", why: "fmod_ret (replacing the return value = blocking)"),
      'SEC("lsm/' =>
        Feature.new(key: "lsm", kernel: "5.7", why: "BPF LSM"),
      # E401: kprobe_multi は 1 prog + 1 link で数千シンボルに attach する代わりに
      # 下限を素の kprobe (5.2) から 5.18 に上げる。E401 が実測で見つけたのは、
      # この行が無いと multi の probe が `>= 5.8` (ringbuf 由来) と申告することだった
      # ——**過少申告**であり、契約が絶対に外してはいけない方向 (E404)。
      # `via: :expand` を選べば下限は 5.2 のままなので、これは機構の選択が
      # 配備の制約を動かす唯一の例でもある。
      'SEC("kprobe.multi' =>
        Feature.new(key: "kprobe_multi", kernel: "5.18",
                    why: "kprobe_multi (one definition -> several symbols, per-symbol cookie)"),
      'SEC("iter/' =>
        Feature.new(key: "bpf_iter", kernel: "5.8", why: "BPF_ITER (enumerating kernel objects)"),
      'SEC("sk_lookup' =>
        Feature.new(key: "sk_lookup", kernel: "5.9", why: "sk_lookup programs"),
      "bpf_loop" =>
        Feature.new(key: "bpf_loop", kernel: "5.17", why: "bpf_loop (n.times with a dynamic count)"),
      "bpf_iter_num_new" =>
        Feature.new(key: "open_coded_iter", kernel: "6.4", why: "open-coded iterator (n.times with a literal count)"),
      # Two unrelated surfaces reach this marker and the `why` has to name both,
      # or a slice author reads "on :timer" and concludes the line is not about
      # their probe: `on :timer` (E079/E411) arms one timer in an ARRAY slot at
      # load time; the pure-XDP TCP slice (E057/E416) embeds one per CONNECTION
      # in the LRU_HASH value and arms it from BPF. Same struct, same floor.
      "bpf_timer_init" =>
        Feature.new(key: "bpf_timer", kernel: "5.15",
                    why: "bpf_timer (on :timer / the TCP slice's per-connection TTL)"),
      "bpf_user_ringbuf_drain" =>
        Feature.new(key: "user_ringbuf", kernel: "6.1", why: "USER_RINGBUF (the host -> kernel command channel)"),
      "bpf_task_storage_get" =>
        Feature.new(key: "task_storage", kernel: "5.11", why: "task local storage"),
      "bpf_d_path" =>
        Feature.new(key: "d_path", kernel: "5.10", why: "bpf_d_path (getting the full path)"),
      # E063/E412: bpf_tail_call + PROG_ARRAY. This entry can never BE the floor:
      # every program that can hold either is an XDP program, so SEC("xdp" (5.9)
      # always dominates. It is here as a record, not as a constraint -- E401
      # measured what a MISSING marker costs (a multi-symbol probe declaring 5.8
      # when it needed 5.18, i.e. under-reporting, the one direction the contract
      # may never take), and the cheap defence is to state the floor of every
      # feature rather than only the ones expected to win.
      "BPF_MAP_TYPE_PROG_ARRAY" =>
        Feature.new(key: "prog_array", kernel: "4.2",
                    why: "bpf_tail_call + PROG_ARRAY (control transfer to xdp_tail__)"),
      # E043/E413: SO_REUSEPORT selection. Like PROG_ARRAY above, this entry can
      # never BE the floor -- 4.19 is below BASE_EBPF_KERNEL (5.2) -- and it is
      # here for the same reason: E401 measured what a MISSING marker costs
      # (under-reporting, the one direction the contract may never take), so the
      # cheap defence is to state every feature's floor rather than only the ones
      # expected to win. BPF_PROG_TYPE_SK_REUSEPORT, the SOCKARRAY it selects
      # from and bpf_sk_select_reuseport all arrived together in 4.19; the older
      # SO_ATTACH_REUSEPORT_EBPF (4.5) took a SOCKET_FILTER program, which is a
      # different thing and is not what this codegen emits.
      'SEC("sk_reuseport' =>
        Feature.new(key: "sk_reuseport", kernel: "4.19",
                    why: "BPF_PROG_TYPE_SK_REUSEPORT (selection in an SO_REUSEPORT group)"),
      "BPF_MAP_TYPE_REUSEPORT_SOCKARRAY" =>
        Feature.new(key: "reuseport_sockarray", kernel: "4.19",
                    why: "REUSEPORT_SOCKARRAY + bpf_sk_select_reuseport (worker_select's target table)"),
      # E051-E054/E416: the pure-XDP TCP slice. The two raw SYN-cookie kfuncs
      # arrived together in 6.8, which makes this the HIGHEST floor any generated
      # program carries -- higher than SEC("xdp") (5.9), higher than the bpf_timer
      # (5.15) the slice also embeds, and higher than USER_RINGBUF (6.1), which
      # was the previous ceiling. So unlike PROG_ARRAY and REUSEPORT_SOCKARRAY
      # above, this entry is not a record: on a slice probe it IS the floor.
      #
      # Two markers rather than one because the seven builtins can be used
      # WITHOUT the bundle (the hand-written `ruby_slice.rb` surface): whichever
      # of the two appears, the frame is being handed to a raw syncookie kfunc.
      "bpf_tcp_raw_gen_syncookie_ipv4" =>
        Feature.new(key: "tcp_raw_syncookie", kernel: "6.8",
                    why: "bpf_tcp_raw_gen_syncookie_ipv4 (the pure-XDP TCP slice's handshake)"),
      "bpf_tcp_raw_check_syncookie_ipv4" =>
        Feature.new(key: "tcp_raw_syncookie", kernel: "6.8",
                    why: "bpf_tcp_raw_check_syncookie_ipv4 (the pure-XDP TCP slice's handshake)"),
      "BPF_MAP_TYPE_ARENA" =>
        Feature.new(key: "arena", kernel: "6.9", why: "bpf_arena (shared memory)"),
      "sched_ext_ops" =>
        Feature.new(key: "sched_ext", kernel: "6.12", why: "sched_ext (CPU scheduler)"),
    }.freeze

    # Features whose minimum we have not established. Reported by name so the
    # reader knows the floor below is a lower bound, not the whole story.
    UNDECLARED = {
      "Qdisc_ops"           => "BPF qdisc (struct_ops/Qdisc_ops)",
      "tcp_congestion_ops"  => "TCP congestion control (struct_ops/tcp_congestion_ops)",
      # E412: the shipped shape puts `bpf_tail_call` inside `<name>_inner`, a
      # `static __noinline` function -- the kernel's own xlated dump confirms it
      # is a real BPF-to-BPF subprogram (`call pc+2#..._inner`, then the tail call
      # at insn 39 inside it) and not something clang inlined away. Mixing bpf2bpf
      # calls with tail calls is a LATER and per-arch-JIT capability than
      # PROG_ARRAY itself (4.2, declared above), so the 4.2 line is the floor of
      # the feature and NOT the floor of this shape. Measured: works on
      # 7.1.5-ebpf / aarch64 (results/E412/e2e_tail_call.txt: 17 of 20 packets
      # jumped). The exact kernel where it started working is not established
      # here, so it is reported as unknown rather than guessed (ADR-003).
      "bpf_tail_call"       => "bpf_tail_call from a subprogram (`_inner`) — " \
                               "later than PROG_ARRAY's own 4.2, and needs per-architecture JIT support " \
                               "(measured on 7.1.5/aarch64; the floor was not measured)",
    }.freeze

    # Runtime conditions that no compile-time check can settle -- the probe
    # loads and attaches, and then does or does not fire. E4 (the silent LSM)
    # is exactly this class, so it is stated here rather than discovered.
    RUNTIME_CAVEATS = {
      'SEC("lsm/' =>
        "BPF LSM needs `lsm=...,bpf` at kernel boot. Where it is disabled, load and attach still succeed, " \
        "**only the firing does not happen** (a silent failure). To make it take effect for sure, use fmod_ret",
      'SEC("xdp' =>
        "if another XDP program is on the target interface, attach fails loudly with EBUSY " \
        "(it does not replace the existing one). Name the target with SPNL_XDP_IFACE",
      'SEC("tcx/' =>
        "name the target interface with SPNL_TCX_IFACE (it is tcx, so it coexists with existing programs)",
      # E413: two runtime facts, and the second is the reason D3 needed a
      # directed measurement rather than a distribution.
      'SEC("sk_reuseport' =>
        "the loader does not attach — the probe itself creates the SO_REUSEPORT listen socket, so " \
        "the probe's userspace side must call `sp_bpf_reuseport_attach(listen_fd, \"sk_reuseport__<name>\")`. " \
        "Without that call the prog is only loaded and **never fires**",
      # E061/E414: two runtime facts about the host->kernel channel, and both are
      # silent. The first is the one E061's own verification method happened to
      # catch without knowing it (count AND last value, not count alone).
      "bpf_user_ringbuf_drain" =>
        "**a record is a fixed 8 bytes** — the generated callback reads `sizeof(__s64)` with `bpf_dynptr_read`. " \
        "If your own pusher (code that drives libbpf's reserve/submit directly) sends a shorter record, " \
        "**the callback fires and the count grows, but only the value becomes 0** (`bpf_dynptr_read` returns -E2BIG and " \
        "gives up silently, E414 measured). A check that looks only at the count lets this failure through, so look at **both the count and the value**. " \
        "The bundled `sp_bpf_user_cmd_push(value)` avoids this hole. " \
        "Also, **if nobody pushes, drain just returns 0 records**, which is silent too " \
        "(\"no command has come\" and \"the sender is broken\" cannot be told apart from the probe's output)",
      "bpf_sk_select_reuseport" =>
        "even when the named slot is empty (no worker called `sp_bpf_reuseport_register` with that index) " \
        "**it is not an error** — the kernel silently falls back to the default 5-tuple spread ⇒ " \
        "\"BPF chose\" and \"BPF did not choose and the kernel did\" cannot be told apart from where connections go. " \
        "To check, request **a skew** the default spread cannot produce and measure it (E413 D3)",
    }.freeze

    Contract = Struct.new(:native, :ebpf, :gpu, keyword_init: true)

    # --- E470 (ADR-018 の GPU 形): gpu-metal 側の契約 -------------------------
    #
    # MIN_KERNEL と同じ規則: 契約の各行は**生成された .metal が実際に使っている
    # 機能**から導出し、そのマーカーを名指しする。probe への手貼り属性は無い。
    # 「実測した」と「未検証」を混ぜない (ADR-003 / E403 の訂正と同じ姿勢):
    # 実測は Apple silicon (M1 Max) のみで、それ以外の GPU は「壊れる」ではなく
    # 「未検証」と書く。
    GpuFeature = Struct.new(:key, :note)
    GPU_FEATURES = {
      "atomic_fetch_add_explicit" => GpuFeature.new(
        "device atomics",
        "atomic_int (32-bit — MSL has no 64-bit integer device atomics). Keep the values the host writes below 2^31"
      ),
      "threadgroup_barrier(" => GpuFeature.new(
        "threadgroup cooperation (barrier)",
        "the shim fixes the dispatch width at min(maxTotalThreadsPerThreadgroup, 256). The cooperative tree kernel " \
        "assumes full groups = n must be a multiple of that width"
      ),
      "threadgroup float" => GpuFeature.new(
        "threadgroup shared array (float)",
        "one instance per threadgroup. Not visible from the host (no accessor is generated)"
      ),
      "threadgroup __s64" => GpuFeature.new(
        "threadgroup shared array (int64)",
        "one instance per threadgroup. Not visible from the host (no accessor is generated)"
      ),
      # const 有無で署名の綴りが変わる (入力 = const、出力 = 非 const) ので両方を
      # 同じ feature に写す。gpu_contract が key で dedupe する。
      "device const float" => (FLOAT_LANE = GpuFeature.new(
        "float32 lane",
        "the GPU is float32 / the bundled oracle is double. The shipped tolerance is rel 1e-5 " \
        "(measured: over 1e-6 in 0/4096 on an 8-step dependency chain — two orders of magnitude of margin)"
      )),
      "device float" => FLOAT_LANE,
      "device const __s64" => (INT_LANE = GpuFeature.new(
        "int64 lane",
        "integers stay integers end to end (the :long FFI lane). Exact even beyond 2^53 (measured in the range that always breaks through double)"
      )),
      "device __s64" => INT_LANE,
    }.freeze

    GPU_CONTRACT_STATIC = {
      "platform" => "macOS + Metal. Measured on Apple silicon (M1 Max) — other GPUs are unverified (not \"broken\")",
      "artifact" => ".metal is MSL text — compiled at run time with MTLDevice.makeLibrary " \
                    "(no offline Metal toolchain needed. Distributed as text, so ISA-independent)",
      "host_side" => "this unit's native side is not plain POSIX: it needs Metal.framework + an ObjC shim " \
                     "(module GPU, tools/metal/examples/lib) = macOS only (the GPU exception to the native contract)",
      "buffer_abi" => "[[buffer(N)]] slots are declared literals / lane widths are f=float32(4B) l=int64(8B) " \
                      "a=atomic int32(4B) / MTLResourceStorageModeShared",
    }.freeze

    # gpu-metal unit の契約。metal_source が空なら nil (この unit に GPU 部は無い)。
    def self.gpu_contract(metal_source)
      src = metal_source.to_s
      return nil if src.empty?
      reasons = GPU_FEATURES.select { |marker, _| src.include?(marker) }.values.uniq { |f| f.key }
      GPU_CONTRACT_STATIC.merge(
        "reasons" => reasons.map { |f| { "feature" => f.key, "note" => f.note } }
      )
    end

    # native side: upstream spinel's contract, verbatim.
    NATIVE_CONTRACT = {
      "platform"  => "POSIX (Linux / macOS / *BSD)",
      "toolchain" => "any C compiler (gcc / clang)",
      "note"      => "upstream spinel's portability as it is. --native-only's output is byte-identical to `spinel -c`",
    }.freeze

    # The architecture the eBPF object is being built for. Mirrors exactly how
    # bin/spinel-ebpf (bpf_clang_argv) picks -D__TARGET_ARCH_*, so the contract
    # names the arch the compiler was actually told about rather than a guess.
    def self.build_arch
      RbConfig::CONFIG["host_cpu"].to_s =~ /aarch64|arm64/ ? "arm64" : "x86_64"
    end

    # Compute the contract for one compiled unit.
    #
    # bpf_c_source: the generated .bpf.c text ("" / nil when the unit has no
    # eBPF partition, in which case only the native contract applies).
    # build_arch: overridable so the contract can be exercised for an arch other
    # than the one running the tests.
    def self.contract(bpf_c_source, build_arch: self.build_arch, gpu_metal_source: nil)
      # E470: a gpu-metal unit has no eBPF side; its contract is native (with
      # the macOS exception stated inside) + the gpu block derived from the
      # generated .metal.
      if (g = gpu_contract(gpu_metal_source))
        return Contract.new(native: NATIVE_CONTRACT, ebpf: nil, gpu: g)
      end
      src = bpf_c_source.to_s
      return Contract.new(native: NATIVE_CONTRACT, ebpf: nil) if src.empty?

      hits = MIN_KERNEL.select { |marker, _| src.include?(marker) }.values
      floor = ([BASE_EBPF_KERNEL] + hits.map(&:kernel)).max_by { |v| version_key(v) }
      caveats = RUNTIME_CAVEATS.select { |marker, _| src.include?(marker) }.values
      undeclared = UNDECLARED.select { |marker, _| src.include?(marker) }.values

      # E404: derived from the generated source, like every other line of this
      # contract -- never a hand-applied attribute on the probe.
      bound_by = ARCH_BOUND_MARKERS.select { |marker, _| src.include?(marker) }.values.uniq

      ebpf = {
        "platform"    => "Linux only",
        "min_kernel"  => floor,
        "requires"    => [
          "BTF (CONFIG_DEBUG_INFO_BTF=y) — CO-RE relocates to kernel structs at run time",
          "root or CAP_BPF / CAP_PERFMON",
        ],
        "reasons"     => hits.sort_by { |f| [version_key(f.kernel), f.key] }.reverse
                             .map { |f| { "feature" => f.key, "kernel" => f.kernel, "why" => f.why } },
        "caveats"     => caveats,
        "undeclared"  => undeclared,
        "arch_note"   => ARCH_NOTE,
        "endian_note" => ENDIAN_NOTE,
        # --- appended by E404; the keys above keep their meaning unchanged ---
        "build_arch"     => build_arch,
        "arch_bound"     => !bound_by.empty?,
        "arch_bound_by"  => bound_by,
        "arch_unit_note" => bound_by.empty? ? ARCH_FREE_NOTE : arch_bound_note(build_arch, bound_by),
      }
      Contract.new(native: NATIVE_CONTRACT, ebpf: ebpf)
    end

    def self.version_key(v)
      v.split(".").map(&:to_i)
    end

    # Human-readable block, printed right after the partition table so that
    # "which side does this run on" and "what does that side require" are read
    # together.
    def self.human(contract)
      out = []
      out << "## portability contract"
      out << "   native  : #{contract.native["platform"]} / #{contract.native["toolchain"]}"
      if (e = contract.ebpf)
        out << "   eBPF    : #{e["platform"]} / kernel >= #{e["min_kernel"]} + BTF + root(CAP_BPF)"
        e["reasons"].each { |r| out << "             - #{r["kernel"]}: #{r["feature"]} — #{r["why"]}" }
        unless e["undeclared"].empty?
          e["undeclared"].each { |u| out << "             - (floor not settled) #{u}" }
        end
        # Where the artifact can travel belongs next to which kernel it needs:
        # both answer "what does shipping this cost me". Endianness is stated
        # every time, because it is a property of the emitted bytecode itself
        # and not of the features the probe happens to use.
        # E404: the verdict for THIS unit goes on the `arch` line, and the
        # general property of bytecode is demoted below it. The other order was
        # tried and rejected: a reader (or an AI) who stops after the first line
        # would come away with "アーキテクチャ非依存" from a unit that cannot
        # even be built for another arch. `!` marks the bound case as a cost,
        # the same convention the caveats use.
        out << "   arch    : #{e["arch_bound"] ? "! " : ""}#{e["arch_unit_note"]}"
        out << "             (in general) #{e["arch_note"]}"
        out << "   ! #{e["endian_note"]}"
        e["caveats"].each { |c| out << "   ! #{c}" }
      elsif (g = contract.gpu)
        # E404 の並び規則: この unit の判定 (native 行への例外) を一般論より先に。
        # native 行の「POSIX」をそのまま読んで離脱した読者が、macOS でしか動かない
        # unit を可搬だと思い込むのを防ぐ。
        out << "   ! #{g["host_side"]}"
        out << "   GPU     : #{g["platform"]}"
        out << "             #{g["artifact"]}"
        out << "   ABI     : #{g["buffer_abi"]}"
        g["reasons"].each { |r| out << "             - #{r["feature"]} — #{r["note"]}" }
      else
        out << "   eBPF    : (none — this unit is entirely native)"
      end
      out.join("\n")
    end

    def self.to_h(contract)
      { "native" => contract.native, "ebpf" => contract.ebpf, "gpu" => contract.gpu }
    end
  end
end
