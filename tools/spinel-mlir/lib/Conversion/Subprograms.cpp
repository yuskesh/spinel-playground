#include "spinel/Conversion/Subprograms.h"
#include "spinel/Conversion/PacketSubprogram.h"
#include "spinel/Conversion/LoopFacts.h"
#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "spinel/Analysis/SubprogramGraph.h"
#include "spinel/Analysis/SubprogramFlow.h"
#include "llvm/ADT/StringExtras.h"
#include "llvm/ADT/ScopeExit.h"
#include "llvm/Support/Path.h"
#include <functional>
namespace spinel::consumer {
struct SubprogramState {
  struct Special {
    enum Kind { Borrowed, Window, Context } kind;
    size_t index = 0, map = 0;
    int64_t length = 0;
    std::string context;
  };
  std::vector<Operation *> definitions;
  std::vector<subprogram::Method> methods;
  std::map<std::string, size_t> index;
  std::vector<size_t> roots;
  subprogram::Graph graph;
  std::vector<subprogram::FunctionFlows> flows;
  std::vector<std::vector<std::string>> parameters;
  std::vector<std::vector<math::MathInterval>> argumentHulls;
  std::map<int64_t, Expr> checkedCalls;
  std::map<int64_t, std::pair<size_t, size_t>> parameterTokens;
  std::vector<Operation *> emittedFunctions;
  std::vector<std::vector<std::string>> paths;
  std::map<int64_t, std::vector<std::string>> flowPaths;
  std::set<size_t> usedMaps, usedGlobals, usedRecords, usedRings;
  std::vector<std::optional<Special>> special;
  std::set<size_t> badFunctions;
  std::set<int64_t> skippedStatements;
};
bool isSubprogramCall(Consumer &c, Operation *node) {
  auto s = c.subprograms;
  if (!s || !node || text(node, "kind") != "CallNode" || c.ref(node, "receiver")) return false;
  auto found = s->index.find(field(node, "strings", "name").str());
  if (found == s->index.end() || !s->graph.reachable[found->second] ||
      llvm::is_contained(s->roots, found->second)) return false;
  auto owner = c.parent(node);
  while (owner && text(owner, "kind") != "DefNode") owner = c.parent(owner);
  return owner == c.activeDef;
}
namespace {
bool integerSignature(StringRef signature) {
  if (signature.empty()) return true;
  auto split = signature.find(") -> ");
  if (!signature.starts_with("(") || split == StringRef::npos || signature.drop_front(split+5) != "Integer") return false;
  SmallVector<StringRef> parameters;
  auto inner = signature.slice(1,split);
  if (!inner.empty()) inner.split(parameters,", ");
  unsigned special = 0;
  for (auto parameter : parameters) {
    if (parameter == "Integer") continue;
    if (parameter != "MapRef" && parameter != "RecordRef" && parameter != "Window" &&
        parameter != "XdpMd" && parameter != "SkBuff") return false;
    ++special;
  }
  return special <= 1;
}
std::string signatureHint(StringRef signature) {
  if (signature.ends_with("-> untyped"))
    return "; if the last expression is arithmetic on a record member, assign it to a local first (`x = r.load.m & 0xFF` then `x`) (E065)";
  auto split = signature.find(") -> ");
  if (!signature.starts_with("(") || split == StringRef::npos) return {};
  SmallVector<StringRef> parameters;
  signature.slice(1,split).split(parameters,", ");
  unsigned special = 0; bool untyped = false; std::string tracing;
  for (auto p : parameters) {
    if (p == "MapRef" || p == "RecordRef" || p == "Window" || p == "XdpMd" || p == "SkBuff") ++special;
    if (p == "untyped") untyped = true;
    if (p == "FentryCtx" || p == "FexitCtx" || p == "KprobeCtx" || p == "UprobeCtx" ||
        p == "TpBtfCtx" || p == "KretprobeCtx" || p == "UretprobeCtx" || p == "RawTpCtx" ||
        p == "SocketFilterCtx" || p == "TracepointCtx" || p == "KsyscallCtx") tracing = p.str();
  }
  if (!tracing.empty()) return "; the " + tracing + " context is not passed to an eBPF-side function — its reads depend on the attach point (bpf-mlir R051): read the values in the program and pass Integers (E095)";
  if (special > 1) return "; a function takes at most one argument that is not an Integer (a borrowed map value, a checked packet window or a packet context) (E095)";
  if (untyped) return "; an argument has different types at different calls (for example the xdp and the sched_cls context, or a window and an Integer) — pass one type in one place (E095)";
  return {};
}
bool containsBadCall(Consumer &c, Operation *node, llvm::DenseSet<int64_t> &seen) {
  if (!node || !seen.insert(c.id(node)).second) return false;
  auto s = c.subprograms;
  if (text(node,"kind") == "CallNode" && !c.ref(node,"receiver")) {
    auto method = s->index.find(field(node,"strings","name").str());
    if (method != s->index.end() && s->badFunctions.count(method->second)) return true;
  }
  for (auto attr : node->getAttrOfType<DictionaryAttr>("refs")) {
    auto id = cast<IntegerAttr>(attr.getValue()).getInt();
    if (id >= 0 && containsBadCall(c,c.nodes.lookup(id),seen)) return true;
  }
  for (auto attr : node->getAttrOfType<DictionaryAttr>("arrays"))
    for (auto id : cast<ArrayAttr>(attr.getValue()))
      if (containsBadCall(c,c.nodes.lookup(cast<IntegerAttr>(id).getInt()),seen)) return true;
  return false;
}
} // namespace
LogicalResult prepareSubprogramSemantics(Consumer &c) {
  auto s = c.subprograms;
  if (!s) return success();
  for (size_t i : s->graph.callerFirst) {
    const auto &name = s->methods[i].name;
    auto definition = s->definitions[i];
    if (failed(c.known(definition))) return failure();
    auto parameters = c.ref(definition,"parameters");
    std::string message;
    if (!c.array(parameters,"optionals").empty() || !c.array(parameters,"keywords").empty())
      message = "the eBPF-side function `" + name + "` takes only required positional Integer arguments (no optional or keyword arguments) (P023)";
    if (c.ref(parameters,"rest") || c.ref(parameters,"keyword_rest") || c.ref(parameters,"block"))
      message = "the eBPF-side function `" + name + "` takes only required positional Integer arguments (no rest, keyword-rest or block argument) (P023)";
    if (message.empty() && s->parameters[i].size() > 5)
      message = "the eBPF-side function `" + name + "` takes " + std::to_string(s->parameters[i].size()) + " arguments — a BPF subprogram takes at most 5 (P023)";
    auto types = c.types.find(c.id(definition));
    if (message.empty() && types != c.types.end() && types->second.size() == 1) {
      auto signature = text(types->second.front(),"signature");
      if (!integerSignature(signature)) message = "Spinel types the eBPF-side function `" + name + "` as " + signature.str() +
          " — its arguments and its value must be Integer (no true / false, nil or other types)" + signatureHint(signature) + " (P023 E092)";
    }
    if (!message.empty()) {
      (void)c.diagnostic(definition,"SB034","SubprogramShape",message);
      s->badFunctions.insert(i);
    }
  }
  return s->badFunctions.empty() ? success() : c.recoverRejectedProgram("SB034");
}
void prepareSubprogramRecovery(Consumer &c, Operation *statements) {
  auto s = c.subprograms;
  if (!s || s->badFunctions.empty()) return;
  std::function<void(Operation *)> visit = [&](Operation *node) {
    if (!node) return;
    if (text(node,"kind") == "StatementsNode") {
      for (auto statement : c.array(node,"body")) {
        auto kind = text(statement,"kind");
        llvm::DenseSet<int64_t> seen;
        auto expression = (kind == "IfNode" || kind == "UnlessNode") ? c.ref(statement,"predicate") : statement;
        if (containsBadCall(c,expression,seen)) {
          s->skippedStatements.insert(c.id(statement));
          if (kind == "IfNode" || kind == "UnlessNode") c.recoverySkipped.insert(c.id(statement));
          continue;
        }
        visit(statement);
      }
      return;
    }
    for (auto attr : node->getAttrOfType<DictionaryAttr>("refs")) {
      auto id = cast<IntegerAttr>(attr.getValue()).getInt();
      if (id >= 0) visit(c.nodes.lookup(id));
    }
  };
  visit(statements);
}
bool skipRejectedSubprogramStatement(Consumer &c, Operation *node) {
  return c.subprograms && c.subprograms->skippedStatements.count(c.id(node));
}

namespace {
FailureOr<size_t> activeFunction(Consumer &c) {
  auto s = c.subprograms;
  if (s)
    for (size_t i = 0; i < s->definitions.size(); ++i)
      if (s->definitions[i] == c.activeDef) return i;
  (void)c.error(c.activeDef, "subprogram flow has no active declared function");
  return failure();
}
FailureOr<subprogram::FlowSource> flowSource(Consumer &c, size_t owner,
                                           ArrayRef<ReadOrigin> reads) {
  subprogram::FlowSource result;
  for (const auto &read : reads) {
    switch (read.domain) {
    case ReadOrigin::Domain::Map:
      if (read.map >= c.maps.size()) {
        (void)c.error(c.activeDef, "subprogram read map index is invalid");
        return failure();
      }
      result.objects.insert({subprogram::Object::Domain::Map, read.map});
      break;
    case ReadOrigin::Domain::Global:
      if (read.map >= c.globals.size()) {
        (void)c.error(c.activeDef, "subprogram read global index is invalid");
        return failure();
      }
      result.objects.insert({subprogram::Object::Domain::Global, read.map});
      break;
    case ReadOrigin::Domain::Parameter: {
      auto found = c.subprograms->parameterTokens.find(read.token);
      if (found == c.subprograms->parameterTokens.end() || found->second.first != owner) {
        (void)c.error(c.activeDef, "subprogram parameter provenance token is invalid");
        return failure();
      }
      result.parameters.insert(found->second.second);
      break;
    }
    case ReadOrigin::Domain::CallResult: {
      // The call can be checked after origins() observes its source node.
      // resolveFlows subsequently requires this exact token to have a site.
      auto node = c.nodes.lookup(read.token);
      auto definition = node ? c.parent(node) : nullptr;
      while (definition && text(definition, "kind") != "DefNode")
        definition = c.parent(definition);
      auto callee = node ? c.subprograms->index.find(field(node, "strings", "name").str())
                         : c.subprograms->index.end();
      if (!node || text(node, "kind") != "CallNode" || c.ref(node, "receiver") ||
          definition != c.subprograms->definitions[owner] ||
          callee == c.subprograms->index.end() ||
          !c.subprograms->graph.reachable[callee->second] ||
          llvm::is_contained(c.subprograms->roots, callee->second)) {
        (void)c.error(c.activeDef, "subprogram call-result provenance token is invalid");
        return failure();
      }
      result.returns.insert(read.token);
      break;
    }
    }
  }
  return result;
}
struct CheckedCall : Payload {
  size_t callee = 0;
};
std::string ringPath(Consumer &c, size_t method, std::set<size_t> &seen) {
  if (!seen.insert(method).second) return {};
  auto s = c.subprograms;
  std::string result;
  std::function<void(Operation *)> visit = [&](Operation *node) {
    if (!node || !result.empty()) return;
    if (text(node,"kind") == "CallNode") {
      auto name = field(node,"strings","name");
      auto receiver = c.constant(c.ref(node,"receiver"));
      if ((name == "output" || name == "output_str") &&
          llvm::any_of(c.rings,[&](const auto &ring) { return ring.constant == receiver; })) {
        result = s->methods[method].name + " → " + receiver + "." + name.str();
        return;
      }
      if (!c.ref(node,"receiver")) {
        auto next = s->index.find(name.str());
        if (next != s->index.end()) {
          auto path = ringPath(c,next->second,seen);
          if (!path.empty()) { result = s->methods[method].name + " → " + path; return; }
        }
      }
    }
    for (auto attr : node->getAttrOfType<DictionaryAttr>("refs")) {
      auto id = cast<IntegerAttr>(attr.getValue()).getInt();
      if (id >= 0) visit(c.nodes.lookup(id));
    }
    for (auto attr : node->getAttrOfType<DictionaryAttr>("arrays"))
      for (auto id : cast<ArrayAttr>(attr.getValue())) visit(c.nodes.lookup(cast<IntegerAttr>(id).getInt()));
  };
  visit(c.ref(s->definitions[method],"body"));
  return result;
}
Dispatch<Expr> call(Consumer &c, Operation *node) {
  auto s = c.subprograms;
  if (!s || c.ref(node, "receiver")) return Dispatch<Expr>::declined();
  auto found = s->index.find(field(node, "strings", "name").str());
  if (found == s->index.end() ||
      std::find(s->roots.begin(), s->roots.end(), found->second) != s->roots.end())
    return Dispatch<Expr>::declined();
  const size_t callee = found->second;
  if (c.registry.packetSubprogram && (!c.registry.packetSubprogram->checkedWindow ||
                                     !c.registry.packetSubprogram->enter))
    return (void)c.error(node,"subprogram packet hooks are incomplete"), Dispatch<Expr>::error();
  const auto &name = s->methods[callee].name;
  for (auto parent = c.parent(node); parent && parent != c.activeDef; parent = c.parent(parent)) {
    if (!loops::isIterator(c,parent)) continue;
    std::set<size_t> seen;
    auto path = ringPath(c,callee,seen);
    if (!path.empty())
      return (void)c.diagnostic(node,"SB030","LoopShape","`" + name +
          "` is called inside a loop and reaches a ring buffer output (" + path +
          ") — bpf-mlir's ebpf.loop body cannot reach a ring buffer op through a call (E047); output after the loop (P023 E092)",true), Dispatch<Expr>::error();
    break;
  }
  auto arguments = c.args(node);
  auto refuse = [&](const std::string &message) {
    (void)c.diagnostic(node, "SB034", "SubprogramShape", message, true);
    return Dispatch<Expr>::error();
  };
  if (c.ref(node, "block"))
    return refuse("a call of the eBPF-side function `" + name + "` takes no block (P023)");
  if (arguments.size() != s->parameters[callee].size())
    return refuse("`" + name + "` takes " + std::to_string(s->parameters[callee].size()) +
                  " arguments, called with " + std::to_string(arguments.size()) + " (P023)");
  if (failed(c.known(node, CalleePolicy{name}))) return Dispatch<Expr>::error();
  auto e = std::make_shared<ScalarExpr>();
  e->node = node;
  e->kind = "subprogram.call";
  e->name = name;
  e->range.interval = math::MathInterval(math::Interval::fullI64());
  auto payload = std::make_shared<CheckedCall>();
  payload->callee = callee;
  e->payload = payload;
  std::optional<SubprogramState::Special> special;
  for (size_t i = 0; i < arguments.size(); ++i) {
    auto argument = arguments[i];
    if (text(argument,"kind") == "LocalVariableReadNode") {
      auto local = field(argument,"strings","name").str();
      std::optional<Borrow> borrowed;
      if (auto found = c.borrows.find(local); found != c.borrows.end())
        borrowed = found->second;
      auto window = c.registry.packetSubprogram
          ? c.registry.packetSubprogram->checkedWindow(c,local) : Dispatch<int64_t>::declined();
      if (window.state == Disposition::Error) return Dispatch<Expr>::error();
      auto owner = activeFunction(c);
      if (failed(owner)) return Dispatch<Expr>::error();
      bool root = llvm::is_contained(s->roots,*owner);
      auto ownerSpecial = s->special[*owner];
      bool context = root ? (!s->parameters[*owner].empty() && local == s->parameters[*owner][0])
          : (ownerSpecial && ownerSpecial->kind == SubprogramState::Special::Context &&
             local == s->parameters[*owner][ownerSpecial->index]);
      if (borrowed || window.state == Disposition::Handled || context) {
        if (special) return refuse("`" + name + "` takes at most one argument that is not an Integer (a borrowed map value, a checked packet window or the context) (P023 E095)");
        auto value = std::make_shared<ScalarExpr>();
        value->node = argument; value->name = local;
        SubprogramState::Special descriptor;
        descriptor.index = i;
        if (window.state == Disposition::Handled) {
          if (!root && ownerSpecial && ownerSpecial->kind == SubprogramState::Special::Window &&
              local == s->parameters[*owner][ownerSpecial->index])
            return (void)c.diagnostic(argument,"SB034","SubprogramShape","the window argument `" + local + "` is not forwarded to another eBPF-side function in this stage — read it here (P023 E095)",true), Dispatch<Expr>::error();
          descriptor.kind = SubprogramState::Special::Window; descriptor.length = *window.value;
          value->kind = "subprogram.window"; value->literal = descriptor.length;
        } else if (context) {
          if (!root) return (void)c.diagnostic(argument,"SB034","SubprogramShape","the context argument `" + local + "` is not forwarded to another eBPF-side function in this stage — check the packet here (P023 E095)",true), Dispatch<Expr>::error();
          if (c.activeKind != "xdp" && c.activeKind != "sched_cls")
            return (void)c.diagnostic(argument,"SB034","SubprogramShape","the " + c.activeKind + " context is not passed to an eBPF-side function — its reads depend on the attach point (bpf-mlir R051); read the values in the program and pass Integers (P023 E095)",true), Dispatch<Expr>::error();
          descriptor.kind = SubprogramState::Special::Context; descriptor.context = c.activeKind;
          value->kind = "subprogram.context";
        } else {
          if (!root && ownerSpecial && ownerSpecial->kind == SubprogramState::Special::Borrowed &&
              local == s->parameters[*owner][ownerSpecial->index])
            return (void)c.diagnostic(argument,"SB034","SubprogramShape","the borrowed argument `" + local + "` is not forwarded to another eBPF-side function in this stage — do the access here (P023 E094)",true), Dispatch<Expr>::error();
          descriptor.kind = SubprogramState::Special::Borrowed; descriptor.map = borrowed->map;
          value->kind = "subprogram.borrow"; value->map = descriptor.map;
        }
        if (auto old = s->special[callee]) {
          if (old->kind != descriptor.kind || old->index != descriptor.index || old->map != descriptor.map ||
              old->length != descriptor.length || old->context != descriptor.context) {
            std::string message;
            if (old->kind == descriptor.kind && descriptor.kind == SubprogramState::Special::Borrowed)
              message = "`" + name + "` is called with a borrowed value of " + c.maps[descriptor.map].name +
                  " as argument " + std::to_string(i+1) + ", but another call passes " + c.maps[old->map].name +
                  " as argument " + std::to_string(old->index+1) + " — every call passes the same map value in the same place (P023 E094)";
            else if (old->kind == descriptor.kind && descriptor.kind == SubprogramState::Special::Window)
              message = "`" + name + "` is called with a " + std::to_string(descriptor.length) +
                  "-byte window as argument " + std::to_string(i+1) + ", but another call passes a " +
                  std::to_string(old->length) + "-byte window as argument " + std::to_string(old->index+1) +
                  " — every call passes the same window length in the same place (P023 E095)";
            else if (old->kind == descriptor.kind && descriptor.kind == SubprogramState::Special::Context)
              message = "`" + name + "` is called with the " + descriptor.context + " context as argument " +
                  std::to_string(i+1) + ", but another call passes the " + old->context + " context as argument " +
                  std::to_string(old->index+1) + " — one function takes one kind of context in one place (P023 E095)";
            else return (void)c.error(argument,"subprogram special argument kind differs despite its checked signature"), Dispatch<Expr>::error();
            return (void)c.diagnostic(argument,"SB034","SubprogramShape",message,true), Dispatch<Expr>::error();
          }
        }
        special = descriptor;
        e->args.push_back(value);
        continue;
      }
      // A nullable lookup local does not become a scalar outside its guard.
      // Restrict this proof to a declared scalar map in this exact method.
      if (!c.locals.count(local)) {
        for (const auto &[id, candidate] : c.nodes) {
          if (text(candidate,"kind") != "LocalVariableWriteNode" ||
              field(candidate,"strings","name") != local) continue;
          auto ownerDef = c.parent(candidate);
          while (ownerDef && text(ownerDef,"kind") != "DefNode") ownerDef = c.parent(ownerDef);
          if (ownerDef != c.activeDef) continue;
          auto lookup = c.ref(candidate,"value");
          if (text(lookup,"kind") != "CallNode" || field(lookup,"strings","name") != "lookup") continue;
          auto mapName = c.constant(c.ref(lookup,"receiver"));
          auto map = llvm::find_if(c.maps,[&](const auto &m) { return m.name == mapName; });
          if (map == c.maps.end() || !map->valueRecord.empty()) continue;
          size_t mapIndex = map - c.maps.begin();
          if (failed(c.knownMap(lookup,mapIndex))) return Dispatch<Expr>::error();
          return (void)c.diagnostic(argument,"SB005","RefCheckShape","`" + local +
              "` may be read only as `if " + local + "` and as `" + local +
              ".load` / `" + local + ".atomic_add(d)` inside it",true), Dispatch<Expr>::error();
        }
      }
    }
    auto value = c.scalar(arguments[i]);
    if (failed(value)) return Dispatch<Expr>::error();
    if ((*value)->range.isBool) {
      (void)c.diagnostic(arguments[i], "SB034", "SubprogramShape",
          "argument " + std::to_string(i + 1) + " of `" + name +
          "` is true / false — an eBPF-side function takes Integer arguments (P023)", true);
      return Dispatch<Expr>::error();
    }
    if ((*value)->range.wide) {
      auto finite = (*value)->range.interval.finite();
      if (!finite) {
        llvm::consumeError(finite.takeError());
        (void)c.error(arguments[i], "subprogram argument range is not finite");
        return Dispatch<Expr>::error();
      }
      (void)c.diagnostic(arguments[i], "SB014", "SemanticGap",
          "argument " + std::to_string(i + 1) + " of `" + name +
          "` is a u64 value " + finite->str() +
          " that does not fit Ruby's Integer — narrow it first (`x & M` or `x >> K`) (P023)", true);
      return Dispatch<Expr>::error();
    }
    e->args.push_back(*value);
  }
  e->reads.push_back({0, std::nullopt, {}, ReadOrigin::Domain::CallResult, c.id(node)});
  if (!c.probing) {
    auto owner = activeFunction(c);
    if (failed(owner)) return Dispatch<Expr>::error();
    subprogram::CallSite site{c.id(node), callee, {}};
    for (const auto &argument : e->args) {
      auto source = flowSource(c, *owner, argument->reads);
      if (failed(source)) return Dispatch<Expr>::error();
      site.arguments.push_back(std::move(*source));
    }
    auto &sites = s->flows[*owner].sites;
    auto existing = llvm::find_if(sites, [&](const auto &old) { return old.id == site.id; });
    if (existing == sites.end()) sites.push_back(std::move(site));
    else *existing = std::move(site);
    s->flowPaths[c.id(node)] = c.activeDiagnosticPath.empty()
        ? std::vector<std::string>{c.programName} : c.activeDiagnosticPath;
    if (special) s->special[callee] = special;
    for (size_t i = 0; i < e->args.size(); ++i)
      if (!special || i != special->index)
        s->argumentHulls[callee][i] = math::MathInterval::join(s->argumentHulls[callee][i], e->args[i]->range.interval);
    s->checkedCalls[c.id(node)] = e;
  }
  return Dispatch<Expr>::handled(e);
}
Dispatch<Value> emitCall(Consumer &c, const Expr &e) {
  if (!c.subprograms || !e->payload)
    return (void)c.error(e->node, "checked subprogram call state is missing"), Dispatch<Value>::error();
  const auto &call = static_cast<const CheckedCall &>(*e->payload);
  if (call.callee >= c.subprograms->methods.size() ||
      e->name != c.subprograms->methods[call.callee].name)
    return (void)c.error(e->node, "checked subprogram call target differs"), Dispatch<Value>::error();
  SmallVector<Value> arguments;
  for (const auto &argument : e->args) {
    if (argument->kind == "subprogram.borrow") {
      auto borrow = c.borrows.find(argument->name);
      if (borrow == c.borrows.end() || borrow->second.map != argument->map || !borrow->second.value)
        return (void)c.error(argument->node,"subprogram borrowed argument is not active"), Dispatch<Value>::error();
      arguments.push_back(borrow->second.value); continue;
    }
    if (argument->kind == "subprogram.window") {
      auto binding = c.bindings.find("packet:"+argument->name);
      if (binding == c.bindings.end() || !binding->second.value ||
          binding->second.value.getType() != ebpf::PktWindowType::get(c.ctx,argument->literal))
        return (void)c.error(argument->node,"subprogram window argument is not active"), Dispatch<Value>::error();
      arguments.push_back(binding->second.value); continue;
    }
    if (argument->kind == "subprogram.context") {
      if (!c.contextValue) return (void)c.error(argument->node,"subprogram context argument is not active"), Dispatch<Value>::error();
      arguments.push_back(c.contextValue); continue;
    }
    auto value = c.emitScalar(argument);
    if (!value || !value.getType().isInteger(64))
      return (void)c.error(e->node, "subprogram Integer operand is not i64"), Dispatch<Value>::error();
    arguments.push_back(value);
  }
  auto op = ebpf::CallOp::create(c.builder, outputLoc(e->node),
      TypeRange{c.builder.getI64Type()}, e->name, arguments);
  return Dispatch<Value>::handled(op.getResult(0));
}
Dispatch<StatementResult> callStatement(Consumer &c, ArrayRef<Operation *> statements,
                                        size_t index, unsigned) {
  auto checked = call(c, statements[index]);
  if (checked.state == Disposition::Declined)
    return Dispatch<StatementResult>::declined();
  if (checked.state == Disposition::Error)
    return Dispatch<StatementResult>::error();
  if (!c.probing && !c.emitScalar(*checked.value))
    return Dispatch<StatementResult>::error();
  return Dispatch<StatementResult>::handled({1});
}
} // namespace
LogicalResult checkSubprogramLoopCall(Consumer &c, Operation *node) {
  if (!isSubprogramCall(c,node)) return success();
  auto found = c.subprograms->index.find(field(node,"strings","name").str());
  std::set<size_t> seen;
  auto path = ringPath(c,found->second,seen);
  if (path.empty()) return success();
  return c.diagnostic(node,"SB030","LoopShape","`" + found->first +
      "` is called inside a loop and reaches a ring buffer output (" + path +
      ") — bpf-mlir's ebpf.loop body cannot reach a ring buffer op through a call (E047); output after the loop (P023 E092)",true);
}
LogicalResult collectSubprogramMaps(Consumer &c, Operation *definition) {
  if (!definition || text(definition, "kind") != "DefNode")
    return c.error(definition, "direct map collection requires a method definition");
  llvm::DenseSet<int64_t> visited;
  std::function<void(Operation *)> visit = [&](Operation *node) {
    if (!node || c.recoverySkipped.count(c.id(node)) ||
        !visited.insert(c.id(node)).second || text(node, "kind") == "DefNode") return;
    const auto name = c.constant(node);
    for (auto &map : c.maps)
      if (map.name == name) map.used = true;
    for (auto attribute : node->getAttrOfType<DictionaryAttr>("refs")) {
      auto id = cast<IntegerAttr>(attribute.getValue()).getInt();
      if (id >= 0) visit(c.nodes.lookup(id));
    }
    for (auto attribute : node->getAttrOfType<DictionaryAttr>("arrays"))
      for (auto id : cast<ArrayAttr>(attribute.getValue()))
        visit(c.nodes.lookup(cast<IntegerAttr>(id).getInt()));
  };
  visit(c.ref(definition, "body"));
  return success();
}
LogicalResult noteSubprogramWrite(Consumer &c, Operation *write,
                                 ReadOrigin destination,
                                 ArrayRef<ReadOrigin> reads) {
  if (!c.subprograms || c.probing) return success();
  auto owner = activeFunction(c);
  if (failed(owner)) return failure();
  auto source = flowSource(c, *owner, reads);
  if (failed(source)) return failure();
  subprogram::Object object;
  if (destination.domain == ReadOrigin::Domain::Map && destination.map < c.maps.size())
    object = {subprogram::Object::Domain::Map, destination.map};
  else if (destination.domain == ReadOrigin::Domain::Global && destination.map < c.globals.size())
    object = {subprogram::Object::Domain::Global, destination.map};
  else return c.error(write, "subprogram write destination is not a declared map or global");
  auto &flows = c.subprograms->flows[*owner].flows;
  subprogram::Flow flow{c.id(write), std::move(*source), false, object};
  auto existing = llvm::find_if(flows, [&](const auto &old) {
    return !old.isReturn && old.node == flow.node;
  });
  if (existing == flows.end()) flows.push_back(std::move(flow));
  else *existing = std::move(flow);
  c.subprograms->flowPaths[c.id(write)] = c.activeDiagnosticPath.empty()
      ? std::vector<std::string>{c.programName} : c.activeDiagnosticPath;
  return success();
}
namespace {
LogicalResult emitIntegerFunction(Consumer &c, size_t index, ModuleOp staging) {
  auto s = c.subprograms;
  auto definition = s->definitions[index];
  auto special = s->special[index];
  const auto &name = s->methods[index].name;
  ScopeGuard scope(c);
  auto savedName = c.programName;
  auto savedPath = c.activeDiagnosticPath;
  SmallVector<Value> savedMaps;
  for (const auto &map : c.maps) savedMaps.push_back(map.value);
  auto restore = llvm::scope_exit([&] {
    c.programName = savedName;
    c.activeDiagnosticPath = savedPath;
    for (size_t i = 0; i < savedMaps.size(); ++i) c.maps[i].value = savedMaps[i];
  });
  c.activeDef = definition;
  c.activeKind = special && special->kind == SubprogramState::Special::Context ? special->context : "func";
  c.programName = name;
  c.activeDiagnosticPath = s->paths[index];
  c.contextValue = {};
  c.locals.clear(); c.borrows.clear(); c.bindings.clear();
  c.environment.clear(); c.frames.clear();
  auto reject = [&](Operation *node, const std::string &message) {
    return c.diagnostic(node, "SB034", "SubprogramShape", message, true);
  };
  auto body = c.ref(definition, "body");
  if (body && text(body, "kind") != "StatementsNode")
    return reject(body, "the body of the eBPF-side function `" + name +
        "` must be a plain sequence of statements (no rescue / ensure) (P023)");
  auto statements = c.array(body, "body");
  if (statements.empty())
    return reject(definition, "the eBPF-side function `" + name +
        "` must end with an Integer expression (its value) (P023)");
  Operation *forbidden = nullptr;
  std::string forbiddenMessage;
  llvm::DenseSet<int64_t> visited;
  std::function<void(Operation *)> inspect = [&](Operation *node) {
    if (!node || forbidden || !visited.insert(c.id(node)).second) return;
    if (text(node,"kind") == "ReturnNode") {
      forbidden = node;
      forbiddenMessage = "`return` is not accepted in the eBPF-side function `" + name +
          "` — its last expression is its value (use if / else) (P023 E092)";
      return;
    }
    auto constant = c.constant(node);
    if (text(node,"kind") == "ConstantPathNode" &&
        (StringRef(constant).starts_with("BPF::XDP_") || StringRef(constant).starts_with("BPF::TC_") ||
         StringRef(constant).starts_with("BPF::FLOW_") || StringRef(constant).starts_with("BPF::CG_"))) {
      forbidden = node;
      forbiddenMessage = constant + " is a program verdict — an eBPF-side function returns an Integer; return the verdict from the program (P023)";
      return;
    }
    for (auto attr : node->getAttrOfType<DictionaryAttr>("refs")) {
      auto id = cast<IntegerAttr>(attr.getValue()).getInt();
      if (id >= 0) inspect(c.nodes.lookup(id));
    }
    for (auto attr : node->getAttrOfType<DictionaryAttr>("arrays"))
      for (auto id : cast<ArrayAttr>(attr.getValue())) inspect(c.nodes.lookup(cast<IntegerAttr>(id).getInt()));
  };
  inspect(body);
  if (forbidden) return reject(forbidden,forbiddenMessage);
  auto last = statements.back();
  auto lastKind = text(last,"kind");
  if (lastKind == "LocalVariableWriteNode" || lastKind == "IfNode" || lastKind == "UnlessNode" ||
      lastKind == "WhileNode" || lastKind == "UntilNode" || lastKind == "CaseNode" ||
      lastKind == "MultiWriteNode" || lastKind == "LocalVariableOperatorWriteNode")
    return reject(last,"the last statement of the eBPF-side function `" + name +
        "` must be an Integer expression (its value), not " + lastKind.str() + " (P023 E092)");
  if (lastKind == "CallNode" && text(c.ref(last,"receiver"),"kind") == "ConstantReadNode") {
    auto receiver = c.constant(c.ref(last,"receiver"));
    auto method = field(last,"strings","name");
    bool map = llvm::any_of(c.maps,[&](const auto &m) { return m.name == receiver; });
    bool global = llvm::any_of(c.globals,[&](const auto &g) { return g.name == receiver; });
    if ((map && (method == "update" || method == "atomic_add")) || (global && method == "add"))
      return reject(last,"the last statement of the eBPF-side function `" + name +
          "` must be an Integer expression (its value), not the map / global call `" + method.str() + "` (P023 E092)");
  }
  for (auto &map : c.maps) map.used = false;
  if (failed(collectSubprogramMaps(c, definition))) return failure();
  SmallVector<Attribute> symbols;
  SmallVector<Type> arguments(s->parameters[index].size(), c.builder.getI64Type());
  if (special) {
    if (special->kind == SubprogramState::Special::Window)
      arguments[special->index] = ebpf::PktWindowType::get(c.ctx,special->length);
    else if (special->kind == SubprogramState::Special::Context)
      arguments[special->index] = ebpf::ContextType::get(c.ctx,special->context);
    else {
      if (special->map >= c.maps.size()) return c.error(definition,"subprogram borrowed map is invalid");
      const auto &map = c.maps[special->map];
      arguments[special->index] = ebpf::BorrowedType::get(c.ctx,
          map.valueType ? map.valueType : c.builder.getIntegerType(map.bits));
    }
  }
  for (const auto &map : c.maps)
    if (map.used) symbols.push_back(FlatSymbolRefAttr::get(c.ctx, map.name));
  c.builder.setInsertionPointToEnd(staging.getBody());
  auto function = ebpf::SubprogramOp::create(c.builder, outputLoc(definition), name,
      "static", c.builder.getFunctionType(arguments, {c.builder.getI64Type()}),
      symbols.empty() ? ArrayAttr{} : c.builder.getArrayAttr(symbols));
  auto block = new Block();
  function.getBody().push_back(block);
  auto required = c.array(c.ref(definition, "parameters"), "requireds");
  std::optional<PacketFunctionWindow> window;
  std::string contextParameter;
  for (size_t i = 0; i < required.size(); ++i) {
    auto value = block->addArgument(arguments[i], c.builder.getUnknownLoc());
    if (special && special->index == i) {
      const auto &name = s->parameters[index][i];
      if (special->kind == SubprogramState::Special::Borrowed)
        c.borrows[name] = {special->map,std::nullopt,value};
      else if (special->kind == SubprogramState::Special::Window)
        window = PacketFunctionWindow{name,special->length,value};
      else { c.contextValue = value; contextParameter = name; }
      continue;
    }
    auto parameter = std::make_shared<ScalarExpr>();
    parameter->node = required[i];
    parameter->kind = "local";
    parameter->name = s->parameters[index][i];
    parameter->range.interval = s->argumentHulls[index][i];
#ifdef SPINEL_E019_TEST_FULL_HULL
    parameter->range.interval = math::MathInterval(math::Interval::fullI64());
#endif
    if (parameter->range.interval.getState() != math::State::Finite)
      return c.error(required[i], "subprogram argument hull was not established by its callers");
    parameter->reads.push_back({0, std::nullopt, {}, ReadOrigin::Domain::Parameter, c.id(required[i])});
    c.locals[parameter->name] = {parameter, value};
  }
  for (auto &map : c.maps)
    if (map.used)
      map.value = block->addArgument(map.mapType ? map.mapType : ebpf::MapType::get(
          c.ctx, map.kind, map.keyType ? map.keyType : c.builder.getIntegerType(map.keyBits),
          map.valueType ? map.valueType : c.builder.getIntegerType(map.bits)),
          c.builder.getUnknownLoc());
  c.builder.setInsertionPointToStart(block);
  std::unique_ptr<PacketSubprogramScope> packetScope;
  if (c.registry.packetSubprogram) {
    if (!c.registry.packetSubprogram->checkedWindow || !c.registry.packetSubprogram->enter)
      return c.error(definition,"subprogram packet hooks are incomplete");
    auto entered = c.registry.packetSubprogram->enter(c,definition,contextParameter,window);
    if (!entered) return c.rangeFailure(entered.takeError(),definition);
    if (!*entered) return c.error(definition,"subprogram packet scope is null");
    packetScope = std::move(*entered);
  } else if (window || !contextParameter.empty())
    return c.error(definition,"subprogram packet hooks are missing");
  if (failed(c.scalarStatements(ArrayRef<Operation *>(statements).drop_back()))) return failure();
  auto result = c.scalar(last);
  if (failed(result)) return failure();
  if ((*result)->range.isBool)
    return reject(last, "the eBPF-side function `" + name +
        "` returns true / false — it returns an Integer (P023)");
  if ((*result)->range.wide)
    return c.diagnostic(last, "SB014", "SemanticGap", "the eBPF-side function `" + name +
        "` returns a u64 value that does not fit Ruby's Integer — narrow it first (`x & M` or `x >> K`) (P023)", true);
  auto source = flowSource(c, index, (*result)->reads);
  if (failed(source)) return failure();
  s->flows[index].flows.push_back({c.id(last), std::move(*source), true, {}});
  auto value = c.emitScalar(*result);
  if (!value) return failure();
  ebpf::ReturnOp::create(c.builder, outputLoc(last), value);
  for (size_t i = 0; i < c.maps.size(); ++i) if (c.maps[i].used) s->usedMaps.insert(i);
  for (size_t i = 0; i < c.globals.size(); ++i) if (c.globals[i].used) s->usedGlobals.insert(i);
  for (size_t i = 0; i < c.records.size(); ++i) if (c.records[i].used) s->usedRecords.insert(i);
  for (size_t i = 0; i < c.rings.size(); ++i) if (c.rings[i].used) s->usedRings.insert(i);
  s->emittedFunctions[index] = function;
  return success();
}
} // namespace
LogicalResult analyzeSubprograms(Consumer &c, ModuleOp staging) {
  auto s = c.subprograms;
  if (!s) return success();
  auto preserveUsage = llvm::scope_exit([&] {
    for (size_t i : s->usedMaps) c.maps[i].used = true;
    for (size_t i : s->usedGlobals) c.globals[i].used = true;
    for (size_t i : s->usedRecords) c.records[i].used = true;
    for (size_t i : s->usedRings) c.rings[i].used = true;
  });
  for (size_t index : s->graph.callerFirst)
    if (failed(emitIntegerFunction(c, index, staging))) return failure();
  std::set<subprogram::Object> exemptions;
  if (!c.programs.empty() && llvm::all_of(c.programs, [](const auto &p) { return p.kind == "xdp"; }))
    for (size_t i = 0; i < c.maps.size(); ++i)
      if (c.maps[i].kind == "percpu_array" || c.maps[i].kind == "percpu_hash")
        exemptions.insert({subprogram::Object::Domain::Map, i});
  auto flows = s->flows;
#ifdef SPINEL_E019_TEST_NO_SUMMARY
  for (auto index : s->graph.callerFirst) flows[index].flows.clear();
#endif
  auto resolved = subprogram::resolveFlows(flows, s->graph.callerFirst, s->roots, exemptions);
  if (!resolved.error.empty()) return c.error(c.activeDef, resolved.error);
  auto objectName = [&](const subprogram::Object &object) {
    return object.domain == subprogram::Object::Domain::Map
        ? c.maps[object.index].name : "Counter " + c.globals[object.index].name;
  };
  for (const auto &issue : resolved.issues) {
    auto node = c.nodes.lookup(issue.node);
    auto object = objectName(issue.object);
    std::string message;
    if (issue.kind == subprogram::FlowIssue::Kind::ArgumentWrite) {
      auto &sites = s->flows[issue.caller].sites;
      auto site = llvm::find_if(sites, [&](const auto &item) { return item.id == issue.node; });
      if (site == sites.end()) return c.error(node, "resolved subprogram issue has no call site");
      auto name = s->methods[site->callee].name;
      message = "`" + name + "(…)` argument " + std::to_string(issue.argument + 1) +
          " carries a value read from " + object + ", and `" + name + "` writes " + object +
          " — concurrent CPUs lose updates across the call; use atomic_add on the entry with a delta that does not read it (P023 E092)";
    } else message = "the value written to " + object +
        " comes from an eBPF-side function that reads " + object +
        " — concurrent CPUs lose updates across the call; use atomic_add on the entry with a delta that does not read it (P023 E092)";
    (void)c.diagnosticWithPath(node, "SB019", "SharedReadModifyWrite", message,
                              s->flowPaths[issue.node]);
  }
  if (!resolved.issues.empty()) return failure();
  // Analysis is caller-first; the public IR is always declaration-first.
  Operation *before = staging.getBody()->empty() ? nullptr : &staging.getBody()->front();
  for (auto function : s->emittedFunctions)
    if (function && before && function != before) function->moveBefore(before);
  return success();
}
void registerSubprograms(Registry &registry) {
  registry.addExpression("CallNode", call);
  registry.addStatement("CallNode", callStatement);
  registry.addEmitter("subprogram.call", emitCall);
  registry.addRMWExemption([](const Consumer &c,const ReadOrigin &read,size_t map) {
    auto s = c.subprograms;
    if (!s || read.domain != ReadOrigin::Domain::Map || read.map != map || map >= c.maps.size() ||
        c.programs.empty() || !llvm::all_of(c.programs,[](const auto &p) { return p.kind == "xdp"; })) return false;
    for (size_t i : s->graph.callerFirst)
      if (s->definitions[i] == c.activeDef)
        return c.maps[map].kind == "percpu_array" || c.maps[map].kind == "percpu_hash";
    return false;
  });
}

LogicalResult prepareSubprograms(Consumer &c, ArrayRef<Operation *> top,
                                ArrayRef<Operation *> rootEntries) {
  c.subprograms.reset();
  if (rootEntries.empty()) return success();
  auto state = std::make_shared<SubprogramState>();
  auto file = rootEntries.front()->getAttr("file_id");
  for (auto node : top) {
    if (node->getAttr("file_id") != file || text(node, "kind") != "DefNode" ||
        c.ref(node, "receiver")) continue;
    auto name = field(node, "strings", "name").str();
    if (!state->index.emplace(name, state->methods.size()).second)
      return c.error(node, "duplicate method declaration");
    state->definitions.push_back(node);
    state->methods.push_back({name, {}});
  }
  std::set<size_t> roots;
  for (auto entry : rootEntries) {
    auto args = c.args(entry);
    if (args.empty() || text(args[0], "kind") != "SymbolNode")
      return c.error(entry, "subprogram graph requires explicit root symbol");
    auto found = state->index.find(c.spelling(args[0], true).str());
    if (found == state->index.end())
      return c.error(entry, "root target must be a declared method");
    if (!roots.insert(found->second).second)
      return c.error(entry, "duplicate analysis root");
    state->roots.push_back(found->second);
  }
  for (size_t i = 0; i < state->methods.size(); ++i) {
    llvm::DenseSet<int64_t> seen;
    std::function<void(Operation *)> visit = [&](Operation *node) {
      if (!node || !seen.insert(c.id(node)).second || text(node, "kind") == "DefNode") return;
      if (text(node, "kind") == "CallNode" && !c.ref(node, "receiver")) {
        auto callee = state->index.find(field(node, "strings", "name").str());
        if (callee != state->index.end() && !roots.count(callee->second))
          state->methods[i].callees.push_back(callee->second);
      }
      for (auto item : node->getAttrOfType<DictionaryAttr>("refs")) {
        int64_t id = cast<IntegerAttr>(item.getValue()).getInt();
        if (id >= 0) visit(c.nodes.lookup(id));
      }
      for (auto item : node->getAttrOfType<DictionaryAttr>("arrays"))
        for (auto id : cast<ArrayAttr>(item.getValue()))
          visit(c.nodes.lookup(cast<IntegerAttr>(id).getInt()));
    };
    visit(c.ref(state->definitions[i], "body"));
  }
  state->graph = subprogram::analyzeGraph(state->methods, state->roots);
  if (!state->graph.error.empty())
    return c.error(rootEntries.front(), state->graph.error);
  for (const auto &cycle : state->graph.cycles) {
    std::vector<std::string> path;
    for (size_t i : cycle.path) path.push_back(state->methods[i].name);
    std::string message;
    for (size_t i : cycle.cycle) {
      if (!message.empty()) message += " → ";
      message += state->methods[i].name;
    }
    (void)c.diagnosticWithPath(state->definitions[cycle.cycle.front()], "SB035", "Recursion",
        "recursion is not accepted on the eBPF side: " + message +
        " (BPF subprograms are non-recursive) (P023)", path);
  }
  if (!state->graph.cycles.empty()) {
    if (c.inspectionOutput && !c.probing) {
      c.inspectionGraphAvailable = true;
      c.snapshotDomainGraph(rootEntries);
    }
    return failure();
  }

  std::set<Operation *> selected(c.selectedTop.begin(), c.selectedTop.end());
  for (size_t i = 0; i < state->definitions.size(); ++i)
    if (state->graph.reachable[i] && !roots.count(i) &&
        selected.insert(state->definitions[i]).second)
      c.selectedTop.push_back(state->definitions[i]);
  if (!state->graph.callerFirst.empty()) {
    state->flows.resize(state->methods.size());
    state->emittedFunctions.resize(state->methods.size());
    state->special.resize(state->methods.size());
    state->paths.resize(state->methods.size());
    std::function<void(size_t, std::vector<std::string>)> path =
        [&](size_t index, std::vector<std::string> prefix) {
      if (!state->paths[index].empty()) return;
      prefix.push_back(state->methods[index].name);
      state->paths[index] = prefix;
      for (auto callee : state->methods[index].callees) path(callee, prefix);
    };
    for (auto root : state->roots) path(root, {});
    state->parameters.resize(state->methods.size());
    state->argumentHulls.resize(state->methods.size());
    for (size_t i = 0; i < state->methods.size(); ++i) {
      auto required = c.array(c.ref(state->definitions[i], "parameters"), "requireds");
      for (auto parameter : required) {
        state->parameterTokens.emplace(c.id(parameter),
            std::make_pair(i, state->parameters[i].size()));
        state->parameters[i].push_back(field(parameter, "strings", "name").str());
      }
      state->argumentHulls[i].resize(required.size());
      state->flows[i].parameterCount = required.size();
    }
    c.subprograms = std::move(state);
  }
  return success();
}
} // namespace spinel::consumer
