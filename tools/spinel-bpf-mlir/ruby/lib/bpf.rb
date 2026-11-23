# bpf — spinel-bpf-mlir の eBPF の側の API (P001 §1・§2)。
#
# eBPF の側の関数 (BPF.xdp で宣言した def) の中でだけ意味を持つ。spinelbpf の frontend が呼び先 (Spinel の推論の codegen の callee) を
# この file の def に照合して ebpf dialect の op に写す (P001 §3.1 — 名前ではなく file で固定)。
# user 空間で eBPF の側の method を呼ぶと、build では frontend が SB003 で止め、実行では BPF.ebpf_only が名指しで raise する。
# stub は常に raise する形にしない — Spinel がそれを見抜くと後の文を到達しないと見なし型が消える (P001 の起草の probe)。
module BPF
  XDP_ABORTED = 0
  XDP_DROP = 1
  XDP_PASS = 2
  XDP_TX = 3

  # sched_cls (tcx) の判定 (P019 E076 — 値は UAPI の TC_ACT_OK / TC_ACT_SHOT = tcx_action_base の TCX_PASS / TCX_DROP)。XDP の定数と混ぜない (frontend が SB028)
  TC_PASS = 0
  TC_DROP = 2

  # socket_filter の判定 (P026 E126 — keep は u32 の最大 (全 byte を受ける) を int32 で読んだ −1 — test run の retval と同じ綴り、drop は 0)。他の kind の定数と混ぜない (frontend が SB028)
  SF_KEEP = -1
  SF_DROP = 0

  # cgroup_skb の判定 (P026 E127 — allow は 1 (送る / 受ける)、deny は 0 (落とす — egress の送り手には EPERM))。egress だけの cn (2 / 3) は無い。他の kind の定数と混ぜない (frontend が SB028)
  CG_ALLOW = 1
  CG_DENY = 0

  # netfilter の判定 (P026 E128 — Linux の NF_ACCEPT 1 / NF_DROP 0 — LOCAL_OUT の drop は送り手に EPERM)。他の kind の定数と混ぜない (frontend が SB028)
  NF_ACCEPT = 1
  NF_DROP = 0

  # fmod_ret の戻り値 (P028 E144 — 0 は元の関数を呼ぶ)。値の差し替えは `BPF.fmod_return(e)` (e は区間で 0 を含まない — frontend が SB014)。
  # 暗黙の最後の式の整数は受けない (frontend が SB008)。他の kind の定数と混ぜない (frontend が SB028)
  FMOD_CALL = 0

  # flow_dissector の判定 (P026 E130 — BPF_OK 0・BPF_DROP 2・BPF_FLOW_DISSECTOR_CONTINUE 129)。他の kind の定数と混ぜない (frontend が SB028)
  FLOW_OK = 0
  FLOW_DROP = 2
  FLOW_CONTINUE = 129

  # sk_lookup の判定 (P026 E129 — SK_DROP 0・SK_PASS 1)。他の kind の定数と混ぜない (frontend が SB028)
  SK_PASS = 1
  SK_DROP = 0

  # hash の系の map の書きの status (負の errno — status と直接比べる。値は Linux の errno — P008 §2、試験が CRuby の Errno と照合)
  ENOENT = -2
  E2BIG = -7
  ENOMEM = -12
  EEXIST = -17

  def self.ebpf_only(what)
    if what.length > 0
      raise "#{what} is eBPF-side only (call it inside a BPF.xdp program)"
    end
    0
  end

  # xdp の context (xdp_md)。読みは `w = ctx.check(off, len)` の直後の `if w` の中の window だけ (P004 §1 — 検査の無い読みは API に無い)。
  class XdpMd
    # packet の [off, off + len) を検査する。範囲の中なら Window、外なら nil (`if w` で分ける)。len は Integer の literal。
    def check(off, len)
      if BPF.ebpf_only("BPF::XdpMd#check") == 0
        return Window.new
      end
      nil
    end

    # xdp_md の ingress_ifindex (u32 — P026 E120、能力の表の xdp の行は読みだけ)
    def ingress_ifindex
      BPF.ebpf_only("BPF::XdpMd#ingress_ifindex")
    end

    # packet の先頭を d byte 動かす (P026 E122 — 正は縮め負は伸ばす、status は 0 か −errno)。`st = ctx.adjust_head(d)` か `_ = …` を program の本体の直下の文だけ
    # (動かした後の packet は新しい `ctx.check` で読み直す)
    def adjust_head(d)
      BPF.ebpf_only("BPF::XdpMd#adjust_head")
    end

    # packet の末尾を縮める (P026 E123 — k は 0 以下の Integer の literal だけ、status は 0 か −errno)。adjust_head と同じく本体の直下の文だけ
    def adjust_tail(k)
      BPF.ebpf_only("BPF::XdpMd#adjust_tail")
    end
  end

  # sched_cls (tcx) の context (__sk_buff — P019 E076)。読みは XdpMd と同じ `w = skb.check(off, len)` の直後の `if w` の中の window だけ
  # (bpf-mlir の sched_cls の window は読みだけ — Window に書きの API は無い)。
  class SkBuff
    def check(off, len)
      if BPF.ebpf_only("BPF::SkBuff#check") == 0
        return Window.new
      end
      nil
    end

    # __sk_buff の len と mark (u32 — P026 E120)。mark は書ける (`skb.mark = v` の文だけ — v の区間は u32、外は SB014)
    def len
      BPF.ebpf_only("BPF::SkBuff#len")
    end

    def mark
      BPF.ebpf_only("BPF::SkBuff#mark")
    end

    def mark=(v)
      BPF.ebpf_only("BPF::SkBuff#mark=")
    end
  end

  # global 変数 (P014 E057 — frontend が読む。実行では eBPF の側だけ)。
  #   X = BPF::Config.new("X", :u16)          .rodata — load の時に必ず値 (無ければ SpinelBPF::ConfigNotSet)
  #   X = BPF::OptionalConfig.new("X", :u8)   .rodata — load の時に無ければ 0
  #   X = BPF::Counter.new("X", :u64)         .bss — :u32 / :u64 / :i32 / :i64、eBPF の側の add(d) は atomic (u32 / u64 は i32 / i64 の atomic_add で bits は同じ —
  #                                            読みの符号は user の側の型)。counter は load から単調 (幅で wrap) — 0 にするのは load し直し
  class Config
    def initialize(name, type)
      @name = name
      @type = type.to_s
    end

    # global_name / global_type は user 空間の library が読む (名前と型の名前 — P014 E058)
    def global_name
      @name
    end

    def global_type
      @type
    end

    def value
      BPF.ebpf_only("BPF::Config#value")
    end
  end

  class OptionalConfig
    def initialize(name, type)
      @name = name
      @type = type.to_s
    end

    # global_name / global_type は user 空間の library が読む (名前と型の名前 — P014 E058)
    def global_name
      @name
    end

    def global_type
      @type
    end

    def value
      BPF.ebpf_only("BPF::OptionalConfig#value")
    end
  end

  class Counter
    def initialize(name, type)
      @name = name
      @type = type.to_s
    end

    # global_name / global_type は user 空間の library が読む (名前と型の名前 — P014 E058)
    def global_name
      @name
    end

    def global_type
      @type
    end

    def value
      BPF.ebpf_only("BPF::Counter#value")
    end

    def add(d)
      BPF.ebpf_only("BPF::Counter#add")
    end
  end

  # tracing の context (P013 E051)。fentry は読める物が無い (helper だけ)、fexit は ctx.ret (宣言の ret の型)、kprobe は ctx.arg(n) (宣言の params の n と型)。
  # fentry の context (P013 E051)。E089 (P021): `args:` で宣言した struct の引数は `q = ctx.kptr_or_null(i, T)` と直後の `if q` (fentry の
  # pointer は常に NULL でありうる)。P026 E117: 整数の引数は `ctx.arg(i)` (宣言の型 — bpf-mlir E530)。
  class FentryCtx
    def arg(i)
      BPF.ebpf_only("BPF::FentryCtx#arg")
    end

    def kptr_or_null(i, t)
      if BPF.ebpf_only("BPF::FentryCtx#kptr_or_null") == 0
        return KPtr.new(t.sample)
      end
      nil
    end
  end

  class FexitCtx
    def ret
      BPF.ebpf_only("BPF::FexitCtx#ret")
    end
  end

  # fmod_ret の context (P028 E144): 整数の引数は `ctx.arg(i)` (宣言の型 — fentry と同じ ebpf.ctx.arg)
  class FmodRetCtx
    def arg(i)
      BPF.ebpf_only("BPF::FmodRetCtx#arg")
    end
  end

  class KprobeCtx
    def arg(n)
      BPF.ebpf_only("BPF::KprobeCtx#arg")
    end

    # P026 E116: `v, st = ctx.read(n, offset, :type)` — :ptr の引数 n の先の offset の固定幅の値と raw の status (成功 0・失敗は負で値 0)
    def read(n, offset, type)
      z = BPF.ebpf_only("BPF::KprobeCtx#read")
      [z, z] # 型は Integer の 2 つの Array (多重代入の右辺)
    end
  end

  # uretprobe の context (P026 E112)。ctx.ret は target の関数の戻り値の register (宣言の ret: の幅)
  class UretprobeCtx
    def ret
      BPF.ebpf_only("BPF::UretprobeCtx#ret")
    end
  end

  # ksyscall の context (P026 E115)。ctx.arg(n) は宣言の params の syscall の第 n 引数 (1 始まり — syscall の規約、4 番目は r10)
  class KsyscallCtx
    def arg(n)
      BPF.ebpf_only("BPF::KsyscallCtx#arg")
    end

    # P028 E143: :user_str の引数 (const char *) — R.output_str の第 3 引数だけ (uprobe の str_arg と同じ)
    def str_arg(n)
      if BPF.ebpf_only("BPF::KsyscallCtx#str_arg") == 0
        return UserStr.new
      end
      UserStr.new
    end

    # P028 E151: :user_str_array の引数 (argv) — R.output_argv の第 3 引数だけ
    def argv_arg(n)
      if BPF.ebpf_only("BPF::KsyscallCtx#argv_arg") == 0
        return UserStrArray.new
      end
      UserStrArray.new
    end
  end

  # tracepoint の context (P026 E114)。ctx.field(:name) は宣言の fields の event の field (宣言の型 — offset と型は load の前に tracefs と照合)
  class TracepointCtx
    def field(name)
      BPF.ebpf_only("BPF::TracepointCtx#field")
    end

    # P028 E142: :user_str の field (char *) — R.output_str の第 3 引数だけ (uprobe の str_arg と同じ)
    def str_field(name)
      if BPF.ebpf_only("BPF::TracepointCtx#str_field") == 0
        return UserStr.new
      end
      UserStr.new
    end

    # P028 E151: :user_str_array の field (char ** — argv) — R.output_argv の第 3 引数だけ
    def argv_field(name)
      if BPF.ebpf_only("BPF::TracepointCtx#argv_field") == 0
        return UserStrArray.new
      end
      UserStrArray.new
    end

    # P029 E153: 固定 byte の配列の field (`[off, [:u8, N]]`) の写し — R.output の S.new の配列の member の引数か `r.load.m = ctx.copy(:f)` だけ (t.copy と同じ)
    def copy(name)
      BPF.ebpf_only("BPF::TracepointCtx#copy")
      Array.new(0, 0)
    end
  end

  # raw_tp の context (P026 E113)。ctx.arg(i) は tracepoint の args[i] (0 始まり・0..11 の literal) — 型は常に u64 (kernel は照合しない)
  class RawTpCtx
    def arg(i)
      BPF.ebpf_only("BPF::RawTpCtx#arg")
    end
  end

  # kretprobe の context (P026 E111)。ctx.ret は関数の戻り値の register (宣言の ret: の幅 — kernel は型を照合しない)
  class KretprobeCtx
    def ret
      BPF.ebpf_only("BPF::KretprobeCtx#ret")
    end
  end

  # cgroup_skb の context (__sk_buff — P026 E127)。読みは SkBuff と同じ `w = skb.check(off, len)` の直後の `if w` の中の window (読みだけ) と skb.len (u32)。
  # **packet は network header から** (eth の header は無い — window の offset 0 は IPv4 の header の先頭)。
  class CgroupSkb
    def check(off, len)
      if BPF.ebpf_only("BPF::CgroupSkb#check") == 0
        return Window.new
      end
      nil
    end

    def len
      BPF.ebpf_only("BPF::CgroupSkb#len")
    end
  end

  # socket_filter の context (__sk_buff — P026 E126)。読めるのは ctx.len (packet の長さ — u32) だけ (bpf-mlir v1.14.0 の socket_filter は packet を持たない)。
  class SocketFilterCtx
    def len
      BPF.ebpf_only("BPF::SocketFilterCtx#len")
    end
  end

  # uprobe の context (P020 E080)。ctx.arg(n) は宣言の params の整数の引数、ctx.str_arg(n) は :user_str の引数 (BPF::UserStr — 整数と別の型:
  # 1 つの method の戻り値の型を 1 つに保つ)。str_arg は RingBuf#output_str の第 3 引数にだけ置ける。
  class UprobeCtx
    def arg(n)
      BPF.ebpf_only("BPF::UprobeCtx#arg")
    end

    def str_arg(n)
      if BPF.ebpf_only("BPF::UprobeCtx#str_arg") == 0
        return UserStr.new
      end
      UserStr.new
    end

    # P029 E158: :user_buf の引数 (BPF::UserBuf — 整数と別の型) — RingBuf#output_buf の第 3 引数だけ
    def buf_arg(n)
      if BPF.ebpf_only("BPF::UprobeCtx#buf_arg") == 0
        return UserBuf.new
      end
      UserBuf.new
    end
  end

  # CO-RE の kernel の struct の型の見本 (P021 E086 — `TaskT = BPF::KernelType.new(Task.new(0, …))`)。frontend は宣言 (BPF.kernel_type) から型を決め、
  # 見本は Spinel の型付け (KPtr#load の戻り値の型) のため (R003 §2)。
  class KernelType
    def initialize(sample)
      @sample = sample
    end

    def sample
      @sample
    end
  end

  # kernel の struct への pointer (P021 E086)。`t.load.m` で整数の field (CO-RE — ebpf.kfield.load)、`t.ptr(:m, T)` で pointer の field (nullable —
  # 段 B)、`t.copy(:m)` で配列の field の写し (段 C)。値としては使えない (frontend が止める)。
  class KPtr
    def initialize(value)
      @value = value
    end

    def load
      BPF.ebpf_only("BPF::KPtr#load")
      @value
    end

    def ptr(field, t)
      if BPF.ebpf_only("BPF::KPtr#ptr") == 0
        return KPtr.new(t.sample)
      end
      nil
    end

    def copy(field)
      BPF.ebpf_only("BPF::KPtr#copy")
      Array.new(0, 0)
    end

    # P029 E155: 検査済みの kernel pointer の address の全 64 bit (bpf-mlir E554 の ebpf.kptr.addr) — map の key・event・比較の整数。
    # pointee を読まない、整数から pointer には戻せない、free の後の再利用を区別しない
    def addr
      BPF.ebpf_only("BPF::KPtr#addr")
      0
    end

    # P026 E118: `:strptr` の field (char *) の先の kernel の文字列 — RingBuf#output_str の 3 番目の引数にだけ置ける (ebpf.kernel.read_str)
    def str(field)
      if BPF.ebpf_only("BPF::KPtr#str") == 0
        return UserStr.new
      end
      UserStr.new
    end
  end

  # tp_btf の context (P021 E086)。`ctx.kptr(i, T)` は非 null の struct の引数、`ctx.kptr_or_null(i, T)` は nullable (段 B — 直後の `if`)、
  # `ctx.arg(i)` は整数の引数 (型は BPF.tp_btf の args の宣言)。
  # flow_dissector の context (__sk_buff — P026 E130)。packet は `w = ctx.check(off, len)` の直後の `if w` の中の window (読みだけ — data は eth の header から)、
  # 出力は flow_keys の field: 読み `ctx.key(:f)` / `ctx.key(:ipv6_src, i)`、書き `ctx.set_key(:f, v)` / `ctx.set_key(:ipv6_src, i, v)` の文
  # (f は struct bpf_flow_keys の field の Symbol、address・port は network order の raw — byte の並びのまま、変換しない)。
  class FlowCtx
    def check(off, len)
      if BPF.ebpf_only("BPF::FlowCtx#check") == 0
        return Window.new
      end
      nil
    end

    def key(f, i = 0)
      BPF.ebpf_only("BPF::FlowCtx#key")
    end

    def set_key(f, a, b = 0)
      BPF.ebpf_only("BPF::FlowCtx#set_key")
      nil
    end
  end

  # netfilter の context (bpf_nf_ctx — P026 E128)。`st = ctx.state(T)` (nf_hook_state) と `sk = ctx.skb(T)` (sk_buff) — program の本体の直下の文で束ね、
  # 読みは `st.load.hook` 等 (BPF.kernel_type の宣言の member — CO-RE)。packet の window は無い。
  class NfCtx
    def state(t)
      BPF.ebpf_only("BPF::NfCtx#state")
      KPtr.new(t.sample)
    end

    def skb(t)
      BPF.ebpf_only("BPF::NfCtx#skb")
      KPtr.new(t.sample)
    end
  end

  class TpBtfCtx
    def kptr(i, t)
      BPF.ebpf_only("BPF::TpBtfCtx#kptr")
      KPtr.new(t.sample)
    end

    def kptr_or_null(i, t)
      if BPF.ebpf_only("BPF::TpBtfCtx#kptr_or_null") == 0
        return KPtr.new(t.sample)
      end
      nil
    end

    def arg(i)
      BPF.ebpf_only("BPF::TpBtfCtx#arg")
    end
  end

  # user の文字列の pointer (P020 E080 — 読みは RingBuf#output_str だけ)。
  class UserStr
  end

  # P028 E151: user の char * の配列 (argv) — R.output_argv の第 3 引数だけ
  class UserStrArray
  end

  # P029 E158: uprobe の user の buffer の address (読みは RingBuf#output_buf だけ — bpf-mlir の user.read)
  class UserBuf
  end

  # RingBuf#output_str の結果 (予約が取れた時だけ — `r = R.output_str(…)` の直後の `if r` の中で r.status)。
  # status は probe_read_user_str の生の status: NUL を含む長さ・切り詰めは field の大きさ・失敗は負の errno (空文字列は kernel の版で 1 か 0 —
  # 空の判定は `status >= 0 && field[0] == 0`、失敗の時の field は 0 で埋まり空と同じ byte — status だけが見分ける)。
  class OutputStr
    def status
      BPF.ebpf_only("BPF::OutputStr#status")
    end

    # sent は event を submit したか (output_str はいつも真、output_str_or_discard は status < 0 で捨てたら偽 — P024 E100)
    def sent
      BPF.ebpf_only("BPF::OutputStr#sent") == 0
    end
  end

  # 検査済みの packet の window (`if w` の中だけで読める)。添字 i は Integer の literal で i + 幅 <= len。
  # 多 byte の読みは byte order を名前に書く (be = network order、le = little endian)。値は Integer (符号無し)。
  class Window
    def u8(i)
      BPF.ebpf_only("BPF::Window#u8")
    end

    def be16(i)
      BPF.ebpf_only("BPF::Window#be16")
    end

    def be32(i)
      BPF.ebpf_only("BPF::Window#be32")
    end

    def le16(i)
      BPF.ebpf_only("BPF::Window#le16")
    end

    def le32(i)
      BPF.ebpf_only("BPF::Window#le32")
    end
  end

  # lookup の結果 (present のときだけ load できる — `if p` の中)。
  class MapRef
    def load
      BPF.ebpf_only("BPF::MapRef#load")
    end

    # atomic_add は present の借用の値に atomic に加える (P008 — key が在る所だけ)。
    def atomic_add(delta)
      BPF.ebpf_only("BPF::MapRef#atomic_add")
    end
  end

  # array の map。key は u32、値の型は :u32 / :u64 / :i32 / :i64 (P002 §1.5)。
  class ArrayMap
    def initialize(name, value_type, max_entries)
      @name = name
      @value_type = value_type
      @max_entries = max_entries
    end

    def name
      @name
    end

    def value_type
      @value_type.to_s # 全ての map の class で String に揃える (library の多相の引数で Symbol の添字が崩れる — E039)
    end

    # record? は user 空間の library が整数の map と record の map を分ける (P006 §3)。
    def record?
      false
    end

    # kind と key_type は maps.json の綴り (user 空間の library の宣言の JSON — P008 §3)。
    def kind
      "array"
    end

    def key_type
      "u32"
    end

    def record_key?
      false
    end


    def max_entries
      @max_entries
    end

    def atomic_add(key, delta)
      BPF.ebpf_only("BPF::ArrayMap#atomic_add")
    end

    def update(key, value)
      BPF.ebpf_only("BPF::ArrayMap#update")
    end

    def lookup(key)
      if BPF.ebpf_only("BPF::ArrayMap#lookup") == 0
        return MapRef.new
      end
      nil
    end
  end

  # pid_tgid は今の task の tgid << 32 | pid (u64 — ktime_ns と同じく eBPF の側では u64 への写し・`& M`・`>> K` だけ — P013 E051)。
  def self.pid_tgid
    BPF.ebpf_only("BPF.pid_tgid")
  end

  # ktime_ns は単調な clock の ns (u64 — eBPF の側では u64 の member / map への写し・`& M`・`>> K` だけ — P006 §2)。
  def self.ktime_ns
    BPF.ebpf_only("BPF.ktime_ns")
  end

  # record の member の幅の宣言 (`BPF.record(S, m: :u16, …)` — S は Struct、P006 §1)。frontend が読む。実行では何もしない。
  def self.record(klass, fields)
    fields.length
  end

  # record の lookup の結果 (present のときだけ — `if p` の中)。`p.load.m` / `p.load.m = e` で member を読み書きし、
  # `p.atomic_add(:m, d)` で member に atomic に加える (P006 §2)。p.load の結果は member の直接の読み書きにだけ使える。
  class RecordRef
    def initialize(value)
      @value = value
    end

    def load
      BPF.ebpf_only("BPF::RecordRef#load")
      @value
    end

    def atomic_add(member, a, b = 0) # (:m, d) か配列の member の (:m, k, d) (P016 E066)
      BPF.ebpf_only("BPF::RecordRef#atomic_add")
    end
  end

  # record を value に持つ array の map。sample は record の型の見本 (全 member が literal の 0 — 初期値ではない、entry は kernel が 0 で作る)。
  class RecordMap
    def initialize(name, sample, max_entries)
      @name = name
      @sample = sample
      @max_entries = max_entries
    end

    def name
      @name
    end

    def sample
      @sample
    end

    # value_type は宣言の綴り (`record:<S>` — maps.json と同じ)。
    def value_type
      "record:" + @sample.class.name
    end

    def record?
      true
    end

    # kind と key_type は maps.json の綴り (user 空間の library の宣言の JSON — P008 §3)。
    def kind
      "array"
    end

    def key_type
      "u32"
    end

    def record_key?
      false
    end


    def max_entries
      @max_entries
    end

    def update(key, value)
      BPF.ebpf_only("BPF::RecordMap#update")
    end

    def lookup(key)
      if BPF.ebpf_only("BPF::RecordMap#lookup") == 0
        return RecordRef.new(@sample)
      end
      nil
    end
  end

  # record の event の ring buffer (P007)。sample は record の型の見本 (全 member が literal の 0)、size は byte (2 の冪・4096 以上)。
  # output は予約が取れて submit したら true、ring が一杯なら false — `if` / `unless` の条件か `_ = …` でだけ受ける (捨てる文は SB025)。
  # `_ = Events.output(e)` は「落ちた event を数えない」選択 (数えるなら `unless Events.output(e)` の腕で)。
  class RingBuf
    def initialize(name, sample, size)
      @name = name
      @sample = sample
      @size = size
    end

    def name
      @name
    end

    def sample
      @sample
    end

    def size
      @size
    end

    def output(value)
      BPF.ebpf_only("BPF::RingBuf#output") == 0
    end

    # output_str は value (S.new(…)) を予約に書き、user の文字列 str (ctx.str_arg(n)) を field (u8 の配列の member) へ読み、status を
    # status_field (:i64 の member) にも書いて submit する (uprobe だけ — P020 E080)。予約が取れなければ nil (読まない)。
    def output_str(value, field, str, status_field)
      if BPF.ebpf_only("BPF::RingBuf#output_str") == 0
        return OutputStr.new
      end
      nil
    end

    # output_str_or_discard (P024 E100) は output_str と同じ形で、read_str の status < 0 (NULL 等の失敗) なら予約を捨てる (event を届けない —
    # bpf-mlir v1.3.0 の腕ごとの submit / discard)。空文字列は捨てない (status は kernel で違う — 7.1.8 は 1)。結果は予約が取れた時だけ真、
    # `r.sent` は submit した時だけ真 (捨てたら偽)、`r.status` は read_str の status。
    def output_str_or_discard(value, field, str, status_field)
      if BPF.ebpf_only("BPF::RingBuf#output_str_or_discard") == 0
        return OutputStr.new
      end
      nil
    end

    # output_comm (P028 E145) は value (S.new(…)) を予約に書き、今の task の comm (bpf_get_current_comm) を field ([:u8, 16] の member) に、
    # helper の生の status を status_field (:i64 の member) に書いて submit する。予約が取れなければ nil
    # output_argv (P028 E151) は argv の slot 0..19 ごとに (present が偽の slot で止まる) value を予約に書き、その slot の文字列を field に、
    # read_str の status を status_field に、slot の番号を index_field に書いて submit する。20 の event は「ちょうど 20」と「21 以上」を区別しない
    def output_argv(value, field, argv, status_field, index_field)
      BPF.ebpf_only("BPF::RingBuf#output_argv")
    end

    # output_buf (P029 E158) は value を予約に書き、user の buffer (ctx.buf_arg(n)) の n = max(0, min(len, N)) byte を field ([:u8, N] の
    # member — 全体をゼロ化してから) に、probe_read_user の生の status を status_field (:i64) に、n を count_field (:i32 — 読めた byte 数では
    # ない) に書いて submit する (uprobe だけ — bpf-mlir E560)。予約が取れなければ nil
    def output_buf(value, field, buf, len, status_field, count_field)
      if BPF.ebpf_only("BPF::RingBuf#output_buf") == 0
        return OutputStr.new
      end
      nil
    end

    def output_comm(value, field, status_field)
      if BPF.ebpf_only("BPF::RingBuf#output_comm") == 0
        return OutputStr.new
      end
      nil
    end
  end

  # hash の map、整数の値 (value は :u32 / :u64 / :i32 / :i64 — lookup は MapRef)。key は :u32 / :u64 / :i32 / :i64 か record の見本 (P008 §1)。
  # update / insert / replace / delete は status (0 か負の errno — BPF::EEXIST 等) を返す: `st = M.op(…)` (読むこと)・比較の operand・`_ = M.op(…)` でだけ受ける (捨てる文は SB026)。
  class HashMap
    def initialize(name, key, value, max_entries)
      @name = name
      @key = key
      @value = value
      @max_entries = max_entries
    end

    def name
      @name
    end

    def kind
      "hash"
    end

    # key_type / value_type は maps.json の綴り (`u32` / `record:<S>` — P008 §3)。
    def key_type
      if @key.is_a?(Symbol)
        return @key.to_s
      end
      "record:" + @key.class.name
    end

    def value_type
      @value.to_s
    end

    def record?
      false
    end

    def record_key?
      !@key.is_a?(Symbol)
    end

    def max_entries
      @max_entries
    end

    def lookup(key)
      if BPF.ebpf_only("BPF::HashMap#lookup") == 0
        return MapRef.new
      end
      nil
    end

    def update(key, value)
      BPF.ebpf_only("BPF::HashMap#update")
    end

    def insert(key, value)
      BPF.ebpf_only("BPF::HashMap#insert")
    end

    def replace(key, value)
      BPF.ebpf_only("BPF::HashMap#replace")
    end

    def delete(key)
      BPF.ebpf_only("BPF::HashMap#delete")
    end

    # add_or_init は key が在れば値に delta を atomic に加え、無ければ delta で作る (同時の作成は −EEXIST の後に加える — 再びの absent は合成の −ENOENT)。status を返す。
    def add_or_init(key, delta)
      BPF.ebpf_only("BPF::HashMap#add_or_init")
    end
  end

  # lru_hash の map、整数の値 (value は :u32 / :u64 / :i32 / :i64 — lookup は MapRef)。key は :u32 / :u64 / :i32 / :i64 か record の見本 (P008 §1)。
  # update / insert / replace / delete は status (0 か負の errno — BPF::EEXIST 等) を返す: `st = M.op(…)` (読むこと)・比較の operand・`_ = M.op(…)` でだけ受ける (捨てる文は SB026)。
  class LruHashMap
    def initialize(name, key, value, max_entries)
      @name = name
      @key = key
      @value = value
      @max_entries = max_entries
    end

    def name
      @name
    end

    def kind
      "lru_hash"
    end

    # key_type / value_type は maps.json の綴り (`u32` / `record:<S>` — P008 §3)。
    def key_type
      if @key.is_a?(Symbol)
        return @key.to_s
      end
      "record:" + @key.class.name
    end

    def value_type
      @value.to_s
    end

    def record?
      false
    end

    def record_key?
      !@key.is_a?(Symbol)
    end

    def max_entries
      @max_entries
    end

    def lookup(key)
      if BPF.ebpf_only("BPF::LruHashMap#lookup") == 0
        return MapRef.new
      end
      nil
    end

    def update(key, value)
      BPF.ebpf_only("BPF::LruHashMap#update")
    end

    def insert(key, value)
      BPF.ebpf_only("BPF::LruHashMap#insert")
    end

    def replace(key, value)
      BPF.ebpf_only("BPF::LruHashMap#replace")
    end

    def delete(key)
      BPF.ebpf_only("BPF::LruHashMap#delete")
    end

    # add_or_init は key が在れば値に delta を atomic に加え、無ければ delta で作る (同時の作成は −EEXIST の後に加える — 再びの absent は合成の −ENOENT)。status を返す。
    def add_or_init(key, delta)
      BPF.ebpf_only("BPF::LruHashMap#add_or_init")
    end
  end

  # hash の map、record の値 (value は record の見本 `S.new(0, …)` — lookup は RecordRef)。key は :u32 / :u64 / :i32 / :i64 か record の見本 (P008 §1)。
  # update / insert / replace / delete は status (0 か負の errno — BPF::EEXIST 等) を返す: `st = M.op(…)` (読むこと)・比較の operand・`_ = M.op(…)` でだけ受ける (捨てる文は SB026)。
  class RecordHashMap
    def initialize(name, key, value, max_entries)
      @name = name
      @key = key
      @value = value
      @max_entries = max_entries
    end

    def name
      @name
    end

    def kind
      "hash"
    end

    # key_type / value_type は maps.json の綴り (`u32` / `record:<S>` — P008 §3)。
    def key_type
      if @key.is_a?(Symbol)
        return @key.to_s
      end
      "record:" + @key.class.name
    end

    def value_type
      "record:" + @value.class.name
    end

    def record?
      true
    end

    def record_key?
      !@key.is_a?(Symbol)
    end

    def max_entries
      @max_entries
    end

    def lookup(key)
      if BPF.ebpf_only("BPF::RecordHashMap#lookup") == 0
        return RecordRef.new(@value)
      end
      nil
    end

    def update(key, value)
      BPF.ebpf_only("BPF::RecordHashMap#update")
    end

    def insert(key, value)
      BPF.ebpf_only("BPF::RecordHashMap#insert")
    end

    def replace(key, value)
      BPF.ebpf_only("BPF::RecordHashMap#replace")
    end

    def delete(key)
      BPF.ebpf_only("BPF::RecordHashMap#delete")
    end
  end

  # lru_hash の map、record の値 (value は record の見本 `S.new(0, …)` — lookup は RecordRef)。key は :u32 / :u64 / :i32 / :i64 か record の見本 (P008 §1)。
  # update / insert / replace / delete は status (0 か負の errno — BPF::EEXIST 等) を返す: `st = M.op(…)` (読むこと)・比較の operand・`_ = M.op(…)` でだけ受ける (捨てる文は SB026)。
  class LruRecordHashMap
    def initialize(name, key, value, max_entries)
      @name = name
      @key = key
      @value = value
      @max_entries = max_entries
    end

    def name
      @name
    end

    def kind
      "lru_hash"
    end

    # key_type / value_type は maps.json の綴り (`u32` / `record:<S>` — P008 §3)。
    def key_type
      if @key.is_a?(Symbol)
        return @key.to_s
      end
      "record:" + @key.class.name
    end

    def value_type
      "record:" + @value.class.name
    end

    def record?
      true
    end

    def record_key?
      !@key.is_a?(Symbol)
    end

    def max_entries
      @max_entries
    end

    def lookup(key)
      if BPF.ebpf_only("BPF::LruRecordHashMap#lookup") == 0
        return RecordRef.new(@value)
      end
      nil
    end

    def update(key, value)
      BPF.ebpf_only("BPF::LruRecordHashMap#update")
    end

    def insert(key, value)
      BPF.ebpf_only("BPF::LruRecordHashMap#insert")
    end

    def replace(key, value)
      BPF.ebpf_only("BPF::LruRecordHashMap#replace")
    end

    def delete(key)
      BPF.ebpf_only("BPF::LruRecordHashMap#delete")
    end
  end

  # per-CPU の percpu_array (P009) — BPF::ArrayMap と同じ形で、eBPF の側の読み書きは今の CPU の slot。同じ slot に同時に書く CPU は無いので、
  # lookup の値を同じ entry に書き戻す形 (`p.load.m += d` 等) を受ける (map を使う program が全て XDP のとき — tracing / perf の program は softirq に割り込みうる)。
  class PerCpuArrayMap
    def initialize(name, value_type, max_entries)
      @name = name
      @value_type = value_type
      @max_entries = max_entries
    end

    def name
      @name
    end

    def value_type
      @value_type.to_s # 全ての map の class で String に揃える (E039)
    end

    # record? は user 空間の library が整数の map と record の map を分ける (P006 §3)。
    def record?
      false
    end

    # kind と key_type は maps.json の綴り (user 空間の library の宣言の JSON — P008 §3)。
    def kind
      "percpu_array"
    end

    def key_type
      "u32"
    end

    def record_key?
      false
    end


    def max_entries
      @max_entries
    end

    def atomic_add(key, delta)
      BPF.ebpf_only("BPF::PerCpuArrayMap#atomic_add")
    end

    def update(key, value)
      BPF.ebpf_only("BPF::PerCpuArrayMap#update")
    end

    def lookup(key)
      if BPF.ebpf_only("BPF::PerCpuArrayMap#lookup") == 0
        return MapRef.new
      end
      nil
    end
  end

  # per-CPU の percpu_array (P009) — BPF::RecordMap と同じ形で、eBPF の側の読み書きは今の CPU の slot。同じ slot に同時に書く CPU は無いので、
  # lookup の値を同じ entry に書き戻す形 (`p.load.m += d` 等) を受ける (map を使う program が全て XDP のとき — tracing / perf の program は softirq に割り込みうる)。
  class PerCpuRecordMap
    def initialize(name, sample, max_entries)
      @name = name
      @sample = sample
      @max_entries = max_entries
    end

    def name
      @name
    end

    def sample
      @sample
    end

    # value_type は宣言の綴り (`record:<S>` — maps.json と同じ)。
    def value_type
      "record:" + @sample.class.name
    end

    def record?
      true
    end

    # kind と key_type は maps.json の綴り (user 空間の library の宣言の JSON — P008 §3)。
    def kind
      "percpu_array"
    end

    def key_type
      "u32"
    end

    def record_key?
      false
    end


    def max_entries
      @max_entries
    end

    def update(key, value)
      BPF.ebpf_only("BPF::PerCpuRecordMap#update")
    end

    def lookup(key)
      if BPF.ebpf_only("BPF::PerCpuRecordMap#lookup") == 0
        return RecordRef.new(@sample)
      end
      nil
    end
  end

  # per-CPU の percpu_hash (P009) — BPF::HashMap と同じ形で、eBPF の側の読み書きは今の CPU の slot。同じ slot に同時に書く CPU は無いので、
  # lookup の値を同じ entry に書き戻す形 (`p.load.m += d` 等) を受ける (map を使う program が全て XDP のとき — tracing / perf の program は softirq に割り込みうる)。
  class PerCpuHashMap
    def initialize(name, key, value, max_entries)
      @name = name
      @key = key
      @value = value
      @max_entries = max_entries
    end

    def name
      @name
    end

    def kind
      "percpu_hash"
    end

    # key_type / value_type は maps.json の綴り (`u32` / `record:<S>` — P008 §3)。
    def key_type
      if @key.is_a?(Symbol)
        return @key.to_s
      end
      "record:" + @key.class.name
    end

    def value_type
      @value.to_s
    end

    def record?
      false
    end

    def record_key?
      !@key.is_a?(Symbol)
    end

    def max_entries
      @max_entries
    end

    def lookup(key)
      if BPF.ebpf_only("BPF::PerCpuHashMap#lookup") == 0
        return MapRef.new
      end
      nil
    end

    def update(key, value)
      BPF.ebpf_only("BPF::PerCpuHashMap#update")
    end

    def insert(key, value)
      BPF.ebpf_only("BPF::PerCpuHashMap#insert")
    end

    def replace(key, value)
      BPF.ebpf_only("BPF::PerCpuHashMap#replace")
    end

    def delete(key)
      BPF.ebpf_only("BPF::PerCpuHashMap#delete")
    end

    # add_or_init は key が在れば値に delta を atomic に加え、無ければ delta で作る (同時の作成は −EEXIST の後に加える — 再びの absent は合成の −ENOENT)。status を返す。
    def add_or_init(key, delta)
      BPF.ebpf_only("BPF::PerCpuHashMap#add_or_init")
    end
  end

  # per-CPU の percpu_hash (P009) — BPF::RecordHashMap と同じ形で、eBPF の側の読み書きは今の CPU の slot。同じ slot に同時に書く CPU は無いので、
  # lookup の値を同じ entry に書き戻す形 (`p.load.m += d` 等) を受ける (map を使う program が全て XDP のとき — tracing / perf の program は softirq に割り込みうる)。
  class PerCpuRecordHashMap
    def initialize(name, key, value, max_entries)
      @name = name
      @key = key
      @value = value
      @max_entries = max_entries
    end

    def name
      @name
    end

    def kind
      "percpu_hash"
    end

    # key_type / value_type は maps.json の綴り (`u32` / `record:<S>` — P008 §3)。
    def key_type
      if @key.is_a?(Symbol)
        return @key.to_s
      end
      "record:" + @key.class.name
    end

    def value_type
      "record:" + @value.class.name
    end

    def record?
      true
    end

    def record_key?
      !@key.is_a?(Symbol)
    end

    def max_entries
      @max_entries
    end

    def lookup(key)
      if BPF.ebpf_only("BPF::PerCpuRecordHashMap#lookup") == 0
        return RecordRef.new(@value)
      end
      nil
    end

    def update(key, value)
      BPF.ebpf_only("BPF::PerCpuRecordHashMap#update")
    end

    def insert(key, value)
      BPF.ebpf_only("BPF::PerCpuRecordHashMap#insert")
    end

    def replace(key, value)
      BPF.ebpf_only("BPF::PerCpuRecordHashMap#replace")
    end

    def delete(key)
      BPF.ebpf_only("BPF::PerCpuRecordHashMap#delete")
    end
  end

  # lpm_trie の map (E121 — IPv4 の最長一致)、整数の値 (value は :u32 / :i32 — lookup は MapRef)。key は library が持つ (prefixlen u32・addr [4]u8 の
  # spinelbpf_lpm_key4 — frontend が作る)。eBPF の側は `p = M.lookup(a0, a1, a2, a3)` (address の 4 byte — prefixlen 32 で引く) と `if p` の中の `p.load`
  # だけ (read-only — 書きは user の側の obj.lpm_put)。
  class LpmTrieMap
    def initialize(name, value, max_entries)
      @name = name
      @value = value
      @max_entries = max_entries
    end

    def name
      @name
    end

    def kind
      "lpm_trie"
    end

    # key_type / value_type は maps.json の綴り (E121)。
    def key_type
      "record:spinelbpf_lpm_key4"
    end

    def value_type
      @value.to_s
    end

    def record?
      false
    end

    def record_key?
      true
    end

    def max_entries
      @max_entries
    end

    def lookup(a0, a1, a2, a3)
      if BPF.ebpf_only("BPF::LpmTrieMap#lookup") == 0
        return MapRef.new
      end
      nil
    end
  end

  # devmap (P026 E124): XDP の redirect_map の先 — key は u32 の添字、value は ifindex (:u32 — user の側が `obj.map_put` で入れる)。
  # eBPF の側は xdp の program の最後の式 `Ports.redirect(k, BPF::XDP_PASS)` だけ (entry が在れば XDP_REDIRECT、無ければ fallback)。
  class DevMap
    def initialize(name, value_type, max_entries)
      @name = name
      @value_type = value_type
      @max_entries = max_entries
    end

    def name
      @name
    end

    def value_type
      @value_type.to_s
    end

    def record?
      false
    end

    def kind
      "devmap"
    end

    def key_type
      "u32"
    end

    def record_key?
      false
    end

    def max_entries
      @max_entries
    end

    def redirect(key, fallback)
      BPF.ebpf_only("BPF::DevMap#redirect")
      fallback
    end
  end

  # sockmap (P026 E129): sk_lookup の sk.assign の元 — key は u32 の添字、value は socket (user の側が fd を `obj.map_put` で入れる — :u64)。
  # eBPF の側は sk_lookup の program の文 `st = Socks.assign(ctx, k)` だけ (socket の参照は Ruby の値にならない)。
  class SockMap
    def initialize(name, value_type, max_entries)
      @name = name
      @value_type = value_type
      @max_entries = max_entries
    end

    def name
      @name
    end

    def value_type
      @value_type.to_s
    end

    def record?
      false
    end

    def kind
      "sockmap"
    end

    def key_type
      "u32"
    end

    def record_key?
      false
    end

    def max_entries
      @max_entries
    end

    def assign(ctx, key)
      BPF.ebpf_only("BPF::SockMap#assign")
    end
  end

  # sk_lookup の context (bpf_sk_lookup — P026 E129)。ctx.local_port は host の順の u32 (ebpf.ctx.field)
  class SkLookupCtx
    def local_port
      BPF.ebpf_only("BPF::SkLookupCtx#local_port")
    end
  end

  # sk_lookup の program の宣言 (P026 E129 — `BPF.sk_lookup :name`)。user の側で netns に attach_netns、試験は test_run_sk_lookup。
  def self.sk_lookup(name)
    name
  end

  # xdp の program の宣言 (`BPF.xdp :name`)。 frontend が読む。実行では名前を返すだけ。
  def self.xdp(name)
    name
  end

  # sched_cls の program の宣言 (P019 E076 — `BPF.tcx :name, :ingress` / `:egress`。向きは Symbol の literal、tcx の link の向き)。frontend が読む。実行では名前を返すだけ。
  def self.tcx(name, direction)
    name
  end

  # socket_filter の program の宣言 (P026 E126 — `BPF.socket_filter :name`)。user の側で `obj.attach_socket(:name の文字列, fd)` で自分の socket に付ける。実行では名前を返すだけ。
  def self.socket_filter(name)
    name
  end

  # cgroup_skb の program の宣言 (P026 E127 — `BPF.cgroup_skb :name, :ingress` / `:egress`)。user の側で `obj.attach_cgroup(:name の文字列, cgroup_fd)` で cgroup に付ける。
  # 実行では名前を返すだけ。
  def self.cgroup_skb(name, direction)
    name
  end

  # netfilter の program の宣言 (P026 E128 — `BPF.netfilter :name`)。hook は user の側の `obj.attach_netfilter(:name の文字列, pf, hooknum, priority)` が
  # 呼ぶ thread の netns に付ける。実行では名前を返すだけ。
  def self.netfilter(name)
    name
  end

  # fmod_ret の program の宣言 (P028 E144 — `BPF.fmod_ret :name, "kernel_function", nargs: N, args: {0 => :i32}`)。nargs は target の引数の数、
  # args は整数の引数 (ctx.arg(i))、戻り値は i32。load の前に target の FUNC_PROTO と照合 (retsig・farg)。実行では名前を返すだけ。
  def self.fmod_ret(name, target, opts)
    name
  end

  # fmod_ret の値の差し替え (P028 E144): program の最後か guard の `return … if cond` で、元の関数を呼ばず e を戻り値にする
  def self.fmod_return(e)
    BPF.ebpf_only("BPF.fmod_return")
  end

  # flow_dissector の program の宣言 (P026 E130 — `BPF.flow_dissector :name`)。user の側で `obj.attach_netns(:name の文字列, netns_fd)`。実行では名前を返すだけ。
  def self.flow_dissector(name)
    name
  end

  # CO-RE の kernel の struct の宣言 (P021 E086 — `BPF.kernel_type(Task, "task_struct", pid: :i32, real_parent: [:kptr, Task], comm: [:u8, 16])`)。
  # frontend が読む。実行では何もしない。
  def self.kernel_type(s, name, opts)
    name
  end

  # tp_btf の program の宣言 (P021 E086 — `BPF.tp_btf :name, "sched_process_fork", args: {0 => TaskT, 1 => TaskT}`)。frontend が読む。
  def self.tp_btf(name, tracepoint, opts)
    name
  end

  # uprobe の program の宣言 (P020 E080 — `BPF.uprobe :name, "target/bin", "symbol", params: {1 => :user_str, 2 => :i32}`)。path は source の
  # directory からの相対 (build が読み SHA-256 を schema に — path は生成物に入れない)。frontend が読む。実行では名前を返すだけ。
  def self.uprobe(name, path, symbol, opts)
    name
  end

  #   BPF.uretprobe :name, "target/binary", "symbol", ret: :i64 — ctx.ret で戻り値の register (P026 E112)
  def self.uretprobe(name, path, symbol, opts)
    name
  end

  # tracing の program の宣言 (P013 E051 — frontend が読む。実行では名前を返すだけ)。target は kernel の関数の名前の文字列の literal。
  #   BPF.fentry :name, "target"                              — 引数は読めない (v0.17.0 の fentry の整数の引数は不可 — helper だけ)
  #   BPF.fexit :name, "target", nargs: N, ret: :i32          — ctx.ret で戻り値 (N は target の引数の数)
  #   BPF.kprobe :name, "target", params: {3 => :u64}        — ctx.arg(n) で register n (1 始まり — schema の params の n と同じ) の整数
  #   BPF.fentry :name, "target", args: {0 => [:or_null, T]} — struct の引数 (P021 E089 — ctx.kptr_or_null と if)
  def self.fentry(name, target, opts = nil)
    name
  end

  def self.fexit(name, target, opts)
    name
  end

  def self.kprobe(name, target, opts)
    name
  end

  #   BPF.kretprobe :name, "target", ret: :i32          — ctx.ret で戻り値の register (P026 E111)
  def self.kretprobe(name, target, opts)
    name
  end

  #   BPF.raw_tp :name, "tracepoint"                    — ctx.arg(i) で args[i] (u64、P026 E113)
  def self.raw_tp(name, target)
    name
  end

  #   BPF.tracepoint :name, "cat/event", fields: {f => [offset, :type]} — ctx.field(:f) (P026 E114)
  def self.tracepoint(name, target, opts)
    name
  end

  #   BPF.ksyscall :name, "syscall", params: {n => :type} — ctx.arg(n) で syscall の第 n 引数 (P026 E115)
  def self.ksyscall(name, target, opts)
    name
  end
end
