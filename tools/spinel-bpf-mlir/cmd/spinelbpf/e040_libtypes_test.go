package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// E040 の H6 (E039 のレビューの P3): library の型の静的な試験。E039 の 2 つの欠陥 (map の class の value_type が Symbol と String に分かれた・双子の ref の class を 2 つの map の class が共有した)
// は「library の同じ field / method に違う型の値が入ると Spinel の推論が崩れる」同じ類。全部入りの program (全ての map の class と全ての公開の API) を Spinel の --emit-rbs に通し、次を見る:
//   (1) map の class の説明の method (name・kind・key_type・value_type・record?・record_key?・max_entries) の戻り値が全ての class で同じ型 (untyped でない)
//   (2) bpf.rb の map の class の instance 変数が untyped でない
//   (3) 双子 (ruby/lib/native) の ref の class の @map が untyped でない (1 つの map の class だけが作る)
// library の関数の map の引数や layout の組 (名前・offset・幅・符号) は設計の上で多相 (untyped) — ここでは見ない。

var mapClasses = []string{"ArrayMap", "RecordMap", "HashMap", "LruHashMap", "RecordHashMap", "LruRecordHashMap", "PerCpuArrayMap", "PerCpuRecordMap", "PerCpuHashMap", "PerCpuRecordHashMap", "LpmTrieMap"}
var descriptorMethods = []string{"name", "kind", "key_type", "value_type", "record?", "record_key?", "max_entries"}
var twinRefClasses = []string{"MapRef", "HashRef", "LruHashRef", "PerCpuMapRef", "PerCpuHashRef", "LpmRef"}

// rbsClasses は RBS の text を class ごとの行に分ける。
func rbsClasses(rbs string) map[string][]string {
	out := map[string][]string{}
	cur := ""
	for _, l := range strings.Split(rbs, "\n") {
		if strings.HasPrefix(l, "class ") || strings.HasPrefix(l, "module ") {
			cur = strings.Fields(l)[1]
			continue
		}
		if cur != "" && strings.HasPrefix(l, "  ") {
			out[cur] = append(out[cur], strings.TrimSpace(l))
		}
	}
	return out
}

// emitRBS は src を lib の下で Spinel の --emit-rbs に通した RBS の text。
func emitRBS(t *testing.T, lib, name, src string) string {
	t.Helper()
	cfg, _ := defaultConfig()
	d := t.TempDir()
	os.WriteFile(filepath.Join(d, name+".rb"), []byte(src), 0o644)
	c := exec.Command(cfg.Spinel, "-I", lib, "--emit-rbs", name+".rb")
	c.Dir = d
	c.Env = append(os.Environ(), "TMPDIR="+d)
	if o, err := c.CombinedOutput(); err != nil {
		t.Fatalf("%v\n%s", err, o)
	}
	b, err := os.ReadFile(filepath.Join(d, name+".rbs"))
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

var defRe = regexp.MustCompile(`^def ([a-z_?]+): \(\) -> ([^ #]+)`)
var ivarRe = regexp.MustCompile(`^(@[a-z_]+): (.+)$`)

// libTypeProblems は lib (bpf.rb と spinelbpf.rb) と native (双子の bpf.rb) の下で 3 つの規則を見て、破れを並べる。
func libTypeProblems(t *testing.T, lib, native string) []string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "libtypes", "allin.rb"))
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	lc := rbsClasses(emitRBS(t, lib, "allin", src))
	tc := rbsClasses(emitRBS(t, native, "twin", src[:strings.Index(src, "require \"spinelbpf\"")]))
	var probs []string
	for _, m := range descriptorMethods {
		seen := map[string][]string{}
		for _, c := range mapClasses {
			for _, l := range lc[c] {
				if g := defRe.FindStringSubmatch(l); g != nil && g[1] == m {
					seen[g[2]] = append(seen[g[2]], c)
				}
			}
		}
		if len(seen) != 1 || seen["untyped"] != nil {
			probs = append(probs, "(1) "+m+" returns differ across the map classes: "+fmtSeen(seen))
		}
	}
	for _, c := range mapClasses {
		for _, l := range lc[c] {
			if g := ivarRe.FindStringSubmatch(l); g != nil && strings.Contains(g[2], "untyped") {
				probs = append(probs, "(2) "+c+" "+g[1]+" is "+g[2])
			}
		}
	}
	for _, c := range twinRefClasses {
		for _, l := range tc[c] {
			if g := ivarRe.FindStringSubmatch(l); g != nil && g[1] == "@map" && strings.Contains(g[2], "untyped") {
				probs = append(probs, "(3) twin "+c+" @map is "+g[2])
			}
		}
	}
	return probs
}

func fmtSeen(seen map[string][]string) string {
	var parts []string
	for ty, cs := range seen {
		parts = append(parts, ty+" in "+strings.Join(cs, ","))
	}
	return strings.Join(parts, "; ")
}

// copyTree は dir を dst に写す (library の写しに欠陥を注入する対照 — 元の file は変えない)。
func copyTree(t *testing.T, dir, dst string) {
	t.Helper()
	if o, err := exec.Command("cp", "-r", dir+"/.", dst).CombinedOutput(); err != nil {
		t.Fatalf("%v\n%s", err, o)
	}
}

// TestLibraryTypeUniformity は E040 の H6: 今の library で 3 つの規則の破れが 0、E039 の 2 つの欠陥の形を library の写しに注入すると名指しで破れる (対照)。
func TestLibraryTypeUniformity(t *testing.T) {
	parallel(t) // P018 E075
	lib := filepath.Join(repoRoot(), "ruby", "lib")
	if p := libTypeProblems(t, lib, filepath.Join(lib, "native")); len(p) != 0 {
		t.Errorf("the library breaks the type rules:\n%s", strings.Join(p, "\n"))
	}
	// 対照 (a): array の class の value_type を Symbol に戻す (E039 の 1 つ目)
	a := t.TempDir()
	copyTree(t, lib, a)
	bb, _ := os.ReadFile(filepath.Join(a, "bpf.rb"))
	bad := strings.Replace(string(bb), "      @value_type.to_s # 全ての map の class で String に揃える (library の多相の引数で Symbol の添字が崩れる — E039)", "      @value_type", 1)
	if bad == string(bb) {
		t.Fatal("control (a): the rewrite did not apply")
	}
	os.WriteFile(filepath.Join(a, "bpf.rb"), []byte(bad), 0o644)
	pa := libTypeProblems(t, a, filepath.Join(a, "native"))
	t.Logf("control (a): %v", pa)
	if len(pa) == 0 || !strings.Contains(strings.Join(pa, "\n"), "value_type") {
		t.Errorf("control (a): the Symbol value_type was not caught")
	}
	// 対照 (b): 双子の lru_hash の ref を HashRef と共有させる (E039 の 2 つ目の形)
	n := t.TempDir()
	copyTree(t, lib, n)
	nb, _ := os.ReadFile(filepath.Join(n, "native", "bpf.rb"))
	badn := strings.Replace(string(nb), "LruHashRef.new(self, s)", "HashRef.new(self, s)", 1)
	if badn == string(nb) {
		t.Fatal("control (b): the rewrite did not apply")
	}
	os.WriteFile(filepath.Join(n, "native", "bpf.rb"), []byte(badn), 0o644)
	pb := libTypeProblems(t, n, filepath.Join(n, "native"))
	t.Logf("control (b): %v", pb)
	if len(pb) == 0 || !strings.Contains(strings.Join(pb, "\n"), "twin HashRef @map") {
		t.Errorf("control (b): the shared HashRef was not caught")
	}
}
