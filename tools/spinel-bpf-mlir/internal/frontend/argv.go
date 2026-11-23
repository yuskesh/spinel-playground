package frontend

import (
	"fmt"
	"strings"
)

// argv (P028 E151 — bpf-mlir E548): `params: {n => :user_str_array}` (ksyscall) / `fields: {f: [off, :user_str_array]}` (tracepoint) と
// `_ = R.output_argv(S.new(…), :arg, ctx.argv_arg(n) | ctx.argv_field(:f), :status, :index)` — 文 1 つが argv の slot 0..19 ごとに ring の event を
// 1 つ出す (present が偽の slot で止まる)。bpf-mlir の `ebpf.user.str_at` は index が属性の 0..19 の定数だけで ebpf.loop の中を拒否するので、
// lower は ebpf.loop を使わず argv20.mlir の形 — str_at [k+1] を present [k] の ebpf.if の中に置く 20 段の straight-line の入れ子 — に展開する
// (present の順を書き手に預けない)。20 の event は「argv がちょうど 20」と「21 以上 (先頭 20 で打ち切り)」を区別できない。

// argvSlots は str_at の slot の数 (bpf-mlir の上限 — 属性の 0..19)。
const argvSlots = 20

// outputArgvShape は output_argv の形の文 (誤りの文の直し方)。
func outputArgvShape(r *RingDecl, src string) string {
	return fmt.Sprintf("`_ = %s.output_argv(%s.new(…), :<u8 array member>, %s, :<i64 status member>, :<u32 index member>)`", r.Const, r.Record.Const, src)
}

// outputArgv は `R.output_argv(S.new(…), :arg, <argv>, :status, :index)` の検査 — Stmt "ostr" (Argv)。結果の束縛は outputStrCheck が SB025。
func (c *progCtx) outputArgv(call *Node, name, refVar string) (Stmt, bool) {
	r := c.ringOf(c.a.ref(call, "receiver"))
	src := map[string]string{"ksyscall": "ctx.argv_arg(n)", "tracepoint": "ctx.argv_field(:f)"}[c.prog.Kind]
	if src == "" {
		c.add(Rejected, SB028TracingKind, call, "`%s.output_argv` reads an argv array (`ctx.argv_arg(n)` in a ksyscall program, `ctx.argv_field(:f)` in a tracepoint program) — a %s program has none", r.Const, c.prog.Kind)
		return Stmt{}, false
	}
	callee, ok := c.callee(call)
	if !ok {
		return Stmt{}, false
	}
	if callee != "RingBuf#output_argv" {
		c.add(Rejected, SB011ShadowedName, call, "`output_argv` resolves to %s, not BPF::RingBuf#output_argv", callee)
		return Stmt{}, false
	}
	as := args(c.a, call)
	if len(as) != 5 {
		c.add(Rejected, SB024RecordShape, call, "output_argv takes five arguments — %s", outputArgvShape(r, src))
		return Stmt{}, false
	}
	member := func(x *Node) *RecordField {
		if x == nil || x.Type != "SymbolNode" {
			return nil
		}
		for i := range r.Record.Fields {
			if r.Record.Fields[i].Name == x.Str["value"] {
				return &r.Record.Fields[i]
			}
		}
		return nil
	}
	f, st, ix := member(as[1]), member(as[3]), member(as[4])
	if f == nil || f.Count == 0 || f.Bits != 8 || f.Signed {
		c.add(Rejected, SB024RecordShape, as[1], "the string member of output_argv must be a :u8 array member of %s (`arg: [:u8, 64]`)", r.Record.Const)
		return Stmt{}, false
	}
	if st == nil || st.Count != 0 || st.Bits != 64 || !st.Signed {
		c.add(Rejected, SB024RecordShape, as[3], "the status member of output_argv must be an :i64 member of %s (the raw status of probe_read_user_str)", r.Record.Const)
		return Stmt{}, false
	}
	if ix == nil || ix.Count != 0 || ix.Bits != 32 || ix.Signed {
		c.add(Rejected, SB024RecordShape, as[4], "the index member of output_argv must be a :u32 member of %s (the argv slot 0..19)", r.Record.Const)
		return Stmt{}, false
	}
	os, ok := c.outputStrMake(call, as[:4], r, "output_argv", f, st, name, refVar)
	if !ok {
		return Stmt{}, false
	}
	os.Argv, os.Index = true, ix
	sa := as[2]
	if sa.Type != "CallNode" || !c.isVarRead(c.a.ref(sa, "receiver"), c.param) || (c.prog.Kind == "ksyscall" && sa.Str["name"] != "argv_arg") || (c.prog.Kind == "tracepoint" && sa.Str["name"] != "argv_field") {
		c.add(Rejected, SB028TracingKind, sa, "the third argument of output_argv is `%s` itself (an argv array is not a value on the eBPF side — not through a local)", strings.Replace(src, "ctx", c.param, 1))
		return Stmt{}, false
	}
	want := ctxClass[c.prog.Kind] + "#" + sa.Str["name"]
	if cs, ok := c.callee(sa); !ok || cs != want {
		if ok {
			c.add(Rejected, SB011ShadowedName, sa, "`%s` resolves to %s, not BPF::%s", sa.Str["name"], cs, want)
		}
		return Stmt{}, false
	}
	sas := args(c.a, sa)
	if c.prog.Kind == "ksyscall" {
		kp := c.uprobeParam(sa, sas)
		if kp == nil {
			return Stmt{}, false
		}
		if kp.Type != "user_str_array" {
			c.add(Rejected, SB028TracingKind, sa, "`%s.argv_arg(%d)`: parameter %d is declared :%s, not :user_str_array", c.param, kp.N, kp.N, kp.Type)
			return Stmt{}, false
		}
		os.Len = int64(kp.N)
		return os, true
	}
	if len(sas) != 1 || sas[0].Type != "SymbolNode" {
		c.add(Rejected, SB028TracingKind, sa, "`%s.argv_field(:f)` takes one Symbol literal — a :user_str_array field declared in `BPF.tracepoint … fields:`", c.param)
		return Stmt{}, false
	}
	fn := sas[0].Str["value"]
	for i := range c.prog.TFields {
		if c.prog.TFields[i].Name == fn {
			if c.prog.TFields[i].Type != "user_str_array" {
				c.add(Rejected, SB028TracingKind, sas[0], "`%s.argv_field(:%s)`: %s is declared :%s, not :user_str_array", c.param, fn, fn, c.prog.TFields[i].Type)
				return Stmt{}, false
			}
			os.TpStr = &c.prog.TFields[i]
			return os, true
		}
	}
	c.add(Rejected, SB028TracingKind, sas[0], "`%s.argv_field(:%s)`: %s is not declared in `BPF.tracepoint … fields:`", c.param, fn, fn)
	return Stmt{}, false
}

// outputArgv は "ostr" (Argv) の lowering: argv の配列の値を 1 つ作り、slot 0..19 の str_at を present の ebpf.if の入れ子に (argv20.mlir の形)。
// 各段の present の中は output_str の lower (StrSSA に slot の文字列、IndexV に slot の番号)。変異 `argv-flat` は入れ子をやめて 20 段を program の
// 直下に並べ (present の順を崩す — E151 H6)、`argv-index-shift` は index の literal を k+1 に。
func (l *lowerer) outputArgv(s Stmt) error {
	av := l.val()
	if s.TpStr != nil {
		l.emit("%s = ebpf.tp.field %%ctx %q [%d] : !ebpf.ctx<\"tracepoint\"> -> !ebpf.user_str_array %s", av, s.TpStr.Name, s.TpStr.Offset, loc(s.Pos))
	} else {
		l.emit("%s = ebpf.ksyscall.arg %%ctx %d : !ebpf.ctx<\"ksyscall\"> -> !ebpf.user_str_array %s", av, s.Len, loc(s.Pos))
	}
	flat := mutation("argv-flat")
	saved := l.indent
	for k := 0; k < argvSlots; k++ {
		sv, stv, pv := l.val(), l.val(), l.val()
		l.emit("%s, %s, %s = ebpf.user.str_at %s [%d] : !ebpf.user_str_array -> (!ebpf.user_str, i64, i1) %s", sv, stv, pv, av, k, loc(s.Pos))
		l.emit("ebpf.if %s {", pv)
		l.indent += "  "
		sub := s
		sub.Argv, sub.TpStr, sub.StrSSA, sub.IndexV = false, nil, sv, k
		if mutation("argv-index-shift") {
			sub.IndexV = k + 1
		}
		if err := l.outputStr(sub); err != nil {
			l.indent = saved
			return err
		}
		if flat {
			l.emit("ebpf.if.yield %s", loc(s.Pos))
			l.indent = l.indent[:len(l.indent)-2]
			l.emit("} else {")
			l.emit("  ebpf.if.yield %s", loc(s.Pos))
			l.emit("} %s", loc(s.Pos))
		}
	}
	if !flat {
		for k := 0; k < argvSlots; k++ {
			l.emit("ebpf.if.yield %s", loc(s.Pos))
			l.indent = l.indent[:len(l.indent)-2]
			l.emit("} else {")
			l.emit("  ebpf.if.yield %s", loc(s.Pos))
			l.emit("} %s", loc(s.Pos))
		}
	}
	l.indent = saved
	return nil
}

// argvTwinEmpty は双子の空の argv (0 個 — NULL の配列)。
const argvTwinEmpty = "BPF::UserStrArray.new(Array.new(0, BPF::UserStr.new(Array.new(0, 0), true)))"

// argvTwinParse は双子の harness の `<key>=<w1,w2,…|@null>` (@e は空の要素) を target に UserStrArray として置く Ruby の行 (P028 E151)。
func argvTwinParse(target string) string {
	return "            _h_aw = Array.new(0, BPF::UserStr.new(Array.new(0, 0), true))\n" +
		"            if _h_kv[1] != \"@null\"\n              _h_ws = _h_kv[1].split(\",\")\n              _h_x = 0\n              while _h_x < _h_ws.length\n" +
		"                if _h_ws[_h_x] == \"@e\"\n                  _h_aw.push(BPF::UserStr.new(Array.new(0, 0), false))\n                else\n                  _h_aw.push(BPF::UserStr.new(_h_ws[_h_x].bytes, false))\n                end\n" +
		"                _h_x += 1\n              end\n            end\n            " + target + " = BPF::UserStrArray.new(_h_aw)\n"
}

// hasArgv は :user_str_array の引数か field を持つ program が在るか (harness の execargv)。
func hasArgv(res *Result) bool {
	for _, p := range res.Programs {
		for _, kp := range p.Params {
			if kp.Type == "user_str_array" {
				return true
			}
		}
		for _, f := range p.TFields {
			if f.Type == "user_str_array" {
				return true
			}
		}
	}
	return false
}

// hArgvSpawnC は harness の `execargv` (P028 E151): h_argv_spawn は argv (`,` 区切り — @e は空の要素、@null は 0 個、63 個まで) を作り子を fork し
// (子は pipe の 1 byte を待って execve("/nonexistent-e151", argv, 空の envp) — ENOENT で失敗するが syscall の入口は argv を読む — _exit(127))、
// h_argv_release はその byte を書いて waitpid し子の終わりの status を返す。
const hArgvSpawnC = `    #include <string.h>
    static int h_av_fd = -1;
    long h_argv_spawn(const char *csv) {
      static char buf[4096];
      static char *av[64];
      int n = 0;
      if (strcmp(csv, "@null") != 0) {
        strncpy(buf, csv, sizeof buf - 1);
        char *p = buf;
        for (;;) {
          char *c = strchr(p, ',');
          if (c) *c = 0;
          if (strcmp(p, "@e") == 0) *p = 0; /* an empty element is a NUL inside buf (an anonymous page the parent wrote before fork) — a "" in .rodata is not yet in the child's page table and the BPF read gets -EFAULT */
          av[n++] = p;
          if (!c || n >= 63) break;
          p = c + 1;
        }
      }
      av[n] = 0;
      int pp[2];
      if (pipe(pp) != 0) return -1;
      pid_t pid = fork();
      if (pid == 0) {
        char b;
        close(pp[1]);
        if (read(pp[0], &b, 1) != 1) _exit(126);
        char *const envp[] = {0};
        execve("/nonexistent-e151", av, envp);
        _exit(127);
      }
      close(pp[0]);
      if (pid < 0) { close(pp[1]); return -1; }
      h_av_fd = pp[1];
      return (long)pid;
    }
    long h_argv_release(long pid) {
      char b = 1;
      if (write(h_av_fd, &b, 1) != 1) return -1;
      close(h_av_fd);
      h_av_fd = -1;
      int st;
      if (waitpid((pid_t)pid, &st, 0) < 0) return -1;
      return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
    }
`
