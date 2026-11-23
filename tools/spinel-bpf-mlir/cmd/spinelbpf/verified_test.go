package main

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// E046 (P011): kernel で走らせ直す固定の事実の試験 (差動の表・変異の対照・hook の変異・veth) を、静的な入力の鍵 (sha256) が
// testdata/verified.tsv に在れば skip する。鍵は生成物の決定因の全て — frontend と build の Go の source・library の Ruby・
// 試験の source の閉包と testdata / 例 / scripts・toolchain の実体 (spinel・libspinel_rt.a・ebpf-compile・ebpf-schema-check・bml の archive)・
// gcc / clang / go の版・uname -r・nproc。
//
//	SPINELBPF_VERIFIED=off      全てを走らせる (E047 の対照・定期の全ての run)
//	VERIFIED_RECORD=E<n>        通った試験の行を verified.tsv に足す (gate は書かない)
//
// 鍵が無くて走った試験は build/tmp/unverified.txt に名指し (gate が最後に一覧する — 走ったことは失敗でない)。
//
// 試験の source の項は、試験の関数から参照の閉包 (package の top-level の func・method・type・var・const — build tag を問わず全ての file) を
// go/parser で辿って決める (手の依存の一覧は漏れると古い skip になる)。testdata と例は閉包の中の文字列の literal が
// cmd/spinelbpf/testdata・internal/frontend/testdata・examples の dir か file の名前に一致するもの、scripts は literal が .sh で終われば scripts/ の全て (source し合う)。

const verifiedTSV = "testdata/verified.tsv"

func shaFile(p string) (string, error) {
	b, err := os.ReadFile(p)
	if err != nil {
		return "", err
	}
	s := sha256.Sum256(b)
	return hex.EncodeToString(s[:]), nil
}

// shaTree は root の下の file (pred が真のもの) の path と sha を並べる (sort 済み)。
func shaTree(root string, pred func(string) bool) ([]string, error) {
	var out []string
	err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() || !pred(p) {
			return nil
		}
		h, err := shaFile(p)
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(repoRoot(), p)
		out = append(out, rel+" "+h)
		return nil
	})
	sort.Strings(out)
	return out, err
}

func firstLine(name string, args ...string) string {
	o, err := exec.Command(name, args...).CombinedOutput()
	if err != nil {
		return fmt.Sprintf("%s: error %v", name, err)
	}
	return strings.SplitN(strings.TrimSpace(string(o)), "\n", 2)[0]
}

var (
	envKeyOnce sync.Once
	envKeyVal  []string
	envKeyErr  error
)

// envKey は全ての対象の試験に共通の鍵の項 (1 つの試験の process で 1 回)。
func envKey() ([]string, error) {
	envKeyOnce.Do(func() {
		cfg, err := defaultConfig()
		if err != nil {
			envKeyErr = err
			return
		}
		r := cfg.Repo
		n, _ := os.ReadFile("/proc/sys/kernel/osrelease")
		k := []string{
			"uname -r " + strings.TrimSpace(string(n)),
			"nproc " + firstLine("nproc"),
			"gcc " + firstLine("gcc", "--version"),
			"clang " + firstLine(cfg.Clang, "--version"),
			"go " + firstLine(cfg.Go, "version"),
		}
		// Spinel の submodule の commit (index の gitlink — E048 の P2: Spinel の内部の関数 sp_Thread_current の性質に頼る試験のため) と threaded の runtime
		if o, err := exec.Command("git", "-C", r, "ls-files", "-s", "third_party/spinel").Output(); err == nil {
			k = append(k, "spinel gitlink "+strings.TrimSpace(string(o)))
		} else {
			envKeyErr = err
			return
		}
		bins := []string{cfg.Spinel, filepath.Join(r, "third_party", "spinel", "lib", "libspinel_rt.a"), filepath.Join(r, "third_party", "spinel", "lib", "libspinel_rt_mt.a"), cfg.EbpfCompile, cfg.SchemaCheck}
		for _, a := range bmlArchives {
			bins = append(bins, filepath.Join(cfg.LoaderLibs, a))
		}
		for _, b := range bins {
			h, err := shaFile(b)
			if err != nil {
				envKeyErr = err
				return
			}
			rel, _ := filepath.Rel(r, b)
			k = append(k, rel+" "+h)
		}
		goSrc := func(p string) bool { return strings.HasSuffix(p, ".go") && !strings.HasSuffix(p, "_test.go") }
		for _, t := range []struct {
			dir  string
			pred func(string) bool
		}{
			{filepath.Join(r, "internal", "frontend"), func(p string) bool { return goSrc(p) && !strings.Contains(p, "/testdata/") }},
			{filepath.Join(r, "cmd", "spinelbpf"), func(p string) bool { return goSrc(p) && !strings.Contains(p, "/testdata/") }},
			{filepath.Join(r, "ruby", "lib"), func(p string) bool { return strings.HasSuffix(p, ".rb") }},
		} {
			l, err := shaTree(t.dir, t.pred)
			if err != nil {
				envKeyErr = err
				return
			}
			k = append(k, l...)
		}
		envKeyVal = k
	})
	return envKeyVal, envKeyErr
}

// declRef は top-level の宣言と、それを持つ file。
type declRef struct {
	file string
	node ast.Node
}

var (
	pkgOnce  sync.Once
	pkgDecls map[string][]declRef
	pkgErr   error
)

// loadPkgDecls は cmd/spinelbpf の全ての Go の file (build tag を問わず) の top-level の名前 → 宣言 (method は receiver の型の名前に)。
func loadPkgDecls() (map[string][]declRef, error) {
	pkgOnce.Do(func() {
		dir := filepath.Join(repoRoot(), "cmd", "spinelbpf")
		ents, err := os.ReadDir(dir)
		if err != nil {
			pkgErr = err
			return
		}
		pkgDecls = map[string][]declRef{}
		fset := token.NewFileSet()
		for _, e := range ents {
			if !strings.HasSuffix(e.Name(), ".go") {
				continue
			}
			af, err := parser.ParseFile(fset, filepath.Join(dir, e.Name()), nil, 0)
			if err != nil {
				pkgErr = err
				return
			}
			add := func(name string, n ast.Node) { pkgDecls[name] = append(pkgDecls[name], declRef{e.Name(), n}) }
			for _, d := range af.Decls {
				switch d := d.(type) {
				case *ast.FuncDecl:
					if d.Recv == nil {
						add(d.Name.Name, d)
					} else if rt := recvName(d.Recv); rt != "" {
						add(rt, d)
					}
				case *ast.GenDecl:
					for _, sp := range d.Specs {
						switch sp := sp.(type) {
						case *ast.TypeSpec:
							add(sp.Name.Name, sp)
						case *ast.ValueSpec:
							for _, n := range sp.Names {
								add(n.Name, sp)
							}
						}
					}
				}
			}
		}
	})
	return pkgDecls, pkgErr
}

func recvName(fl *ast.FieldList) string {
	if fl == nil || len(fl.List) == 0 {
		return ""
	}
	x := fl.List[0].Type
	if st, ok := x.(*ast.StarExpr); ok {
		x = st.X
	}
	if id, ok := x.(*ast.Ident); ok {
		return id.Name
	}
	return ""
}

// closureOf は試験の関数から辿れる top-level の宣言の file の集合と、その中の文字列の literal。
func closureOf(test string) (map[string]bool, map[string]bool, error) {
	decls, err := loadPkgDecls()
	if err != nil {
		return nil, nil, err
	}
	if len(decls[test]) == 0 {
		return nil, nil, fmt.Errorf("no declaration of %s in cmd/spinelbpf", test)
	}
	files, lits, seen := map[string]bool{}, map[string]bool{}, map[string]bool{}
	queue := []string{test}
	for len(queue) > 0 {
		n := queue[0]
		queue = queue[1:]
		if seen[n] {
			continue
		}
		seen[n] = true
		for _, d := range decls[n] {
			files[d.file] = true
			ast.Inspect(d.node, func(x ast.Node) bool {
				switch x := x.(type) {
				case *ast.Ident:
					if _, ok := decls[x.Name]; ok && !seen[x.Name] {
						queue = append(queue, x.Name)
					}
				case *ast.BasicLit:
					if x.Kind == token.STRING {
						if v, err := strconv.Unquote(x.Value); err == nil {
							lits[v] = true
						}
					}
				}
				return true
			})
		}
	}
	return files, lits, nil
}

// verifiedKey は試験の鍵 (共通の項・試験の名前・閉包の file・閉包の literal が指す testdata / 例 / scripts) と項の列。
func verifiedKey(test string) (string, []string, error) {
	k, err := envKey()
	if err != nil {
		return "", nil, err
	}
	files, lits, err := closureOf(test)
	if err != nil {
		return "", nil, err
	}
	files["verified_test.go"] = true
	r := repoRoot()
	base := filepath.Join(r, "cmd", "spinelbpf")
	items := append([]string{"test " + test}, k...)
	var fl []string
	for f := range files {
		fl = append(fl, f)
	}
	sort.Strings(fl)
	for _, f := range fl {
		h, err := shaFile(filepath.Join(base, f))
		if err != nil {
			return "", nil, err
		}
		items = append(items, "cmd/spinelbpf/"+f+" "+h)
	}
	var paths []string
	scripts := false
	for l := range lits {
		if strings.HasSuffix(l, ".sh") {
			scripts = true
		}
		if l == "" || l == "." || l == ".." || strings.Contains(l, "\n") {
			continue
		}
		if strings.Contains(l, "/") {
			// P027 E134: examples の下の相対の dir (`bcc/<tool>`) — tool の dir だけを鍵に (examples/bcc の tree の全てにしない)
			// clean な相対の path だけ (E136 — `"./"` 等は Clean で形が変わるので受けない — E134 の受けは examples の全てに解いた)
			if filepath.Clean(l) == l && !strings.HasPrefix(l, "/") && !strings.HasPrefix(l, ".") && !strings.Contains(l, "..") {
				if fi, err := os.Stat(filepath.Join(r, "examples", l)); err == nil && fi.IsDir() {
					paths = append(paths, filepath.Join(r, "examples", l))
				}
			}
			continue
		}
		for _, d := range []string{filepath.Join(base, "testdata"), filepath.Join(r, "internal", "frontend", "testdata"), filepath.Join(r, "examples")} {
			if _, err := os.Stat(filepath.Join(d, l)); err == nil {
				paths = append(paths, filepath.Join(d, l))
			}
		}
	}
	if scripts {
		paths = append(paths, filepath.Join(r, "scripts"))
	}
	sort.Strings(paths)
	for _, p := range paths {
		// 例の dir の untracked の build の産物 (実行 file) は鍵に入れない — tracked の file だけ
		l, err := trackedTree(p)
		if err != nil {
			return "", nil, err
		}
		items = append(items, l...)
	}
	s := sha256.Sum256([]byte(strings.Join(items, "\n")))
	return hex.EncodeToString(s[:]), items, nil
}

// trackedTree は p (file か dir) の下の git の index に在る file の path と sha (verified.tsv 自身は除く — 記録で鍵が変わらないように)。
// untracked の新しい testdata は鍵に入らない — gate の前に git add -N (CLAUDE.md の規約)。
func trackedTree(p string) ([]string, error) {
	r := repoRoot()
	rel, _ := filepath.Rel(r, p)
	o, err := exec.Command("git", "-C", r, "ls-files", "-z", "--", rel).Output()
	if err != nil {
		return nil, err
	}
	var out []string
	for _, f := range strings.Split(string(o), "\x00") {
		if f == "" || strings.HasSuffix(f, "verified.tsv") {
			continue
		}
		h, err := shaFile(filepath.Join(r, f))
		if err != nil {
			return nil, err
		}
		out = append(out, f+" "+h)
	}
	sort.Strings(out)
	return out, nil
}

// readVerified は verified.tsv の鍵 → 実験の番号。
func readVerified() map[string]string {
	m := map[string]string{}
	f, err := os.Open(filepath.Join(repoRoot(), "cmd", "spinelbpf", verifiedTSV))
	if err != nil {
		return m
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		fs := strings.Split(sc.Text(), "\t")
		if len(fs) >= 3 && !strings.HasPrefix(fs[0], "#") {
			m[fs[0]] = fs[2]
		}
	}
	return m
}

var verifiedMu sync.Mutex

// verifiedRecordAllowed は試験 name の鍵を記録してよいか: root の試験の一覧 (rootsPath) に在る試験は、guest の正式の run (記録の先 out が在る) でだけ。
// out が在れば一覧は読まずに許す。out の無い host の側で一覧を読めないときは記録しない (fail closed)。
func verifiedRecordAllowed(name, out, rootsPath string) bool {
	if out != "" {
		return true
	}
	b, err := os.ReadFile(rootsPath)
	if err != nil {
		return false
	}
	top := strings.SplitN(name, "/", 2)[0]
	for _, l := range strings.Fields(string(b)) {
		if l == top {
			return false
		}
	}
	return true
}

// requireUnverified は対象の試験の頭で呼ぶ: 鍵が verified.tsv に在れば skip、無ければ走らせ、通れば記録か unverified の一覧へ。
// root の skip (SPINELBPF_NO_ROOT) は各試験の今までの所 (sudo の helper) のまま — 鍵の skip は `verified <key>` の文で区別できる。
func requireUnverified(t *testing.T) {
	t.Helper()
	key, items, err := verifiedKey(t.Name())
	if err != nil {
		t.Fatalf("verified key: %v", err)
	}
	e, known := readVerified()[key]
	if known && os.Getenv("SPINELBPF_VERIFIED") != "off" {
		t.Skipf("verified %s (%s) — SPINELBPF_VERIFIED=off runs it", key[:12], e)
	}
	if os.Getenv("SPINELBPF_VERIFIED_ITEMS") == "1" {
		t.Logf("verified key items:\n%s", strings.Join(items, "\n"))
	}
	if known {
		t.Logf("verified key %s (%s) — running because SPINELBPF_VERIFIED=off", key[:12], e)
	} else {
		t.Logf("verified key %s (%d items) is not in %s — running", key[:12], len(items), verifiedTSV)
	}
	t.Cleanup(func() {
		if t.Failed() || t.Skipped() {
			return
		}
		// E166: root の試験の一覧の試験は、root の部分を子の t.Run で持つと host では親が通ってしまう — guest の正式の run の外では鍵を書かない
		if !known && !verifiedRecordAllowed(t.Name(), os.Getenv("SPINELBPF_VERIFIED_OUT"), filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "root_tests.txt")) {
			return
		}
		verifiedMu.Lock()
		defer verifiedMu.Unlock()
		if e := os.Getenv("VERIFIED_RECORD"); e != "" {
			if known { // 既に在る鍵は書かない (E057 — E054 の off の記録で重なった)
				return
			}
			p := filepath.Join(repoRoot(), "cmd", "spinelbpf", verifiedTSV)
			if o := os.Getenv("SPINELBPF_VERIFIED_OUT"); o != "" { // E165: repo が ro の VM の guest — host が boot の後に検証して足す
				p = o
			}
			f, err := os.OpenFile(p, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
			if err != nil {
				t.Errorf("recording: %v", err)
				return
			}
			defer f.Close()
			fmt.Fprintf(f, "%s\t%s\t%s\t%s\n", key, t.Name(), e, time.Now().Format("2006-01-02"))
			return
		}
		// 鍵が verified に在るのに走った (SPINELBPF_VERIFIED=off) 試験は別の一覧に — unverified と混ぜない (E047 で見つけ E045 で直した)
		list := "unverified.txt"
		if known {
			list = "verified_off.txt"
		}
		f, err := os.OpenFile(filepath.Join(repoRoot(), "build", "tmp", list), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
		if err == nil {
			fmt.Fprintf(f, "%s %s\n", t.Name(), key[:12])
			f.Close()
		}
	})
}

// parallel は独占の要らない試験を並行に (P018 E075 — t.Parallel の helper)。独占の試験 (veth・Thread・多 CPU・global な tracing の attach・
// t.Setenv — docs/experiments/results/E075/exclusive.tsv) は呼ばない — Go は並行でない最上位の試験を先に直列に走らせ、並行の試験は後でまとめる。
// 並行の度合いは gate の `-parallel ${GATE_JOBS}`。
func parallel(t *testing.T) {
	t.Helper()
	t.Parallel()
}

// writeExec は実行する file を書く (P018 E075): この process で書く fd は並行の試験の fork が exec までの間
// 持ち、その間の exec が ETXTBSY (text file busy) で落ちる — 実行の file は子の process (install) に書かせる。
func writeExec(t *testing.T, p string, data []byte) {
	t.Helper()
	src := p + ".src"
	if err := os.WriteFile(src, data, 0o644); err != nil {
		t.Fatal(err)
	}
	if out, err := exec.Command("install", "-m", "0755", src, p).CombinedOutput(); err != nil {
		t.Fatalf("install %s: %v\n%s", p, err, out)
	}
	os.Remove(src)
}
