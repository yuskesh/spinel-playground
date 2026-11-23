# examples/observability/uprobe_demo.rb
#
# E081: uprobe + uretprobe attach demo.
#
# Counts calls to readline() in bash (or any binary exporting the symbol).
# The target binary path comes from $SPNL_UPROBE_BINARY at runtime;
# $SPNL_UPROBE_PID restricts attach to a single process (default -1 = all).
#
# Build:
#   bin/spinel-ebpf compile examples/observability/uprobe_demo.rb \
#                   -o build/uprobe_demo --build
#
# Run:
#   SPNL_UPROBE_BINARY=/usr/bin/bash ./build/uprobe_demo/uprobe_demo &
#   bash -c 'echo "hello"; echo "world"'   # generates 2 readline calls
#
# Inspect:
#   # カーネルが保持する map 名は 15 文字までなので、この 2 本は
#   # どれも `uprobe_demo_top` に見えて名前では区別できない。id で 1 本ずつ引く:
#   bpftool map show | grep uprobe_demo_top
#   bpftool map dump id <上で出た id>

@calls = 0
@returns = 0

def uprobe__readline(prompt)
  @calls = @calls + 1
end

def uretprobe__readline(ret)
  @returns = @returns + 1
end

puts "[E081] uprobe_demo loaded — set SPNL_UPROBE_BINARY=/usr/bin/bash and trigger readline"
sleep 3600
