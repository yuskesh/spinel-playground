package main

import (
	"bufio"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// E159 の試験 (P029 の完成): 波 3 の移植の数え。

// p029Ported は P029 で移植した tool (PROVENANCE の波の列「3-done」— E153・E154・E155・E156・E157・E158)。
var p029Ported = []string{"tcpaccept", "tcpconnect", "tcpretrans", "biosnoop", "gethostlatency", "deadlock", "sslsniff"}

// TestBccWave3Accounting は E159 の H1: PROVENANCE の「3-done」の行の集合が P029 で移植した 7 本と一致する (P027 の 29 の勘定は
// TestBccWave1Accounting、P028 の 7 本は TestBccWave2Accounting)。
func TestBccWave3Accounting(t *testing.T) {
	parallel(t)
	f, err := os.Open(filepath.Join(repoRoot(), "examples", "bcc", "PROVENANCE.md"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	var got []string
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		c := strings.Split(sc.Text(), "|")
		if len(c) != 7 || strings.TrimSpace(c[2]) != "3-done" {
			continue
		}
		got = append(got, strings.TrimSpace(c[1]))
	}
	want := append([]string{}, p029Ported...)
	sort.Strings(got)
	sort.Strings(want)
	t.Logf("3-done: %d %v", len(got), got)
	if strings.Join(got, " ") != strings.Join(want, " ") {
		t.Errorf("PROVENANCE 3-done rows %v != the 7 tools ported in P029 %v", got, want)
	}
}
