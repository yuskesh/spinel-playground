package main

import (
	"fmt"
	"regexp"
	"strings"
	"testing"
)

// E073 の試験: 早い return の guard — .mlir の形・双子 (Ruby の return) と kernel の判定の差動・否定を外す変異。

// TestEarlyReturnShapes は E073 の H1・H6・H7: verdict.if 1 つ・単独の verdict 無し・i1 の ebpf.if の数・guard の後ろの loop。
func TestEarlyReturnShapes(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	for _, c := range []struct {
		name   string
		guards int
		has    []string
	}{
		{"early_return", 2, []string{`ebpf.verdict.if`, `"drop" else "pass"`, "ebpf.ref.index"}},
		{"early_return_deep", 3, []string{`ebpf.verdict.if`, "ebpf.loop 8 unroll"}},
	} {
		m := readIn(t, buildPos(t, c.name, ""), c.name+".mlir")
		if n := strings.Count(m, "ebpf.verdict.if"); n != 1 {
			t.Errorf("%s: %d ebpf.verdict.if, want 1", c.name, n)
		}
		if regexp.MustCompile(`ebpf\.verdict "`).MatchString(m) {
			t.Errorf("%s: a plain ebpf.verdict besides the verdict.if", c.name)
		}
		if n := len(regexp.MustCompile(`= ebpf\.if %v\d+ -> i1 \{`).FindAllString(m, -1)); n != c.guards {
			t.Errorf("%s: %d i1 ebpf.if, want %d", c.name, n, c.guards)
		}
		for _, h := range c.has {
			if !strings.Contains(m, h) {
				t.Errorf("%s: no %q", c.name, h)
			}
		}
	}
}

// guardScript は In の値の行 (reset → Hs[0].hist[m] = 100 + m → In → run → dump)。
func guardScript(ks []string) string {
	var b strings.Builder
	for r, k := range ks {
		fmt.Fprintf(&b, "echo r%d\nreset\n", r)
		for m := 0; m < 8; m++ {
			fmt.Fprintf(&b, "poke Hs 0 hist[%d] %d\n", m, 100+m)
		}
		fmt.Fprintf(&b, "poke In 0 %s\nrun prog\ndump\n", k)
	}
	return b.String()
}

var guardRows = map[string][]string{
	"early_return":      {"-5", "-1", "0", "3", "7", "8", "100"},
	"early_return_deep": {"12", "13", "14", "100", "101", "-100", "-101"},
}

// TestEarlyReturnDifferential は E073 の H2・H8・H9 (root): guard の境界の行で双子と kernel の ret= と dump が一致、最初の guard の条件の否定の変異は全ての行で食い違う。
func TestEarlyReturnDifferential(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	firstGuard := regexp.MustCompile(`(%v\d+) = ebpf\.if (%v\d+) -> i1 \{`)
	for _, name := range []string{"early_return", "early_return_deep"} {
		ks := guardRows[name]
		h := buildHarnesses(t, posSrc(name))
		s := guardScript(ks)
		tw := feed(t, false, s, h.twinBin)
		kn := feed(t, true, s, h.kernelBin)
		if strings.Contains(tw, "err=") || strings.Contains(kn, "err=") {
			t.Fatalf("%s: an error line — twin:\n%s\nkernel:\n%s", name, tw, kn)
		}
		for i, x := range loopDiff(t, tw, kn, len(ks)) {
			t.Errorf("%s row %d (k %s): twin and kernel differ in %v", name, i, ks[i], keysOf(x))
		}
		if name == "early_return" {
			bl := loopBlocks(t, tw, len(ks))
			for i, k := range ks {
				want := "2"
				if k == "-5" || k == "-1" || k == "8" || k == "100" {
					want = "1"
				}
				if bl[i]["ret"] != want {
					t.Errorf("early_return k %s: ret=%s, want %s", k, bl[i]["ret"], want)
				}
			}
		}
		// H9: 最初の guard の条件を否定 (frontend の否定の腕を外す)
		mut, _, _ := mutatedKernelNamed(t, h, name, func(m string) (string, bool) {
			x := firstGuard.FindStringSubmatchIndex(m)
			if x == nil {
				return m, false
			}
			line := strings.LastIndex(m[:x[0]], "\n") + 1
			ind := m[line:x[0]]
			c := m[x[4]:x[5]]
			pre := fmt.Sprintf("%%mt = arith.constant true\n%s%%mn = arith.xori %s, %%mt : i1\n%s", ind, c, ind)
			return m[:x[0]] + pre + m[x[2]:x[3]] + " = ebpf.if %mn -> i1 {" + m[x[1]:], true
		})
		km := feed(t, true, s, mut)
		d := loopDiff(t, tw, km, len(ks))
		if len(d) != len(ks) {
			t.Errorf("%s: the negation mutation differs in %d of %d rows, want all", name, len(d), len(ks))
		}
		t.Logf("%s: %d rows agree, mutation differs in %d rows", name, len(ks), len(d))
	}
}
