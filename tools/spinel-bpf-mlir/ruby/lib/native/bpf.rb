# bpf (native の twin) — eBPF の側の API を Ruby の配列で実装した library (P001 §3.8 — 差動の model)。
#
# ruby/lib/bpf.rb と同じ名前と形 (BPF::ArrayMap・MapRef・XdpMd・XDP_*・BPF.xdp) で、eBPF の側の関数を Spinel の native で走らせる。
# 試験の build だけで使う (`spinel -I ruby/lib/native` — 利用者の実行 file には入らない)。値の意味は BPF の array の map に合わせる:
# 範囲の外の key の lookup は nil、atomic_add / update は範囲の外で何もしない、32 bit の値は型に合わせて wrap (u32 は 2^32 の剰余、i32 は符号付きに)。
# 64 bit の値が Integer を溢れると Spinel は RangeError で止まる (BPF は wrap — 差動の表は溢れる行を持たない — P002 §2.1)。
module BPF
  XDP_ABORTED = 0
  XDP_DROP = 1
  XDP_PASS = 2
  XDP_TX = 3

  # sched_cls (tcx) の判定 (P019 — ruby/lib/bpf.rb と同じ値: TC_ACT_OK / TC_ACT_SHOT)
  TC_PASS = 0
  TC_DROP = 2

  SF_KEEP = -1
  SF_DROP = 0
  CG_ALLOW = 1
  CG_DENY = 0
  NF_ACCEPT = 1
  NF_DROP = 0
  FMOD_CALL = 0
  FLOW_OK = 0
  FLOW_DROP = 2
  FLOW_CONTINUE = 129
  SK_PASS = 1
  SK_DROP = 0

  ENOENT = -2
  E2BIG = -7
  ENOMEM = -12
  EEXIST = -17

  # xdp の context — packet の bytes (Integer の Array、各 0..255) を持つ (P004 §3)。check の意味は手で書いた model (kernel との差動が確かめる):
  # [off, off + len) が bytes の中なら Window、外なら nil。
  class XdpMd
    def initialize(bytes)
      @bytes = bytes
      @ifx = 1
    end

    def check(off, len)
      if off >= 0 && off + len <= @bytes.length
        return Window.new(@bytes, off)
      end
      nil
    end

    # ingress_ifindex (P026 E120) — kernel の ctx 無しの test run の値 (呼ぶ process の netns の lo — 1)。_h_ifx は harness の変異 (E120 H6) が値を置く
    def ingress_ifindex
      @ifx
    end

    def _h_ifx(v)
      @ifx = v
      self
    end

    # adjust_head (P026 E122) — kernel の bpf_xdp_adjust_head の範囲: 縮めた後の残りが 14 byte 未満なら −22、伸ばす側は test run の headroom (双子の model は 200 —
    # 表は −100 と −1000 だけで境界は確かめない)、伸ばした先頭は 0 (test run の headroom は kzalloc)。失敗の packet は不変
    def adjust_head(d)
      lim = 14
      if BPF::ADJH_BOUND[0] != 0
        lim = BPF::ADJH_BOUND[0]
      end
      if d > 0
        if @bytes.length - d < lim
          return -22
        end
        @bytes = @bytes[d, @bytes.length - d]
      elsif d < 0
        if -d > 200
          return -22
        end
        @bytes = Array.new(-d, 0) + @bytes
      end
      0
    end

    # adjust_tail (P026 E123) — kernel の bpf_xdp_adjust_tail の縮める側: 残り (n + k) が 14 byte 未満なら −22 (不変 — 境界は ADJH_BOUND と同じ変異の器)、
    # でなければ末尾の −k byte を落とす
    def adjust_tail(k)
      lim = 14
      if BPF::ADJH_BOUND[0] != 0
        lim = BPF::ADJH_BOUND[0]
      end
      if @bytes.length + k < lim
        return -22
      end
      @bytes = @bytes[0, @bytes.length + k]
      0
    end
  end

  # sched_cls の context (P019 E077) — XdpMd と同じ check の model (skb の data は Ethernet の header から — kernel との差動が確かめる)。
  class SkBuff
    def initialize(bytes)
      @bytes = bytes
      @mark = 0
    end

    def check(off, len)
      if off >= 0 && off + len <= @bytes.length
        return Window.new(@bytes, off)
      end
      nil
    end

    # len と mark (P026 E120) — len は frame の bytes の数 (tc の skb は L2 から)、mark は 0 から始まり mark= で書く (kernel の ctx 無しの test run と同じ)
    def len
      @bytes.length
    end

    def mark
      @mark
    end

    def mark=(v)
      @mark = v
    end
  end

  # cgroup_skb の context (P026 E127) — data は network header から: test run の frame の bytes の hdr (eth の 14 — harness が渡す) から先が packet、
  # len は bytes.length − hdr (kernel との差動が確かめる)。
  class CgroupSkb
    def initialize(bytes, hdr)
      @bytes = bytes
      @hdr = hdr
    end

    def check(off, len)
      if off >= 0 && @hdr + off + len <= @bytes.length
        return Window.new(@bytes, @hdr + off)
      end
      nil
    end

    def len
      @bytes.length - @hdr
    end
  end

  # 検査済みの window — 読みは window の先頭からの添字 (範囲は frontend が検査済み)。be は network order、le は little endian。
  class Window
    def initialize(bytes, off)
      @bytes = bytes
      @off = off
    end

    def u8(i)
      @bytes[@off + i]
    end

    def be16(i)
      (@bytes[@off + i] << 8) | @bytes[@off + i + 1]
    end

    def le16(i)
      @bytes[@off + i] | (@bytes[@off + i + 1] << 8)
    end

    def be32(i)
      (be16(i) << 16) | be16(i + 2)
    end

    def le32(i)
      le16(i) | (le16(i + 2) << 16)
    end
  end


  class MapRef
    def initialize(map, key)
      @map = map
      @key = key
    end

    def load
      @map.peek(@key)
    end

    def atomic_add(delta)
      @map.atomic_add(@key, delta)
    end
  end

  class ArrayMap
    def initialize(name, value_type, max_entries)
      @name = name
      @value_type = value_type
      @max_entries = max_entries
      @vals = Array.new(max_entries, 0)
    end

    def name
      @name
    end

    def value_type
      @value_type
    end

    def max_entries
      @max_entries
    end

    def in_range(key)
      key >= 0 && key < @max_entries
    end

    def wrap(v)
      if @value_type == :u32
        return v & 0xffffffff
      end
      if @value_type == :i32
        u = v & 0xffffffff
        if u >= 0x80000000
          return u - 0x100000000
        end
        return u
      end
      v
    end

    # reset は twin の harness が全ての slot を 0 にする (eBPF の側の API ではない)。
    def reset
      i = 0
      while i < @max_entries
        @vals[i] = 0
        i += 1
      end
      0
    end

    # poke は twin の harness が入力を置く (eBPF の側の API ではない)。
    def poke(key, value)
      @vals[key] = value
    end

    def atomic_add(key, delta)
      if in_range(key)
        @vals[key] = wrap(@vals[key] + delta)
      end
      0
    end

    def update(key, value)
      if in_range(key)
        @vals[key] = wrap(value)
      end
      0
    end

    def lookup(key)
      if in_range(key)
        return MapRef.new(self, key)
      end
      nil
    end

    # peek は twin の harness が map の値を読む (eBPF の側の API ではない)。
    def peek(key)
      @vals[key]
    end
  end

  # devmap の双子 (P026 E124): slot の値は ifindex (0 は entry 無し — kernel は ifindex 0 の更新を拒む)。redirect は entry が在れば
  # XDP_REDIRECT (4 — bpf_redirect_map の helper の値、test run の戻り値)、無ければ fallback の判定。
  class DevMap
    def initialize(name, value_type, max_entries)
      @name = name
      @value_type = value_type
      @max_entries = max_entries
      @vals = Array.new(max_entries, 0)
    end

    def name
      @name
    end

    def value_type
      @value_type
    end

    def max_entries
      @max_entries
    end

    def reset
      i = 0
      while i < @max_entries
        @vals[i] = 0
        i += 1
      end
      0
    end

    def poke(key, value)
      @vals[key] = value & 0xffffffff
    end

    def peek(key)
      @vals[key]
    end

    def redirect(key, fallback)
      if key >= 0 && key < @max_entries && @vals[key] != 0
        return 4
      end
      fallback
    end
  end

  # sockmap の双子 (P026 E129): slot は socket の protocol (17 UDP・6 TCP — 0 は entry 無し)。assign は entry 無しで −2 (frontend の番兵)、
  # protocol の違いで −91 (−EPROTOTYPE — bpf_sk_lookup_assign)、他は 0 (選んだ)。family は AF_INET だけ (双子は family を持たない)
  class SockMap
    def initialize(name, value_type, max_entries)
      @name = name
      @value_type = value_type
      @max_entries = max_entries
      @protos = Array.new(max_entries, 0)
    end

    def name
      @name
    end

    def max_entries
      @max_entries
    end

    def reset
      i = 0
      while i < @max_entries
        @protos[i] = 0
        i += 1
      end
      0
    end

    def poke(key, value)
      @protos[key] = value
    end

    def peek(key)
      @protos[key]
    end

    def assign(ctx, key)
      if key < 0 || key >= @max_entries || @protos[key] == 0
        return -2
      end
      if @protos[key] != ctx.protocol
        return -91
      end
      0
    end
  end

  # sk_lookup の合成の context (P026 E129 — protocol と local_port)
  class SkLookupCtx
    def initialize(protocol, local_port)
      @protocol = protocol
      @local_port = local_port
    end

    def protocol
      @protocol
    end

    def local_port
      @local_port
    end
  end

  # record (P006 — E022): 宣言は twin では何もしない。slot は member の値の Integer の Array (Struct にしない — 多相の Struct の setter で
  # Spinel が不正な C を出す、probe t1 / t2)。member の読み書きは harness が record ごとに生成する view (_h_view)、加算は _h_radd (member の幅で wrap)。
  def self.record(klass, fields)
    fields.length
  end

  # ktime_ns は双子では固定の値 1 (時刻は差動の対象外 — P006 のレビューの P3、kernel は単調性だけを見る)。
# global 変数の双子 (P014 E058): harness の `config <Name> <v>` が値を置く。必須の Config の未設定の読みは誤り (kernel は load で ConfigNotSet)、
# OptionalConfig と Counter の未設定は 0。Counter の add は宣言の幅で wrap (32 bit — 64 bit は溢れれば Spinel の RangeError: 表は溢れない)
GLOBAL_NAMES = []
GLOBAL_VALUES = []

def self.set_global(name, v)
  i = 0
  while i < GLOBAL_NAMES.length
    if GLOBAL_NAMES[i] == name
      GLOBAL_VALUES[i] = v
      return v
    end
    i += 1
  end
  GLOBAL_NAMES.push(name)
  GLOBAL_VALUES.push(v)
  v
end

def self.global_read(name, required)
  i = 0
  while i < GLOBAL_NAMES.length
    if GLOBAL_NAMES[i] == name
      return GLOBAL_VALUES[i]
    end
    i += 1
  end
  if required
    raise "config #{name} is not set"
  end
  0
end

def self.global_add(name, type, d)
  v = global_read(name, false) + d
  if type == "u32"
    v = v & 0xFFFFFFFF
  elsif type == "i32"
    v = ((v & 0xFFFFFFFF) ^ 0x80000000) - 0x80000000
  end
  set_global(name, v)
end

class Config
  def initialize(name, type)
    @name = name
    @type = type.to_s
  end

  def value
    BPF.global_read(@name, true)
  end
end

class OptionalConfig
  def initialize(name, type)
    @name = name
    @type = type.to_s
  end

  def value
    BPF.global_read(@name, false)
  end
end

class Counter
  def initialize(name, type)
    @name = name
    @type = type.to_s
  end

  def value
    BPF.global_read(@name, false)
  end

  def add(d)
    BPF.global_add(@name, @type, d)
    0
  end
end

  def self.ktime_ns
    1
  end

  # tracing の双子 (P013 E052): context は harness が作る合成の値 (fexit の戻り値・kprobe の register の値 — harness が宣言の型の幅で切る)、
  # pid_tgid は harness の `task <v>` が TASK[0] に置く値
  TASK = [0]

  def self.pid_tgid
    TASK[0]
  end

  # P028 E145: 双子の今の task の comm (16 byte) — harness の `comm <name>` が PR_SET_NAME と同じ規則 (先頭 15 byte までと NUL、後ろは 0) で置く
  TASK_COMM = Array.new(16, 0)

  def self.set_comm(s)
    b = s.bytes
    i = 0
    while i < 16
      if i < 15 && i < b.length
        TASK_COMM[i] = b[i]
      else
        TASK_COMM[i] = 0
      end
      i += 1
    end
    0
  end

  # E089 (P021): args の在る fentry の双子は kptrs (宣言の struct の引数の KPtr か nil) と idx (その番号) — args の無い fentry は FentryCtx.new
  class FentryCtx
    def initialize(kptrs = nil, idx = nil, ints = nil)
      @kptrs = kptrs
      @idx = idx
      @ints = ints
    end

    # P026 E117: 整数の引数 (harness が宣言の幅で切った 12 の slot)
    def arg(i)
      @ints[i]
    end

    def kptr_or_null(i, t)
      j = 0
      while j < @idx.length
        if @idx[j] == i
          return @kptrs[j]
        end
        j += 1
      end
      raise "twin: argument #{i} is not a declared struct argument"
    end
  end

  class FexitCtx
    def initialize(ret)
      @ret = ret
    end

    def ret
      @ret
    end
  end

  # P028 E144: fmod_ret の双子 — 整数の引数 (harness が宣言の幅で切った 12 の slot)
  class FmodRetCtx
    def initialize(ints)
      @ints = ints
    end

    def arg(i)
      @ints[i]
    end
  end

  # tp_btf の双子 (P021 E087): kernel の struct の値は harness が作る Struct (試験の知る値 — 他の member は 0)、KPtr はそれを包む
  class KernelType
    def initialize(sample)
      @sample = sample
    end

    def sample
      @sample
    end
  end

  # pointer の member (E088): harness が set_ptr で名前と先の KPtr を置く (置かない member は NULL — ptr は nil)
  class KPtr
    def initialize(value)
      @value = value
      @names = []
      @ptrs = []
      @anames = []
      @arrs = []
      @snames = []
      @strs = []
      @addr = 0
    end

    # P029 E155: 検査済みの kernel pointer の address (harness が set_addr で置く — 値は kernel だけが知るので双子は harness の値)
    def set_addr(a)
      @addr = a
    end

    def addr
      @addr
    end

    # 配列の member (E089): harness が set_arr で byte を置き、copy はその写し (t.copy(:m) — 固定の N byte)
    def set_arr(field, a)
      @anames.push(field)
      @arrs.push(a)
    end

    def copy(field)
      j = 0
      while j < @anames.length
        if @anames[j] == field
          out = Array.new(0, 0)
          k = 0
          while k < @arrs[j].length
            out.push(@arrs[j][k])
            k += 1
          end
          return out
        end
        j += 1
      end
      raise "twin: no array member #{field}"
    end

    # P026 E118: `:strptr` の field の先の文字列 — harness が set_str で byte を置く (置かない field は空文字列)
    def set_str(field, a)
      @snames.push(field)
      @strs.push(a)
    end

    def str(field)
      j = 0
      while j < @snames.length
        if @snames[j] == field
          return UserStr.new(@strs[j], false)
        end
        j += 1
      end
      UserStr.new(Array.new(0, 0), false)
    end

    def load
      @value
    end

    def set_ptr(field, kp)
      @names.push(field)
      @ptrs.push(kp)
    end

    def ptr(field, t)
      j = 0
      while j < @names.length
        if @names[j] == field
          return @ptrs[j]
        end
        j += 1
      end
      nil
    end
  end

  # kptrs は宣言の struct の引数の KPtr、idx はその引数の番号 (kptrs と同じ並び)、ints は整数の引数 (番号で — 宣言の幅で切った値)
  # flow_dissector の context (P026 E130) — kernel の bpf_flow_dissect と同じ: flow_keys (56 byte — struct bpf_flow_keys の little endian の byte) を 0 にし、
  # n_proto に eth の h_proto の raw (bytes[12], bytes[13] のまま)、nhoff = thoff = 14。program の後に harness が _h_keys で nhoff を [14, n]、
  # thoff を [nhoff, n] に clamp して読む (ipv4_src / ipv4_dst は ipv6_src[0] / [1] と同じ byte — union)。
  class FlowCtx
    def initialize(bytes)
      @bytes = bytes
      @k = Array.new(56, 0)
      if bytes.length >= 14
        @k[10] = bytes[12]
        @k[11] = bytes[13]
      end
      _h_put(0, 2, 14)
      _h_put(2, 2, 14)
    end

    def check(off, len)
      if off >= 0 && off + len <= @bytes.length
        return Window.new(@bytes, off)
      end
      nil
    end

    # field の offset (byte) と幅 (byte) — bpf-mlir の UAPI の表の bpf_flow_keys の行
    def _h_off(f)
      if f == :nhoff
        return 0
      elsif f == :thoff
        return 2
      elsif f == :addr_proto
        return 4
      elsif f == :is_frag
        return 6
      elsif f == :is_first_frag
        return 7
      elsif f == :is_encap
        return 8
      elsif f == :ip_proto
        return 9
      elsif f == :n_proto
        return 10
      elsif f == :sport
        return 12
      elsif f == :dport
        return 14
      elsif f == :ipv4_src || f == :ipv6_src
        return 16
      elsif f == :ipv4_dst
        return 20
      elsif f == :ipv6_dst
        return 32
      elsif f == :flags
        return 48
      end
      52
    end

    def _h_width(f)
      if f == :is_frag || f == :is_first_frag || f == :is_encap || f == :ip_proto
        return 1
      elsif f == :ipv4_src || f == :ipv4_dst || f == :ipv6_src || f == :ipv6_dst || f == :flags || f == :flow_label
        return 4
      end
      2
    end

    def _h_get(off, w)
      v = 0
      i = w - 1
      while i >= 0
        v = (v << 8) | @k[off + i]
        i -= 1
      end
      v
    end

    def _h_put(off, w, v)
      i = 0
      while i < w
        @k[off + i] = (v >> (8 * i)) & 0xFF
        i += 1
      end
    end

    def key(f, i = 0)
      _h_get(_h_off(f) + 4 * i, _h_width(f))
    end

    # set_key(:f, v) か set_key(:ipv6_src / :ipv6_dst, i, v)
    def set_key(f, a, b = 0)
      if f == :ipv6_src || f == :ipv6_dst
        _h_put(_h_off(f) + 4 * a, 4, b)
      else
        _h_put(_h_off(f), _h_width(f), a)
      end
      nil
    end

    # program の後の key の値 (kernel と同じ clamp — cl が 0 なら thoff の clamp を外す — 引数の名前を clamp にしない: Comparable#clamp の名前で Spinel が builtins を継ぎ込む S11 (E130 追補 2) — 変異 flow-noclamp)。順は SpinelBPF::FLOW_KEYS と同じ
    def _h_keys(cl)
      n = @bytes.length
      nh = _h_get(0, 2)
      if nh < 14
        nh = 14
      elsif nh > n
        nh = n
      end
      th = _h_get(2, 2)
      if cl != 0
        if th < nh
          th = nh
        elsif th > n
          th = n
        end
      end
      [nh, th, _h_get(4, 2), _h_get(6, 1), _h_get(7, 1), _h_get(8, 1), _h_get(9, 1), _h_get(10, 2), _h_get(12, 2), _h_get(14, 2),
       _h_get(16, 4), _h_get(20, 4), _h_get(24, 4), _h_get(28, 4), _h_get(32, 4), _h_get(36, 4), _h_get(40, 4), _h_get(44, 4),
       _h_get(48, 4), _h_get(52, 4)]
    end
  end

  # netfilter の context (P026 E128) — harness が宣言の kernel の struct の双子 (state の hook / pf・skb の len) を作って渡す。
  class NfCtx
    def initialize(state, skb)
      @state = state
      @skb = skb
    end

    def state(t)
      @state
    end

    def skb(t)
      @skb
    end
  end

  class TpBtfCtx
    def initialize(kptrs, idx, ints)
      @kptrs = kptrs
      @idx = idx
      @ints = ints
    end

    def kptr(i, t)
      j = 0
      while j < @idx.length
        if @idx[j] == i
          return @kptrs[j]
        end
        j += 1
      end
      raise "twin: argument #{i} is not a declared struct argument"
    end

    # nullable の struct の引数 (E088 — harness の `a<i>=null` で nil)
    def kptr_or_null(i, t)
      j = 0
      while j < @idx.length
        if @idx[j] == i
          return @kptrs[j]
        end
        j += 1
      end
      raise "twin: argument #{i} is not a declared struct argument"
    end

    def arg(i)
      @ints[i]
    end
  end

  # uprobe の双子 (P020 E081): 整数の引数 (args[n]) と文字列の引数 (strs[n] — UserStr) と buffer の引数 (bufs[n] — UserBuf — P029 E158) は
  # harness が cfix の命令から作る
  class UprobeCtx
    def initialize(args, strs, bufs)
      @args = args
      @strs = strs
      @bufs = bufs
    end

    def buf_arg(n)
      @bufs[n]
    end

    def arg(n)
      @args[n]
    end

    def str_arg(n)
      @strs[n]
    end
  end

  # user の文字列 (bytes の Array、null は NULL の pointer)
  class UserStr
    def initialize(bytes, null)
      @bytes = bytes
      @null = null
    end

    def bytes
      @bytes
    end

    def null?
      @null
    end
  end

  # P029 E158: 双子の user の buffer (bytes は pointer の先の memory — 読む長さ以上を harness が置く、null は NULL の pointer)
  class UserBuf
    def initialize(bytes, null)
      @bytes = bytes
      @null = null
    end

    def bytes
      @bytes
    end

    def null?
      @null
    end
  end

  # P028 E151: 双子の argv (UserStr の並び — NULL 終端の前の要素だけ。空の要素は空文字列の UserStr)
  class UserStrArray
    def initialize(items)
      @items = items
    end

    def items
      @items
    end
  end

  class OutputStr
    def initialize(status, sent)
      @status = status
      @sent = sent
    end

    def status
      @status
    end

    def sent
      @sent
    end
  end

  # NULL の read の status (−14 = −EFAULT — 変異の対照は harness が 0 に置く — E081)
  USTR_NULL_STATUS = [-14]

  # adjust_head の縮める側の境界 (0 は既定の 14 — 変異の対照 adjh-bound は harness が 13 に置く — P026 E122)
  ADJH_BOUND = [0]

  # uretprobe の合成の context (P026 E112 — 戻り値は harness が宣言の幅で切る)
  class UretprobeCtx
    def initialize(ret)
      @ret = ret
    end

    def ret
      @ret
    end
  end

  # ksyscall の合成の context (P026 E115 — args は添字 n に宣言の幅で切った値、kprobe と同じ形)
  class KsyscallCtx
    def initialize(args, strs, arrs)
      @args = args
      @strs = strs
      @arrs = arrs
    end

    def arg(n)
      @args[n]
    end

    # P028 E143: :user_str の引数 (harness の与えた UserStr — NULL は status −14、空は 1 (7.1.8 の値 — E142 追補 1))
    def str_arg(n)
      @strs[n]
    end

    # P028 E151: :user_str_array の引数 (harness の与えた UserStrArray — 0 個は NULL の argv)
    def argv_arg(n)
      @arrs[n]
    end
  end

  # tracepoint の合成の context (P026 E114 — fields は field の名前 (String) → 値 (harness が宣言の幅で切る))
  class TracepointCtx
    def initialize(fields, strs, arrs, bytes)
      @fields = fields
      @strs = strs
      @arrs = arrs
      @bytes = bytes
    end

    # P029 E153: 固定 byte の配列の field (harness の与えた N byte — 書かない field は全て 0)
    def copy(name)
      @bytes[name.to_s]
    end

    def field(name)
      @fields[name.to_s]
    end

    # P028 E142: :user_str の field (harness の与えた UserStr — NULL は status −14、空は 1 (7.1.8 の値 — E142 追補 1))
    def str_field(name)
      @strs[name.to_s]
    end

    # P028 E151: :user_str_array の field (harness の与えた UserStrArray)
    def argv_field(name)
      @arrs[name.to_s]
    end
  end

  # raw_tp の合成の context (P026 E113 — args は 12 個の整数)
  class RawTpCtx
    def initialize(args)
      @args = args
    end

    def arg(i)
      @args[i]
    end
  end

  # kretprobe の合成の context (P026 E111 — 戻り値は harness が宣言の幅で切る)
  class KretprobeCtx
    def initialize(ret)
      @ret = ret
    end

    def ret
      @ret
    end
  end

  # socket_filter の context (P026 E126) — test run の frame の bytes の数 n から hdr を引いた len (kernel の test run は eth の 14 byte を外す — bpf-mlir E391。
  # harness が hdr に 14 を渡す)。
  class SocketFilterCtx
    def initialize(n, hdr)
      @len = n - hdr
    end

    def len
      @len
    end
  end

  class KprobeCtx
    # reads (P026 E116): "<n>_<offset>" → [値, status] (harness が与える — 与えない読みは [0, 0])
    def initialize(args, reads)
      @args = args
      @reads = reads
    end
  
    def arg(n)
      @args[n]
    end
  
    def read(n, offset, type)
      k = "#{n}_#{offset}"
      if @reads.key?(k)
        @reads[k]
      else
        [0, 0]
      end
    end
  end

  class RecordRef
    def initialize(name, slot)
      @name = name
      @slot = slot
    end

    def load
      _h_view(@name, @slot)
    end

    def atomic_add(member, a, b = 0) # (:m, d) か配列の member の (:m, k, d) — _h_radd が member で読み分ける (P016 E066)
      _h_radd(@name, @slot, member, a, b)
    end
  end

  class RecordMap
    def initialize(name, sample, max_entries)
      @name = name
      @sample = _h_flat(name, sample) # 平らな Array (配列の member は要素ごと — harness が生成 — P016 E066)
      @max_entries = max_entries
      @slots = []
      i = 0
      while i < max_entries
        @slots.push(_h_flat(name, sample))
        i += 1
      end
    end

    def name
      @name
    end

    def max_entries
      @max_entries
    end

    def in_range(key)
      key >= 0 && key < @max_entries
    end

    # update は値の member を slot に写す (kernel の array の update と同じ — 前の lookup の参照も新しい値を見る)。
    def update(key, value)
      if in_range(key)
        src = value.to_a
        i = 0
        while i < src.length
          @slots[key][i] = src[i]
          i += 1
        end
      end
      0
    end

    def lookup(key)
      if in_range(key)
        return RecordRef.new(@name, @slots[key])
      end
      nil
    end

    # slot / reset は twin の harness が使う (eBPF の側の API ではない)。
    def slot(key)
      @slots[key]
    end

    def reset
      k = 0
      while k < @max_entries
        i = 0
        while i < @slots[k].length
          @slots[k][i] = 0
          i += 1
        end
        k += 1
      end
      0
    end
  end

  # ring buffer の双子 (P007 — E028 の容量の model)。予約の大きさは round_up(8 + record の byte, 8) (8 は kernel の event の header)、
  # 使用中 + 予約 > 限度 (size − 1 — kernel の __bpf_ringbuf_reserve の mask) なら output は false。drain は event を返して空にし使用中を 0 に
  # (kernel は consumer が読んだ分だけ空きを戻す — harness の drain は全てを読む)。record の byte と限度は harness が schema から _h_set で置く。
  class RingBuf
    def initialize(name, sample, size)
      @name = name
      @size = size
      @events = []
      @used = 0
      @reserve = 0
      @limit = 0
    end

    def name
      @name
    end

    def _h_set(rec_bytes, limit)
      @reserve = (8 + rec_bytes + 7) / 8 * 8
      @limit = limit
      0
    end

    def output(value)
      if @reserve == 0
        raise "BPF::RingBuf #{@name}: the twin has no record size (the harness sets it)"
      end
      if @used + @reserve > @limit
        return false
      end
      @used += @reserve
      @events.push(value.to_a)
      true
    end

    # output_str (P020 E081) — probe_read_user_str の model (kernel との差動が確かめる): NULL は field を 0 のまま status −14 (USTR_NULL_STATUS)、
    # でなければ min(長さ, N − 1) byte と NUL を field に書き status は書いた byte + 1 (切り詰めは N、空は 1 — 7.1.8 の値)。status は status_field に。
    # 予約の上限は output と同じ (取れなければ nil)。
    def output_str(value, field, str, status_field)
      if @reserve == 0
        raise "BPF::RingBuf #{@name}: the twin has no record size (the harness sets it)"
      end
      if @used + @reserve > @limit
        return nil
      end
      @used += @reserve
      a = value.to_a
      buf = a[value.members.index(field)]
      st = USTR_NULL_STATUS[0]
      if !str.null?
        b = str.bytes
        n = b.length
        if n > buf.length - 1
          n = buf.length - 1
        end
        i = 0
        while i < n
          buf[i] = b[i]
          i += 1
        end
        buf[n] = 0
        st = n + 1
      end
      a[value.members.index(status_field)] = st
      @events.push(a)
      OutputStr.new(st, true)
    end

    # output_buf (P029 E158) — bpf-mlir の user.read の model (kernel との差動が確かめる): n = max(0, min(len, N))、field は全て 0 にしてから
    # NULL かつ n > 0 は status −14 (USTR_NULL_STATUS — field は 0 のまま)、他は先頭 n byte を写し status 0 (n = 0 も 0)。count_field に n。
    def output_buf(value, field, buf, len, status_field, count_field)
      if @reserve == 0
        raise "BPF::RingBuf #{@name}: the twin has no record size (the harness sets it)"
      end
      if @used + @reserve > @limit
        return nil
      end
      @used += @reserve
      a = value.to_a
      fi = value.members.index(field)
      dst = Array.new(a[fi].length, 0)
      n = len
      if n > dst.length
        n = dst.length
      end
      if n < 0
        n = 0
      end
      st = 0
      if buf.null? && n > 0
        st = USTR_NULL_STATUS[0]
      elsif !buf.null?
        b = buf.bytes
        i = 0
        while i < n && i < b.length
          dst[i] = b[i]
          i += 1
        end
      end
      a[fi] = dst
      a[value.members.index(status_field)] = st
      a[value.members.index(count_field)] = n
      @events.push(a)
      OutputStr.new(st, true)
    end

    # output_argv (P028 E151): 双子の argv の先頭 20 の要素ごとに event を積む — field に文字列 (先頭 N−1 byte と NUL)、status は長さ + 1、
    # index_field に要素の番号。予約が取れない要素は積まない (kernel の reserve の失敗と同じ — その slot の event だけが欠ける)
    def output_argv(value, field, argv, status_field, index_field)
      if @reserve == 0
        raise "BPF::RingBuf #{@name}: the twin has no record size (the harness sets it)"
      end
      fi = value.members.index(field)
      si = value.members.index(status_field)
      xi = value.members.index(index_field)
      its = argv.items
      k = 0
      while k < 20 && k < its.length
        if @used + @reserve <= @limit
          @used += @reserve
          a = value.to_a
          src = a[fi]
          buf = Array.new(src.length, 0)
          b = its[k].bytes
          n = b.length
          if n > buf.length - 1
            n = buf.length - 1
          end
          i = 0
          while i < n
            buf[i] = b[i]
            i += 1
          end
          a[fi] = buf
          a[si] = n + 1
          a[xi] = k
          @events.push(a)
        end
        k += 1
      end
      0
    end

    # output_comm (P028 E145): 双子の今の comm (BPF::TASK_COMM — harness が置く) を field に写し、status は 0 (bpf_get_current_comm の成功)
    def output_comm(value, field, status_field)
      if @reserve == 0
        raise "BPF::RingBuf #{@name}: the twin has no record size (the harness sets it)"
      end
      if @used + @reserve > @limit
        return nil
      end
      @used += @reserve
      a = value.to_a
      buf = a[value.members.index(field)]
      i = 0
      while i < 16
        buf[i] = TASK_COMM[i]
        i += 1
      end
      a[value.members.index(status_field)] = 0
      @events.push(a)
      OutputStr.new(0, true)
    end

    # output_str_or_discard (P024 E100): output_str と同じ model で、status < 0 なら event を積まず予約を返す (discard)
    def output_str_or_discard(value, field, str, status_field)
      r = output_str(value, field, str, status_field)
      if r.nil?
        return nil
      end
      if r.status < 0
        @events.pop
        @used -= @reserve
        return OutputStr.new(r.status, false)
      end
      r
    end

    def drain
      out = @events
      @events = []
      @used = 0
      out
    end
  end

  # HashRef は双子の整数の値の hash の present の借用 (P008 E034)。
  class HashRef
    def initialize(map, key)
      @map = map
      @key = key
    end

    def load
      @map.peek(@key)
    end

    def atomic_add(delta)
      @map.atomic_add(@key, delta)
    end
  end

  # LruHashRef は双子の lru_hash の present の借用 (HashRef を HashMap と共有すると HashRef の @map が多相になる — E040 の library の型の静的な試験)。
  class LruHashRef
    def initialize(map, key)
      @map = map
      @key = key
    end

    def load
      @map.peek(@key)
    end

    def atomic_add(delta)
      @map.atomic_add(@key, delta)
    end
  end

  # 双子の hash の map (P008 E034)。値は Integer (lookup は HashRef)。entry は key の文字列 (member の値を `,` で繋ぐ — Spinel の Hash の key を 1 つの型に) → 値。
  # 容量の model: 新しい key で entry が容量 (max_entries — prealloc の hash) なら −E2BIG、在る key の置き換えは満杯でも成功。
  class HashMap
    def initialize(name, key, value, max_entries)
      @name = name
      @rk = !key.is_a?(Symbol)
      @vt = value
      @max_entries = max_entries
      @cap = max_entries
      @vals = {"" => 0}
      @vals.delete("")
      @order = [""]
      @order.pop
    end

    def name
      @name
    end

    def max_entries
      @max_entries
    end

    # _h_cap は harness の変異の対照 (hash-cap — 容量の読み違い) だけが使う。
    def _h_cap(n)
      @cap = n
      0
    end

    def kstr(key)
      if @rk
        return key.to_a.join(",")
      end
      key.to_s
    end

    def wrap(v)
      if @vt == :u32
        return v & 0xffffffff
      end
      if @vt == :i32
        u = v & 0xffffffff
        if u >= 0x80000000
          return u - 0x100000000
        end
        return u
      end
      v
    end

    # write は try_update (flag 0 any・1 noexist・2 exist) の status。
    def write(key, value, flag)
      s = kstr(key)
      has = @vals.key?(s)
      if flag == 1 && has
        return -17
      end
      if flag == 2 && !has
        return -2
      end
      if !has
        if @vals.length >= @cap
          return -7
        end
        @order.push(s)
      end
      @vals[s] = wrap(value)
      0
    end

    def update(key, value)
      write(key, value, 0)
    end

    def insert(key, value)
      write(key, value, 1)
    end

    def replace(key, value)
      write(key, value, 2)
    end

    def delete(key)
      s = kstr(key)
      if !@vals.key?(s)
        return -2
      end
      @vals.delete(s)
      @order.delete(s)
      0
    end

    def add_or_init(key, delta)
      s = kstr(key)
      if @vals.key?(s)
        @vals[s] = wrap(@vals[s] + delta)
        return 0
      end
      write(key, delta, 1)
    end

    # peek / atomic_add は HashRef (present の借用) が使う。
    def peek(s)
      @vals[s]
    end

    def atomic_add(s, delta)
      @vals[s] = wrap(@vals[s] + delta)
      0
    end

    def lookup(key)
      s = kstr(key)
      if @vals.key?(s)
        return HashRef.new(self, s)
      end
      nil
    end

    # _h_keys / _h_val / reset は twin の harness が使う (eBPF の側の API ではない)。
    def _h_keys
      @order.dup
    end

    def _h_val(s)
      [@vals[s]]
    end

    def reset
      @vals.clear
      @order.clear
      0
    end
  end

  # 双子の lru_hash の map (P008 E034)。値は Integer (lookup は HashRef)。entry は key の文字列 (member の値を `,` で繋ぐ — Spinel の Hash の key を 1 つの型に) → 値。
  # 容量の model: 満杯なら最も古く入れた key を 1 つ追い出して status 0 (kernel の LRU は近似で CPU ごとの list に依り victim を固定しない — 差動は数だけを比べる)。
  class LruHashMap
    def initialize(name, key, value, max_entries)
      @name = name
      @rk = !key.is_a?(Symbol)
      @vt = value
      @max_entries = max_entries
      @cap = max_entries
      @vals = {"" => 0}
      @vals.delete("")
      @order = [""]
      @order.pop
    end

    def name
      @name
    end

    def max_entries
      @max_entries
    end

    # _h_cap は harness の変異の対照 (hash-cap — 容量の読み違い) だけが使う。
    def _h_cap(n)
      @cap = n
      0
    end

    def kstr(key)
      if @rk
        return key.to_a.join(",")
      end
      key.to_s
    end

    def wrap(v)
      if @vt == :u32
        return v & 0xffffffff
      end
      if @vt == :i32
        u = v & 0xffffffff
        if u >= 0x80000000
          return u - 0x100000000
        end
        return u
      end
      v
    end

    # write は try_update (flag 0 any・1 noexist・2 exist) の status。
    def write(key, value, flag)
      s = kstr(key)
      has = @vals.key?(s)
      if flag == 1 && has
        return -17
      end
      if flag == 2 && !has
        return -2
      end
      if !has
        if @vals.length >= @cap
          victim = @order.shift
          @vals.delete(victim)
        end
        @order.push(s)
      end
      @vals[s] = wrap(value)
      0
    end

    def update(key, value)
      write(key, value, 0)
    end

    def insert(key, value)
      write(key, value, 1)
    end

    def replace(key, value)
      write(key, value, 2)
    end

    def delete(key)
      s = kstr(key)
      if !@vals.key?(s)
        return -2
      end
      @vals.delete(s)
      @order.delete(s)
      0
    end

    def add_or_init(key, delta)
      s = kstr(key)
      if @vals.key?(s)
        @vals[s] = wrap(@vals[s] + delta)
        return 0
      end
      write(key, delta, 1)
    end

    # peek / atomic_add は HashRef (present の借用) が使う。
    def peek(s)
      @vals[s]
    end

    def atomic_add(s, delta)
      @vals[s] = wrap(@vals[s] + delta)
      0
    end

    def lookup(key)
      s = kstr(key)
      if @vals.key?(s)
        return LruHashRef.new(self, s)
      end
      nil
    end

    # _h_keys / _h_val / reset は twin の harness が使う (eBPF の側の API ではない)。
    def _h_keys
      @order.dup
    end

    def _h_val(s)
      [@vals[s]]
    end

    def reset
      @vals.clear
      @order.clear
      0
    end
  end

  # 双子の hash の map (P008 E034)。値は member の値の Array (lookup は RecordRef — view は harness の _h_view、加算は _h_radd)。entry は key の文字列 (member の値を `,` で繋ぐ — Spinel の Hash の key を 1 つの型に) → 値。
  # 容量の model: 新しい key で entry が容量 (max_entries — prealloc の hash) なら −E2BIG、在る key の置き換えは満杯でも成功。
  class RecordHashMap
    def initialize(name, key, value, max_entries)
      @name = name
      @rk = !key.is_a?(Symbol)
      @vt = :u64
      @max_entries = max_entries
      @cap = max_entries
      @vals = {"" => [0]}
      @vals.delete("")
      @order = [""]
      @order.pop
    end

    def name
      @name
    end

    def max_entries
      @max_entries
    end

    # _h_cap は harness の変異の対照 (hash-cap — 容量の読み違い) だけが使う。
    def _h_cap(n)
      @cap = n
      0
    end

    def kstr(key)
      if @rk
        return key.to_a.join(",")
      end
      key.to_s
    end

    def wrap(v)
      if @vt == :u32
        return v & 0xffffffff
      end
      if @vt == :i32
        u = v & 0xffffffff
        if u >= 0x80000000
          return u - 0x100000000
        end
        return u
      end
      v
    end

    # write は try_update (flag 0 any・1 noexist・2 exist) の status。
    def write(key, value, flag)
      s = kstr(key)
      has = @vals.key?(s)
      if flag == 1 && has
        return -17
      end
      if flag == 2 && !has
        return -2
      end
      if !has
        if @vals.length >= @cap
          return -7
        end
        @order.push(s)
      end
      @vals[s] = value.to_a.dup
      0
    end

    def update(key, value)
      write(key, value, 0)
    end

    def insert(key, value)
      write(key, value, 1)
    end

    def replace(key, value)
      write(key, value, 2)
    end

    def delete(key)
      s = kstr(key)
      if !@vals.key?(s)
        return -2
      end
      @vals.delete(s)
      @order.delete(s)
      0
    end

    def lookup(key)
      s = kstr(key)
      if @vals.key?(s)
        return RecordRef.new(@name, @vals[s])
      end
      nil
    end

    # _h_keys / _h_val / reset は twin の harness が使う (eBPF の側の API ではない)。
    def _h_keys
      @order.dup
    end

    def _h_val(s)
      @vals[s]
    end

    def reset
      @vals.clear
      @order.clear
      0
    end
  end

  # 双子の lru_hash の map (P008 E034)。値は member の値の Array (lookup は RecordRef — view は harness の _h_view、加算は _h_radd)。entry は key の文字列 (member の値を `,` で繋ぐ — Spinel の Hash の key を 1 つの型に) → 値。
  # 容量の model: 満杯なら最も古く入れた key を 1 つ追い出して status 0 (kernel の LRU は近似で CPU ごとの list に依り victim を固定しない — 差動は数だけを比べる)。
  class LruRecordHashMap
    def initialize(name, key, value, max_entries)
      @name = name
      @rk = !key.is_a?(Symbol)
      @vt = :u64
      @max_entries = max_entries
      @cap = max_entries
      @vals = {"" => [0]}
      @vals.delete("")
      @order = [""]
      @order.pop
    end

    def name
      @name
    end

    def max_entries
      @max_entries
    end

    # _h_cap は harness の変異の対照 (hash-cap — 容量の読み違い) だけが使う。
    def _h_cap(n)
      @cap = n
      0
    end

    def kstr(key)
      if @rk
        return key.to_a.join(",")
      end
      key.to_s
    end

    def wrap(v)
      if @vt == :u32
        return v & 0xffffffff
      end
      if @vt == :i32
        u = v & 0xffffffff
        if u >= 0x80000000
          return u - 0x100000000
        end
        return u
      end
      v
    end

    # write は try_update (flag 0 any・1 noexist・2 exist) の status。
    def write(key, value, flag)
      s = kstr(key)
      has = @vals.key?(s)
      if flag == 1 && has
        return -17
      end
      if flag == 2 && !has
        return -2
      end
      if !has
        if @vals.length >= @cap
          victim = @order.shift
          @vals.delete(victim)
        end
        @order.push(s)
      end
      @vals[s] = value.to_a.dup
      0
    end

    def update(key, value)
      write(key, value, 0)
    end

    def insert(key, value)
      write(key, value, 1)
    end

    def replace(key, value)
      write(key, value, 2)
    end

    def delete(key)
      s = kstr(key)
      if !@vals.key?(s)
        return -2
      end
      @vals.delete(s)
      @order.delete(s)
      0
    end

    def lookup(key)
      s = kstr(key)
      if @vals.key?(s)
        return RecordRef.new(@name, @vals[s])
      end
      nil
    end

    # _h_keys / _h_val / reset は twin の harness が使う (eBPF の側の API ではない)。
    def _h_keys
      @order.dup
    end

    def _h_val(s)
      @vals[s]
    end

    def reset
      @vals.clear
      @order.clear
      0
    end
  end

  # PerCpuMapRef は双子の per-CPU の map の present の借用 (MapRef を共有すると MapRef の @map が多相になり、双子の型が崩れる — E039 の gate の TestTwinTypes)。
  class PerCpuMapRef
    def initialize(map, key)
      @map = map
      @key = key
    end

    def load
      @map.peek(@key)
    end

    def atomic_add(delta)
      @map.atomic_add(@key, delta)
    end
  end

  # PerCpuHashRef は双子の per-CPU の map の present の借用 (HashRef を共有すると HashRef の @map が多相になり、双子の型が崩れる — E039 の gate の TestTwinTypes)。
  class PerCpuHashRef
    def initialize(map, key)
      @map = map
      @key = key
    end

    def load
      @map.peek(@key)
    end

    def atomic_add(delta)
      @map.atomic_add(@key, delta)
    end
  end

  # 双子の per-CPU の map (P009 E039) — CPU を 1 つとして BPF::ArrayMap の双子と同じ (harness は kernel の CPU ごとの和と比べ、kernel の harness は 1 つの CPU に固定する)。
  class PerCpuArrayMap
    def initialize(name, value_type, max_entries)
      @name = name
      @value_type = value_type
      @max_entries = max_entries
      @vals = Array.new(max_entries, 0)
    end

    def name
      @name
    end

    def value_type
      @value_type
    end

    def max_entries
      @max_entries
    end

    def in_range(key)
      key >= 0 && key < @max_entries
    end

    def wrap(v)
      if @value_type == :u32
        return v & 0xffffffff
      end
      if @value_type == :i32
        u = v & 0xffffffff
        if u >= 0x80000000
          return u - 0x100000000
        end
        return u
      end
      v
    end

    # reset は twin の harness が全ての slot を 0 にする (eBPF の側の API ではない)。
    def reset
      i = 0
      while i < @max_entries
        @vals[i] = 0
        i += 1
      end
      0
    end

    # poke は twin の harness が入力を置く (eBPF の側の API ではない)。
    def poke(key, value)
      @vals[key] = value
    end

    def atomic_add(key, delta)
      if in_range(key)
        @vals[key] = wrap(@vals[key] + delta)
      end
      0
    end

    def update(key, value)
      if in_range(key)
        @vals[key] = wrap(value)
      end
      0
    end

    def lookup(key)
      if in_range(key)
        return PerCpuMapRef.new(self, key)
      end
      nil
    end

    # peek は twin の harness が map の値を読む (eBPF の側の API ではない)。
    def peek(key)
      @vals[key]
    end
  end

  # 双子の per-CPU の map (P009 E039) — CPU を 1 つとして BPF::RecordMap の双子と同じ (harness は kernel の CPU ごとの和と比べ、kernel の harness は 1 つの CPU に固定する)。
  class PerCpuRecordMap
    def initialize(name, sample, max_entries)
      @name = name
      @sample = _h_flat(name, sample) # 平らな Array (配列の member は要素ごと — harness が生成 — P016 E066)
      @max_entries = max_entries
      @slots = []
      i = 0
      while i < max_entries
        @slots.push(_h_flat(name, sample))
        i += 1
      end
    end

    def name
      @name
    end

    def max_entries
      @max_entries
    end

    def in_range(key)
      key >= 0 && key < @max_entries
    end

    # update は値の member を slot に写す (kernel の array の update と同じ — 前の lookup の参照も新しい値を見る)。
    def update(key, value)
      if in_range(key)
        src = value.to_a
        i = 0
        while i < src.length
          @slots[key][i] = src[i]
          i += 1
        end
      end
      0
    end

    def lookup(key)
      if in_range(key)
        return RecordRef.new(@name, @slots[key])
      end
      nil
    end

    # slot / reset は twin の harness が使う (eBPF の側の API ではない)。
    def slot(key)
      @slots[key]
    end

    def reset
      k = 0
      while k < @max_entries
        i = 0
        while i < @slots[k].length
          @slots[k][i] = 0
          i += 1
        end
        k += 1
      end
      0
    end
  end

  # 双子の per-CPU の map (P009 E039) — CPU を 1 つとして BPF::HashMap の双子と同じ (harness は kernel の CPU ごとの和と比べ、kernel の harness は 1 つの CPU に固定する)。
  class PerCpuHashMap
    def initialize(name, key, value, max_entries)
      @name = name
      @rk = !key.is_a?(Symbol)
      @vt = value
      @max_entries = max_entries
      @cap = max_entries
      @vals = {"" => 0}
      @vals.delete("")
      @order = [""]
      @order.pop
    end

    def name
      @name
    end

    def max_entries
      @max_entries
    end

    # _h_cap は harness の変異の対照 (hash-cap — 容量の読み違い) だけが使う。
    def _h_cap(n)
      @cap = n
      0
    end

    def kstr(key)
      if @rk
        return key.to_a.join(",")
      end
      key.to_s
    end

    def wrap(v)
      if @vt == :u32
        return v & 0xffffffff
      end
      if @vt == :i32
        u = v & 0xffffffff
        if u >= 0x80000000
          return u - 0x100000000
        end
        return u
      end
      v
    end

    # write は try_update (flag 0 any・1 noexist・2 exist) の status。
    def write(key, value, flag)
      s = kstr(key)
      has = @vals.key?(s)
      if flag == 1 && has
        return -17
      end
      if flag == 2 && !has
        return -2
      end
      if !has
        if @vals.length >= @cap
          return -7
        end
        @order.push(s)
      end
      @vals[s] = wrap(value)
      0
    end

    def update(key, value)
      write(key, value, 0)
    end

    def insert(key, value)
      write(key, value, 1)
    end

    def replace(key, value)
      write(key, value, 2)
    end

    def delete(key)
      s = kstr(key)
      if !@vals.key?(s)
        return -2
      end
      @vals.delete(s)
      @order.delete(s)
      0
    end

    def add_or_init(key, delta)
      s = kstr(key)
      if @vals.key?(s)
        @vals[s] = wrap(@vals[s] + delta)
        return 0
      end
      write(key, delta, 1)
    end

    # peek / atomic_add は HashRef (present の借用) が使う。
    def peek(s)
      @vals[s]
    end

    def atomic_add(s, delta)
      @vals[s] = wrap(@vals[s] + delta)
      0
    end

    def lookup(key)
      s = kstr(key)
      if @vals.key?(s)
        return PerCpuHashRef.new(self, s)
      end
      nil
    end

    # _h_keys / _h_val / reset は twin の harness が使う (eBPF の側の API ではない)。
    def _h_keys
      @order.dup
    end

    def _h_val(s)
      [@vals[s]]
    end

    def reset
      @vals.clear
      @order.clear
      0
    end
  end

  # 双子の per-CPU の map (P009 E039) — CPU を 1 つとして BPF::RecordHashMap の双子と同じ (harness は kernel の CPU ごとの和と比べ、kernel の harness は 1 つの CPU に固定する)。
  class PerCpuRecordHashMap
    def initialize(name, key, value, max_entries)
      @name = name
      @rk = !key.is_a?(Symbol)
      @vt = :u64
      @max_entries = max_entries
      @cap = max_entries
      @vals = {"" => [0]}
      @vals.delete("")
      @order = [""]
      @order.pop
    end

    def name
      @name
    end

    def max_entries
      @max_entries
    end

    # _h_cap は harness の変異の対照 (hash-cap — 容量の読み違い) だけが使う。
    def _h_cap(n)
      @cap = n
      0
    end

    def kstr(key)
      if @rk
        return key.to_a.join(",")
      end
      key.to_s
    end

    def wrap(v)
      if @vt == :u32
        return v & 0xffffffff
      end
      if @vt == :i32
        u = v & 0xffffffff
        if u >= 0x80000000
          return u - 0x100000000
        end
        return u
      end
      v
    end

    # write は try_update (flag 0 any・1 noexist・2 exist) の status。
    def write(key, value, flag)
      s = kstr(key)
      has = @vals.key?(s)
      if flag == 1 && has
        return -17
      end
      if flag == 2 && !has
        return -2
      end
      if !has
        if @vals.length >= @cap
          return -7
        end
        @order.push(s)
      end
      @vals[s] = value.to_a.dup
      0
    end

    def update(key, value)
      write(key, value, 0)
    end

    def insert(key, value)
      write(key, value, 1)
    end

    def replace(key, value)
      write(key, value, 2)
    end

    def delete(key)
      s = kstr(key)
      if !@vals.key?(s)
        return -2
      end
      @vals.delete(s)
      @order.delete(s)
      0
    end

    def lookup(key)
      s = kstr(key)
      if @vals.key?(s)
        return RecordRef.new(@name, @vals[s])
      end
      nil
    end

    # _h_keys / _h_val / reset は twin の harness が使う (eBPF の側の API ではない)。
    def _h_keys
      @order.dup
    end

    def _h_val(s)
      @vals[s]
    end

    def reset
      @vals.clear
      @order.clear
      0
    end
  end

  # LpmRef は双子の lpm_trie の present の借用 (E121 — ref の class を他の map と共有しない: E039 の欠陥 2・E040 H6)。
  class LpmRef
    def initialize(map, i)
      @map = map
      @i = i
    end

    def load
      @map.peek(@i)
    end
  end

  # 双子の lpm_trie の map (E121)。entry は prefixlen・address (u32 — network の順の 4 byte を上位から)・値の 3 本の Integer の配列 (要素の型を 1 つに)。
  # lookup は全ての entry を走査して一致する prefixlen の最大 (naive な最長一致)。容量の model: 新しい prefix で entry が max_entries なら −ENOSPC、
  # 在る prefix の上書きは満杯でも成功 (bpf-mlir / go-bpf-mlir E091 / mojo E082 の実測と同じ)。
  class LpmTrieMap
    def initialize(name, value, max_entries)
      @name = name
      @vt = value
      @max_entries = max_entries
      @plens = [0]
      @plens.pop
      @addrs = [0]
      @addrs.pop
      @vals = [0]
      @vals.pop
      @shortest = false
      @full_over = false
    end

    def name
      @name
    end

    def max_entries
      @max_entries
    end

    def wrap(v)
      u = v & 0xffffffff
      if @vt == :i32 && u >= 0x80000000
        return u - 0x100000000
      end
      u
    end

    # _h_shortest / _h_full_overwrite は harness の変異の対照 (lpm-shortest — 最短一致・lpm-full-overwrite — 満杯の上書きを −ENOSPC に) だけが使う。
    def _h_shortest
      @shortest = true
      0
    end

    def _h_full_overwrite
      @full_over = true
      0
    end

    def mask(plen)
      if plen == 0
        return 0
      end
      (0xffffffff << (32 - plen)) & 0xffffffff
    end

    # lpm_best は x を含む entry の添字 (最長一致 — 無ければ −1)。
    def lpm_best(x)
      best = -1
      i = 0
      while i < @plens.length
        if (x & mask(@plens[i])) == @addrs[i]
          if best < 0 || (!@shortest && @plens[i] > @plens[best]) || (@shortest && @plens[i] < @plens[best])
            best = i
          end
        end
        i += 1
      end
      best
    end

    def lookup(a0, a1, a2, a3)
      i = lpm_best((a0 << 24) | (a1 << 16) | (a2 << 8) | a3)
      if i >= 0
        return LpmRef.new(self, i)
      end
      nil
    end

    def peek(i)
      @vals[i]
    end

    # _h_addr は "a.b.c.d" の u32 (harness の入力は試験が書く — 形の誤りは見ない)。
    def _h_addr(s)
      p = s.split(".")
      (p[0].to_i << 24) | (p[1].to_i << 16) | (p[2].to_i << 8) | p[3].to_i
    end

    def _h_exact(plen, a)
      i = 0
      while i < @plens.length
        if @plens[i] == plen && @addrs[i] == a
          return i
        end
        i += 1
      end
      -1
    end

    # _h_put / _h_remove / _h_match / _h_list / reset は twin の harness が使う (eBPF の側の API ではない)。put は 0 か −28、remove は 0 か −2。
    def _h_put(prefix, v)
      f = prefix.split("/")
      plen = f[1].to_i
      a = _h_addr(f[0])
      i = _h_exact(plen, a)
      if i >= 0 && @full_over && @plens.length >= @max_entries
        return -28
      end
      if i >= 0
        @vals[i] = wrap(v)
        return 0
      end
      if @plens.length >= @max_entries
        return -28
      end
      @plens.push(plen)
      @addrs.push(a)
      @vals.push(wrap(v))
      0
    end

    def _h_remove(prefix)
      f = prefix.split("/")
      i = _h_exact(f[1].to_i, _h_addr(f[0]))
      if i < 0
        return -2
      end
      @plens.delete_at(i)
      @addrs.delete_at(i)
      @vals.delete_at(i)
      0
    end

    # _h_match は最長一致の値の 10 進か "absent" (kernel の側の lpm_match と同じ綴り)。
    def _h_match(s)
      i = lpm_best(_h_addr(s))
      if i < 0
        return "absent"
      end
      @vals[i].to_s
    end

    def _h_ip(a)
      "#{(a >> 24) & 255}.#{(a >> 16) & 255}.#{(a >> 8) & 255}.#{a & 255}"
    end

    # _h_list は "a.b.c.d/n v" の行 (順は harness が並べ直す)。
    def _h_list
      out = [""]
      out.pop
      i = 0
      while i < @plens.length
        out.push("#{_h_ip(@addrs[i])}/#{@plens[i]} #{@vals[i]}")
        i += 1
      end
      out
    end

    def reset
      @plens.clear
      @addrs.clear
      @vals.clear
      0
    end
  end

  def self.fentry(name, target, opts = nil)
    name
  end

  def self.fexit(name, target, opts)
    name
  end

  def self.kprobe(name, target, opts)
    name
  end

  def self.kretprobe(name, target, opts)
    name
  end

  def self.raw_tp(name, target)
    name
  end

  def self.tracepoint(name, target, opts)
    name
  end

  def self.ksyscall(name, target, opts)
    name
  end

  def self.xdp(name)
    name
  end

  def self.tcx(name, direction)
    name
  end

  def self.flow_dissector(name)
    name
  end

  def self.sk_lookup(name)
    name
  end

  def self.netfilter(name)
    name
  end

  def self.fmod_ret(name, target, opts)
    name
  end

  # P028 E144: 双子の fmod_ret の戻り値は e そのもの (FMOD_CALL は 0 — harness が ret= に出す)
  def self.fmod_return(e)
    e
  end

  def self.cgroup_skb(name, direction)
    name
  end

  def self.socket_filter(name)
    name
  end

  def self.uprobe(name, path, symbol, opts)
    name
  end

  def self.uretprobe(name, path, symbol, opts)
    name
  end

  def self.kernel_type(s, name, opts)
    name
  end

  def self.tp_btf(name, tracepoint, opts)
    name
  end
end
