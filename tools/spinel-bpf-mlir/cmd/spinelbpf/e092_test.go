package main

import (
	"fmt"
	"path/filepath"
	"strings"
	"testing"
)

// E092 の試験 (P023 段 1 — 整数の static の helper)。

// TestSubprogramDifferential は E092 の H7 (host、root): 同じ計算を inline に書いた program と helper を呼ぶ program を In の値の表で走らせ、
// kernel と双子の dump が一致し、inline の Out[0..3] と helper の Out[4..7] が一致する。
func TestSubprogramDifferential(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046
	h := buildHarnesses(t, filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "sub", "t_sub.rb"))
	vals := [][2]string{{"0", "0"}, {"1", "2"}, {"65535", "255"}, {"12345", "7"}, {"70000", "65536"}, {"9223372036854775807", "300"}}
	for _, v := range vals {
		script := fmt.Sprintf("reset\npoke In 0 %s\npoke In 1 %s\nrun p_inline\nrun p_helper\nrun p_inline\nrun p_helper\ndump\n", v[0], v[1])
		kn := feed(t, true, script, h.kernelBin)
		tw := feed(t, false, script, h.twinBin)
		sameDump(t, "In="+v[0]+","+v[1], kn, tw)
		t.Logf("In=%v kernel:\n%s", v, strings.Join(traceDumpLines(kn), " "))
		for i := 0; i < 4; i++ {
			a, b := dumpVal(kn, fmt.Sprintf("Out[%d]", i)), dumpVal(kn, fmt.Sprintf("Out[%d]", i+4))
			if a == "" || a != b {
				t.Errorf("In=%v: inline Out[%d]=%q, helper Out[%d]=%q\n%s", v, i, a, i+4, b, kn)
			}
		}
	}
}

// dumpVal は dump の `key=value` の value ("" は無い)。
func dumpVal(out, key string) string {
	for _, l := range strings.Split(out, "\n") {
		if strings.HasPrefix(l, key+"=") {
			return strings.TrimPrefix(l, key+"=")
		}
	}
	return ""
}

// TestSubprogramRingHost は E092 の H6 (host、root): ring buffer の output を持つ helper (loop の外の call) の program が load され、test run で予約が
// 取れ (Out[0]=1)、双子と dump が一致する。
func TestSubprogramRingHost(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046
	h := buildHarnesses(t, filepath.Join(repoRoot(), "internal", "frontend", "testdata", "pos", "sub_ring.rb"))
	script := "reset\nrun prog\ndump\n"
	kn := feed(t, true, script, h.kernelBin)
	tw := feed(t, false, script, h.twinBin)
	sameDump(t, "sub_ring", kn, tw)
	if !strings.Contains(kn, "Out[0]=1\n") {
		t.Errorf("kernel: want Out[0]=1 (the helper's ring output reserved):\n%s", kn)
	}
	t.Logf("kernel:\n%s\ntwin:\n%s", kn, tw)
}
