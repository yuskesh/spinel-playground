# spinel-tier: arena
# E093 control -- what tier arena still allows.  An UNBOXED global survives the
# escape check (the allow-list in tools/platform/arena.yaml), and $stdout /
# $stderr are runtime-owned handles the ledger exempts: a `$stdout.write` is a
# READ of a global, never a store into one.
$hits = 0
$hits += 1
$stdout.write("hits=" + $hits.to_s + "\n")
