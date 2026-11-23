package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestTableThreeTargets は E011: E010 の 6 つの表の kernel の harness を VM 6.12.111 / 6.6.157 で走らせ、host の twin と CRuby と比べる
// (SPINELBPF_VM=1 のときだけ — 時間がかかる。host の行は E010 の TestTableDifferential)。
func TestTableThreeTargets(t *testing.T) {
	parallel(t) // P018 E075
	if os.Getenv("SPINELBPF_VM") != "1" {
		t.Skip("SPINELBPF_VM=1 runs the VM targets")
	}
	names := []string{"t_i32", "t_i32b", "t_u32", "t_i64", "t_u64", "t_min"}
	dir, err := os.MkdirTemp(filepath.Join(repoRoot(), "build", "tmp"), "e011-")
	if err != nil {
		t.Fatal(err)
	}
	type prepared struct {
		script      string
		rows        int
		twin, cruby string
	}
	prep := map[string]prepared{}
	for _, n := range names {
		h := buildHarnesses(t, tableSrc(n))
		script, rows := tableScript(n)
		b, err := os.ReadFile(h.kernelBin)
		if err != nil {
			t.Fatal(err)
		}
		writeExec(t, filepath.Join(dir, n+".kernel"), b)
		os.WriteFile(filepath.Join(dir, n+".script"), []byte(script), 0o644)
		prep[n] = prepared{script, rows,
			feed(t, false, script, h.twinBin),
			crubyFeed(t, script, h)}
	}
	for _, k := range []string{"6.12.111", "6.6.157"} {
		img := filepath.Join(os.Getenv("HOME"), "kernel-build", "linux-"+k, "arch", "x86", "boot", "bzImage")
		out, err := sudoCmd(t, filepath.Join(repoRoot(), "scripts", "run-table-vm.sh"), img, dir).CombinedOutput()
		if err != nil {
			t.Fatalf("vm %s: %v\n%s", k, err, out)
		}
		t.Logf("vm %s:\n%s", k, strings.TrimSpace(string(out)))
		total := 0
		for _, n := range names {
			kb, err := os.ReadFile(filepath.Join(dir, fmt.Sprintf("%s.%s.out", n, k)))
			if err != nil {
				t.Fatal(err)
			}
			p := prep[n]
			r := compareTable(t, n, p.script, p.rows, p.twin, string(kb), p.cruby)
			total += r.rows
			t.Logf("vm %s %s: %d rows (Spinel table %d, −2^63 rows %d) — Spinel mismatches %d, CRuby mismatches %d", k, n, r.rows, r.spinelRows, r.minRows, len(r.spinelBad), len(r.crubyBad))
			for _, b := range first(append(r.spinelBad, r.crubyBad...), 5) {
				t.Log(b)
			}
			if len(r.spinelBad)+len(r.crubyBad) > 0 {
				t.Fail()
			}
		}
		t.Logf("vm %s: %d rows", k, total)
	}
}
