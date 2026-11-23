package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// E100 の試験 (P024 段 1 — output_str_or_discard と r.sent)。

// buildDiscard は up_discard.rb を target と一緒に一時の directory で build し、その directory を返す。
func buildDiscard(t *testing.T) string {
	t.Helper()
	cfg, _ := defaultConfig()
	d := t.TempDir()
	src := uprobeSrc("up_discard")
	b, _ := os.ReadFile(src)
	os.WriteFile(filepath.Join(d, "up_discard.rb"), b, 0o644)
	if o, err := exec.Command("cp", "-r", filepath.Join(filepath.Dir(src), "target"), d).CombinedOutput(); err != nil {
		t.Fatalf("copy target: %v %s", err, o)
	}
	if _, err := Build(cfg, filepath.Join(d, "up_discard.rb")); err != nil {
		t.Fatal(err)
	}
	return d
}

// TestOutputStrDiscardOwnership は E100 の H3: 生成した .mlir の捨ての腕の discard を消す・submit の腕の submit を消す・submit を 2 つにする変異を
// ebpf-compile が ownership の誤りで止め (全ての経路でちょうど 1 回 — bpf-mlir v1.3.0 の ebpf-verify-ownership)、変異の無い .mlir は通る —
// frontend の lowering が腕ごとの消費を正しく書いていることの対照。
func TestOutputStrDiscardOwnership(t *testing.T) {
	parallel(t) // P018 E075
	cfg, _ := defaultConfig()
	d := buildDiscard(t)
	m, err := os.ReadFile(filepath.Join(d, "up_discard.mlir"))
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.SplitAfter(string(m), "\n")
	disc, lastSub := -1, -1
	for i, l := range lines {
		if strings.Contains(l, "ebpf.ringbuf.discard") {
			disc = i
		}
		if strings.Contains(l, "ebpf.ringbuf.submit") {
			lastSub = i
		}
	}
	if disc < 0 || lastSub < disc {
		t.Fatalf("no discard / submit arms in the generated .mlir:\n%s", m)
	}
	without := func(k int) string { return strings.Join(append(append([]string{}, lines[:k]...), lines[k+1:]...), "") }
	dup := strings.Join(append(append(append([]string{}, lines[:lastSub+1]...), lines[lastSub]), lines[lastSub+1:]...), "")
	compile := func(name, text string) (string, error) {
		p := filepath.Join(d, name+".mlir")
		os.WriteFile(p, []byte(text), 0o644)
		c := exec.Command(cfg.EbpfCompile, p, "--schema", filepath.Join(d, "up_discard.schema.json"), "-o", filepath.Join(d, name+".bpf.o"))
		o, err := c.CombinedOutput()
		return string(o), err
	}
	if o, err := compile("orig", string(m)); err != nil {
		t.Fatalf("the generated .mlir does not compile: %v\n%s", err, o)
	}
	for _, c := range []struct{ name, text, want string }{
		{"no-discard", without(disc), "consumed in only some of this operation's regions"},
		{"no-submit", without(lastSub), "consumed in only some of this operation's regions"},
		{"two-submits", dup, "after it was submitted or discarded"},
	} {
		o, err := compile(c.name, c.text)
		if err == nil || !strings.Contains(o, c.want) {
			t.Errorf("%s: want an ownership error %q, got err %v\n%s", c.name, c.want, err, firstLines(o, 4))
		}
		t.Logf("%s: %s", c.name, firstLines(o, 1))
	}
}

// TestOutputStrDiscardDifferential は E100 の H4 (host、root): cfix の greet に文字列・空・NULL・切り詰めを送り、kernel と双子の出力 (dump と Keep /
// Drop の ring の drain) が一致し、NULL の行だけ Drop の event が無く r 真・r.sent 偽・r.status −14、他の行は Drop にも event が在り r.sent 真、
// Keep (output_str) はどの行も event が在る。
func TestOutputStrDiscardDifferential(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046
	h := buildHarnesses(t, uprobeSrc("up_discard"))
	rows := []string{"greet 5 hello", "greet 0", "null 3", "greet 9 " + strings.Repeat("b", 40)}
	var b strings.Builder
	for _, r := range rows {
		b.WriteString("reset\nrun on_greet " + r + "\ndump\ndrain Keep\ndrain Drop\n")
	}
	kn := feed(t, true, "child\n"+b.String(), h.kernelBin, cfixPath())
	tw := feed(t, false, childTask(t, kn)+b.String(), h.twinBin)
	kn = strings.Replace(kn, kn[:strings.Index(kn, "\n")+1], "ok\n", 1)
	for _, bad := range first(uprobeCompare(tw, kn), 8) {
		t.Errorf("kernel / twin: %s", bad)
	}
	blocks := strings.Split(kn, "ret=0\n")[1:]
	if len(blocks) != len(rows) {
		t.Fatalf("want %d runs, got %d:\n%s", len(rows), len(blocks), firstLines(kn, 30))
	}
	for i, r := range rows {
		blk := blocks[i]
		null := strings.HasPrefix(r, "null")
		wantDrop, wantSent := "Drop drained=1", "Seen[1]=1"
		if null {
			wantDrop, wantSent = "Drop drained=0", "Seen[1]=0"
		}
		for _, w := range []string{"Keep drained=1", wantDrop, "Seen[0]=1", wantSent} {
			if !strings.Contains(blk, w+"\n") {
				t.Errorf("row %q: want %q in\n%s", r, w, blk)
			}
		}
		if null && !strings.Contains(blk, "Seen[2]=-14\n") {
			t.Errorf("row %q: want r.status -14 (Seen[2]) in\n%s", r, blk)
		}
		if r == "greet 0" && !strings.Contains(blk, "Seen[2]=1\n") {
			t.Errorf("row %q: the empty string's status on 7.1.8 is 1 (not discarded) — want Seen[2]=1 in\n%s", r, blk)
		}
	}
	t.Logf("kernel:\n%s", firstLines(kn, 60))
}
