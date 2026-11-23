#include "spinel/Conversion/Subprograms.h"
#include "spinel/Conversion/PacketSubprogram.h"
#include "spinel/Import/Import.h"
#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Parser/Parser.h"
#include "llvm/Support/raw_ostream.h"
#include <cstdlib>
using namespace mlir;
using namespace spinel;
using namespace spinel::consumer;
static void check(bool ok, StringRef name) {
  if (!ok) { llvm::errs() << "FAIL " << name << '\n'; std::exit(1); }
  llvm::outs() << "PASS " << name << '\n';
}
int main(int argc, char **argv) {
  check(argc == 2, "usage");
  MLIRContext context;
  context.loadDialect<ir::SpinelFactsDialect, ebpf::EBPFDialect, arith::ArithDialect>();
  auto input = parseSourceFile<ModuleOp>(argv[1], &context);
  check(bool(input) && succeeded(verifyImport(*input)), "real-sub-int-facts");
  Consumer c(*input);
  Operation *root = nullptr;
  for (auto table : input->getOps<ir::TableOp>())
    if (text(table, "phase") == "pristine")
      root = c.nodes.lookup(table->getAttrOfType<IntegerAttr>("root_id").getInt());
  check(root && succeeded(c.select(root)), "existing-root-selection");
  auto top = c.array(c.ref(root, "statements"), "body");
  SmallVector<Operation *> entries;
  for (auto node : c.selectedTop)
    if (text(node, "kind") == "CallNode" && c.constant(c.ref(node, "receiver")) == "BPF")
      entries.push_back(node);
  check(entries.size() == 2, "two-explicit-program-roots");
  check(succeeded(prepareSubprograms(c, top, entries)), "prepare-reachable-subprograms");
  std::set<std::string> names;
  for (auto node : c.selectedTop)
    if (text(node, "kind") == "DefNode")
      check(names.insert(field(node, "strings", "name").str()).second,
            "selected-defs-are-unique");
  check(names == std::set<std::string>({"mix", "tally", "sum_to", "twice_mix", "read_in", "on_xdp", "on_tc"}),
        "five-reachable-callees-and-two-roots");
  check(c.maps.empty() && c.locals.empty() && c.borrows.empty() && c.programs.empty(),
        "prepare-does-not-run-declaration-or-range-semantics");
  Operation *literalCall = nullptr;
  for (const auto &[id, node] : c.nodes)
    if (text(node, "kind") == "CallNode" && field(node, "strings", "name") == "tally") {
      auto arguments = c.args(node);
      if (arguments.size() == 2 && text(arguments[0], "kind") == "IntegerNode") {
        literalCall = node;
        break;
      }
    }
  check(literalCall != nullptr, "fixed-integer-call-site");
  auto parent = c.parent(literalCall);
  while (parent && text(parent, "kind") != "DefNode") parent = c.parent(parent);
  c.activeDef = parent;
  c.programName = field(parent, "strings", "name").str();
  check(c.registry.valid, "production-subprogram-registry-is-valid");
  auto call = c.dispatchExpression("CallNode", literalCall);
  check(call.state == Disposition::Handled, "checked-subprogram-call");
  auto expr = *call.value;
  check(expr->kind == "subprogram.call" && expr->args.size() == 2 &&
        expr->range.interval == math::MathInterval(math::Interval::fullI64()),
        "caller-result-is-full-i64-not-callee-return-range");
  auto target = c.analyzed.lookup(c.id(literalCall));
  auto original = target->getAttrOfType<DictionaryAttr>("integers");
  auto mutateIntegers = [&](StringRef key, StringRef value) {
    NamedAttrList values(original);
    values.set(key, c.builder.getStringAttr(value));
    target->setAttr("integers", values.getDictionary(&context));
  };
  mutateIntegers("unknown_metadata", "1");
  check(!c.equivalentNode(literalCall, target), "unknown-analysis-key-refused");
  target->setAttr("integers", original);
  Operation *unrelated = nullptr;
  for (const auto &[id, node] : c.analyzed)
    if (text(node, "kind") == "DefNode" && node->getAttr("file_id") != literalCall->getAttr("file_id") &&
        field(node, "strings", "name") != "__enum_tally__" + std::to_string(c.id(literalCall))) {
      unrelated = node;
      break;
    }
  check(unrelated != nullptr, "unrelated-builtin-target-exists");
  mutateIntegers("enum_copy", std::to_string(c.id(unrelated)));
  check(c.equivalentNode(literalCall, target), "analysis-stamp-does-not-select-callee");
  target->setAttr("integers", original);
  auto version = (*input)->getAttr("spinel_facts.version");
  (*input)->setAttr("spinel_facts.version", c.builder.getI64IntegerAttr(1));
  check(!c.equivalentNode(literalCall, target), "v1-does-not-ignore-analysis-key");
  (*input)->setAttr("spinel_facts.version", version);
  for (auto attr : original) {
    if (attr.getName() == "enum_copy") continue;
    mutateIntegers(attr.getName(), "999999");
    check(!c.equivalentNode(literalCall, target), "syntax-integer-change-refused");
    break;
  }
  target->setAttr("integers", original);
  auto strings = target->getAttrOfType<DictionaryAttr>("strings");
  NamedAttrList changedStrings(strings);
  changedStrings.set("enum_copy", c.builder.getStringAttr("1"));
  target->setAttr("strings", changedStrings.getDictionary(&context));
  check(!c.equivalentNode(literalCall, target), "other-dictionary-key-refused");
  target->setAttr("strings", strings);
  auto refs = target->getAttrOfType<DictionaryAttr>("refs");
  NamedAttrList changedRefs(refs);
  changedRefs.set("e076_unknown_ref", c.builder.getI64IntegerAttr(0));
  target->setAttr("refs", changedRefs.getDictionary(&context));
  check(!c.equivalentNode(literalCall, target), "reference-change-refused");
  target->setAttr("refs", refs);
  auto location = target->getLoc();
  target->setLoc(FileLineColLoc::get(&context, "e076-other.rb", 1, 1));
  check(!c.equivalentNode(literalCall, target), "location-change-refused");
  target->setLoc(location);
  c.probing = true;
  auto &evidence = c.evidence[c.id(literalCall)];
  evidence.push_back(evidence.front());
  check(failed(c.known(literalCall, CalleePolicy{"tally"})), "duplicate-evidence-refused");
  evidence.pop_back();
  auto record = evidence.front();
  auto callee = record->getAttr("callee");
  record->setAttr("callee", c.builder.getStringAttr("other"));
  check(failed(c.known(literalCall, CalleePolicy{"tally"})), "different-callee-refused");
  record->setAttr("callee", callee);
  c.probing = false;
  c.probeIssues.clear();
  check(c.equivalentNode(literalCall, target), "syntax-proof-restored");
  OwningOpRef<ModuleOp> staging(ModuleOp::create(UnknownLoc::get(&context)));
  c.builder.setInsertionPointToEnd(staging->getBody());
  auto result = c.emitScalar(expr);
  check(bool(result), "emit-checked-integer-call");
  auto emitted = result.getDefiningOp<ebpf::CallOp>();
  check(emitted && emitted.getCallee() == "tally" && emitted.getArgs().size() == 2 &&
        emitted.getLoc() == outputLoc(literalCall) && result.getType().isInteger(64),
        "call-has-explicit-operands-and-ruby-location");
  MapDecl out, in;
  out.name = "Out";
  in.name = "In";
  c.maps = {out, in};
  Operation *readIn = nullptr;
  for (auto node : c.selectedTop)
    if (text(node, "kind") == "DefNode" && field(node, "strings", "name") == "read_in")
      readIn = node;
  check(readIn && succeeded(collectSubprogramMaps(c, readIn)) &&
        !c.maps[0].used && c.maps[1].used,
        "callee-collects-only-its-direct-map");
  c.maps[0].used = c.maps[1].used = false;
  check(succeeded(collectSubprogramMaps(c, parent)) &&
        c.maps[0].used && !c.maps[1].used,
        "root-does-not-import-transitive-callee-map");
  auto dropped = c.dispatchStatement("CallNode", {literalCall}, 0, 0);
  check(dropped.state == Disposition::Handled && dropped.value->consumed == 1,
        "call-statement-discards-one-result");
  check(bool(c.registry.packetSubprogram), "packet-subprogram-hooks-registered");
  auto windowDefinition = c.parent(literalCall);
  while (windowDefinition && text(windowDefinition,"kind") != "DefNode")
    windowDefinition = c.parent(windowDefinition);
  auto windowParameters = c.array(c.ref(windowDefinition,"parameters"),"requireds");
  check(!windowParameters.empty(), "packet-scope-test-has-parameter");
  auto windowName = field(windowParameters.front(),"strings","name").str();
  auto callerDef = c.activeDef;
  auto callerKind = c.activeKind;
  auto bindingsBefore = c.bindings.size();
  {
    ScopeGuard restore(c);
    c.activeDef = windowDefinition;
    c.activeKind = "func";
    c.contextValue = {};
    auto block = new Block();
    staging->getBodyRegion().push_back(block);
    auto windowValue = block->addArgument(ebpf::PktWindowType::get(&context,14),
                                         c.builder.getUnknownLoc());
    auto entered = c.registry.packetSubprogram->enter(c, windowDefinition, {},
        PacketFunctionWindow{windowName,14,windowValue});
    check(bool(entered) && bool(*entered), "enter-window-only-function-scope");
    auto activeWindow = c.registry.packetSubprogram->checkedWindow(c,windowName);
    check(activeWindow.state == Disposition::Handled && *activeWindow.value == 14 &&
          c.activeKind == "func" && !c.contextValue && c.activeDef == windowDefinition,
          "window-scope-preserves-explicit-consumer-context");
    auto invalid = c.registry.packetSubprogram->enter(c, windowDefinition, {},
        PacketFunctionWindow{windowName,0,windowValue});
    check(!invalid, "invalid-window-descriptor-refused-before-state-change");
    llvm::consumeError(invalid.takeError());
    check(c.registry.packetSubprogram->checkedWindow(c,windowName).state == Disposition::Handled,
          "failed-enter-preserves-existing-window");
  }
  check(c.activeDef == callerDef && c.activeKind == callerKind &&
        c.bindings.size() == bindingsBefore &&
        c.registry.packetSubprogram->checkedWindow(c,windowName).state == Disposition::Declined,
        "function-packet-scope-restores-caller");
  auto rejectedBefore = c.printedRejections;
  {
    ScopeGuard restore(c);
    c.probing = true;
    ReadOrigin invalid{99, std::nullopt, {}, ReadOrigin::Domain::Parameter, -1};
    check(succeeded(noteSubprogramWrite(c, literalCall, invalid, {invalid})),
          "probe-does-not-record-or-diagnose-flow");
  }
  check(!c.probing && c.printedRejections == rejectedBefore,
        "probe-restores-state-without-rejections");
  check(succeeded(noteSubprogramWrite(c, literalCall,
          {0, std::nullopt, {}, ReadOrigin::Domain::Map}, expr->reads)),
        "checked-call-result-can-feed-deferred-map-write");
  check(!c.blocking, "partial-hook-control-starts-without-prior-blocking");
  auto enter = c.registry.packetSubprogram->enter;
  c.registry.packetSubprogram->enter = {};
  check(c.dispatchExpression("CallNode", literalCall).state == Disposition::Error,
        "partial-packet-hooks-refused-without-calling-empty-function");
  c.registry.packetSubprogram->enter = std::move(enter);
  ReadOrigin unknown{0, std::nullopt, {}, ReadOrigin::Domain::Parameter, -1};
  check(failed(noteSubprogramWrite(c, literalCall,
          {0, std::nullopt, {}, ReadOrigin::Domain::Map}, {unknown})),
        "unknown-parameter-token-blocks-flow");
}
