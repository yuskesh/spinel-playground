/* builtin_schema.h -- the builtin vocabulary, first axis: declared arity
 * (E462 / ADR-019 Phase C stage 1).
 *
 * E462 probed all 195 advertised builtins with one surplus argument appended to
 * their own affordance example. 157 died in their handlers' inline checks; the
 * 38 below COMPILED BYTE-IDENTICALLY to the correct call -- the surplus argument
 * silently vanished. That is the E428 failure shape ("the mistake only ever
 * shows up as silence"): `pid(tgid)` or `stack_id(1)` reads as if the argument
 * meant something, compiles, loads, verifies, and answers the no-argument
 * question. This table is the fold: cc_require_declared_arity() checks it at
 * the CallNode entry of both lowering functions, BEFORE any handler matches.
 *
 * SCOPE RULE -- the table deliberately holds ONLY the builtins whose handlers do
 * not enforce their own arity (the measured-silent set). The other 157 keep
 * their inline checks: those die with richer, call-shaped messages ("udp_dport/
 * udp_daddr expect two arguments: the socket and the message (e.g. ...)"), and
 * a central generic check firing first would replace actionable errors with a
 * bland one (an E435 error-quality regression). When a handler grows its own
 * check, its row here becomes dead and should move out; when a new builtin's
 * handler skips the check, the arity section of tools/affordance_gate.rb
 * (`--section arity`, enforcing since E462) fails until a row lands here.
 *
 * Lockstep: each row's arity must equal the Ruby side's declared signature
 * (Capabilities.signature_for) -- tests/spinel_ebpf/capabilities_test.rb
 * parses this header and compares (same pattern as the E390/E460 gate tables).
 *
 * This header is the seed of Phase C: further machine axes of the builtin
 * vocabulary (existence, hook legality, per-target legality) migrate here in
 * later stages -- each one measured first, folded second (E460 -> E461 shape).
 */
#ifndef SPNL_BUILTIN_SCHEMA_H
#define SPNL_BUILTIN_SCHEMA_H

#include <string.h>   /* cc_builtin_on_target: strcmp */

typedef struct {
  const char *name;
  int arity;        /* exact -- these builtins have no optional arguments */
} CcBuiltinArity;

static const CcBuiltinArity cc_declared_arity[] = {
  /* current-task / kernel-context readers (E083/E120/E125): the value comes
   * from the hook context, never from an argument. */
  { "ktime_ns", 0 }, { "pid", 0 }, { "tgid", 0 }, { "tid", 0 },
  { "cpu_id", 0 }, { "uid", 0 }, { "gid", 0 }, { "ppid", 0 },
  { "cgroup_id", 0 }, { "comm_hash", 0 }, { "emit_comm", 0 },
  { "cap_effective", 0 },
  /* latency pair (E083) -- the KEYED forms lat_start(key)/lat_end(key) are
   * different builtins with their own handler checks. */
  { "latency_start", 0 }, { "latency_end", 0 },
  /* stack ids (E088/E090) */
  { "stack_id", 0 }, { "user_stack_id", 0 },
  /* queue/stack pops (E107) -- push takes a value, pop takes nothing. */
  { "queue_pop", 0 }, { "fifo_pop", 0 }, { "lifo_pop", 0 },
  /* per-task storage read (E103) */
  { "task_load", 0 },
  /* sock_addr ctx readers (E105) */
  { "sock_addr_ip4", 0 }, { "sock_addr_port", 0 },
  /* packet header readers (E030/E050/E080) -- all read ctx, arity 0. The chain
   * spellings (`pkt.len`) have a receiver and are exempt from this check by
   * construction (a builtin call is a bare call). */
  { "pkt_len", 0 }, { "pkt_eth_proto", 0 },
  { "pkt_ip4_src", 0 }, { "pkt_ip4_dst", 0 },
  { "pkt_ip6_src_hi", 0 }, { "pkt_ip6_src_lo", 0 },
  { "pkt_ip6_dst_hi", 0 }, { "pkt_ip6_dst_lo", 0 },
  { "pkt_l4_proto", 0 }, { "pkt_l4_sport", 0 }, { "pkt_l4_dport", 0 },
  { "pkt_l4_payload_len", 0 },
  { "pkt_tcp_flags", 0 }, { "pkt_tcp_seq", 0 }, { "pkt_tcp_ack", 0 },
  /* conntrack delete (E168): exactly the flow name -- the handler checked
   * "at least one" and ignored the rest (measured). */
  { "flow_del", 1 },
};
#define CC_N_DECLARED_ARITY ((int)(sizeof(cc_declared_arity) / sizeof(cc_declared_arity[0])))

/* --- E465 (ADR-019 Phase C stage 4 / P013 Phase 2): per-target existence ----
 *
 * "builtin X exists on target Y" is a fact THREE consumers used to hold in
 * their own spelling: target_profile.rb's call_allowlist arrays, the C
 * backstops (amp_scan_supported / gpu_scan_supported) as inline strcmp chains,
 * and the E463 existence extractor as a g_gpu line-filter special case. That
 * is the ADR-019 decision-6 shape exactly -- multiple consumers, one fact --
 * so it is declared once here and everything else derives:
 *   - the backstops call cc_builtin_on_target()
 *   - target_profile.rb reads the generated JSON (make -C src/codegen_c
 *     builtin-schema) for its allowlists
 *   - the existence coverage subtracts the declared non-linux names instead
 *     of pattern-matching g_gpu lines
 *
 * SCOPE RULE -- rows exist only where the target set differs from the default
 * {linux}: the overwhelming majority of the vocabulary is linux-only and
 * listing it would bury the exceptions. A builtin absent from this table is
 * linux-only by definition (cc_builtin_on_target's else arm).
 * The prose halves (supported_summary / remedy / the backstop die text) stay
 * in their consumers -- they are not shared facts (decision 6 again); the
 * die-message <-> supported_summary prose lockstep lives in
 * tests/spinel_ebpf/target_profile_test.rb as before. */
#define CC_TGT_LINUX     1u
#define CC_TGT_AMP       2u   /* --target amp-m7 / amp-m33 (ADR-016) */
#define CC_TGT_GPU_METAL 4u   /* --target gpu-metal (P013 / E456) */

typedef struct {
  const char *name;
  unsigned targets;   /* OR of CC_TGT_*; never 0 */
} CcBuiltinTargets;

static const CcBuiltinTargets cc_builtin_targets[] = {
  /* linux builtins that ALSO lower on the M-core (E357: amp_emit / amp_ktime) */
  { "spnl_emit",     CC_TGT_LINUX | CC_TGT_AMP },
  { "ktime_ns",      CC_TGT_LINUX | CC_TGT_AMP },
  /* the GPU kernel surface (E456/E459) -- gpu-only, never on the linux path
   * (every recognizing strcmp in the lowering functions is g_gpu-guarded) */
  { "gpu_global_id", CC_TGT_GPU_METAL },
  { "gpu_load",      CC_TGT_GPU_METAL },
  { "gpu_store",     CC_TGT_GPU_METAL },
  { "gpu_buffer",    CC_TGT_GPU_METAL },
  /* E467: threadgroup cooperation -- coordinates, barrier, shared arrays */
  { "gpu_local_id",     CC_TGT_GPU_METAL },
  { "gpu_group_id",     CC_TGT_GPU_METAL },
  { "gpu_group_size",   CC_TGT_GPU_METAL },
  { "gpu_barrier",      CC_TGT_GPU_METAL },
  { "gpu_shared",       CC_TGT_GPU_METAL },
  { "gpu_shared_load",  CC_TGT_GPU_METAL },
  { "gpu_shared_store", CC_TGT_GPU_METAL },
  /* E469: device-buffer atomics (32-bit atomic_int lanes, :atomic buffers) */
  { "gpu_atomic_add",   CC_TGT_GPU_METAL },
};
#define CC_N_BUILTIN_TARGETS ((int)(sizeof(cc_builtin_targets) / sizeof(cc_builtin_targets[0])))

static inline int cc_builtin_on_target(const char *name, unsigned tgt) {
  for (int i = 0; i < CC_N_BUILTIN_TARGETS; i++)
    if (!strcmp(name, cc_builtin_targets[i].name))
      return (cc_builtin_targets[i].targets & tgt) != 0;
  return tgt == CC_TGT_LINUX;   /* default: linux-only */
}

/* --- E466: per-target SYNTAX support ---------------------------------------
 *
 * `times` is not a builtin (it is iterator syntax, owned by the SYNTAX
 * vocabulary and excluded from the existence coverage for exactly that
 * reason), but WHERE it lowers is still a per-target fact with multiple
 * consumers: the restricted-target scans (amp/gpu) must not die on it where a
 * lowering exists, and the Ruby partition's allowlist check must not count it
 * as an unsupported call there. Same decision-6 shape as cc_builtin_targets,
 * kept as a SEPARATE table so syntax never pollutes the builtin vocabulary.
 *
 * linux is listed for the record but never consulted (linux has no allowlist);
 * amp is deliberately absent: the AMP v0 codegen has no loop lowering, so its
 * scan refusing `times` is correct behavior, not a missing row. */
typedef struct {
  const char *name;
  unsigned targets;
} CcSyntaxTargets;

static const CcSyntaxTargets cc_syntax_targets[] = {
  /* n.times { |i| } -- linux: bpf_loop / open-coded (E016/E062); gpu-metal:
   * a plain MSL for loop (E466, no verifier -> no callback machinery). */
  { "times", CC_TGT_LINUX | CC_TGT_GPU_METAL },
};
#define CC_N_SYNTAX_TARGETS ((int)(sizeof(cc_syntax_targets) / sizeof(cc_syntax_targets[0])))

static inline int cc_syntax_on_target(const char *name, unsigned tgt) {
  for (int i = 0; i < CC_N_SYNTAX_TARGETS; i++)
    if (!strcmp(name, cc_syntax_targets[i].name))
      return (cc_syntax_targets[i].targets & tgt) != 0;
  return 0;   /* not a declared syntax name */
}

#endif /* SPNL_BUILTIN_SCHEMA_H */
