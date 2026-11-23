package main

import (
	"bufio"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// E150 の試験 (P028 の完成): 波 2 の移植の数え。

// p028Ported は P028 で移植した tool (PROVENANCE の波の列「2-done」— E147・E148・E151。E149 の inject は中止)。
var p028Ported = []string{"execsnoop", "opensnoop", "statsnoop", "trace", "capable", "biolatency", "filelife"}

// TestBccWave2Accounting は E150 の H1: PROVENANCE の「2-done」の行の集合が P028 で移植した 7 本と一致する (P027 の 29 の勘定は TestBccWave1Accounting)。
func TestBccWave2Accounting(t *testing.T) {
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
		if len(c) != 7 || strings.TrimSpace(c[2]) != "2-done" {
			continue
		}
		got = append(got, strings.TrimSpace(c[1]))
	}
	want := append([]string{}, p028Ported...)
	sort.Strings(got)
	sort.Strings(want)
	t.Logf("2-done: %d %v", len(got), got)
	if strings.Join(got, " ") != strings.Join(want, " ") {
		t.Errorf("PROVENANCE 2-done rows %v != the 7 tools ported in P028 %v", got, want)
	}
}
