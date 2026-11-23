package main

import (
	"bufio"
	"bytes"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// E083 の試験: 例 greetwatch (P020 §4) — C の target (greeter) の greet の名前と回数を uprobe で ring に。

var greetwatchArtefacts = []string{"greetwatch.mlir", "greetwatch.schema.json", "greetwatch.maps.json", "greetwatch.domain.json", "greetwatch.bpf.o",
	"greetwatch.compile_warnings.txt", "greetwatch_embed.S", "greetwatch_embed.o"}

func greeterPath() string {
	return filepath.Join(repoRoot(), "examples", "greetwatch", "target", "greeter")
}

func linkedGreetwatch(t *testing.T) string {
	t.Helper()
	cfg, _ := defaultConfig()
	d, err := os.MkdirTemp(filepath.Join(repoRoot(), "build", "tmp"), "e083-")
	if err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(filepath.Join(repoRoot(), "examples", "greetwatch", "greetwatch.rb"))
	src := filepath.Join(d, "greetwatch.rb")
	os.WriteFile(src, b, 0o644)
	os.MkdirAll(filepath.Join(d, "target"), 0o755)
	gb, _ := os.ReadFile(greeterPath())
	writeExec(t, filepath.Join(d, "target", "greeter"), gb)
	r, err := Build(cfg, src)
	if err != nil {
		t.Fatal(err)
	}
	for _, x := range r.Output.Result.Diags {
		t.Errorf("unexpected diagnostic: %s", x)
	}
	exe := filepath.Join(d, "greetwatch")
	if err := Link(cfg, src, exe); err != nil {
		t.Fatal(err)
	}
	return exe
}

// TestGreetwatchArtefacts は E083 の H1: 2 回の build の生成物が commit 済みの物と byte 同じ、schema の binary_sha256 は greeter の SHA256SUMS の値。
func TestGreetwatchArtefacts(t *testing.T) {
	parallel(t) // P018 E075
	cfg, _ := defaultConfig()
	b, _ := os.ReadFile(filepath.Join(repoRoot(), "examples", "greetwatch", "greetwatch.rb"))
	gb, _ := os.ReadFile(greeterPath())
	for i := 0; i < 2; i++ {
		d := t.TempDir()
		src := filepath.Join(d, "greetwatch.rb")
		os.WriteFile(src, b, 0o644)
		os.MkdirAll(filepath.Join(d, "target"), 0o755)
		writeExec(t, filepath.Join(d, "target", "greeter"), gb)
		if _, err := Build(cfg, src); err != nil {
			t.Fatal(err)
		}
		for _, f := range greetwatchArtefacts {
			got, _ := os.ReadFile(filepath.Join(d, f))
			want, err := os.ReadFile(filepath.Join(repoRoot(), "examples", "greetwatch", f))
			if err != nil || !bytes.Equal(got, want) {
				t.Errorf("build %d: %s differs from the committed one (%v)", i, f, err)
			}
		}
	}
	sums, _ := os.ReadFile(filepath.Join(repoRoot(), "examples", "greetwatch", "target", "SHA256SUMS"))
	schema, _ := os.ReadFile(filepath.Join(repoRoot(), "examples", "greetwatch", "greetwatch.schema.json"))
	if f := strings.Fields(string(sums)); len(f) < 2 || !strings.Contains(string(schema), `"binary_sha256": "`+f[0]+`"`) {
		t.Errorf("the schema's binary_sha256 is not greeter's SHA256SUMS value")
	}
}

var pidRe = regexp.MustCompile(`pid=\d+`)

// TestGreetwatchSelftestHost は E083 の H2 (root) と H4 (uid 1000 の CAP_BPF + CAP_PERFMON + CAP_SYS_ADMIN — 出力は pid の値を除いて root と同じ)。
func TestGreetwatchSelftestHost(t *testing.T) {
	parallel(t) // P018 E075
	exe := linkedGreetwatch(t)
	out := feed(t, true, "", exe, "--selftest", "--target", greeterPath())
	for _, w := range []string{"count=1 status=6 name=hello\n", "count=2 status=1 name=(empty)\n", "count=3 status=32 name=" + strings.Repeat("a", 31) + "\n", "count=4 status=-14 name=(read failed)\n", "selftest ok\n"} {
		if !strings.Contains(out, w) {
			t.Errorf("H2: want %q in\n%s", w, out)
		}
	}
	nr, err := nonroot(t, "+bpf,+perfmon,+sys_admin", "", exe, "--selftest", "--target", greeterPath())
	if err != nil || pidRe.ReplaceAllString(nr, "pid=P") != pidRe.ReplaceAllString(out, "pid=P") {
		t.Errorf("H4: non-root (err %v):\n%s\nroot:\n%s", err, nr, out)
	}
	t.Log(out)
}

// greeterProc は外で起動した greeter の process (stdin に行を送り返事を読む)。
type greeterProc struct {
	cmd *exec.Cmd
	in  io.WriteCloser
	out *bufio.Reader
	pid string
}

func startGreeter(t *testing.T) *greeterProc {
	t.Helper()
	cmd := exec.Command(greeterPath())
	in, _ := cmd.StdinPipe()
	op, _ := cmd.StdoutPipe()
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	g := &greeterProc{cmd: cmd, in: in, out: bufio.NewReader(op)}
	l, err := g.out.ReadString('\n')
	if err != nil || !strings.HasPrefix(l, "ready ") {
		t.Fatalf("greeter: %q %v", l, err)
	}
	g.pid = strings.TrimSpace(strings.TrimPrefix(l, "ready "))
	return g
}

func (g *greeterProc) send(t *testing.T, line string) {
	t.Helper()
	g.in.Write([]byte(line + "\n"))
	if _, err := g.out.ReadString('\n'); err != nil {
		t.Fatalf("greeter did not answer: %v", err)
	}
}

// TestGreetwatchHost は E083 の H3 (root): `--pid` で外の greeter の 1 つに attach — その greeter に送った 3 行 (普通・空・NULL) の event が
// 表示の規則で出て、別の pid の greeter に送った行の event は出ない。
func TestGreetwatchHost(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	exe := linkedGreetwatch(t)
	a, b := startGreeter(t), startGreeter(t)
	defer func() { a.in.Close(); b.in.Close(); a.cmd.Wait(); b.cmd.Wait() }()
	cmd := sudoCmd(t, exe, "--target", greeterPath(), "--pid", a.pid, "--duration-ms", "3000")
	op, _ := cmd.StdoutPipe()
	cmd.Stderr = cmd.Stdout
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	r := bufio.NewReader(op)
	var lines []string
	for {
		l, err := r.ReadString('\n')
		if err != nil {
			t.Fatalf("greetwatch ended before attaching: %v\n%s", err, strings.Join(lines, ""))
		}
		lines = append(lines, l)
		if strings.HasPrefix(l, "attached ") {
			break
		}
	}
	for _, n := range []string{"alice", "", "(null)"} {
		a.send(t, n)
		b.send(t, "bob-"+n)
	}
	rest, _ := io.ReadAll(r)
	cmd.Wait()
	out := strings.Join(lines, "") + string(rest)
	t.Log(out)
	for _, w := range []string{
		"greeting pid=" + a.pid + " count=1 status=6 name=alice\n",
		"greeting pid=" + a.pid + " count=2 status=1 name=(empty)\n",
		"greeting pid=" + a.pid + " count=3 status=-14 name=(read failed)\n",
		"events=3 ring_full=0\n",
	} {
		if !strings.Contains(out, w) {
			t.Errorf("H3: want %q", w)
		}
	}
	if strings.Contains(out, "bob") || strings.Contains(out, "pid="+b.pid) {
		t.Errorf("H3: the other greeter's calls were counted")
	}
}
