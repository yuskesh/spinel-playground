# examples/observability/usdt_libstdcxx_demo.rb
#
# E081: USDT (User Statically-Defined Tracing) attach demo.
#
# libstdc++.so.6 ships with two USDT probes:
#   libstdcxx:throw   — fires on `throw <expr>` (C++ exception throw)
#   libstdcxx:catch   — fires when the runtime hands the exception to a handler
#
# Counts both. Doesn't read the args (they're typeinfo + object pointers,
# not very interesting from BPF without symbol resolution).
#
# Build:
#   bin/spinel-ebpf compile examples/observability/usdt_libstdcxx_demo.rb \
#                   -o build/usdt_libstdcxx --build
#
# Run (need a process that throws):
#   SPNL_USDT_BINARY=/usr/lib/aarch64-linux-gnu/libstdc++.so.6 \
#       ./build/usdt_libstdcxx/usdt_libstdcxx_demo &
#   # Then run any C++ binary that throws — e.g. our throw_loop sample.
#
# Inspect:
#   # カーネルが保持する map 名は 15 文字までなので、この 2 本は
#   # どれも `usdt_libstdcxx_` に見えて名前では区別できない。id で 1 本ずつ引く:
#   bpftool map show | grep usdt_libstdcxx_
#   bpftool map dump id <上で出た id>

@throws = 0
@catches = 0

def usdt__libstdcxx__throw(obj, tinfo, dest)
  @throws = @throws + 1
end

def usdt__libstdcxx__catch(obj, tinfo)
  @catches = @catches + 1
end

puts "[E081] usdt_libstdcxx_demo loaded — set SPNL_USDT_BINARY=/usr/lib/.../libstdc++.so.6 and run a throwing C++ process"
sleep 3600
