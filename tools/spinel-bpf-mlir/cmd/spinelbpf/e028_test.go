package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// E028 の試験: ring buffer の差動 (双子の容量の model — P007 §4)。

func tRingSrc() string {
	return filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "ring", "t_ring.rb")
}

// tRingScript は t_ring の表 (期待の値を持たない)。行は `echo <label>` で始まる: 境界の値の event・drain せずに N 回・drain の後に再び・unless / _ = の形。
func tRingScript() string {
	var b strings.Builder
	runs := func(p string, n int) {
		for i := 0; i < n; i++ {
			fmt.Fprintf(&b, "run %s\n", p)
		}
	}
	for _, x := range []string{"0", "-1", "4294967296", "9223372036854775807", "-9223372036854775807", "305419896"} {
		for _, y := range []string{"0", "4294967295", "-1", "2147483648"} {
			fmt.Fprintf(&b, "echo bounds_x=%s_y=%s\nreset\npoke In 0 %s\npoke In 1 %s\nrun t_if\ndump\ndrain Events\n", x, y, x, y)
		}
	}
	for _, n := range []int{126, 127, 128, 200} {
		fmt.Fprintf(&b, "echo fill_if_%d\nreset\n", n)
		runs("t_if", n)
		b.WriteString("dump\ndrain Events\n")
	}
	b.WriteString("echo refill\nreset\n")
	runs("t_if", 127)
	b.WriteString("drain Events\n")
	runs("t_if", 128)
	b.WriteString("dump\ndrain Events\n")
	b.WriteString("echo fill_unless_128\nreset\n")
	runs("t_unless", 128)
	b.WriteString("dump\ndrain Events\n")
	b.WriteString("echo fill_any_128\nreset\n")
	runs("t_any", 128)
	b.WriteString("dump\ndrain Events\n")
	return b.String()
}

// ringDiff は 2 つの出力の最初の食い違いを、その行の印 (`## <label>`) 付きで返す (無ければ "")。
func ringDiff(a, b string) string {
	x, y := strings.Split(a, "\n"), strings.Split(b, "\n")
	label := "-"
	for i := 0; i < len(x) || i < len(y); i++ {
		var p, q string
		if i < len(x) {
			p = x[i]
		}
		if i < len(y) {
			q = y[i]
		}
		if strings.HasPrefix(p, "## ") {
			label = p[3:]
		}
		if p != q {
			return fmt.Sprintf("row %s line %d: %q | %q", label, i+1, p, q)
		}
	}
	return ""
}

// TestRingTable は E028 の H1〜H3 (host、root): t_ring の表で twin (Spinel)・kernel・CRuby が byte 一致し、満たす行の落ちた数と event の数が model の予測どおり。
func TestRingTable(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	h := buildHarnesses(t, tRingSrc())
	script := tRingScript()
	tw := feed(t, false, script, h.twinBin)
	kn := feed(t, true, script, h.kernelBin)
	rb := crubyFeed(t, script, h)
	if d := ringDiff(tw, kn); d != "" {
		t.Errorf("twin / kernel: %s", d)
	}
	if d := ringDiff(tw, rb); d != "" {
		t.Errorf("twin / CRuby: %s", d)
	}
	t.Logf("%d lines", strings.Count(tw, "\n"))
	for _, w := range []string{
		"## fill_if_126\n", "Cnt[0]=126\nCnt[1]=0\n", "Events drained=126\n",
		"## fill_if_127\n", "Cnt[0]=127\nCnt[1]=0\n", "Events drained=127\n",
		"## fill_if_128\n", "Cnt[0]=127\nCnt[1]=1\n",
		"## fill_if_200\n", "Cnt[0]=127\nCnt[1]=73\n",
		"## refill\n", "Events drained=127\n", "Cnt[0]=254\nCnt[1]=1\n", "Events drained=127\n",
		"## fill_unless_128\n", "Cnt[2]=1\n", "Events drained=127\n",
		"## fill_any_128\n", "Events drained=127\n",
	} {
		i := strings.Index(kn, w)
		if i < 0 {
			t.Fatalf("the kernel output lacks %q in order", w)
		}
		kn = kn[i+len(w):]
	}
}

// TestRingTableOut は E028 の成果物: 表の手順と kernel の出力を E028_OUT に残す。
func TestRingTableOut(t *testing.T) {
	parallel(t) // P018 E075
	o := os.Getenv("E028_OUT")
	if o == "" {
		t.Skip("E028_OUT")
	}
	h := buildHarnesses(t, tRingSrc())
	script := tRingScript()
	os.WriteFile(filepath.Join(o, "t_ring.script"), []byte(script), 0o644)
	os.WriteFile(filepath.Join(o, "t_ring.kernel.out"), []byte(feed(t, true, script, h.kernelBin)), 0o644)
}

// ringMC は testdata/ring/mc.rb を build し (hook は変異の対照 — 試験の build だけで効く)、mcrun の ring の mode を root で走らせ数を返す。
func ringMC(t *testing.T, hook string, repeat int) (cpus, sent, received, dropped int) {
	t.Helper()
	if os.Getenv("SPINELBPF_NO_ROOT") == "1" {
		t.Skip("SPINELBPF_NO_ROOT=1")
	}
	cfg, _ := defaultConfig()
	d := t.TempDir()
	b, _ := os.ReadFile(filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "ring", "mc.rb"))
	src := filepath.Join(d, "mc.rb")
	os.WriteFile(src, b, 0o644)
	if hook != "" {
		t.Setenv("SPINELBPF_MUTATION", hook)
	}
	_, err := Build(cfg, src)
	os.Unsetenv("SPINELBPF_MUTATION")
	if err != nil {
		t.Fatal(err)
	}
	runner := filepath.Join(d, "mcrun")
	gb := exec.Command(cfg.Go, "build", "-o", runner, "./cmd/spinelbpf/testdata/mcrun")
	gb.Dir = cfg.Repo
	gb.Env = append(os.Environ(), "GOFLAGS=-mod=mod")
	if o, err := gb.CombinedOutput(); err != nil {
		t.Fatalf("%v\n%s", err, o)
	}
	out, err := sudoCmd(t, runner, "ring", filepath.Join(d, "mc.bpf.o"), fmt.Sprint(repeat)).CombinedOutput()
	if err != nil {
		t.Fatalf("%v\n%s", err, out)
	}
	t.Logf("%s: %s", hook, strings.TrimSpace(string(out)))
	var rep int
	var ok bool
	if _, err := fmt.Sscanf(strings.TrimSpace(string(out)), "cpus=%d repeat=%d sent=%d received=%d dropped=%d sum_ok=%t", &cpus, &rep, &sent, &received, &dropped, &ok); err != nil {
		t.Fatalf("unreadable: %v", err)
	}
	return
}

// TestRingMultiCPU は E028 の H5 (host、root): 全ての CPU で同時に output し reader が並んで読む — 受け取った数 + 落ちた数 = 送った数、落ちた数 > 0 (溢れる経路を通った)。
func TestRingMultiCPU(t *testing.T) {
	cpus, sent, received, dropped := ringMC(t, "", 20000)
	if received+dropped != sent {
		t.Errorf("received %d + dropped %d != sent %d on %d CPUs", received, dropped, sent, cpus)
	}
	if dropped == 0 {
		t.Errorf("no drops — the full-ring path was not exercised (raise repeat)")
	}
}
