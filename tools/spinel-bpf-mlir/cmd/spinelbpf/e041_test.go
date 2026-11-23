package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// E041 の試験: C の loader (bml) の固定・build・link の口・版の照合 (P010 §1)。

// TestBMLVersionsMatch は E041 の H3: spinel と bml の bpf-mlir の commit・判定の版・requirements の形式の上限が同じ (食い違えば bml の link が止まる)。
func TestBMLVersionsMatch(t *testing.T) {
	parallel(t) // P018 E075
	cfg, _ := defaultConfig()
	sp, err := spinelVersions(cfg)
	if err != nil {
		t.Fatal(err)
	}
	b, err := bmlVersions(cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("spinel %+v, bml %+v", sp, b)
	if err := compareVersions(sp, b); err != nil {
		t.Fatal(err)
	}
}

// TestBMLVersionMismatchStops は E041 の H3 の注入の対照: 3 つの版の各々の食い違いを名指しで止める。
func TestBMLVersionMismatchStops(t *testing.T) {
	parallel(t) // P018 E075
	base := versionSet{"8ec35683", 4, 7}
	for _, c := range []struct {
		name string
		b    versionSet
		want string
	}{
		{"commit", versionSet{"5bd056dc", 4, 7}, "bpf-mlir commit"},
		{"policy", versionSet{"8ec35683", 3, 7}, "judgement (policy) version"},
		{"format", versionSet{"8ec35683", 4, 6}, "requirements format maximum"},
	} {
		err := compareVersions(base, c.b)
		if err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: want an error naming %q, got %v", c.name, c.want, err)
		} else {
			t.Logf("%s: %v", c.name, err)
		}
	}
}

// TestBMLTestCapsNotInProduct は E041 の H1 (P010 のレビューの (d)): 試験の caps (-DBML_TEST_CAPS) の関数と文字列は製品の libbml.a に無く、試験の libbml.a に在る。
func TestBMLTestCapsNotInProduct(t *testing.T) {
	parallel(t) // P018 E075
	cfg, _ := defaultConfig()
	count := func(a string) (int, bool) {
		out, err := exec.Command("nm", a).Output()
		if err != nil {
			t.Fatalf("nm %s: %v", a, err)
		}
		n := 0
		for _, l := range strings.Split(string(out), "\n") {
			f := strings.Fields(l)
			if len(f) >= 2 && (f[len(f)-1] == "deny_type" || f[len(f)-1] == "deny_helper" || f[len(f)-1] == "unknown_helper") {
				n++
			}
		}
		b, _ := os.ReadFile(a)
		return n, strings.Contains(string(b), "bml_test: helper probe")
	}
	pn, ps := count(filepath.Join(cfg.LoaderLibs, "libbml.a"))
	tn, ts := count(filepath.Join(cfg.Repo, "build", "bml-test", "lib", "libbml.a"))
	t.Logf("product %d symbols / string %v, test %d / %v", pn, ps, tn, ts)
	if pn != 0 || ps {
		t.Errorf("the product libbml.a carries the test caps")
	}
	if tn != 3 || !ts {
		t.Errorf("the test libbml.a lacks the test caps")
	}
}
