package main

import (
	"bufio"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/yuskesh/spinel-playground/tools/spinel-bpf-mlir/internal/frontend"
)

// E082 の試験 (P020): C でない uprobe の target — Go の関数・Spinel の build した binary・自分の実行 file。

// uwatchSrc は target (source の directory からの相対の rel)・symbol の関数の引数 1・2 (:i64) を読む利用者の program。
//
//	<exe> <target の path> load    load の結果だけ
//	<exe> <target の path> watch   全ての process に attach し `attached` を出し、stdin の 1 行を待ってから Calls と引数の最後の値を出す
func uwatchSrc(rel, sym string, params ...string) string {
	ps := "{1 => :i64, 2 => :i64}"
	if len(params) > 0 {
		ps = params[0]
	}
	return `require "bpf"

Args = BPF::ArrayMap.new("Args", :i64, 3)

def on_fn(ctx)
  Args.atomic_add(0, 1)
  Args.update(1, ctx.arg(1))
  Args.update(2, ctx.arg(2))
end
BPF.uprobe :on_fn, "` + rel + `", "` + sym + `", params: ` + ps + `

require "spinelbpf"

tg = SpinelBPF::UprobeTargets.new
tg.add("on_fn", ARGV[0])
obj = nil
begin
  obj = SpinelBPF.load_embedded_targets(SpinelBPF::ConfigSet.new, tg)
rescue SpinelBPF::Error => e
  puts "load kind=#{e.class} msg=#{e.message}"
  exit 0
end
puts "load ok unmet=#{obj.unmet.length}"
if ARGV[1] == "watch"
  l = obj.attach_uprobe("on_fn", 0)
  puts "attached"
  $stdout.flush
  $stdin.gets
  puts "calls=#{obj.map_get(Args, 0)} a1=#{obj.map_get(Args, 1)} a2=#{obj.map_get(Args, 2)}"
  l.detach
end
obj.close
`
}

// uwatchBuild は uwatch の program を target の file (rel に写す) で build する。build の時の照合で止まれば誤りを返す (force なら照合を通さずに
// Build の書いた .mlir / schema から ELF・埋め込み・link — load の時の bml の照合を見るため)。
func uwatchBuild(t *testing.T, target, rel, sym string, force bool) (string, error) {
	t.Helper()
	cfg, _ := defaultConfig()
	d := t.TempDir()
	src := filepath.Join(d, "uwatch.rb")
	os.WriteFile(src, []byte(uwatchSrc(rel, sym)), 0o644)
	if target != "" {
		b, err := os.ReadFile(target)
		if err != nil {
			t.Fatal(err)
		}
		os.MkdirAll(filepath.Dir(filepath.Join(d, rel)), 0o755)
		writeExec(t, filepath.Join(d, rel), b)
	}
	exe := filepath.Join(d, "uwatch")
	if _, err := Build(cfg, src); err != nil {
		if !force {
			return exe, err
		}
		if err := runIn(d, cfg.EbpfCompile, "uwatch.mlir", "--schema", "uwatch.schema.json", "-o", "uwatch.bpf.o"); err != nil {
			t.Fatalf("forced compile: %v", err)
		}
		schema, _ := os.ReadFile(filepath.Join(d, "uwatch.schema.json"))
		sha, err := checkSchemaSHA(filepath.Join(d, "uwatch.bpf.o"), schema)
		if err != nil {
			t.Fatal(err)
		}
		os.WriteFile(filepath.Join(d, "uwatch_embed.S"), []byte(embedAsm("uwatch.bpf.o", sha, "uwatch.maps.json")), 0o644)
		if err := runIn(d, cfg.Clang, "-c", "-x", "assembler", "uwatch_embed.S", "-o", "uwatch_embed.o"); err != nil {
			t.Fatal(err)
		}
	}
	if err := Link(cfg, src, exe); err != nil {
		t.Fatal(err)
	}
	return exe, nil
}

// sb032 は build の誤りが SB032 の 1 つの診断ならその文 (でなければ "")。
func sb032(err error) string {
	var e *frontend.Error
	if errors.As(err, &e) && len(e.Diags) == 1 && e.Diags[0].Code == frontend.SB032UprobeTarget {
		return e.Diags[0].Msg
	}
	return ""
}

// goFixture は Go の関数 main.Greet (noinline) を持つ binary (試験の中で go build — Go の既定の DWARF)。
func goFixture(t *testing.T) string {
	t.Helper()
	d := t.TempDir()
	os.WriteFile(filepath.Join(d, "go.mod"), []byte("module gofix\n\ngo 1.22\n"), 0o644)
	os.WriteFile(filepath.Join(d, "main.go"), []byte(`package main

import (
	"fmt"
	"os"
	"strconv"
)

//go:noinline
func Greet(a, b int64) int64 { return a*3 + b }

func main() {
	n, _ := strconv.Atoi(os.Args[1])
	var s int64
	for i := 0; i < n; i++ {
		s += Greet(int64(i), 7)
	}
	fmt.Println(s)
}
`), 0o644)
	cmd := exec.Command("/usr/local/go/bin/go", "build", "-trimpath", "-o", "gofix", ".")
	cmd.Dir = d
	cmd.Env = append(os.Environ(), "GOFLAGS=-mod=mod", "GOWORK=off")
	if o, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("go build: %v\n%s", err, o)
	}
	return filepath.Join(d, "gofix")
}

// TestUprobeGoTarget は E082 の H1: Go の関数は build の時の照合 (SB032 の uprobearg_abi) と、照合を通さずに作った ELF の load の前の bml の照合
// (uprobearg_abi — TargetRejected) の両方で止まる。
func TestUprobeGoTarget(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	gofix := goFixture(t)
	_, err := uwatchBuild(t, gofix, "target/gofix", "main.Greet", false)
	msg := sb032(err)
	t.Logf("H1 (a) build: %v", err)
	if !strings.Contains(msg, "uprobearg_abi") {
		t.Errorf("H1 (a): want one SB032 naming uprobearg_abi, got %v", err)
	}
	exe, _ := uwatchBuild(t, gofix, "target/gofix", "main.Greet", true)
	out := feed(t, true, "", exe, gofix, "load")
	t.Logf("H1 (b) load:\n%s", out)
	if !strings.Contains(out, "load kind=SpinelBPF::TargetRejected") || !strings.Contains(out, "Go") {
		t.Errorf("H1 (b): want bml's pre-load check to stop the Go function (uprobearg_abi), got\n%s", out)
	}
}

// spinelTarget は Ruby の source を spinel (flags) で build した binary。
func spinelTarget(t *testing.T, rb string, flags ...string) string {
	t.Helper()
	cfg, _ := defaultConfig()
	d := t.TempDir()
	os.WriteFile(filepath.Join(d, "st.rb"), []byte(rb), 0o644)
	cmd := exec.Command(cfg.Spinel, append([]string{"st.rb", "-o", "st"}, flags...)...)
	cmd.Dir = d
	cmd.Env = append(os.Environ(), "TMPDIR="+d)
	if o, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("spinel: %v\n%s", err, o)
	}
	return filepath.Join(d, "st")
}

// spinelSmall は inline される小さな method、spinelRec は inline されない (再帰の) method を持つ Ruby。
const spinelSmall = `def greet(n, m)
  n * 3 + m
end
i = 0
s = 0
while i < ARGV[0].to_i
  s += greet(i, 7)
  i += 1
end
puts s
`

const spinelRec = `def greet(n, m)
  if n <= 0
    return m
  end
  greet(n - 1, m + 1)
end
i = 0
s = 0
while i < ARGV[0].to_i
  s += greet(i, 7)
  i += 1
end
puts s
`

// TestUprobeSpinelTarget は E082 の H2 (観察 — 主張しない): Spinel の build した binary の method の C の関数 (sp_greet) を target にした時の
// build の時の照合の結果と、通れば attach して読める値。
func TestUprobeSpinelTarget(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	for _, c := range []struct {
		name, rb string
		flags    []string
	}{
		{"default", spinelSmall, nil},
		{"g-inlined", spinelSmall, []string{"-g"}},
		{"g-recursive", spinelRec, []string{"-g"}},
	} {
		st := spinelTarget(t, c.rb, c.flags...)
		exe, err := uwatchBuild(t, st, "target/st", "sp_greet", false)
		if err != nil {
			t.Logf("H2 %s: build stops: %v", c.name, err)
			if sb032(err) == "" {
				t.Errorf("H2 %s: a build-time stop other than one SB032: %v", c.name, err)
			}
			continue
		}
		// 照合を通った — attach して target を走らせ、読めた値を観察する
		cmd := sudoCmd(t, exe, st, "watch")
		in, _ := cmd.StdinPipe()
		outp, _ := cmd.StdoutPipe()
		cmd.Stderr = cmd.Stdout
		if err := cmd.Start(); err != nil {
			t.Fatal(err)
		}
		r := bufio.NewReader(outp)
		var lines []string
		for {
			l, err := r.ReadString('\n')
			lines = append(lines, strings.TrimSpace(l))
			if err != nil || strings.HasPrefix(l, "attached") || strings.HasPrefix(l, "load kind=") {
				break
			}
		}
		if strings.HasPrefix(lines[len(lines)-1], "attached") {
			o, err := exec.Command(st, "3").CombinedOutput()
			lines = append(lines, "target: "+strings.TrimSpace(string(o))+" "+errString(err))
			time.Sleep(100 * time.Millisecond)
			in.Write([]byte("\n"))
			rest, _ := r.ReadString('\n')
			lines = append(lines, strings.TrimSpace(rest))
		}
		in.Close()
		cmd.Wait()
		t.Logf("H2 %s: build passed; run:\n%s", c.name, strings.Join(lines, "\n"))
	}
}

func errString(err error) string {
	if err == nil {
		return "rc=0"
	}
	return err.Error()
}

// TestUprobeSelfTarget は E082 の H3: 自分の出力の path を target にした program — placeholder (cfix の写し) の SHA-256 で build し同じ path に link
// した実行 file を /proc/self/exe で load すると binary (sha の食い違い) で TargetRejected (不動点が無い)。
func TestUprobeSelfTarget(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	cfg, _ := defaultConfig()
	d := t.TempDir()
	src := filepath.Join(d, "uwatch.rb")
	os.WriteFile(src, []byte(uwatchSrc("uwatch", "sum_args", "{1 => :i64, 2 => :u32}")), 0o644) // sum_args(int64_t, uint32_t, …) の型 (1 回目は :i64 と書き build の時の照合が uprobearg で止めた — 試験の誤り)
	if _, err := Build(cfg, src); err == nil || !strings.Contains(err.Error(), "SB008") {
		t.Errorf("H3: before the executable exists the build must stop (SB008 — the target file is missing), got %v", err)
	}
	fb, _ := os.ReadFile(cfixPath())
	writeExec(t, filepath.Join(d, "uwatch"), fb) // placeholder
	if _, err := Build(cfg, src); err != nil {
		t.Fatalf("H3: build against the placeholder: %v", err)
	}
	exe := filepath.Join(d, "uwatch")
	if err := Link(cfg, src, exe); err != nil {
		t.Fatal(err)
	}
	out := feed(t, true, "", exe, "/proc/self/exe", "load")
	t.Logf("H3:\n%s", out)
	if !strings.Contains(out, "load kind=SpinelBPF::TargetRejected") || !strings.Contains(out, "but the object was built for") {
		t.Errorf("H3: want a binary (SHA-256) mismatch, got\n%s", out)
	}
}
