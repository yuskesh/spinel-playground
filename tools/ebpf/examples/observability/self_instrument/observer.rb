# E243: spinel-ebpf 専用計装の observer。
#
# 「spinel が出した AOT binary を、spinel-ebpf 自身が eBPF で計装する」 — OBI が
# Go の DWARF と格闘している問題の裏返し。spinel はコンパイラなので関数シンボル
# (`sp_<method>`) と引数 ABI (PT_REGS_PARM<N>) を compile-time に確定でき、DWARF
# 不要で uprobe を貼れる。
#
#   def uprobe__sp_fib(n)   ... target binary の `sp_fib` に uprobe を attach、
#                               第 1 引数 n を PT_REGS_PARM1 で捕捉して ringbuf emit
#   on_emit do |v| ...      ... userspace 側 (E242 consumer DSL) で集計
#
# build: bin/spinel-ebpf compile examples/observability/self_instrument/observer.rb \
#          --build --ebpf-dispatch -o build
# run:   SPNL_UPROBE_BINARY=$PWD/build/target ./build/observer &
#        ./build/target            # sp_fib が 177 回 fire
#   -> count=177  sum=364   (= 177 呼出 / 全 n 引数の総和)
@count = 0
@sum   = 0

def uprobe__sp_fib(n)
  spnl_emit(n)
end

on_emit do |v|
  @count = @count + 1
  @sum   = @sum + v
end

# 固定回ポーリングで drain 窓を作る (sleep FFI が無いため反復数で時間窓を確保)。
# 各 consume_events(100) は最大 100ms epoll wait。100 反復 = 最大 ~10s。
i = 0
while i < 100
  consume_events(100)
  i = i + 1
end

puts @count
puts @sum
