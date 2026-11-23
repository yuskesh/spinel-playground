package main

import "testing"

// TestUprobePtrTwinSmoke は H3 の非 root の部分: 双子の `at` は引数 1 に raw の値を置き (幅で切らない)、unlock は Held を 0 に — AB-BA で辺 2 つ。
func TestUprobePtrTwinSmoke(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	h := sysHarnesses(t, "up_libc_lock")
	out := feed(t, false, "task 4294967297\nreset\nrun on_lock at 94000000000001\nrun on_lock at 94000000000002\nrun on_unlock unlock 1\nrun on_unlock unlock 0\nrun on_lock at 94000000000002\nrun on_lock at 94000000000001\ndump\ndrain Edges\n", h.twinBin)
	t.Log(out)
	wantLines(t, out, "Out[0]=4", "Out[1]=2", "Out[2]=0", "Held{1}=94000000000001", "Edges#0.from=94000000000001", "Edges#0.to=94000000000002", "Edges#1.from=94000000000002", "Edges#1.to=94000000000001")
}
