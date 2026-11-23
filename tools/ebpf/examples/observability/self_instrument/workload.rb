# E244/E245 S1: 複数メソッド + 非再帰の被計装ワークロード。
#
# add / square / driver はいずれも非再帰。`cc -O2` は通常これらを呼出元へ inline
# 消滅させる (E243 control) が、`--instrument` は選択メソッドに noinline を注入する
# ので sp_add / sp_square / sp_driver がシンボルとして残り、uprobe で計測できる。
#
# build: bin/spinel-ebpf compile examples/observability/self_instrument/workload.rb --instrument -o build
# run (既定 = Prometheus /metrics, E247):
#   SPNL_UPROBE_BINARY=$PWD/build/workload SPINEL_HTTP_PORT=9100 ./build/workload_agent &
#   ./build/workload    # を N 回。 curl localhost:9100/metrics
#   -> spnl_method_calls_total{method="add"} 10N  (square も)、driver 1N、
#      spnl_method_latency_ns{...,quantile="0.5"} は driver >> add/square。
# one-shot で stderr に hist を吐くなら --instrument-dump (E246)。
# 単一 self-attaching binary (sidecar 不要) は --instrument-self (E248):
#   bin/spinel-ebpf compile <this> --instrument --instrument-self -o build
#   SPINEL_HTTP_PORT=9100 ./build/workload_self    # workload 実行 -> /metrics
# 再帰メソッドは --instrument-depth-collapse で最外呼出のみ計測 (E249)。
# 詳細は E245-E249。
def add(a, b)
  a + b
end

def square(x)
  x * x
end

def driver(n)
  i = 0
  total = 0
  while i < n
    total = add(total, square(i))
    i = i + 1
  end
  total
end

puts driver(10)   # add/square を各 10 回、driver を 1 回呼ぶ -> 285
