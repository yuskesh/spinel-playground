package main

import (
	"bufio"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// E140 の試験 (P027 の完成): 波 1 の 29 本の行き先の数え。

// p027Wave1 は P027 の波 1 の 29 本 (spinel-mlir P003 の区分 1)。
var p027Wave1 = []string{"runqlat", "runqslower", "cpudist", "hardirqs", "softirqs", "biolatency", "biosnoop", "funclatency", "fileslower",
	"gethostlatency", "tcplife", "tcpaccept", "tcpconnect", "tcpstates", "tcpretrans", "killsnoop", "setuids", "syncsnoop", "exitsnoop",
	"syscount", "argdist", "vfsstat", "funccount", "capable", "cachestat", "slabratetop", "memleak", "deadlock", "mountsnoop"}

// p027Held は P027 で「保留」(利用者の判断待ち) だった tool — 後で移植して「3-done」になっても P027 の勘定は「保留」の桶 (P029 E156)。
var p027Held = map[string]bool{"deadlock": true, "gethostlatency": true}

// TestBccWave1Accounting は E140 の H1: PROVENANCE の行の P027 の 29 本の行き先 (済み 1・波 2・波 3・保留 — 利用者の判断待ち) の数が 21 / 2 / 4 / 2。
// P028 E151 (the bpf-mlir coordinator's decision — the meaning of the count is unchanged): only P027's 29 names are counted (rows outside P027, execsnoop and others, are not), and in the wave column
// "2-done" (ported in P028) counts in the same bucket as "2". P028's counting test is separate, in E150.
func TestBccWave1Accounting(t *testing.T) {
	parallel(t)
	f, err := os.Open(filepath.Join(repoRoot(), "examples", "bcc", "PROVENANCE.md"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	waves := map[string]string{}
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		c := strings.Split(sc.Text(), "|")
		if len(c) != 7 || strings.TrimSpace(c[1]) == "tool" || strings.HasPrefix(strings.TrimSpace(c[1]), "---") {
			continue
		}
		waves[strings.TrimSpace(c[1])] = strings.TrimSpace(c[2])
	}
	var got, want []string
	count := map[string]int{}
	inP027 := map[string]bool{}
	for _, n := range p027Wave1 {
		inP027[n] = true
	}
	for n, w := range waves {
		if !inP027[n] {
			continue
		}
		got = append(got, n)
		if w == "2-done" {
			w = "2"
		}
		if w == "3-done" { // P029 E153: 「3-done」は「3」の桶 (P027 の 29 の勘定は不変)
			w = "3"
			if p027Held[n] { // P029 E156: P027 で「保留」だった tool (gethostlatency) は held の桶のまま
				w = "held"
			}
		}
		count[w]++
	}
	want = append(want, p027Wave1...)
	sort.Strings(got)
	sort.Strings(want)
	if strings.Join(got, " ") != strings.Join(want, " ") {
		t.Errorf("PROVENANCE rows %v != the 29 wave-1 tools %v", got, want)
	}
	t.Logf("done %d, wave 2 %d, wave 3 %d, awaiting the user's decision %d", count["1"], count["2"], count["3"], count["held"])
	if count["1"] != 21 || count["2"] != 2 || count["3"] != 4 || count["held"] != 2 {
		t.Errorf("want 21 / 2 / 4 / 2, got %v", count)
	}
}
