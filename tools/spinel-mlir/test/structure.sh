#!/bin/sh
set -eu
B="${1:?build directory}"
T="$B/structure-test"
N="$B/bin/spinel-ir-normalize"
if [ ! -x "$N" ]; then echo "E001 structure: normalizer not built" >&2; exit 1; fi
mkdir -p "$T"
cat > "$T/a.mlir" <<'IR'
ebpf.program @p "xdp" {
^entry(%ctx: !ebpf.ctx<"xdp">):
  ebpf.verdict "pass" loc("example.rb":5:3)
} loc("example.rb":4:1)
IR
cat > "$T/b.mlir" <<'IR'
// whitespace and SSA are not semantic
ebpf.program @p "xdp" {

^entry(%other: !ebpf.ctx<"xdp">):
    ebpf.verdict "pass" loc("example.rb":5:3)

} loc("example.rb":4:1)
IR
cat > "$T/c.mlir" <<'IR'
ebpf.program @p "xdp" {
^entry(%ctx: !ebpf.ctx<"xdp">):
  ebpf.verdict "pass" loc("example.rb":6:3)
} loc("example.rb":4:1)
IR
"$N" "$T/a.mlir" > "$T/a.txt"
"$N" "$T/b.mlir" > "$T/b.txt"
"$N" "$T/c.mlir" > "$T/c.txt"
cmp "$T/a.txt" "$T/b.txt"
if cmp -s "$T/a.txt" "$T/c.txt"; then
  echo "E001 structure: changed Ruby loc escaped comparison" >&2
  exit 1
fi
echo "E001 structure: whitespace/SSA GREEN; Ruby loc mutation RED"
