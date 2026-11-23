package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// E044 の試験: Go の loader の撤去で消える E003 の段の試験 (loader/loader_test.go) と E025 の厳しい JSON の試験 (internal/loader) を、
// 試験の caps の libbml (build/bml-test — 種類 1 は全て無いと答える) を link した Spinel の driver (testdata/stages/stages.rb) に移したもの。

type stagesFixture struct {
	dir                    string
	exe, badReq, verifier  string // 埋め込みの ELF が元・header の版を壊した・最後の `r0 = 2` を `r0 = r9` にした実行 file
	sha                    string
	maps, badMaps, maxMaps string
}

// testLoaderLibs は製品の archive の dir の libbml.a だけを試験の caps の libbml に替えた dir を作る (他の 4 つは製品と同じ)。
func testLoaderLibs(t *testing.T, cfg Config, d string) string {
	t.Helper()
	libs := filepath.Join(d, "libs")
	os.MkdirAll(libs, 0o755)
	for _, a := range bmlArchives {
		src := filepath.Join(cfg.LoaderLibs, a)
		if a == "libbml.a" {
			src = filepath.Join(cfg.Repo, "build", "bml-test", "lib", "libbml.a")
		}
		if _, err := os.Stat(src); err != nil {
			t.Fatalf("%s is missing — run scripts/setup.sh", src)
		}
		if err := os.Symlink(src, filepath.Join(libs, a)); err != nil {
			t.Fatal(err)
		}
	}
	return libs
}

// stagesVariant は ELF を elf に替えた埋め込みの object で driver を link する。
func stagesVariant(t *testing.T, cfg Config, base, name string, elf []byte, sha string) string {
	t.Helper()
	v := filepath.Join(filepath.Dir(base), name)
	os.MkdirAll(v, 0o755)
	for _, f := range []string{"stages.rb", "stages.maps.json"} {
		b, err := os.ReadFile(filepath.Join(base, f))
		if err != nil {
			t.Fatal(err)
		}
		os.WriteFile(filepath.Join(v, f), b, 0o644)
	}
	os.WriteFile(filepath.Join(v, "stages.bpf.o"), elf, 0o644)
	os.WriteFile(filepath.Join(v, "stages_embed.S"), []byte(embedAsm("stages.bpf.o", sha, "stages.maps.json")), 0o644)
	if err := runIn(v, cfg.Clang, "-c", "-x", "assembler", "stages_embed.S", "-o", "stages_embed.o"); err != nil {
		t.Fatal(err)
	}
	exe := filepath.Join(v, "stages")
	if err := Link(cfg, filepath.Join(v, "stages.rb"), exe); err != nil {
		t.Fatal(err)
	}
	return exe
}

func buildStages(t *testing.T) stagesFixture {
	t.Helper()
	cfg, err := defaultConfig()
	if err != nil {
		t.Fatal(err)
	}
	root, err := os.MkdirTemp(filepath.Join(repoRoot(), "build", "tmp"), "e044-")
	if err != nil {
		t.Fatal(err)
	}
	cfg.LoaderLibs = testLoaderLibs(t, cfg, root)
	base := filepath.Join(root, "base")
	os.MkdirAll(base, 0o755)
	b, _ := os.ReadFile(filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "stages", "stages.rb"))
	src := filepath.Join(base, "stages.rb")
	os.WriteFile(src, b, 0o644)
	if _, err := Build(cfg, src); err != nil {
		t.Fatal(err)
	}
	f := stagesFixture{dir: root, exe: filepath.Join(base, "stages"), maps: filepath.Join(base, "stages.maps.json")}
	if err := Link(cfg, src, f.exe); err != nil {
		t.Fatal(err)
	}
	schema, _ := os.ReadFile(filepath.Join(base, "stages.schema.json"))
	sum := sha256.Sum256(schema)
	f.sha = hex.EncodeToString(sum[:])
	elf, err := os.ReadFile(filepath.Join(base, "stages.bpf.o"))
	if err != nil {
		t.Fatal(err)
	}
	// 段 1: requirements の header の版を壊した ELF (同じ長さ)
	if strings.Count(string(elf), "ebpf-requirements ") != 1 {
		t.Fatal("the requirements header was not found exactly once")
	}
	i := strings.Index(string(elf), "ebpf-requirements ") + len("ebpf-requirements ")
	bad := append([]byte(nil), elf...)
	bad[i] = '0' // E107: 版 0 はどの reader も読まない (1 桁のまま — 版 9 は bpf-mlir v1.5.0 から読まれる)
	f.badReq = stagesVariant(t, cfg, base, "badreq", bad, f.sha)
	// 段 4: 最後の `r0 = 2; exit` を `r0 = r9; exit` に (verifier が R9 !read_ok で拒否)
	mov := "\xb7\x00\x00\x00\x02\x00\x00\x00\x95\x00\x00\x00\x00\x00\x00\x00"
	if strings.Count(string(elf), mov) != 1 {
		t.Fatal("the final `r0 = 2; exit` was not found exactly once")
	}
	f.verifier = stagesVariant(t, cfg, base, "verifier", []byte(strings.Replace(string(elf), mov, "\xbf\x90\x00\x00\x00\x00\x00\x00\x95\x00\x00\x00\x00\x00\x00\x00", 1)), f.sha)
	m, _ := os.ReadFile(f.maps)
	f.badMaps = filepath.Join(root, "bad.maps.json")
	os.WriteFile(f.badMaps, []byte(`{"maps": [`), 0o644)
	if !strings.Contains(string(m), `"max_entries": 2`) {
		t.Fatalf("maps.json has no max_entries 2:\n%s", m)
	}
	f.maxMaps = filepath.Join(root, "max.maps.json")
	os.WriteFile(f.maxMaps, []byte(strings.Replace(string(m), `"max_entries": 2`, `"max_entries": 3`, 1)), 0o644)
	return f
}

func runStages(t *testing.T, root bool, args ...string) string {
	t.Helper()
	var out []byte
	var err error
	if root {
		var s string
		s, err = sudo(t, args...)
		out = []byte(s)
	} else {
		out, err = exec.Command(args[0], args[1:]...).CombinedOutput()
	}
	if err != nil {
		t.Errorf("%v: %v\n%s", args, err, out)
	}
	return string(out)
}

// TestLoadStages は E044 の H3 と H5: 段ごとの拒否 (非 root は試験の caps の種類 1、root は実機の caps) と、書き換えの無い入力の対照。
func TestLoadStages(t *testing.T) {
	parallel(t) // P018 E075
	f := buildStages(t)
	tamper := func(from, to string) string {
		m, _ := os.ReadFile(f.maps)
		bad := strings.Replace(string(m), from, to, 1)
		if bad == string(m) {
			t.Fatalf("the rewrite %q did not apply", from)
		}
		p := filepath.Join(f.dir, fmt.Sprintf("t%d.maps.json", len(bad)))
		os.WriteFile(p, []byte(bad), 0o644)
		return p
	}
	cases := []struct {
		name string
		args []string
		want []string
	}{
		{"stage0 unknown caps", []string{f.exe, "load", "-", "-", "7"}, []string{"load kind=SpinelBPF::PrecheckFailed", "no capabilities given"}},
		{"stage0' broken maps.json", []string{f.exe, "load", "-", f.badMaps, "1"}, []string{"load kind=SpinelBPF::PrecheckFailed", "map declarations are unreadable"}},
		{"stage0' nul", []string{f.exe, "load", "-", tamper(`"name": "Counts"`, `"name": "Counts\u0000"`), "1"}, []string{"load kind=SpinelBPF::PrecheckFailed", "map declarations are unreadable", `\u0000 in a string`}},
		{"stage0' duplicate key", []string{f.exe, "load", "-", tamper(`"max_entries": 2`, `"max_entries": 99, "max_entries": 2`), "1"}, []string{"load kind=SpinelBPF::PrecheckFailed", "map declarations are unreadable", ": duplicate key"}},
		{"stage0' key case", []string{f.exe, "load", "-", tamper(`"max_entries": 2`, `"Max_entries": 2`), "1"}, []string{"load kind=SpinelBPF::PrecheckFailed", "map declarations are unreadable", `key differs only in case from "max_entries"`}},
		{"stage1 requirements header", []string{f.badReq, "load", "-", "-", "1"}, []string{"load kind=SpinelBPF::PrecheckFailed", `ebpf-requirements 0`}},
		{"stage2 schema sha", []string{f.exe, "load", f.sha[:63] + "x", "-", "1"}, []string{"load kind=SpinelBPF::SchemaMismatch"}},
		{"stage2' max_entries", []string{f.exe, "load", "-", f.maxMaps, "1"}, []string{"load kind=SpinelBPF::MapMismatch", "max_entries"}},
		{"stage3 deny caps", []string{f.exe, "load", "-", "-", "1"}, []string{"load kind=SpinelBPF::TargetRejected"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			out := runStages(t, false, tc.args...)
			t.Log(strings.TrimSpace(out))
			for _, w := range tc.want {
				if !strings.Contains(out, w) {
					t.Errorf("want %q", w)
				}
			}
		})
	}
	// 対照 (H5): 書き換えの無い入力は、非 root の種類 1 で段 3 まで進み (TargetRejected — 段 0〜2' の拒否は書き換えが原因)、
	// root の実機の caps で OK (段 3・4 の拒否は種類 1 と書き換えた ELF が原因)
	t.Run("control", func(t *testing.T) {
		out := runStages(t, false, f.exe, "load", f.sha, f.maps, "1")
		if !strings.Contains(out, "load kind=SpinelBPF::TargetRejected") {
			t.Errorf("the untouched input with deny caps should reach stage 3:\n%s", out)
		}
		out = runStages(t, true, f.exe, "load", "-", "-", "0")
		if !strings.Contains(out, "load kind=OK") || !strings.Contains(out, "run value=2 counts0=3") {
			t.Errorf("the untouched input should load as root:\n%s", out)
		}
	})
	t.Run("stage4 verifier", func(t *testing.T) {
		out := runStages(t, true, f.verifier, "load", "-", "-", "0")
		t.Log(firstLines(out, 3))
		if !strings.Contains(out, "load kind=SpinelBPF::VerifierRejected") || !strings.Contains(out, "R9 !read_ok") {
			t.Errorf("want VerifierRejected naming R9 !read_ok:\n%s", firstLines(out, 3))
		}
	})
	t.Run("state", func(t *testing.T) {
		out := runStages(t, true, f.exe, "state")
		t.Log(strings.TrimSpace(out))
		for _, w := range []string{"before kind=SpinelBPF::State", "load1 kind=OK", "load2 kind=SpinelBPF::State", "closed kind=SpinelBPF::State"} {
			if !strings.Contains(out, w) {
				t.Errorf("want %q", w)
			}
		}
	})
	t.Run("u64 value range", func(t *testing.T) {
		out := runStages(t, true, f.exe, "range")
		t.Log(strings.TrimSpace(out))
		if !strings.Contains(out, "get0 kind=OK value=9223372036854775807") || !strings.Contains(out, "get1 kind=SpinelBPF::ValueRange") {
			t.Errorf("want 2^63-1 then ValueRange for 2^64-2")
		}
	})
	t.Run("fiber", func(t *testing.T) {
		out := runStages(t, false, f.badReq, "fiber", "-", "-", "1")
		if strings.Count(out, "kind=SpinelBPF::PrecheckFailed") != 20 || !strings.Contains(out, "\nafter") {
			t.Errorf("want 20 PrecheckFailed inside the Fiber and the process to go on:\n%s", out)
		}
	})
}

// kindTable は bml の include/bml/kind.h の enum の名前を値の順に返す (BML_ の接頭辞を外す)。
func kindTable(h string) ([]string, error) {
	re := regexp.MustCompile(`(?m)^\s*BML_([A-Z_]+)\s*=\s*(\d+),`)
	var names []string
	for _, m := range re.FindAllStringSubmatch(h, -1) {
		var v int
		fmt.Sscan(m[2], &v)
		if v != len(names) {
			return nil, fmt.Errorf("kind.h: BML_%s = %d is out of order (want %d)", m[1], v, len(names))
		}
		names = append(names, m[1])
	}
	return names, nil
}

// rubyKindNames は spinelbpf.rb の KIND_NAMES の並びを返す。
func rubyKindNames(rb string) []string {
	m := regexp.MustCompile(`KIND_NAMES = \[([^\]]*)\]`).FindStringSubmatch(rb)
	if m == nil {
		return nil
	}
	var names []string
	for _, s := range strings.Split(m[1], ",") {
		names = append(names, strings.Trim(strings.TrimSpace(s), `"`))
	}
	return names
}

// TestKindTable は E044 の H4: Ruby の kind の名前の表が bml の kind.h の値と一致する (Go の loader の TestKindNames の置き換え)。
// 対照: 2 つの kind を入れ替えた写しは食い違いとして落ちる。
func TestKindTable(t *testing.T) {
	parallel(t) // P018 E075
	h, err := os.ReadFile(filepath.Join(repoRoot(), "third_party", "bpf-mlir-loader", "include", "bml", "kind.h"))
	if err != nil {
		t.Fatal(err)
	}
	want, err := kindTable(string(h))
	if err != nil {
		t.Fatal(err)
	}
	rb, _ := os.ReadFile(filepath.Join(repoRoot(), "ruby", "lib", "spinelbpf.rb"))
	got := rubyKindNames(string(rb))
	if len(want) < 12 || strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("spinelbpf.rb KIND_NAMES %v, bml kind.h %v", got, want)
	}
	swapped := strings.Replace(string(rb), `"STATE", "RUNTIME_CONFLICT"`, `"RUNTIME_CONFLICT", "STATE"`, 1)
	if swapped == string(rb) || strings.Join(rubyKindNames(swapped), ",") == strings.Join(want, ",") {
		t.Fatal("the control (two kinds swapped) did not differ")
	}
}

// TestLoaderGoRemoved は E044 の H1: SPINELBPF_LOADER に bml 以外 (go を含む) を与えると Config が名指しで止まる (黙って bml にしない)。bml と空は通る。
func TestLoaderGoRemoved(t *testing.T) {
	for _, c := range []struct {
		v  string
		ok bool
	}{{"", true}, {"bml", true}, {"go", false}, {"cgo", false}} {
		t.Setenv("SPINELBPF_LOADER", c.v)
		_, err := defaultConfig()
		if c.ok != (err == nil) || (err != nil && !strings.Contains(err.Error(), "the Go loader was removed")) {
			t.Errorf("SPINELBPF_LOADER=%q: got %v", c.v, err)
		}
	}
}

// TestNoGoInProduct は E044 の H2: module の中に cgo の package と c-archive の build が無く (Go は build の時の frontend と試験の道具だけ)、
// go.mod に bpf-mlir の kernel の module (livecaps — 実行時の caps の probe) が無い。実行 file の Go の symbol 0 は TestGoRuntimeRemoved (E043)。
func TestNoGoInProduct(t *testing.T) {
	cfg, _ := defaultConfig()
	// testdata の mcrun (cilium の試験の道具) も含めて見る — ./... は testdata を含まない。
	// E084: ./... は build/tmp (並行の他の package の試験の一時の directory — 生まれて消える) を歩いて `no such file` で落ちた —
	// 製品の tree (cmd・internal) だけを列にする (docs の probe は製品でない)
	pkgs := []string{"./cmd/...", "./internal/...", "./cmd/spinelbpf/testdata/mcrun"}
	gl := exec.Command(cfg.Go, append([]string{"list", "-f", "{{.ImportPath}} {{len .CgoFiles}}"}, pkgs...)...)
	gl.Dir = repoRoot()
	out, err := gl.CombinedOutput()
	if err != nil {
		t.Fatalf("go list: %v\n%s", err, out)
	}
	for _, l := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if !strings.HasSuffix(l, " 0") {
			t.Errorf("a cgo package remains: %s", l)
		}
	}
	gm, _ := os.ReadFile(filepath.Join(repoRoot(), "go.mod"))
	if strings.Contains(string(gm), "bpf-mlir/kernel") {
		t.Errorf("go.mod still requires the bpf-mlir kernel module (livecaps):\n%s", gm)
	}
	// 型の文字列を分けて書く (この file 自身に一続きの文字列を置かない — E044 の commit の後に自分に当たった、E044 の事後の訂正)
	gr, _ := exec.Command("git", "-C", repoRoot(), "grep", "-l", "-e", "buildmode"+"=c-archive", "--", "*.go", "scripts").Output()
	if s := strings.TrimSpace(string(gr)); s != "" {
		t.Errorf("a c-archive build remains in: %s", s)
	}
}
