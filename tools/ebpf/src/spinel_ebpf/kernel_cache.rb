# frozen_string_literal: true
#
# spinel-ebpf — detector for the REFUSED `kernel_cache "/path", body` directive.
#
# STATUS (E427, 2026-08-07): this module has exactly one live consumer —
# `Validate#check_kernel_cache_unported!` (check (6), E420), which refuses the
# directive at compile time. It is NOT a step in any compile that succeeds.
#
# History, and why the file survives at all:
#   E188 built an auto kernel-cache (response-granularity partition) in the
#   retired Ruby oracle: declare a path, and the pure-XDP TCP slice serves it
#   from the kernel. The C port (ADR-011 Stage 2) never carried it, and E416
#   re-ported the tcp_slice bundle WITHOUT the kernel_cache branch. E420
#   measured what the surface did in that state — parsed, announced an eBPF
#   method, emitted a .bpf.c with zero programs, built, printed "BPF loaded and
#   attached", served nothing, exit 0 — and made it a hard error.
#
#   ADR-003 says the refusal has to fire where the author's own spelling is
#   still visible, so the refusal needs to SEE the directive. That is this file.
#   Everything else the surface used to need is gone (E427).
#
# Therefore the only property that matters here is the BLAST RADIUS: which
# programs get refused and which do not. That shape is deliberately narrow and
# unchanged since E188 — a bare (receiver-less) 2-argument call named
# `kernel_cache` whose first argument is a string literal:
#
#   kernel_cache "/health", "OK\n"     -> refused (literal body)
#   kernel_cache "/health", body       -> refused (runtime body; E188 Phase 1
#                                         populated it via sp_kc_set, which
#                                         E420 deleted — so this form reaches
#                                         nothing too, and must not slip past)
#   kernel_cache "/health"             -> NOT a declaration (wrong arity)
#   obj.kernel_cache "/a", "b"         -> NOT a declaration (has a receiver)
#
# The second argument's TYPE is not inspected: a runtime body is still a
# declaration, and the body itself is never read. (It was read once, for
# compile-time HTTP framing; E188 Phase 1 moved bodies to runtime and left that
# half of the parser with no consumer at all — measured in E427, including
# inside the retired oracle. It is deleted rather than kept warm by its test.)
#
# AST shape (from `spinel --dump-ast`):
#   ProgramNode -> StatementsNode body[] -> CallNode(name="kernel_cache", receiver=-1)
#     -> ArgumentsNode arguments[] -> [StringNode(path), <anything>]

module SpinelEbpf
  module KernelCache
    module_function

    # Returns the declared paths, in source order, for every top-level
    # `kernel_cache "<path>", <anything>` call. Empty means "this program does
    # not use the refused surface" — the common case, and the only case in which
    # a compile proceeds.
    def declared_paths(ast)
      out = []
      stmts = ast.statements_of(ast.root_id)
      return out if stmts.nil? || stmts < 0
      ast.body_array_of(stmts).each do |sid|
        n = ast.node(sid)
        next unless n && n.type == "CallNode"
        next unless ast.str_attr(sid, "name") == "kernel_cache"
        next unless ast.ref(sid, "receiver") == -1          # bare call, not recv.kernel_cache
        args = ast.ref(sid, "arguments")
        next if args < 0
        items = ast.array(args, "arguments")
        next unless items.length == 2
        pn = ast.node(items[0])
        next unless pn && pn.type == "StringNode"           # path must be a literal
        out << ast.str_attr(items[0], "content")
      end
      out
    end
  end
end
