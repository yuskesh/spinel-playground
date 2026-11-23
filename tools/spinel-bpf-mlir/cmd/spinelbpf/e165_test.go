package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// fakeSudo は呼ばれた引数を file に残して rc 0 の偽物の sudo (絶対 path)。対照はこれだけを渡す (E165 の条件 3 — 実 sudo に届く経路を作らない)。
func fakeSudo(t *testing.T) (path, argvFile string) {
	t.Helper()
	d := t.TempDir()
	path, argvFile = filepath.Join(d, "fake-sudo"), filepath.Join(d, "argv")
	if err := os.WriteFile(path, []byte("#!/bin/bash\nprintf '%s\\n' \"$@\" > "+argvFile+"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	return path, argvFile
}

func e165Cmdline(t *testing.T, s string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "cmdline")
	if err := os.WriteFile(p, []byte(s), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

// TestRootAllowed は E165 の H6: 印の token が cmdline に完全一致で在るときだけ真。
func TestRootAllowed(t *testing.T) {
	cl := e165Cmdline(t, "console=ttyS0 spinelbpf_vm_mark=abc123 ro\n")
	for _, c := range []struct {
		mark string
		want bool
	}{{"abc123", true}, {"", false}, {"abc", false}, {"abc123 ", false}, {"zzz", false}} {
		if got := rootAllowed(cl, c.mark); got != c.want {
			t.Errorf("mark %q: got %v", c.mark, got)
		}
	}
	if rootAllowed(filepath.Join(t.TempDir(), "absent"), "abc123") {
		t.Error("a missing cmdline must not allow root")
	}
	if rootAllowed(procCmdline, "e165-the-host-has-no-such-mark") {
		t.Error("the host cmdline must not hold a mark")
	}
}

// TestSudoCmdGuestGuard は E165 の H6 と条件 3: 印があれば偽物の sudo に届き (-n 付き)、無ければ sudo を作らずに skip して root_needed に名を残す。実 sudo の path は渡さない。
func TestSudoCmdGuestGuard(t *testing.T) {
	lock := filepath.Join(t.TempDir(), "root.lock")
	if err := os.WriteFile(lock, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("SPINELBPF_ROOT_LOCK", lock)
	tmp := t.TempDir()
	t.Setenv("TMPDIR", tmp) // root_needed の記録を gate の一覧に混ぜない
	fake, argv := fakeSudo(t)
	cl := e165Cmdline(t, "spinelbpf_vm_mark=m1\n")
	t.Run("mark", func(t *testing.T) {
		t.Setenv(vmMarkEnv, "m1")
		o, err := sudoCmdAt(t, fake, cl, "payload", "x y").CombinedOutput()
		if err != nil {
			t.Fatalf("%v\n%s", err, o)
		}
		b, err := os.ReadFile(argv)
		if err != nil || string(b) != "-n\npayload\nx y\n" {
			t.Fatalf("the fake sudo got %q (%v)", b, err)
		}
		t.Logf("reached the fake sudo with %q", b)
	})
	os.Remove(argv)
	reached := false
	t.Run("no-mark", func(t *testing.T) {
		t.Setenv(vmMarkEnv, "other")
		_ = sudoCmdAt(t, fake, cl, "payload")
		reached = true
	})
	if reached {
		t.Fatal("sudoCmdAt returned a command without the guest mark")
	}
	if _, err := os.Stat(argv); err == nil {
		t.Fatal("the fake sudo ran without the guest mark")
	}
	b, err := os.ReadFile(filepath.Join(tmp, "root_needed.txt"))
	if err != nil || strings.TrimSpace(string(b)) != t.Name() {
		t.Fatalf("root_needed: %q %v", b, err)
	}
	t.Logf("skipped and recorded %q", strings.TrimSpace(string(b)))
}

// TestRsudoGuestGuard は E165 の条件 2 と 3: shell の rsudo_at に偽物の sudo と cmdline の file を渡し、印の有無で偽物に届くか rc 126 で止まるかを見る。
func TestRsudoGuestGuard(t *testing.T) {
	lock := filepath.Join(t.TempDir(), "root.lock")
	if err := os.WriteFile(lock, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	fake, argv := fakeSudo(t)
	cl := e165Cmdline(t, "spinelbpf_vm_mark=m2\n")
	run := func(mark string) (string, int) {
		c := exec.Command("bash", "-c", `. scripts/lib/rootlock.sh; rsudo_at "$1" "$2" payload`, "x", fake, cl)
		c.Dir = repoRoot()
		c.Env = append(os.Environ(), "SPINELBPF_ROOT_LOCK="+lock, vmMarkEnv+"="+mark)
		o, err := c.CombinedOutput()
		rc := 0
		if ee, ok := err.(*exec.ExitError); ok {
			rc = ee.ExitCode()
		} else if err != nil {
			t.Fatal(err)
		}
		return string(o), rc
	}
	if o, rc := run("m2"); rc != 0 {
		t.Fatalf("with the mark: rc %d\n%s", rc, o)
	}
	if b, _ := os.ReadFile(argv); string(b) != "-n\npayload\n" {
		t.Fatalf("the fake sudo got %q", b)
	}
	os.Remove(argv)
	o, rc := run("wrong")
	if rc != 126 || !strings.Contains(o, "refusing to run on the host") {
		t.Fatalf("without the mark: want rc 126 and the refusal, got rc %d\n%s", rc, o)
	}
	if _, err := os.Stat(argv); err == nil {
		t.Fatal("the fake sudo ran without the guest mark")
	}
	t.Logf("no mark: rc %d: %s", rc, strings.TrimSpace(o))
}

// TestRootScriptsRefuseHost は E165 の条件 2: root の script (run-*-host.sh・run-*-vm.sh・run-bmlcheck.sh) は印の無い host で rc 126 で止まる
// (対象は git の tracked の全て。非 root で実行するので guard が壊れても root の操作には届かない)。tutorial-run.sh と clone-check.sh の SUDO=1 は rsudo / vm_guest_require を通る形を読みで見る。
func TestRootScriptsRefuseHost(t *testing.T) {
	out, err := exec.Command("git", "-C", repoRoot(), "ls-files", "scripts/run-*-host.sh", "scripts/run-*-vm.sh", "scripts/run-bmlcheck.sh").Output()
	if err != nil {
		t.Fatal(err)
	}
	fs := strings.Fields(string(out))
	if len(fs) < 11 {
		t.Fatalf("want the 11 root scripts, got %v", fs)
	}
	for _, f := range fs {
		c := exec.Command("bash", filepath.Join(repoRoot(), f))
		c.Env = append(os.Environ(), vmMarkEnv+"=", "BIN=/nonexistent/e165")
		o, err := c.CombinedOutput()
		ee, ok := err.(*exec.ExitError)
		if !ok || ee.ExitCode() != 126 || !strings.Contains(string(o), "refusing to run on the host") {
			t.Errorf("%s: want rc 126 and the refusal, got %v\n%s", f, err, o)
		}
	}
	b, err := os.ReadFile(filepath.Join(repoRoot(), "scripts", "tutorial-run.sh"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(b), "vm_guest_require") {
		t.Error("tutorial-run.sh must stop on the host before the clone (vm_guest_require)")
	}
	t.Logf("%d root scripts refuse the host", len(fs))
}

// TestNoOtherSudoPath は E165 の H6: 実 sudo の絶対 path の文字列は sudoCmd の定数と rootlock.sh の rsudo だけ。
func TestNoOtherSudoPath(t *testing.T) {
	// Spinel Extended: bml is a submodule upstream, which git grep does not
	// enter; here it is imported as source, so its tree is left out by path.
	out, err := exec.Command("git", "-C", repoRoot(), "grep", "-l", "/usr/bin/sudo", "--", "*.go", "*.sh", ":!third_party/bpf-mlir-loader").Output()
	if err != nil {
		t.Fatal(err)
	}
	got := strings.Join(strings.Fields(string(out)), " ")
	want := "cmd/spinelbpf/e165_test.go cmd/spinelbpf/rootlock_test.go scripts/gate-vm-guest.sh scripts/lib/rootlock.sh"
	if got != want {
		t.Errorf("files naming the real sudo:\n got %s\nwant %s", got, want)
	}
}

// e165Script は scripts/ の script を bash で走らせ、合わせた出力と rc を返す (非 root の seam — BPF にも kernel にも触れない)。
func e165Script(t *testing.T, env []string, script string, args ...string) (string, int) {
	t.Helper()
	cmd := exec.Command("bash", append([]string{filepath.Join("..", "..", "scripts", script)}, args...)...)
	cmd.Env = append(os.Environ(), env...)
	o, err := cmd.CombinedOutput()
	if err == nil {
		return string(o), 0
	}
	ee, ok := err.(*exec.ExitError)
	if !ok {
		t.Fatalf("%s: %v\n%s", script, err, o)
	}
	return string(o), ee.ExitCode()
}

// TestGuestScriptGatesBeforeSideEffects is the bpf-mlir reviewer's groups 1 and 2: the guest script checks the mode and the record ID first, stops at the uid gate on the host, and writes nothing to the output dir before the gate.
func TestGuestScriptGatesBeforeSideEffects(t *testing.T) {
	if os.Getuid() == 0 {
		t.Fatal("this seam expects a non-root host")
	}
	for _, c := range []struct {
		name, mode, record, want string
	}{
		{"formal_empty", "formal", "", "VERIFIED_RECORD が無いか不正"},
		{"formal_bad", "formal", "e165;x", "VERIFIED_RECORD が無いか不正"},
		{"formal_ok_reaches_uid", "formal", "E165", "root で"},
		{"recon_with_record", "recon", "E165", "recon に VERIFIED_RECORD は渡さない"},
		{"recon_reaches_uid", "recon", "", "root で"},
		{"bad_mode", "pin", "", "mode: pin"},
	} {
		t.Run(c.name, func(t *testing.T) {
			out := t.TempDir()
			env := filepath.Join(out, "guest-env")
			if err := os.Mkdir(env, 0o755); err != nil {
				t.Fatal(err)
			}
			o, rc := e165Script(t, nil, "gate-vm-guest.sh", out, "m1", "not-the-boot-id", c.mode, c.record)
			t.Logf("rc %d: %s", rc, strings.TrimSpace(o))
			if rc != 2 || !strings.Contains(o, c.want) {
				t.Fatalf("want rc 2 and %q, got rc %d: %s", c.want, rc, o)
			}
			ents, err := os.ReadDir(env)
			if err != nil || len(ents) != 0 {
				t.Fatalf("the guest-env dir must stay empty before the gates: %v %v", ents, err)
			}
		})
	}
}

// TestGateVMFormalRecord is the host side of the bpf-mlir reviewer's group 2: an empty or bad formal record ID stops before anything else, and a correct ID goes on to the pin check (the pin is a missing path — boot is never reached).
func TestGateVMFormalRecord(t *testing.T) {
	d := t.TempDir()
	pin, out := filepath.Join(d, "absent.pin"), filepath.Join(d, "out")
	for _, c := range []struct {
		name, record string
		bad          bool
	}{{"empty", "", true}, {"bad", "165", true}, {"ok", "E165", false}} {
		t.Run(c.name, func(t *testing.T) {
			o, rc := e165Script(t, []string{"SPINELBPF_VM_FORMAL=1", "VERIFIED_RECORD=" + c.record}, "gate-vm.sh", "formal", pin, out)
			t.Logf("rc %d: %s", rc, strings.TrimSpace(o))
			if rc != 2 || strings.Contains(o, "VERIFIED_RECORD") != c.bad {
				t.Fatalf("rc %d: %s", rc, o)
			}
			if _, err := os.Stat(out); !os.IsNotExist(err) {
				t.Fatalf("the output dir must not be created: %v", err)
			}
		})
	}
}

// e165Ev は go test -json の 1 行。name が空なら package の行。
func e165Ev(action, name string) string {
	if name == "" {
		return `{"Action":"` + action + `"}`
	}
	return `{"Action":"` + action + `","Test":"` + name + `"}`
}

// TestGateVMJudge is the bpf-mlir reviewer's group 3: positive and negative cases of judging the guest's JSON (synthetic JSON — the positive from real raw output is recorded under recon6).
func TestGateVMJudge(t *testing.T) {
	ok := func(names ...string) []string {
		var l []string
		for _, n := range names {
			l = append(l, e165Ev("run", n), e165Ev("pass", n))
		}
		return append(l, e165Ev("pass", ""))
	}
	replace := func(l []string, from, to string) []string {
		var r []string
		for _, s := range l {
			if s == from {
				s = to
			}
			if s != "" {
				r = append(r, s)
			}
		}
		return r
	}
	plainOK, mutOK := ok("TestA", "TestA/s", "TestB"), ok("TestHookC")
	skipA := e165Ev("skip", "TestA/allowed")
	for _, c := range []struct {
		name       string
		plain, mut []string
		want       string // 空なら rc 0
	}{
		{"ok", plainOK, mutOK, ""},
		{"allowed_subtest_skip", append([]string{e165Ev("run", "TestA/allowed"), skipA}, plainOK...), mutOK, ""},
		{"duplicate_terminal", append([]string{e165Ev("pass", "TestB")}, plainOK...), mutOK, "terminal 2 回"},
		{"duplicate_run", append([]string{e165Ev("run", "TestB")}, plainOK...), mutOK, "run 2 回"},
		{"no_terminal", replace(plainOK, e165Ev("pass", "TestB"), ""), mutOK, "terminal 0 回"},
		{"foreign", append([]string{e165Ev("run", "TestZ"), e165Ev("pass", "TestZ")}, plainOK...), mutOK, "foreign の試験: TestZ"},
		{"foreign_subtest", append([]string{e165Ev("run", "TestZ/s"), e165Ev("pass", "TestZ/s")}, plainOK...), mutOK, "foreign の試験: TestZ/s"},
		{"wrong_binary", ok("TestA", "TestA/s", "TestB", "TestHookC"), mutOK, "foreign の試験: TestHookC"},
		{"missing", ok("TestA", "TestA/s"), mutOK, "missing: TestB"},
		{"top_fail", replace(plainOK, e165Ev("pass", "TestB"), e165Ev("fail", "TestB")), mutOK, "TestB: fail"},
		{"sub_fail", replace(plainOK, e165Ev("pass", "TestA/s"), e165Ev("fail", "TestA/s")), mutOK, "TestA/s: fail"},
		{"unallowed_skip", replace(plainOK, e165Ev("pass", "TestA/s"), e165Ev("skip", "TestA/s")), mutOK, "許可の外の skip: TestA/s"},
		{"top_skip", replace(plainOK, e165Ev("pass", "TestB"), e165Ev("skip", "TestB")), mutOK, "top-level の skip: TestB"},
		{"no_package_pass", replace(plainOK, e165Ev("pass", ""), ""), mutOK, "package の完了"},
		{"package_fail", replace(plainOK, e165Ev("pass", ""), e165Ev("fail", "")), mutOK, "package の完了"},
		{"mut_package_missing", plainOK, replace(mutOK, e165Ev("pass", ""), ""), "mut: package の完了"},
		{"malformed", append([]string{"{not json"}, plainOK...), mutOK, "JSON を読めない"},
		{"absent_json", nil, mutOK, "plain: JSON が無い"},
	} {
		t.Run(c.name, func(t *testing.T) {
			d := t.TempDir()
			if err := os.Mkdir(filepath.Join(d, "host"), 0o755); err != nil {
				t.Fatal(err)
			}
			if c.plain != nil {
				if err := os.WriteFile(filepath.Join(d, "host", "plain.json"), []byte(strings.Join(c.plain, "\n")+"\n"), 0o644); err != nil {
					t.Fatal(err)
				}
			}
			if err := os.WriteFile(filepath.Join(d, "host", "mut.json"), []byte(strings.Join(c.mut, "\n")+"\n"), 0o644); err != nil {
				t.Fatal(err)
			}
			list, skips := filepath.Join(d, "tests"), filepath.Join(d, "skips")
			if err := os.WriteFile(list, []byte("TestA\nTestB\nTestHookC\n"), 0o644); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(skips, []byte("# comment\nTestA/allowed\treason\n"), 0o644); err != nil {
				t.Fatal(err)
			}
			o, rc := e165Script(t, nil, "gate-vm-judge.sh", d, list, skips)
			t.Logf("rc %d: %s", rc, strings.TrimSpace(o))
			if c.want == "" {
				if rc != 0 {
					t.Fatalf("want a pass, got rc %d: %s", rc, o)
				}
				return
			}
			if rc != 1 || !strings.Contains(o, c.want) {
				t.Fatalf("want rc 1 and %q, got rc %d: %s", c.want, rc, o)
			}
		})
	}
}

// TestVerifiedRecordAllowedRootTests は E166 の事後の直し: host の off の形 (記録の先 out が無い) では root の試験の一覧の試験の鍵を記録しない。子の t.Run が sudoCmd で skip しても親が通る 4 試験を名指し、実の root_tests.txt で見る。
func TestVerifiedRecordAllowedRootTests(t *testing.T) {
	roots := filepath.Join("testdata", "root_tests.txt")
	for _, name := range []string{"TestLoopMutations", "TestRecordArrayMutations", "TestTableDifferential", "TestTextMutations", "TestTableDifferential/t_i32"} {
		got := verifiedRecordAllowed(name, "", roots)
		t.Logf("%s on the host: allowed = %v", name, got)
		if got {
			t.Errorf("%s: a root test must not be recorded without the guest record path", name)
		}
		if !verifiedRecordAllowed(name, "/guest/verified_guest.tsv", roots) {
			t.Errorf("%s: the guest formal run must be able to record", name)
		}
	}
	if !verifiedRecordAllowed("TestVerifiedKeyClosure", "", roots) {
		t.Error("a test outside the root list must stay recordable")
	}
	if verifiedRecordAllowed("TestVerifiedKeyClosure", "", filepath.Join(t.TempDir(), "absent")) {
		t.Error("an unreadable root list must not allow recording")
	}
}
