package frontend

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// Spinel の実行。解析用の directory に利用者の file と同じ basename で source を置き、その directory を cwd にして走らせる
// (types JSON と AST の file の名前が利用者の file の basename になる — E002 の着手前の変更)。
// `--dump-ast` は AST を出して終わり JSON を書かない (E002 の H1) ので、同じ入力に 2 回走らせる。

// Spinel は Spinel の呼び方。
type Spinel struct {
	Bin    string // spinel の実行 file (絶対の path)
	LibDir string // ruby/lib (絶対の path — `require "bpf"` の解決と、呼び先の file の照合に使う)
}

// Analysis は 1 つの入力の解析の結果。
type Analysis struct {
	Dir   string
	AST   *AST
	Types *Types
}

func (s Spinel) run(dir string, args ...string) (stdout, stderr []byte, err error) {
	tmp := filepath.Join(dir, "tmp")
	if err := os.MkdirAll(tmp, 0o755); err != nil {
		return nil, nil, err
	}
	cmd := exec.Command(s.Bin, append([]string{"-I", s.LibDir}, args...)...)
	cmd.Dir = dir
	// TMPDIR は絶対の path (相対だと Spinel の --rbs の seed が黙って落ちる等 — upstream_suspects S3)
	cmd.Env = append(os.Environ(), "TMPDIR="+tmp)
	var o, e bytes.Buffer
	cmd.Stdout, cmd.Stderr = &o, &e
	err = cmd.Run()
	return o.Bytes(), e.Bytes(), err
}

// Analyze は dir に base の名前で text を書き、AST と types を取る。Spinel が拒否したら (JSON の error の診断か rc ≠ 0) SB000 の Diag を返す。
func (s Spinel) Analyze(dir, base, text string) (*Analysis, Diags, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, nil, err
	}
	if err := os.WriteFile(filepath.Join(dir, base), []byte(text), 0o644); err != nil {
		return nil, nil, err
	}
	astOut, astErr, err := s.run(dir, "--dump-ast", "--emit-types", base)
	if err != nil {
		return nil, Diags{{Verdict: Rejected, Code: SB000Spinel, Pos: Pos{File: base}, Msg: "spinel --dump-ast failed: " + firstLines(astErr, 5)}}, nil
	}
	jsonPath := filepath.Join(dir, "types.json")
	_ = os.Remove(jsonPath)
	_, tyErr, runErr := s.run(dir, "--emit-types", base, "-o", jsonPath)
	data, rerr := os.ReadFile(jsonPath)
	if rerr != nil {
		return nil, Diags{{Verdict: Rejected, Code: SB000Spinel, Pos: Pos{File: base}, Msg: "spinel --emit-types wrote no JSON: " + firstLines(tyErr, 5)}}, nil
	}
	a, err := ParseAST(string(astOut))
	if err != nil {
		return nil, nil, err
	}
	t, err := ParseTypes(data)
	if err != nil {
		return nil, nil, err
	}
	var ds Diags
	for _, e := range t.Errors() {
		ds = append(ds, Diag{Verdict: Rejected, Code: SB000Spinel, Pos: Pos{File: e.File, Line: e.Line, Col: e.Col + 1}, Msg: "spinel refused the program: " + e.Message})
	}
	if runErr != nil && len(ds) == 0 {
		ds = append(ds, Diag{Verdict: Rejected, Code: SB000Spinel, Pos: Pos{File: base}, Msg: "spinel --emit-types failed: " + firstLines(tyErr, 5)})
	}
	return &Analysis{Dir: dir, AST: a, Types: t}, ds, nil
}

// UsesThreads は Spinel 自身の判定で program が Thread 系 (-DSP_THREADS の runtime) を使うかを返す (P001 §3.7)。
func (s Spinel) UsesThreads(dir, base string) (bool, error) {
	out, errb, err := s.run(dir, "--print-build", base)
	if err != nil {
		return false, fmt.Errorf("spinel --print-build failed: %s", firstLines(errb, 5))
	}
	for _, l := range strings.Split(string(out), "\n") {
		if strings.TrimSpace(l) == "define -DSP_THREADS" {
			return true, nil
		}
	}
	return false, nil
}

// Version は spinel --version の 1 行。
func (s Spinel) Version() (string, error) {
	out, err := exec.Command(s.Bin, "--version").Output()
	return strings.TrimSpace(string(out)), err
}

func firstLines(b []byte, n int) string {
	ls := strings.Split(strings.TrimSpace(string(b)), "\n")
	if len(ls) > n {
		ls = ls[:n]
	}
	return strings.Join(ls, " | ")
}
