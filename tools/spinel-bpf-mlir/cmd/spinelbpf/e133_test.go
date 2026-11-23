package main

import (
	"bufio"
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// P027 (E133〜E139) の試験: examples/bcc の tool — 生成物の一致・root の selftest と実用の形・由来の表。
// tool の一覧は examples/bcc の dir (E136 — 表を持たない)。後の E は自分の試験の file (e<NNN>_test.go) に TestBccSelftest<Name> を足すだけで、
// この file は変えない (selftest の verified の鍵は宣言の file の hash を含む — 共有の file を変えると全ての tool の鍵が変わる)。

// bccToolNames は examples/bcc の tool の dir の名前 (sort 済み)。
func bccToolNames(t *testing.T) []string {
	t.Helper()
	es, err := os.ReadDir(filepath.Join(repoRoot(), "examples", "bcc"))
	if err != nil {
		t.Fatal(err)
	}
	var ns []string
	for _, e := range es {
		if e.IsDir() {
			ns = append(ns, e.Name())
		}
	}
	sort.Strings(ns)
	return ns
}

// bccArtefacts は tool の commit した生成物 (例と同じ組)。
func bccArtefacts(name string) []string {
	return []string{name + ".mlir", name + ".schema.json", name + ".maps.json", name + ".domain.json", name + ".bpf.o",
		name + ".compile_warnings.txt", name + "_embed.S", name + "_embed.o"}
}

// bccSource は tool の source (examples/<rel>/<名前>.rb — rel は `bcc/<名前>`) を dir に写し、その path を返す。
// rel は呼び手の literal — verified の鍵 (E046) は literal の `bcc/<名前>` で tool の dir だけを入れる (E134 — `bcc` の tree の全てにしない)。
func bccSource(t *testing.T, d, rel string) string {
	t.Helper()
	name := filepath.Base(rel)
	b, err := os.ReadFile(filepath.Join(repoRoot(), "examples", rel, name+".rb"))
	if err != nil {
		t.Fatal(err)
	}
	src := filepath.Join(d, name+".rb")
	if err := os.WriteFile(src, b, 0o644); err != nil {
		t.Fatal(err)
	}
	return src
}

// TestBccArtefacts は P027 の検証 (a): 各 tool の build の生成物が commit 済みの物と byte 同じ。
func TestBccArtefacts(t *testing.T) {
	parallel(t)
	cfg, _ := defaultConfig()
	for _, name := range bccToolNames(t) {
		name := name
		t.Run(name, func(t *testing.T) {
			parallel(t)
			d := t.TempDir()
			if _, err := Build(cfg, bccSource(t, d, "bcc/"+name)); err != nil {
				t.Fatal(err)
			}
			for _, f := range bccArtefacts(name) {
				got, _ := os.ReadFile(filepath.Join(d, f))
				want, err := os.ReadFile(filepath.Join(repoRoot(), "examples", "bcc", name, f))
				if err != nil || !bytes.Equal(got, want) {
					t.Errorf("%s differs from the committed one (%v) — run spinelbpf build examples/bcc/%s/%s.rb", f, err, name, name)
				}
			}
		})
	}
}

// bccSelftest は P027 の検証 (d) (host、root): tool の --selftest (自分の事象で照らす — 出力に `selftest ok`) と実用の形 (--duration-ms 1000 — rc 0 だけ)。
// 鍵 (E046) は試験の関数ごと — tool ごとに TestBccSelftest<Name> を 1 つ (subtest は鍵の宣言を持たない)。
func bccSelftest(t *testing.T, rel string) {
	name := filepath.Base(rel)
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	cfg, _ := defaultConfig()
	d := t.TempDir()
	src := bccSource(t, d, rel)
	if _, err := Build(cfg, src); err != nil {
		t.Fatal(err)
	}
	exe := filepath.Join(d, name)
	if err := Link(cfg, src, exe); err != nil {
		t.Fatal(err)
	}
	out := feed(t, true, "", exe, "--selftest")
	t.Log(out)
	if !strings.Contains(out, "selftest ok") {
		t.Errorf("--selftest: want %q in the output", "selftest ok")
	}
	t.Log(feed(t, true, "", exe, "--duration-ms", "1000"))
}

// TestBccSelftestRunqlat は E133 の H4 / H5 (E134 以降の tool の試験は各 E の file に)。
func TestBccSelftestRunqlat(t *testing.T) { bccSelftest(t, "bcc/runqlat") }

// TestBccProvenance は P027 §2: PROVENANCE の表の波 1 と「2-done」(P028 E151) の行と examples/bcc の dir の集合が一致し、各 tool に TestBccSelftest<Name> が在り、
// 各行の blob が spinel-ebpf の 23fa4b0 の path と一致する。
func TestBccProvenance(t *testing.T) {
	parallel(t)
	f, err := os.Open(filepath.Join(repoRoot(), "examples", "bcc", "PROVENANCE.md"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	type row struct{ wave, path, blob string }
	rows := map[string]row{}
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		c := strings.Split(sc.Text(), "|")
		if len(c) != 7 || strings.TrimSpace(c[1]) == "tool" || strings.HasPrefix(strings.TrimSpace(c[1]), "---") {
			continue
		}
		rows[strings.TrimSpace(c[1])] = row{strings.TrimSpace(c[2]), strings.TrimSpace(c[3]), strings.TrimSpace(c[4])}
	}
	var wave1 []string
	for n, r := range rows {
		if r.wave == "1" || r.wave == "2-done" || r.wave == "3-done" { // P028 E151 (the bpf-mlir coordinator's decision): "2-done" is a tool ported in P028 — it has a dir (P029 E153: "3-done" too)
			wave1 = append(wave1, n)
		}
	}
	sort.Strings(wave1)
	dirs := bccToolNames(t)
	if strings.Join(wave1, " ") != strings.Join(dirs, " ") {
		t.Errorf("PROVENANCE wave-1 rows %v != examples/bcc dirs %v", wave1, dirs)
	}
	decls, err := loadPkgDecls()
	if err != nil {
		t.Fatal(err)
	}
	for _, n := range dirs {
		if len(decls["TestBccSelftest"+strings.ToUpper(n[:1])+n[1:]]) == 0 {
			t.Errorf("%s has no TestBccSelftest%s%s (one root test per tool)", n, strings.ToUpper(n[:1]), n[1:])
		}
	}
	// Spinel Extended: spinel-ebpf 23fa4b0 is imported here as tools/ebpf/,
	// so each row's blob is checked against this repository's copy of the
	// file, not a sibling spinel-ebpf checkout as in spinel-bpf-mlir.
	src := filepath.Join(repoRoot(), "..", "ebpf")
	for n, r := range rows {
		o, err := exec.Command("git", "hash-object", filepath.Join(src, r.path)).Output()
		if err != nil || strings.TrimSpace(string(o)) != r.blob {
			t.Errorf("%s: blob of tools/ebpf/%s is %q, PROVENANCE says %s (%v)", n, r.path, strings.TrimSpace(string(o)), r.blob, err)
		}
	}
}

// TestBccArtefactsSha256 は spinel-extended の依頼 (E134): examples/bcc/artefacts.sha256 の行が file の在る全ての生成物 (各 tool の 8 つ) と一致する。
func TestBccArtefactsSha256(t *testing.T) {
	parallel(t)
	base := filepath.Join(repoRoot(), "examples", "bcc")
	b, err := os.ReadFile(filepath.Join(base, "artefacts.sha256"))
	if err != nil {
		t.Fatal(err)
	}
	listed := map[string]string{}
	for _, l := range strings.Split(strings.TrimSpace(string(b)), "\n") {
		f := strings.Fields(l)
		if len(f) != 2 {
			t.Fatalf("bad line %q", l)
		}
		listed[f[1]] = f[0]
	}
	var want []string
	for _, name := range bccToolNames(t) {
		for _, f := range bccArtefacts(name) {
			want = append(want, name+"/"+f)
		}
	}
	if len(listed) != len(want) {
		t.Errorf("artefacts.sha256 has %d lines, want %d (8 per tool)", len(listed), len(want))
	}
	for _, p := range want {
		h, err := shaFile(filepath.Join(base, p))
		if err != nil || listed[p] != h {
			t.Errorf("%s: sha256 %s, artefacts.sha256 says %q (%v)", p, h, listed[p], err)
		}
	}
}
