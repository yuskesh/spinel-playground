/* tools/wasm/raise_stubs.c -- the shim-vs-raise policy, driver side.
 *
 *   R003 §3-1: "Raise NotImplementedError for anything that has no observable
 *   answer.  Only a *true* no-op -- a call whose meaning is 'do nothing' and
 *   whose return value is never observed by the program -- may be shimmed."
 *
 * Before E012 the wasm32 profile answered `File.fnmatch("*.rb","a.rb")` with
 * false, `Dir.home` with "" and `Dir.pwd` with "/".  All three link, all three
 * run, all three return a *different answer* than the native build without
 * raising -- the exact failure mode E010 removed for SP_INT64 (R003 §3-2).
 *
 * MECHANISM (both halves proved by R003 probes A / A2, no vendor patch):
 *
 *   sp_raise_cls() is declared in spinel_rt.h and DEFINED IN THE GENERATED TU
 *   (R001 §1.5: the runtime archive depends on 29 symbols the generated TU
 *   provides).  A driver-side TU therefore needs the declaration only -- the
 *   link closes against the program.  The result is a real, catchable Ruby
 *   exception: `rescue NotImplementedError` and `rescue ScriptError` both
 *   catch it and execution continues (probe A).
 *
 *   Runtime symbols with a real body in lib/*.c (sp_dir_home lives in
 *   sp_cold.c) cannot be overridden here -- that is a duplicate definition.
 *   wasm-ld --wrap=NAME redirects every *cross-TU* reference to __wrap_NAME at
 *   link time instead (probe A2).  References inside the defining TU are not
 *   redirected, which is what we want: sp_file_expand_path keeps using the
 *   real sp_dir_pwd, only the Ruby-visible `Dir.pwd` call in the generated TU
 *   is diverted.  --wrap is link-time resolution, so it works in --mode
 *   command as well as --mode reactor (R003 §3-3 corrected the README here).
 *
 * SIGNATURES MUST MATCH.  wasm-ld uses typed function references (E009 §4), so
 * every declaration below reproduces the wasm signature of the real symbol:
 *   mrb_int   = int64_t   (SP_INT64 is unconditional on wasm32, E010) -> i64
 *   mrb_bool  = int                                                   -> i32
 *   any pointer                                                       -> i32
 * The bodies never return, so the return type only has to have the right wasm
 * kind; `void *` (i32) stands in for every pointer type.
 *
 * The list is kept in step with the --wrap list in tools/wasm/spinel-wasm; a
 * __wrap_ body with no matching --wrap is simply unreferenced and dropped by
 * --gc-sections, and a --wrap with no body is only a problem if the program
 * actually reaches the symbol.
 */

__attribute__((noreturn)) void sp_raise_cls(const char *cls, const char *msg);

#define SP_NI(msg) sp_raise_cls("NotImplementedError", msg)

/* ---- the platform name (R008 D-5, implemented by E058) ---------------------
 * The sentence used to end "... on the Cloudflare Workers target", which was
 * literally false as soon as the same module ran on Fastly (R008 P08 caught
 * the wording in a Fastly log).  The name is now a symbol:
 *
 *   WEAK here                                    -> "Cloudflare Workers"
 *   STRONG in tools/wasm/fastly/fastly_cgi.c     -> "Fastly Compute"
 *
 * A weak symbol rather than a -D on purpose.  $CFLAGS must stay ONE array,
 * byte for byte, across platforms (see the SP_INT64 banner in spinel-wasm):
 * the runtime object cache is keyed on the flag string, so a per-platform -D
 * would split the cache in two and reintroduce exactly the "two sets of flags"
 * hazard E010 called blocking.  Link-time selection costs nothing and keeps
 * one cache.
 *
 * The message is therefore composed at RUNTIME, into a static buffer.  This is
 * the same shape sp_wasm_host.c already uses for its own messages, and
 * sp_raise_cls copies what it is given.
 */
__attribute__((weak)) const char *const sp_platform_name = "Cloudflare Workers";

static char sp_ni_msg[512];

static char *sp_ni_cat(char *p, const char *s) {
  char *end = sp_ni_msg + sizeof sp_ni_msg - 1;
  while (s && *s && p < end) *p++ = *s++;
  *p = 0;
  return p;
}

/* One place for the sentence, so the build scan, the link-error translation
   table (spinel-wasm) and the runtime raise cannot drift apart. */
__attribute__((noreturn))
static void sp_unavail(const char *what, const char *why) {
  char *p = sp_ni_msg;
  p = sp_ni_cat(p, what);
  p = sp_ni_cat(p, " is not available on the ");
  p = sp_ni_cat(p, sp_platform_name);
  p = sp_ni_cat(p, " target (wasm32-wasip1)");
  sp_ni_cat(p, why);
  SP_NI(sp_ni_msg);
}

#define SP_UNAVAIL(what, why) sp_unavail(what, why)

/* ---- Dir.home / Dir.home(user) -- shim returned "" (R003 §3-2) ------------ */
void *__wrap_sp_dir_home(void) {
  SP_UNAVAIL("Dir.home",
        "; there is no passwd database (getpwnam is a declaration-only shim)");
}
void *__wrap_sp_dir_home_user(const char *user) {
  (void)user;
  SP_UNAVAIL("Dir.home(user)",
        "; there is no passwd database (getpwnam is a declaration-only shim)");
}

/* ---- Dir.pwd -- shim returned "/" (R003 §3-2) ---------------------------- */
/* WASI preview1 has no cwd at all.  "/" is not a small inaccuracy: it is a
   path that does not exist, and File.expand_path built on it is wrong too. */
void *__wrap_sp_dir_pwd(void) {
  SP_UNAVAIL("Dir.pwd",
        "; WASI preview1 has no current working directory");
}

/* ---- Dir.glob / File.fnmatch -- shim returned an empty Array / false ------ */
/* Dir.glob does not necessarily reach fnmatch(): with no preopened directory
   the directory walk fails first and the glob comes back *empty*, which is a
   perfectly normal answer to a program.  So the Ruby-level entry points are
   wrapped as well as the libc stub in stubs.c. */
void *__wrap_sp_dir_glob(const char *pattern) {
  (void)pattern;
  SP_UNAVAIL("Dir.glob",
        "; there is no filesystem to walk (no WASI preopens)");
}
void *__wrap_sp_dir_glob_dot(const char *pattern) {
  (void)pattern;
  SP_UNAVAIL("Dir.glob",
        "; there is no filesystem to walk (no WASI preopens)");
}
int __wrap_sp_file_fnmatch(const char *pat, const char *path) {
  (void)pat; (void)path;
  SP_UNAVAIL("File.fnmatch",
        "; fnmatch() is a stub in this profile, not an implementation");
}

/* ---- Kernel#system / backticks / shell capture --------------------------- */
/* Rejected by the scan too; this is the backstop for --allow-unsupported and
   for any path the scan does not see (R003 §3-4). */
int __wrap_sp_system_args(int argc, const char *const *argv) {
  (void)argc; (void)argv;
  SP_UNAVAIL("Kernel#system",
        "; WASI preview1 cannot create processes");
}
void *__wrap_sp_backtick(const char *cmd) {
  (void)cmd;
  SP_UNAVAIL("Kernel#` (backticks)",
        "; WASI preview1 cannot create processes");
}
void *__wrap_sp_net_shell_capture(const char *cmd, int max_bytes) {
  (void)cmd; (void)max_bytes;
  SP_UNAVAIL("shell capture",
        "; WASI preview1 cannot create processes");
}

/* ---- sockets ------------------------------------------------------------- */
/* R003 §2-4 layer 1: outbound traffic is an explicit host bridge
   (spinel_host.http_request), never an emulated Socket.  listen/accept has no
   counterpart on Workers at all, so a half-working Socket would be exactly the
   "half correct" API §3 forbids.  Every entry point raises.
   sp_net_connect / sp_net_listen_host live in lib/sp_net.c, which does not
   even compile for wasm32 -- wrapping them converts an `undefined symbol`
   link failure into a catchable Ruby exception. */
#define SP_SOCK_NI(what) SP_UNAVAIL(what, \
  "; WASI preview1 has no sockets. Use an explicit host bridge (R003 §2-4) "  \
  "for outbound requests; listen/accept has no counterpart on this platform")

/* constructors (lib/sp_io.c) */
void *__wrap_sp_sock_new(long long d, long long t, long long p) { (void)d; (void)t; (void)p; SP_SOCK_NI("Socket.new"); }
void *__wrap_sp_sock_udp_new(long long fam) { (void)fam; SP_SOCK_NI("UDPSocket.new"); }
void *__wrap_sp_sock_unix_server(const char *path) { (void)path; SP_SOCK_NI("UNIXServer.new"); }
void *__wrap_sp_sock_unix_connect(const char *path) { (void)path; SP_SOCK_NI("UNIXSocket.new"); }
void *__wrap_sp_sock_pair_end(long long d, long long t, long long p, long long w) { (void)d; (void)t; (void)p; (void)w; SP_SOCK_NI("Socket.pair"); }
void *__wrap_sp_io_fdopen_sock(int fd, const char *kind) { (void)fd; (void)kind; SP_SOCK_NI("TCPSocket/TCPServer"); }
/* lib/sp_net.c -- does not compile for wasm32; these close the link */
int __wrap_sp_net_connect(const char *host, int port) { (void)host; (void)port; SP_SOCK_NI("TCPSocket.new"); }
int __wrap_sp_net_listen_host(const char *host, int port, int backlog) { (void)host; (void)port; (void)backlog; SP_SOCK_NI("TCPServer.new"); }

/* name/address lookup (reachable without a socket object) */
void *__wrap_sp_sock_gethostname(void) { SP_SOCK_NI("Socket.gethostname"); }
void *__wrap_sp_sock_getaddrinfo(const char *host, long long port) { (void)host; (void)port; SP_SOCK_NI("Socket.getaddrinfo"); }

/* the method surface: the generated TU calls these directly, so wrapping only
   the constructors would leave lib/sp_io.c's bodies alive and their sp_net_*
   references undefined at link time. */
void *__wrap_sp_sock_accept(void *f) { (void)f; SP_SOCK_NI("BasicSocket#accept"); }
void *__wrap_sp_sock_accept_nb(void *f, int exc) { (void)f; (void)exc; SP_SOCK_NI("BasicSocket#accept_nonblock"); }
void __wrap_sp_sock_wait_readable(void *f) { (void)f; SP_SOCK_NI("BasicSocket#wait_readable"); }
void *__wrap_sp_sock_read_nb(void *f, long long len, int exc, int is_recv) { (void)f; (void)len; (void)exc; (void)is_recv; SP_SOCK_NI("BasicSocket#read_nonblock"); }
long long __wrap_sp_sock_write_nb(void *f, const char *d, int exc) { (void)f; (void)d; (void)exc; SP_SOCK_NI("BasicSocket#write_nonblock"); }
long long __wrap_sp_sock_write_nb_bin(void *f, const char *d, int exc) { (void)f; (void)d; (void)exc; SP_SOCK_NI("BasicSocket#write_nonblock"); }
long long __wrap_sp_sock_connect_nb(void *f, const char *h, long long p, int exc) { (void)f; (void)h; (void)p; (void)exc; SP_SOCK_NI("Socket#connect_nonblock"); }
long long __wrap_sp_sock_bind(void *f, const char *h, long long p) { (void)f; (void)h; (void)p; SP_SOCK_NI("Socket#bind"); }
long long __wrap_sp_sock_connect(void *f, const char *h, long long p) { (void)f; (void)h; (void)p; SP_SOCK_NI("Socket#connect"); }
long long __wrap_sp_sock_send(void *f, const char *d, long long l, const char *h, long long p) { (void)f; (void)d; (void)l; (void)h; (void)p; SP_SOCK_NI("Socket#send"); }
long long __wrap_sp_sock_shutdown(void *f, long long how) { (void)f; (void)how; SP_SOCK_NI("Socket#shutdown"); }
void *__wrap_sp_sock_recv(void *f, long long len) { (void)f; (void)len; SP_SOCK_NI("Socket#recv"); }
void *__wrap_sp_sock_recvfrom(void *f, long long len, const char **ip, long long *port) { (void)f; (void)len; (void)ip; (void)port; SP_SOCK_NI("Socket#recvfrom"); }
long long __wrap_sp_sock_setsockopt(void *f, long long lv, long long o, long long v) { (void)f; (void)lv; (void)o; (void)v; SP_SOCK_NI("Socket#setsockopt"); }
void *__wrap_sp_sock_getsockopt(void *f, long long lv, long long o) { (void)f; (void)lv; (void)o; SP_SOCK_NI("Socket#getsockopt"); }
long long __wrap_sp_sock_listen(void *f, long long backlog) { (void)f; (void)backlog; SP_SOCK_NI("Socket#listen"); }
void *__wrap_sp_sock_address(void *f, long long peer) { (void)f; (void)peer; SP_SOCK_NI("BasicSocket#addr"); }

/* These previously lived in stubs.c because their runtime TU was omitted.
 * The real scheduler is compiled now; keep the existing refusal at link time. */
const char *__wrap_sp_Queue_class_name(void *q) {
  (void)q;
  SP_NI("Thread::Queue is not available on wasm32-wasip1");
}
const char *__wrap_sp_Mutex_class_name(void *m) {
  (void)m;
  SP_NI("Thread::Mutex is not available on wasm32-wasip1");
}
