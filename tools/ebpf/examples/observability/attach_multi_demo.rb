# examples/observability/attach_multi_demo.rb
#
# E401 (P011 S12): 1 定義 → 複数 attach。
#
#   on :kprobe, %w[vfs_read vfs_write vfs_open] do ... end
#
# 1 つの body が 3 つのカーネル関数に載る。**どちらの下回りが使われるかは
# body から見えない** — 展開 (N プログラム) でも kprobe_multi (1 プログラム +
# per-symbol cookie) でも、「今どのシンボルか」の綴りは
# `attached_symbol_eq("...")` / `attached_index` の 1 通りだけ。
# リストが伸びて codegen が機構を切り替えても body は 1 文字も変わらない。
#
# `via: :expand` / `via: :multi` で機構を名指しできる。それは body のためでは
# なく**配備**のため: kprobe_multi はカーネル下限を 5.18 に上げるので、
# 上げられない環境向けに展開を選べる必要がある。
#
# filter_by :comm は測定を決定的にするためのもの (E399)。この probe と無関係な
# プロセスの vfs_* を数えない。
#
# Build:
#   spinel-ebpf compile examples/observability/attach_multi_demo.rb \
#       -o build/attach_multi_demo --build
# Run:
#   SPNL_FILTER_COMM=cat ./build/attach_multi_demo/attach_multi_demo &
#   cat /etc/hostname > /dev/null
#   bpftool map dump name bpf_path_counts   # key = attached_index (0/1/2)
#   bpftool map dump name attach_multi_de   # @reads (attached_symbol_eq 経路)

filter_by :comm

@reads = 0

module VfsAudit
  include BPF::EventLoop

  on :kprobe, %w[vfs_read vfs_write vfs_open] do
    # 「今どのシンボルか」を訊く 2 つの形。どちらも同じ 1 本の値
    # (inner の __spnl_sym) に lower されるので、機構が切り替わっても意味は不変。
    #
    #   index 形  — 出力に載せる用 (index → 名前の対応は describe が公開する)
    path_counter_inc(attached_index)
    #   名前形    — 判断に使う用 (リストを並べ替えても壊れない / typo は compile error)
    if attached_symbol_eq("vfs_read")
      @reads = @reads + 1
    end
  end
end

puts "[E401] VfsAudit loaded (one body, three symbols)"
sleep 3600
