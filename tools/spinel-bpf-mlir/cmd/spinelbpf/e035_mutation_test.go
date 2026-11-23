//go:build spinelbpf_mutation

package main

import "testing"

// TestHookHashMultiCPU は E035 の H4・H5 (root): 再試行の加算を外した add_or_init (aoi-no-retry-add) と、lookup → update の非 atomic (no-rmw の mc_rmw) は数え落とす。
// 差が 0 なら対照は効いていない (環境が競合を作れない) — loud に落とす (黙って「落とさない」側に通さない)。
func TestHookHashMultiCPU(t *testing.T) {
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	o := hashMC(t, "mc", "aoi-no-retry-add", 20000, false)
	t.Logf("H4: retries (lost adds) = %d of %d executions", o.stat[0]-o.counts, o.stat[0])
	if o.counts >= o.stat[0] {
		t.Errorf("H4: removing the retry add lost nothing (Σ %d, executions %d) — the −EEXIST path was not exercised here", o.counts, o.stat[0])
	}
	r := hashMC(t, "mc_rmw", "no-rmw", 20000, false)
	t.Logf("H5: lookup → update lost %d of %d", r.stat[0]-r.counts, r.stat[0])
	if r.counts >= r.stat[0] {
		t.Errorf("H5: the non-atomic lookup → update lost nothing (Σ %d, executions %d)", r.counts, r.stat[0])
	}
}
