//go:build spinelbpf_mutation

package main

import (
	"os"
	"strings"
	"testing"
)

// TestHookPercpuShared は E039 の H2 (root): 免除を共有の map に漏らす hook (percpu-exempt-all) で compile した共有の RecordMap の += は数え落とす。
// 差が 0 なら対照は効いていない — loud に落とす (対照の感度の注 — E022 / E035 と同じ)。
func TestHookPercpuShared(t *testing.T) {
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	o := pcpuMC(t, "mc_shared", "percpu-exempt-all", 20000)
	t.Logf("H2: the shared RecordMap += lost %d of %d (n) and %d of %d (m)", o.nominal-o.sumN, o.nominal, 2*o.nominal-o.sumM, 2*o.nominal)
	if o.sumN >= o.nominal {
		t.Errorf("H2: the shared += lost nothing (n %d, nominal %d)", o.sumN, o.nominal)
	}
}

// TestHookPercpuFaddSub は E039 の H4 (root): hook fadd-sub (per-CPU の record の member の += を subi に) で twin と kernel (taskset -c 0) が食い違い、
// 最初の食い違いが add の行の record の member の和。
func TestHookPercpuFaddSub(t *testing.T) {
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	t.Setenv("SPINELBPF_MUTATION", "fadd-sub")
	h := buildHarnesses(t, tPcpuSrc())
	os.Unsetenv("SPINELBPF_MUTATION")
	script := tPcpuScript()
	tw := feed(t, false, script, h.twinBin)
	kn := feed(t, true, script, "taskset", "-c", "0", h.kernelBin)
	d := ringDiff(tw, kn)
	t.Logf("fadd-sub: %s", d)
	if d == "" || !strings.HasPrefix(d, "row add ") || !strings.Contains(d, "\"PR[0].a=") {
		t.Errorf("want the first difference at row add on PR[0].a, got %q", d)
	}
}
