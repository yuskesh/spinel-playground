# E243: self-instrumentation の被計装プログラム (target)。
#
# spinel が AOT した binary は、Ruby メソッド `def fib` を C 関数 `sp_fib` に
# lower する。再帰メソッドは `cc -O2` でも inline されず .symtab にシンボルが
# 残る (非再帰 `def work` は inline 消滅する — E243 本文参照)。この `sp_fib`
# シンボルを observer.rb が uprobe で計装する。
#
# build: bin/spinel-ebpf compile examples/observability/self_instrument/target.rb --native-only -o build
# run:   ./build/target            # -> 55 (fib(10))
#   fib(10) は naive 再帰で 2*fib(11)-1 = 177 回 sp_fib を呼ぶ。
def fib(n)
  if n < 2
    n
  else
    fib(n - 1) + fib(n - 2)
  end
end

puts fib(10)
