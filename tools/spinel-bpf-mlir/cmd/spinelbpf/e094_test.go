package main

import (
	"fmt"
	"path/filepath"
	"strings"
	"testing"
)

// TestSubprogramBorrowDifferential は E094 の H5 (host、root): 同じ計算を inline に書いた program (key 0 の entry・Out[0] / Out[2]) と借用の
// helper を呼ぶ program (key 1・Out[1] / Out[3]) を Vals の値の表で 2 回ずつ走らせ、kernel と双子の dump が一致し、inline と helper の値が一致する。
func TestSubprogramBorrowDifferential(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046
	h := buildHarnesses(t, filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "sub", "t_sub2.rb"))
	for _, v := range []string{"0", "5", "65535", "70000", "9223372036854775000"} {
		script := fmt.Sprintf("reset\npoke Vals 0 %s\npoke Vals 1 %s\nrun p_inline\nrun p_helper\nrun p_inline\nrun p_helper\ndump\n", v, v)
		kn := feed(t, true, script, h.kernelBin)
		tw := feed(t, false, script, h.twinBin)
		sameDump(t, "Vals="+v, kn, tw)
		if ks, ws := recordLines(kn, "Stats["), recordLines(tw, "Stats["); ks == "" || ks != ws { // record の member の行 (traceDumpLines の外)
			t.Errorf("Vals=%s: kernel and twin Stats differ\nkernel: %s\ntwin: %s", v, ks, ws)
		}
		t.Logf("Vals=%s kernel: %s %s", v, strings.Join(traceDumpLines(kn), " "), recordLines(kn, "Stats["))
		for _, pr := range [][2]string{{"Vals[0]", "Vals[1]"}, {"Out[0]", "Out[1]"}, {"Out[2]", "Out[3]"}, {"Stats[0].hits", "Stats[1].hits"}, {"Stats[0].last", "Stats[1].last"}, {"Stats[0].tag", "Stats[1].tag"}} {
			a, b := dumpVal(kn, pr[0]), dumpVal(kn, pr[1])
			if a == "" || a != b {
				t.Errorf("Vals=%s: inline %s=%q, helper %s=%q\n%s", v, pr[0], a, pr[1], b, kn)
			}
		}
	}
}

// recordLines は dump の prefix で始まる行 (record の member — `Stats[0].hits=2`) を空白で繋いだ物。
func recordLines(out, prefix string) string {
	var r []string
	for _, l := range strings.Split(out, "\n") {
		if strings.HasPrefix(l, prefix) {
			r = append(r, l)
		}
	}
	return strings.Join(r, " ")
}
