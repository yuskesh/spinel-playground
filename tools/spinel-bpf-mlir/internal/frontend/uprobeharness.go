package frontend

import (
	"fmt"
	"strings"
)

// uprobe の harness (P020 E081): kernel の側は target (ARGV[0] — cfix の fixture) を子の process として起動し、stdin の行で関数を呼ばせる
// (probe は子の中で発火)。双子は同じ行を cfix の約束で引数にして root を呼ぶ。cfix の約束 (internal/frontend/testdata/uprobe/target/cfix.c):
//   sum A B C     → sum_args(A, B, C) — 引数 1..3 の整数
//   greet N TEXT  → greet(TEXT, N) — 引数 1 は文字列 (TEXT は行の残り、空は空文字列)、2 は整数
//   null N        → greet(NULL, N)
//   gai HOST SERV → (E156 — 子は gfix) libc の getaddrinfo(HOST, SERV, …) — 引数 1・2 は文字列
//   lock I / unlock I → (E157 — 子は mfix) libc の pthread_mutex_lock / unlock(&m[I]) — 子は mutex の address を答え、kernel は rv= に。
//                   双子は `at ADDR` (引数 1 に raw の値) か、引数を読まない program に `lock I` / `unlock I` をそのまま
// 試験の build だけ (利用者の実行 file には入らない)。

// hasUprobe は uprobe の program が在るか。
func hasUprobe(res *Result) bool {
	for _, p := range res.Programs {
		if p.Kind == "uprobe" || p.Kind == "uretprobe" { // P026 E112: uretprobe も同じ子の process
			return true
		}
	}
	return false
}

// hasPtrParam は :ptr の引数を持つか (E157 — kernel の harness が子の答えの値を rv= に出す)。
func hasPtrParam(p *Program) bool {
	for _, kp := range p.Params {
		if kp.Type == "ptr" {
			return true
		}
	}
	return false
}

// uprobeKernelSetup は kernel の harness の子の process の起動 (fork・exec・pipe の inline C)。uprobe の program が無ければ空。
func uprobeKernelSetup(res *Result) string {
	if !hasUprobe(res) {
		return ""
	}
	return `module HUprobe
  ffi_source <<~C
    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>
    #include <unistd.h>
    #include <sys/types.h>
    static int h_in = -1;
    static FILE *h_rf = NULL;
    static long h_child = 0;
    static char h_last[1100];
    long h_start(const char *path) {
      int a[2], b[2];
      if (pipe(a) != 0 || pipe(b) != 0) return -1;
      pid_t p = fork();
      if (p < 0) return -1;
      if (p == 0) {
        dup2(a[0], 0); dup2(b[1], 1); close(a[1]); close(b[0]);
        execl(path, path, (char *)0);
        _exit(127);
      }
      close(a[0]); close(b[1]);
      h_in = a[1];
      h_rf = fdopen(b[0], "r");
      h_child = (long)p;
      char line[256];
      if (h_rf == NULL || fgets(line, sizeof line, h_rf) == NULL || strncmp(line, "ready ", 6) != 0) return -1;
      return h_child;
    }
    long h_pid(void) { return h_child; }
    long h_send(const char *s) {
      size_t n = strlen(s);
      char nl = 10; /* newline, by value (the Ruby heredoc expands escapes inside strings) */
      if (write(h_in, s, n) != (ssize_t)n || write(h_in, &nl, 1) != 1) return -1;
      char line[1100];
      if (fgets(line, sizeof line, h_rf) == NULL) return -1;
      strcpy(h_last, line);
      return (long)strlen(line);
    }
    /* the integer in the second word of the child's last answer (the return value of the uretprobe's function) */
    long h_last_value(void) { char *s = strchr(h_last, 32); return s ? strtoll(s + 1, NULL, 10) : 0; }
  C
  ffi_func :h_start, [:str], :long
  ffi_func :h_pid, [], :long
  ffi_func :h_send, [:str], :long
  ffi_func :h_last_value, [], :long
end
if HUprobe.h_start(ARGV[0]) < 0
  raise "the kernel harness could not start the uprobe target #{ARGV[0]} as a child process"
end
`
}

// uprobeTwinRun は双子の `run <prog> <cfix の命令>` (宣言の params の型の幅で切る — kernel が register の bits を幅で読む形の model)。
func uprobeTwinRun(kw string, p *Program) string {
	var b strings.Builder
	decl := map[int]string{}
	for _, kp := range p.Params {
		decl[kp.N] = kp.Type
	}
	setInt := func(n int, x string) {
		if t, ok := decl[n]; ok && t == "ptr" { // E157: pointer の raw の値 (幅で切らない i64)
			fmt.Fprintf(&b, "          _h_args[%d] = %s\n", n, x)
		} else if ok && t != "user_str" && t != "user_buf" {
			fmt.Fprintf(&b, "          _h_args[%d] = %s\n", n, widthCut(x, t))
		}
	}
	setStr := func(n int, bytes, null string) {
		if decl[n] == "user_str" {
			fmt.Fprintf(&b, "          _h_strs[%d] = BPF::UserStr.new(%s, %s)\n", n, bytes, null)
		}
	}
	setBuf := func(n int, bytes, null string) { // P029 E158: :user_buf の引数 (pointer の先の memory)
		if decl[n] == "user_buf" {
			fmt.Fprintf(&b, "          _h_bufs[%d] = BPF::UserBuf.new(%s, %s)\n", n, bytes, null)
		}
	}
	fmt.Fprintf(&b, "      %s _h_f[1] == %q\n        _h_args = Array.new(7, 0)\n        _h_strs = Array.new(7, BPF::UserStr.new(Array.new(0, 0), true))\n        _h_bufs = Array.new(7, BPF::UserBuf.new(Array.new(0, 0), true))\n", kw, p.Name)
	if mutation("ustr-null-status") { // 変異の対照 (試験の build だけ — E081): 双子の NULL の status を 0 に
		b.WriteString("        BPF::USTR_NULL_STATUS[0] = 0\n")
	}
	b.WriteString("        if _h_f[2] == \"sum\"\n")
	setInt(1, "_h_f[3].to_i")
	setInt(2, "_h_f[4].to_i")
	setInt(3, "_h_f[5].to_i")
	b.WriteString("        elsif _h_f[2] == \"greet\"\n          _h_txt = \"\"\n          if _h_f.length > 4\n            _h_txt = _h_f[4, _h_f.length - 4].join(\" \")\n          end\n")
	setStr(1, "_h_txt.bytes", "false")
	setInt(2, "_h_f[3].to_i")
	b.WriteString("        elsif _h_f[2] == \"null\"\n")
	setStr(1, "Array.new(0, 0)", "true")
	setInt(2, "_h_f[3].to_i")
	b.WriteString("        elsif _h_f[2] == \"gai\"\n") // E156: gfix の `gai HOST SERV` (libc の getaddrinfo — 引数 1・2 は文字列)
	setStr(1, "_h_f[3].bytes", "false")
	setStr(2, "_h_f[4].bytes", "false")
	b.WriteString("        elsif _h_f[2] == \"at\"\n") // E157: 双子だけの `at ADDR` — 引数 1 に子の出した pointer の raw の値 (kernel は mfix に `lock I` を送り rv= に)
	setInt(1, "_h_f[3].to_i")
	b.WriteString("        elsif _h_f[2] == \"lock\" || _h_f[2] == \"unlock\"\n") // E157: 引数を読まない program (unlock) の双子は命令だけ
	b.WriteString("        elsif _h_f[2] == \"put\"\n          _h_bb = Array.new(256, 0)\n          if _h_f.length > 4\n            _h_tb = _h_f[4].bytes\n            _h_i = 0\n            while _h_i < _h_tb.length && _h_i < 256\n              _h_bb[_h_i] = _h_tb[_h_i]\n              _h_i += 1\n            end\n          end\n") // E158: pfix の `put LEN TEXT` — 256 byte の 0 の buffer の先頭に TEXT
	setBuf(1, "_h_bb", "false")
	setInt(2, "_h_f[3].to_i")
	b.WriteString("        elsif _h_f[2] == \"putnull\"\n") // E158: pfix の `putnull LEN` — NULL の buffer
	setBuf(1, "Array.new(0, 0)", "true")
	setInt(2, "_h_f[3].to_i")
	b.WriteString("        else\n          raise \"unknown cfix command #{_h_f[2]}\"\n        end\n")
	fmt.Fprintf(&b, "        %s(BPF::UprobeCtx.new(_h_args, _h_strs, _h_bufs))\n        puts \"ret=0\"\n", p.Name)
	return b.String()
}
