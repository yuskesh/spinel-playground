package main

import (
	"bytes"
	"errors"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/yuskesh/spinel-playground/tools/spinel-bpf-mlir/internal/frontend"
	"github.com/yuskesh/spinel-playground/tools/spinel-bpf-mlir/internal/toolchain"
)

// E152 の試験 (P029 §1 — driver の seam): Go の経路の出力から spinel-mlir E075 の形の E / I (5 file と domain + manifest v1) を作り、
// seam の build が Go の経路と同じ artefacts になること (H6 の往復)、manifest と入力の照らしの負の対照 (H4)、後ろの照合が seam でも効くこと (H5)。

// seamCase は Go の経路で build した source の dir と、そこから作った E / I。
type seamCase struct {
	dir, rb, name string
	E, I          string
	manifest      map[string]any
}

// copySource は repo の source (と target/) を dir に写す。
func copySource(t *testing.T, rel, dir string) string {
	t.Helper()
	src := filepath.Join(repoRoot(), rel)
	b, err := os.ReadFile(src)
	if err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(dir, filepath.Base(src))
	if err := os.WriteFile(p, b, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(filepath.Dir(src), "target")); err == nil {
		if err := os.MkdirAll(filepath.Join(dir, "target"), 0o755); err != nil {
			t.Fatal(err)
		}
		copyTree(t, filepath.Join(filepath.Dir(src), "target"), filepath.Join(dir, "target"))
	}
	return p
}

// makeSeam は rel を Go の経路で build し、その出力から E / I を作る (rc は Go の経路の成否 — 0 なら 6 出力、1 なら domain だけ)。
func makeSeam(t *testing.T, cfg Config, rel string) *seamCase {
	t.Helper()
	dir := t.TempDir()
	rb := copySource(t, rel, dir)
	name := strings.TrimSuffix(filepath.Base(rb), ".rb")
	r, berr := Build(cfg, rb)
	if r == nil || r.Output == nil || r.Output.Domain == nil {
		t.Fatalf("%s: the Go path produced no domain: %v", rel, berr)
	}
	c := &seamCase{dir: dir, rb: rb, name: name, E: filepath.Join(t.TempDir(), "E"), I: filepath.Join(t.TempDir(), "I")}
	for _, d := range []string{c.E, c.I} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	src, _ := os.ReadFile(rb)
	v, err := toolchain.Check(cfg.EbpfCompile, cfg.Repo)
	if err != nil {
		t.Fatal(err)
	}
	outputs := map[string]any{}
	put := func(key, d, ext string, b []byte) {
		p := filepath.Join(d, name+ext)
		if err := os.WriteFile(p, b, 0o644); err != nil {
			t.Fatal(err)
		}
		outputs[key] = map[string]any{"path": "/captured/" + key, "sha256": sha256Hex(b)}
	}
	put("domain", c.I, ".domain.json", r.Output.Domain)
	rc := 1
	if berr == nil {
		rc = 0
		put("mlir", c.E, ".mlir", []byte(r.Output.MLIR))
		put("schema", c.E, ".schema.json", r.Output.Schema)
		put("maps", c.E, ".maps.json", r.Output.Maps)
		put("records", c.E, ".records.txt", []byte(r.Output.Records))
		type decl struct {
			File string `json:"file"`
			Line int    `json:"line"`
			Col  int    `json:"col"`
		}
		type prog struct {
			Name       string `json:"name"`
			Kind       string `json:"kind"`
			BinaryPath string `json:"binary_path"`
			Decl       decl   `json:"decl"`
		}
		tg := struct {
			Version  int    `json:"version"`
			Programs []prog `json:"programs"`
		}{Version: 1, Programs: []prog{}}
		for _, p := range r.Output.Result.Programs {
			if p.Kind == "uprobe" || p.Kind == "uretprobe" {
				tg.Programs = append(tg.Programs, prog{p.Name, p.Kind, p.BinaryPath, decl{p.DeclPos.File, p.DeclPos.Line, p.DeclPos.Col}})
			}
		}
		b, _ := json.MarshalIndent(tg, "", "  ")
		put("uprobe_targets", c.E, ".uprobe_targets.json", b)
	}
	c.manifest = map[string]any{
		"version":   1,
		"source":    map[string]any{"path": "/captured/" + name + ".rb", "sha256": sha256Hex(src)},
		"facts":     map[string]any{"path": "/captured/facts.mlir", "sha256": strings.Repeat("ab", 32)},
		"execution": "consumer",
		"pins": map[string]any{
			"spinel":   map[string]any{"commit": strings.Repeat("0", 40), "producer_revision": "test", "producer_source": "facts"},
			"consumer": map[string]any{"commit": strings.Repeat("1", 40), "dirty": false},
			"bpf_mlir": map[string]any{"commit": v.Commit},
		},
		"result":  map[string]any{"rc": rc, "domain_produced": true},
		"outputs": outputs,
	}
	c.writeManifest(t)
	return c
}

func (c *seamCase) writeManifest(t *testing.T) {
	t.Helper()
	b, err := json.MarshalIndent(c.manifest, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(c.I, c.name+".inspect-manifest.json"), b, 0o644); err != nil {
		t.Fatal(err)
	}
}

// seamBuild は c の source を別の dir に写して seam で build し、rc・stderr と dir を返す。
func seamBuild(t *testing.T, c *seamCase, rel string, extra ...string) (int, string, string) {
	t.Helper()
	dir := t.TempDir()
	rb := copySource(t, rel, dir)
	var so, se bytes.Buffer
	args := append([]string{"build", "--seam-emit", c.E, "--seam-inspect", c.I}, extra...)
	rc := run(append(args, rb), &so, &se)
	return rc, strings.ReplaceAll(se.String(), dir, "<dir>"), dir
}

var seamArtefacts = []string{".mlir", ".schema.json", ".maps.json", ".domain.json", ".bpf.o", ".compile_warnings.txt", "_embed.S"}

// TestSeamRoundTrip は E152 の H6 (と H2 の小さな形): Go の経路の出力から作った E / I を seam で通すと、artefacts と stderr が Go の経路と同じ
// (xdpcount — uprobe 無し・greetwatch — uprobe の target の照合、record の表を持つ)。
func TestSeamRoundTrip(t *testing.T) {
	parallel(t)
	cfg, err := defaultConfig()
	if err != nil {
		t.Fatal(err)
	}
	for _, rel := range []string{"examples/xdpcount/xdpcount.rb", "examples/greetwatch/greetwatch.rb"} {
		c := makeSeam(t, cfg, rel)
		goDir := t.TempDir()
		var gso, gse bytes.Buffer
		grc := run([]string{"build", copySource(t, rel, goDir)}, &gso, &gse)
		rc, se, dir := seamBuild(t, c, rel)
		t.Logf("%s: go rc %d, seam rc %d", rel, grc, rc)
		if grc != 0 || rc != 0 {
			t.Fatalf("%s: go rc %d, seam rc %d\n%s", rel, grc, rc, se)
		}
		// 追補 5: seam は Go の経路の stderr に manifest の写しの wrote の 1 行だけを足す
		if g := strings.ReplaceAll(gse.String(), goDir, "<dir>") + "spinelbpf: wrote <dir>/" + c.name + ".inspect-manifest.json\n"; g != se {
			t.Errorf("%s: the seam's stderr is not the Go path's plus the manifest line\nwant:\n%s\nseam:\n%s", rel, g, se)
		}
		a, err1 := os.ReadFile(filepath.Join(c.I, c.name+".inspect-manifest.json"))
		b, err2 := os.ReadFile(filepath.Join(dir, c.name+".inspect-manifest.json"))
		if err1 != nil || err2 != nil || !bytes.Equal(a, b) {
			t.Errorf("%s: the copied manifest differs from the consumer's (%v %v)", rel, err1, err2)
		}
		for _, ext := range seamArtefacts {
			a, err1 := os.ReadFile(filepath.Join(goDir, c.name+ext))
			b, err2 := os.ReadFile(filepath.Join(dir, c.name+ext))
			if err1 != nil || err2 != nil || !bytes.Equal(a, b) {
				t.Errorf("%s: %s differs between the Go path and the seam (%v %v)", rel, ext, err1, err2)
			}
		}
	}
}

// TestSeamRefusal は E152 の H3 の形: 拒否の source の domain だけの manifest (rc 1) は Go の経路と同じ印字と rc、blocking の診断の無い domain と
// failure_stage は名指しで止まる (追補 2)。
func TestSeamRefusal(t *testing.T) {
	parallel(t)
	cfg, err := defaultConfig()
	if err != nil {
		t.Fatal(err)
	}
	rel := "internal/frontend/testdata/neg/kc_copy_value.rb"
	c := makeSeam(t, cfg, rel)
	goDir := t.TempDir()
	var gso, gse bytes.Buffer
	grc := run([]string{"build", copySource(t, rel, goDir)}, &gso, &gse)
	rc, se, _ := seamBuild(t, c, rel)
	t.Logf("go rc %d, seam rc %d, seam stderr: %s", grc, rc, se)
	if grc != 1 || rc != grc || strings.ReplaceAll(gse.String(), goDir, "<dir>") != se {
		t.Errorf("refusal: go rc %d / seam rc %d\ngo:\n%s\nseam:\n%s", grc, rc, gse.String(), se)
	}
	// domain の blocking の診断を conditional に書き換え (manifest の hash も直す) — 成功扱いせず止まる
	dp := filepath.Join(c.I, c.name+".domain.json")
	d, _ := os.ReadFile(dp)
	d2 := bytes.ReplaceAll(d, []byte(`"verdict": "rejected"`), []byte(`"verdict": "conditional"`))
	if bytes.Equal(d, d2) {
		t.Fatal("the domain has no rejected diagnostic to rewrite")
	}
	os.WriteFile(dp, d2, 0o644)
	c.manifest["outputs"].(map[string]any)["domain"] = map[string]any{"path": "/captured/domain", "sha256": sha256Hex(d2)}
	c.writeManifest(t)
	rc, se, _ = seamBuild(t, c, rel)
	t.Logf("no blocking: rc %d: %s", rc, se)
	if rc != 1 || !strings.Contains(se, "the domain has no blocking diagnostic") {
		t.Errorf("a refusal without a blocking diagnostic: rc %d\n%s", rc, se)
	}
	c.manifest["result"].(map[string]any)["failure_stage"] = "emit_io"
	c.writeManifest(t)
	rc, se, _ = seamBuild(t, c, rel)
	t.Logf("failure_stage: rc %d: %s", rc, se)
	if rc != 1 || !strings.Contains(se, "the consumer failed at stage emit_io") {
		t.Errorf("failure_stage: rc %d\n%s", rc, se)
	}
}

// TestSeamManifestChecks は E152 の H4: manifest と入力の照らしの負の対照 — 各々が名指しで止まり、後ろの道に進まない (.bpf.o を書かない)。
func TestSeamManifestChecks(t *testing.T) {
	parallel(t)
	cfg, err := defaultConfig()
	if err != nil {
		t.Fatal(err)
	}
	rel := "examples/greetwatch/greetwatch.rb"
	base := makeSeam(t, cfg, rel)
	clone := func() *seamCase {
		c := *base
		c.E, c.I = filepath.Join(t.TempDir(), "E"), filepath.Join(t.TempDir(), "I")
		copyTree(t, base.E, mkdir(t, c.E))
		copyTree(t, base.I, mkdir(t, c.I))
		b, _ := json.Marshal(base.manifest)
		c.manifest = map[string]any{}
		json.Unmarshal(b, &c.manifest)
		return &c
	}
	mf := func(c *seamCase) map[string]any { return c.manifest }
	sub := func(m map[string]any, k string) map[string]any { return m[k].(map[string]any) }
	flip := func(c *seamCase, key, dir, ext string) { // file の 1 byte を変える (manifest は元の hash)
		p := filepath.Join(dir, c.name+ext)
		b, _ := os.ReadFile(p)
		b[len(b)-1] ^= 1
		os.WriteFile(p, b, 0o644)
	}
	cases := []struct {
		name string
		mut  func(c *seamCase)
		want string
	}{
		{"version 2", func(c *seamCase) { mf(c)["version"] = 2 }, "manifest version 2"},
		{"unknown key", func(c *seamCase) { mf(c)["extra"] = 1 }, "unknown_key"},
		{"missing key", func(c *seamCase) { delete(mf(c), "execution") }, `has no key "execution"`},
		{"source sha", func(c *seamCase) { sub(mf(c), "source")["sha256"] = strings.Repeat("0", 64) }, "the consumer's output was not made from this source"},
		{"bpf_mlir pin", func(c *seamCase) { sub(sub(mf(c), "pins"), "bpf_mlir")["commit"] = strings.Repeat("f", 40) }, "pins.bpf_mlir.commit"},
		{"metadata on consumer", func(c *seamCase) { sub(sub(mf(c), "pins"), "spinel")["producer_source"] = "metadata" }, `producer_source "facts"`},
		{"rc 0 missing output", func(c *seamCase) { delete(sub(mf(c), "outputs"), "records") }, "needs outputs"},
		{"rc 1 extra output", func(c *seamCase) { sub(mf(c), "result")["rc"] = 1 }, "needs outputs"},
		{"rc 2", func(c *seamCase) { sub(mf(c), "result")["rc"] = 2 }, "manifest result.rc 2"},
		{"failure_stage", func(c *seamCase) { sub(mf(c), "result")["failure_stage"] = "emit_io" }, "failed at stage emit_io"},
		{"targets version", func(c *seamCase) {
			p := filepath.Join(c.E, c.name+".uprobe_targets.json")
			b, _ := os.ReadFile(p)
			b = bytes.Replace(b, []byte(`"version": 1`), []byte(`"version": 2`), 1)
			os.WriteFile(p, b, 0o644)
			sub(mf(c), "outputs")["uprobe_targets"] = map[string]any{"path": "/x", "sha256": sha256Hex(b)}
		}, "uprobe_targets: version 2"},
		{"targets missing program", func(c *seamCase) {
			b := []byte(`{"version": 1, "programs": []}`)
			os.WriteFile(filepath.Join(c.E, c.name+".uprobe_targets.json"), b, 0o644)
			sub(mf(c), "outputs")["uprobe_targets"] = map[string]any{"path": "/x", "sha256": sha256Hex(b)}
		}, "has no target"},
		{"targets binary sha", func(c *seamCase) {
			p := filepath.Join(c.E, c.name+".uprobe_targets.json")
			b, _ := os.ReadFile(p)
			bad := filepath.Join(t.TempDir(), "bad")
			os.WriteFile(bad, []byte("not the target"), 0o755)
			var tg map[string]any
			json.Unmarshal(b, &tg)
			tg["programs"].([]any)[0].(map[string]any)["binary_path"] = bad
			b, _ = json.Marshal(tg)
			os.WriteFile(p, b, 0o644)
			sub(mf(c), "outputs")["uprobe_targets"] = map[string]any{"path": "/x", "sha256": sha256Hex(b)}
		}, "SB032"},
	}
	for _, o := range seamOutputs {
		o := o
		cases = append(cases, struct {
			name string
			mut  func(c *seamCase)
			want string
		}{"1 byte " + o.key, func(c *seamCase) {
			d := c.E
			if o.dir == "I" {
				d = c.I
			}
			flip(c, o.key, d, o.ext)
		}, "outputs." + o.key + ": "})
		cases = append(cases, struct {
			name string
			mut  func(c *seamCase)
			want string
		}{"missing " + o.key, func(c *seamCase) {
			d := c.E
			if o.dir == "I" {
				d = c.I
			}
			os.Remove(filepath.Join(d, c.name+o.ext))
		}, "outputs." + o.key + ": "})
	}
	for _, k := range cases {
		c := clone()
		k.mut(c)
		c.writeManifest(t)
		rc, se, dir := seamBuild(t, c, rel)
		t.Logf("%s: rc %d: %s", k.name, rc, strings.TrimSpace(se))
		if rc != 1 || !strings.Contains(se, k.want) {
			t.Errorf("%s: want rc 1 naming %q, got rc %d\n%s", k.name, k.want, rc, se)
		}
		if k.want != "SB032" {
			if _, err := os.Stat(filepath.Join(dir, c.name+".bpf.o")); err == nil {
				t.Errorf("%s: the seam went on to ebpf-compile", k.name)
			}
		}
	}
	// 別の .rb (stem が違う) — manifest が無い
	var so, se bytes.Buffer
	dir := t.TempDir()
	if rc := run([]string{"build", "--seam-emit", base.E, "--seam-inspect", base.I, copySource(t, "examples/xdpcount/xdpcount.rb", dir)}, &so, &se); rc != 1 || !strings.Contains(se.String(), "inspection manifest") {
		t.Errorf("another source: rc %d\n%s", rc, se.String())
	}
	t.Logf("another source: %s", strings.TrimSpace(se.String()))
	// flag は両方か無し
	for _, args := range [][]string{{"build", "--seam-emit", base.E, "x.rb"}, {"build", "--seam-inspect", base.I, "x.rb"}} {
		var so, se bytes.Buffer
		if rc := run(args, &so, &se); rc != 2 || !strings.Contains(se.String(), "go together") {
			t.Errorf("%v: rc %d\n%s", args, rc, se.String())
		}
	}
}

// TestSeamBackChecks は E152 の H5: seam の入力を (manifest の hash も合わせて) 後ろの照合と食い違わせると、その照合で止まる — seam が飛ばしていない。
func TestSeamBackChecks(t *testing.T) {
	parallel(t)
	cfg, err := defaultConfig()
	if err != nil {
		t.Fatal(err)
	}
	rel := "examples/greetwatch/greetwatch.rb"
	for _, k := range []struct {
		name, ext, from, to, want string
	}{
		{"records vs schema", ".records.txt", "count:8:u32", "count:9:u32", "record"},
		{"map name vs ELF", ".schema.json", `"Greetings"`, `"Greetingz"`, ""},
		// 停止 A・B: 自己整合の改変 (schema の note) と schema だけの値 (max_entries — .mlir に無い) は後ろの照合に見えない — 境界の記録として下で rc 0 を求める
		{"max_entries (schema only — passes the build)", ".schema.json", `"max_entries": 2,`, `"max_entries": 3,`, "PASS"},
	} {
		c := makeSeam(t, cfg, rel)
		p := filepath.Join(c.E, c.name+k.ext)
		b, _ := os.ReadFile(p)
		b2 := bytes.Replace(b, []byte(k.from), []byte(k.to), 1)
		if bytes.Equal(b, b2) {
			t.Fatalf("%s: %q not in %s", k.name, k.from, k.ext)
		}
		os.WriteFile(p, b2, 0o644)
		key := map[string]string{".records.txt": "records", ".schema.json": "schema"}[k.ext]
		c.manifest["outputs"].(map[string]any)[key] = map[string]any{"path": "/x", "sha256": sha256Hex(b2)}
		c.writeManifest(t)
		rc, se, _ := seamBuild(t, c, rel)
		t.Logf("%s: rc %d: %s", k.name, rc, strings.TrimSpace(se))
		if k.want == "PASS" { // E152 の Honest boundary: load の時の bml の CheckMapDecls が見る見込み (測っていない)
			if rc != 0 {
				t.Errorf("%s: the recorded boundary changed — a schema-only value now stops the build (rc %d)\n%s", k.name, rc, se)
			}
			continue
		}
		if rc != 1 || strings.Contains(se, "seam:") || !strings.Contains(se, k.want) {
			t.Errorf("%s: want a back-end check to stop it (not the seam's reader), got rc %d\n%s", k.name, rc, se)
		}
	}
}

func mkdir(t *testing.T, d string) string {
	t.Helper()
	if err := os.MkdirAll(d, 0o755); err != nil {
		t.Fatal(err)
	}
	return d
}

// TestReadDomainGraphRoundTrip は E152: ReadDomainGraph が DomainGraph の診断を Go の Diag に戻す (印字が同じ)。
func TestReadDomainGraphRoundTrip(t *testing.T) {
	parallel(t)
	cfg, err := defaultConfig()
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	r, berr := Build(cfg, copySource(t, "internal/frontend/testdata/neg/kc_copy_value.rb", dir))
	var fe *frontend.Error
	if r == nil || berr == nil || !errors.As(berr, &fe) {
		t.Fatalf("want a refusal: %v", berr)
	}
	_, ds, err := frontend.ReadDomainGraph(r.Output.Domain)
	if err != nil {
		t.Fatal(err)
	}
	if got := (&frontend.Error{Diags: ds}).Error(); got != fe.Error() {
		t.Errorf("read back:\n%s\nGo:\n%s", got, fe.Error())
	}
}
