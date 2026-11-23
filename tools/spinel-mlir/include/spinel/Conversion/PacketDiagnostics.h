#pragma once
#include "spinel/Conversion/Consumer.h"

namespace spinel::consumer {
// Go's verdictWant: wording is distinct from the declaration/kind names.
inline std::string packetVerdictWant(StringRef kind, StringRef xdp) {
  if (kind == "sched_cls") return "a sched_cls verdict (BPF::TC_PASS / TC_DROP)";
  if (kind == "socket_filter") return "a socket_filter verdict (BPF::SF_KEEP / SF_DROP)";
  if (kind == "cgroup_skb") return "a cgroup_skb verdict (BPF::CG_ALLOW / CG_DENY)";
  if (kind == "netfilter") return "a netfilter verdict (BPF::NF_ACCEPT / NF_DROP)";
  if (kind == "flow_dissector") return "a flow_dissector verdict (BPF::FLOW_OK / FLOW_DROP / FLOW_CONTINUE)";
  if (kind == "sk_lookup") return "an sk_lookup verdict (BPF::SK_PASS / SK_DROP)";
  return xdp.str();
}
inline LogicalResult packetEndingDiagnostic(Consumer &c, Operation *last) {
  std::string message;
  if (!last)
    message = "the program `" + c.programName + "` must end with " +
        packetVerdictWant(c.activeKind,"an XDP verdict (BPF::XDP_PASS etc.)");
  else if (text(last,"kind") == "ReturnNode" && c.args(last).size() != 1)
    message = "`return` must return one " + packetVerdictWant(c.activeKind,"BPF::XDP_* constant");
  else
    message = "the program must end with " +
        packetVerdictWant(c.activeKind,"an XDP verdict (BPF::XDP_ABORTED / XDP_DROP / XDP_PASS / XDP_TX)") +
        ", got " + text(last,"kind").str();
  return c.diagnostic(last ? last : c.activeDef,"SB008","ProgramShape",message,true);
}
inline LogicalResult packetFinalizeBody(Consumer &c) {
  auto *block = c.builder.getInsertionBlock();
  if (!block->empty() && block->back().hasTrait<mlir::OpTrait::IsTerminator>()) return success();
  auto statements = c.array(c.ref(c.activeDef,"body"),"body");
  return packetEndingDiagnostic(c,statements.empty() ? nullptr : statements.back());
}
} // namespace spinel::consumer
