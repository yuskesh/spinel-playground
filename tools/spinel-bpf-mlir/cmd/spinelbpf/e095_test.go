package main

import (
	"fmt"
	"path/filepath"
	"strings"
	"testing"
)

// E095 の試験 (P023 段 3 — 窓と context の引数、hash の借用の helper)。

// eth は dst・src の 12 byte の 0 と ethertype・続きの byte (hex)。
func eth(etype, rest string) string {
	return strings.Repeat("00", 12) + etype + rest
}

// TestSubprogramWindowDifferential は E095 の H4 (host、root): packet の表で xdp (inline Out[0..1] と窓 / context の helper Out[2..3]) と
// sched_cls (inline Out[4] と窓の helper Out[5]) を走らせ、kernel と双子の dump が一致し、inline = helper。
func TestSubprogramWindowDifferential(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046
	h := buildHarnesses(t, filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "sub", "t_sub3.rb"))
	ipv4 := func(proto string) string { // IPv4 の header の 20 byte (proto は byte 23 = header の 9 byte 目)
		return eth("0800", "4500001c00000000"+"40"+proto+strings.Repeat("00", 10))
	}
	pkts := map[string]string{"ipv4-tcp": ipv4("06"), "ipv4-udp": ipv4("11"), "arp": eth("0806", strings.Repeat("00", 28)), "short": strings.Repeat("00", 10), "ipv6": eth("86dd", strings.Repeat("00", 40))}
	for _, name := range []string{"ipv4-tcp", "ipv4-udp", "arp", "short", "ipv6"} {
		p := pkts[name]
		script := fmt.Sprintf("reset\nrun x_inline %s\nrun x_helper %s\nrun c_inline %s\nrun c_helper %s\ndump\n", p, p, p, p)
		kn := feed(t, true, script, h.kernelBin)
		tw := feed(t, false, script, h.twinBin)
		sameDump(t, name, kn, tw)
		t.Logf("%s kernel: %s", name, strings.Join(traceDumpLines(kn), " "))
		for _, pr := range [][2]string{{"Out[0]", "Out[2]"}, {"Out[1]", "Out[3]"}, {"Out[4]", "Out[5]"}} {
			a, b := dumpVal(kn, pr[0]), dumpVal(kn, pr[1])
			if a == "" || a != b {
				t.Errorf("%s: inline %s=%q, helper %s=%q\n%s", name, pr[0], a, pr[1], b, kn)
			}
		}
	}
}

// TestSubprogramHashBorrowDifferential は E095 の H5 (レビュー役の足し — host、root): 共有の hash の借用を helper に渡す program と inline の
// program を走らせ、kernel と双子の dump が一致し、inline の key 1 の entry と Out[0] = helper の key 2 の entry と Out[1]。
func TestSubprogramHashBorrowDifferential(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046
	h := buildHarnesses(t, filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "sub", "t_hash_sub.rb"))
	for _, v := range []string{"0", "7", "65535", "70000"} {
		script := fmt.Sprintf("reset\npoke H 1 %s\npoke H 2 %s\nrun h_inline\nrun h_helper\nrun h_inline\nrun h_helper\ndump\n", v, v)
		kn := feed(t, true, script, h.kernelBin)
		tw := feed(t, false, script, h.twinBin)
		sameDump(t, "H="+v, kn, tw)
		t.Logf("H=%s kernel: %s", v, strings.Join(traceDumpLines(kn), " "))
		for _, pr := range [][2]string{{"H{1}", "H{2}"}, {"Out[0]", "Out[1]"}} {
			a, b := dumpVal(kn, pr[0]), dumpVal(kn, pr[1])
			if a == "" || a != b {
				t.Errorf("H=%s: inline %s=%q, helper %s=%q\n%s", v, pr[0], a, pr[1], b, kn)
			}
		}
	}
}
