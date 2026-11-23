#include "spinel/Conversion/Consumer.h"
#include "llvm/ADT/StringSwitch.h"
namespace spinel::consumer {
LogicalResult Consumer::typed(Operation *node) {
  if (failed(known(node, false))) return failure();
  auto type = types[id(node)].front()->getAttrOfType<TypeAttr>("value_type");
  // M3 records all nodes, whereas the Go JSON omits unknown and void. This is
  // the sole sentinel test; no type is inferred from a call name or a range.
  if (type && isa<ir::UnknownType, ir::VoidType>(type.getValue()))
    return unknownDiagnostic(node, "SB001", "UnsupportedConstruct",
        "Spinel gives this " + text(node, "kind").str() +
        " no type — outside the typed subset (fail closed)", true);
  return success();
}

LogicalResult Consumer::checkScalarShape(Operation *node) {
  auto kind = text(node, "kind");
  auto reject = [&](StringRef code, StringRef label, const std::string &message) {
    // Semantic rejection never substitutes for pristine/analyzed identity.
    if (failed(known(node, false))) return failure();
    return diagnostic(node, code, label, message, true);
  };
  if (kind == "NilNode")
    return reject("SB001", "UnsupportedConstruct", "nil is not a value on the eBPF side");
  if (kind == "StringNode")
    return reject("SB001", "UnsupportedConstruct", "StringNode is not accepted in an expression on the eBPF side");
  auto parameters = activeDef ? array(ref(activeDef, "parameters"), "requireds")
                              : SmallVector<Operation *>();
  std::string param = parameters.empty() ? "" : field(parameters.front(), "strings", "name").str();
  if (kind == "LocalVariableReadNode") {
    auto name = field(node, "strings", "name").str();
    if (name == param && (activeKind == "xdp" || activeKind == "sched_cls" ||
                         activeKind == "flow_dissector" || activeKind == "cgroup_skb"))
      return reject("SB001", "UnsupportedConstruct", "the context `"+param+
          "` is used only as `w = "+param+".check(off, len)` right before `if w` (P004 §1)");
    if (!locals.count(name) && !borrows.count(name))
      return reject("SB001", "UnsupportedConstruct", "`"+name+
          "` is not defined on every path here (Ruby would read nil)");
  }
  if (kind != "CallNode") return success();
  auto name = field(node, "strings", "name");
  if (name == "**")
    return reject("SB001", "UnsupportedConstruct", "`**` is outside the eBPF side");
  if (name == "atomic_add" || name == "update")
    return reject("SB002", "UnsupportedCall", "`"+name.str()+
        "` is a statement, not a value (its result is not used on the eBPF side)");
  bool op = llvm::StringSwitch<bool>(name)
      .Cases({"+", "-", "*", "/", "%"}, true)
      .Cases({"&", "|", "^", "<<", ">>"}, true)
      .Cases({"==", "!=", "<", "<=", ">", ">="}, true)
      .Cases({"-@", "~", "!", "load"}, true).Default(false);
  auto receiver = ref(node, "receiver");
  if (constant(receiver) == "Thread") {
    // Preserve the registered family's source-constant SB027 before the generic
    // unsupported-call fallback; never replace it with inferred call metadata.
    auto value = scalar(receiver);
    if (failed(value)) return failure();
  }
  bool context = text(receiver, "kind") == "LocalVariableReadNode" &&
                 field(receiver, "strings", "name") == param;
  if (context && failed(typed(node))) return failure();
  if (!op)
    return reject("SB002", "UnsupportedCall", "call `"+name.str()+"` is not accepted on the eBPF side");
  return success();
}
} // namespace spinel::consumer
