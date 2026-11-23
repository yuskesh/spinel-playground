#include "spinel/Conversion/Consumer.h"
#include "llvm/Support/Error.h"
#include <algorithm>
namespace spinel::consumer {
namespace {
math::Condition rangeCondition(const Expr &e) {
  math::Condition result;
  result.eligible = false;
  if (e->kind == "not" || e->kind == "and" || e->kind == "or") {
    result.op = e->kind; result.eligible = true;
    for (const auto &arg : e->args) result.children.push_back(rangeCondition(arg));
  } else if (e->kind == "compare" && e->args.size() == 2) {
    auto a = e->args[0], b = e->args[1];
    auto ai = a->range.interval.finite(), bi = b->range.interval.finite();
    if (!ai || !bi) {
      if (!ai) llvm::consumeError(ai.takeError());
      if (!bi) llvm::consumeError(bi.takeError());
      return result;
    }
    result.eligible = !a->range.wide && !b->range.wide && !a->range.isBool && !b->range.isBool;
    result.op = e->op;
    result.left = a->kind == "local" ? a->name : "";
    result.right = b->kind == "local" ? b->name : "";
    result.leftValue = *ai; result.rightValue = *bi;
  }
  return result;
}
}
LogicalResult Consumer::refineLocals(const Expr &predicate, bool positive) {
  range::Environment entry;
  for (const auto &[name, value] : locals) entry[name] = value.expr->range;
  auto narrowed = range::refineEnvironment(entry, rangeCondition(predicate), positive);
  if (!narrowed) return rangeFailure(narrowed.takeError(), predicate->node);
  for (auto &[name, value] : locals) {
    auto found = narrowed->find(name);
    if (found == narrowed->end()) continue;
    value.expr = std::make_shared<ScalarExpr>(*value.expr);
    value.expr->range = range::asLocal(found->second);
  }
  return success();
}
std::vector<size_t> Consumer::usedRecordOrder() const {
  std::vector<size_t> order;
  auto append = [&](const std::string &name) {
    if (name.empty()) return;
    for (size_t i = 0; i < records.size(); ++i) {
      if (records[i].name != name) continue;
      if (std::find(order.begin(), order.end(), i) == order.end())
        order.push_back(i);
      return;
    }
  };
  for (const auto &map : maps) {
    if (!map.used) continue;
    append(map.keyRecord);
    append(map.valueRecord);
  }
  // E029: then the records of used rings in declaration order (schema.go:72).
  for (const auto &ring : rings)
    if (ring.used && ring.layout)
      append(ring.layout->name);
  return order;
}
struct ScopeState {
  Locals locals;
  std::map<std::string, Borrow> borrows;
  range::Environment environment;
  std::vector<LoopFrame> frames;
  std::map<std::string, ScopeBinding> bindings;
  std::vector<bool> usedMaps;
  bool usedMap, probing;
  OpBuilder::InsertPoint insertion;
  std::vector<bool> usedGlobals, usedRecords, usedRings;
  Operation *activeDef;
  std::string activeKind;
  Value contextValue;
};
ScopeGuard::ScopeGuard(Consumer &c)
    : consumer(c), saved(new ScopeState{c.locals,
                                        c.borrows,
                                        c.environment,
                                        c.frames,
                                        c.bindings,
                                        {},
                                        c.usedMap,
                                        c.probing,
                                        c.builder.saveInsertionPoint()}) {
  for (const auto &map : c.maps)
    saved->usedMaps.push_back(map.used);
  for (const auto &global : c.globals)
    saved->usedGlobals.push_back(global.used);
  for (const auto &record : c.records)
    saved->usedRecords.push_back(record.used);
  for (const auto &ring : c.rings)
    saved->usedRings.push_back(ring.used);
  saved->activeDef = c.activeDef;
  saved->activeKind = c.activeKind;
  saved->contextValue = c.contextValue;
}
ScopeGuard::~ScopeGuard() {
  if (!saved)
    return;
  consumer.locals = std::move(saved->locals);
  consumer.borrows = std::move(saved->borrows);
  consumer.environment = std::move(saved->environment);
  consumer.frames = std::move(saved->frames);
  consumer.bindings = std::move(saved->bindings);
  consumer.usedMap = saved->usedMap;
  consumer.probing = saved->probing;
  for (size_t i = 0; i < saved->usedMaps.size(); ++i)
    consumer.maps[i].used = saved->usedMaps[i];
  consumer.builder.restoreInsertionPoint(saved->insertion);
  for (size_t i = 0; i < saved->usedGlobals.size(); ++i)
    consumer.globals[i].used = saved->usedGlobals[i];
  for (size_t i = 0; i < saved->usedRecords.size(); ++i)
    consumer.records[i].used = saved->usedRecords[i];
  for (size_t i = 0; i < saved->usedRings.size(); ++i)
    consumer.rings[i].used = saved->usedRings[i];
  consumer.activeDef = saved->activeDef;
  consumer.activeKind = std::move(saved->activeKind);
  consumer.contextValue = saved->contextValue;
}
void ScopeGuard::commit() { saved.reset(); }
bool Registry::addEmitter(StringRef key, EmitHandler handler) {
  for (const auto &entry : emitters)
    if (entry.first == key) {
      valid = false;
      return false;
    }
  emitters.emplace_back(key.str(), std::move(handler));
  return true;
}
Operation *Consumer::parent(Operation *node) const {
  return parents.lookup(node);
}
LogicalResult Consumer::known(Operation *node, const CalleePolicy &policy) {
  if (failed(known(node, false)))
    return failure();
  auto &items = evidence[id(node)];
  if (items.size() != 1 ||
      (policy.requireDirect && text(items.front(), "dispatch") != "direct") ||
      text(items.front(), "name") != field(node, "strings", "name"))
    return error(node,
                 "call evidence does not match the explicit callee policy");
  auto callee = text(items.front(), "callee");
  if (isProducer() && policy.requireCallee && callee != policy.expected)
    return error(node, "call evidence callee differs from explicit policy");
  return success();
}
template <class T> static bool validValue(const T &) { return true; }
static bool validValue(const Expr &value) { return bool(value); }
static bool validValue(Value value) { return bool(value); }
static bool validValue(const ExportValue &value) {
  return bool(value.writer) || value.primitive.has_value();
}
template <class T>
static Dispatch<T> validate(Consumer &c, Dispatch<T> result) {
  if (result.state == Disposition::Handled &&
      (!result.value || !validValue(*result.value)))
    result = Dispatch<T>::error();
  if (result.state == Disposition::Error)
    c.blocking = true;
  return result;
}
template <class T, class List, class Invoke>
static Dispatch<T> dispatch(Consumer &c, const List &list, StringRef key,
                            Invoke invoke) {
  if (c.blocking || !c.registry.valid) {
    c.blocking = true;
    return Dispatch<T>::error();
  }
  for (const auto &entry : list) {
    if (entry.first != key)
      continue;
    ScopeGuard scope(c);
    auto result = validate(c, invoke(entry.second));
    if (result.state != Disposition::Declined) {
      if (result.state == Disposition::Handled)
        scope.commit();
      return result;
    }
  }
  return Dispatch<T>::declined();
}
Dispatch<Expr> Consumer::dispatchExpression(StringRef kind, Operation *node) {
  return dispatch<Expr>(*this, registry.expressions, kind,
                        [&](const ExprHandler &h) { return h(*this, node); });
}
Dispatch<Value> Consumer::dispatchEmitter(StringRef kind, const Expr &expr) {
  return dispatch<Value>(*this, registry.emitters, kind,
                         [&](const EmitHandler &h) { return h(*this, expr); });
}
Dispatch<StatementResult>
Consumer::dispatchStatement(StringRef kind,
                            llvm::ArrayRef<Operation *> statements,
                            size_t index, unsigned depth) {
  return dispatch<StatementResult>(
      *this, registry.statements, kind, [&](const StmtHandler &h) {
        auto result = h(*this, statements, index, depth);
        // Validate before dispatch commits its scope snapshot.
        if (result.state == Disposition::Handled && result.value &&
            (index >= statements.size() || result.value->consumed == 0 ||
             result.value->consumed > statements.size() - index))
          return Dispatch<StatementResult>::error();
        return result;
      });
}
Dispatch<bool> Consumer::dispatchDeclaration(Operation *node) {
  auto call = ref(node, "value");
  if (!call)
    call = node;
  DeclKey key{constant(ref(call, "receiver")),
              field(call, "strings", "name").str()};
  if (blocking || !registry.valid) {
    blocking = true;
    return Dispatch<bool>::error();
  }
  for (const auto &entry : registry.declarations) {
    if (entry.first.receiver != key.receiver ||
        entry.first.method != key.method)
      continue;
    ScopeGuard scope(*this);
    size_t nm = maps.size(), ng = globals.size(), nr = records.size(),
           nring = rings.size();
    auto result = validate(*this, entry.second(*this, node));
    if (result.state != Disposition::Declined) {
      if (result.state == Disposition::Handled) {
        for (size_t i = nm; i < maps.size(); ++i)
          declarationOrder.push_back({DeclarationRef::Domain::Map, i});
        for (size_t i = ng; i < globals.size(); ++i)
          declarationOrder.push_back({DeclarationRef::Domain::Global, i});
        for (size_t i = nr; i < records.size(); ++i)
          declarationOrder.push_back({DeclarationRef::Domain::Record, i});
        for (size_t i = nring; i < rings.size(); ++i)
          declarationOrder.push_back({DeclarationRef::Domain::Ring, i});
        scope.commit();
      }
      return result;
    }
  }
  return Dispatch<bool>::declined();
}
Dispatch<ProgramDecl> Consumer::dispatchRoot(Operation *node) {
  if (constant(ref(node, "receiver")) != "BPF")
    return Dispatch<ProgramDecl>::declined();
  return dispatch<ProgramDecl>(
      *this, registry.roots, field(node, "strings", "name"),
      [&](const RootHandler &h) { return h(*this, node); });
}
Dispatch<Expr> Consumer::dispatchMapKey(size_t map,
                                        llvm::ArrayRef<Operation *> args,
                                        Operation *site) {
  if (map >= maps.size()) {
    blocking = true;
    return Dispatch<Expr>::error();
  }
  return dispatch<Expr>(
      *this, registry.mapKeys, maps[map].kind,
      [&](const MapKeyHandler &h) { return h(*this, map, args, site); });
}
Dispatch<ExportFields> Consumer::dispatchExport(DeclarationRef declaration,
                                                bool schema) {
  if (declaration.domain == DeclarationRef::Domain::Map) {
    if (declaration.index >= maps.size()) {
      blocking = true;
      return Dispatch<ExportFields>::error();
    }
    return dispatch<ExportFields>(*this, registry.mapExporters,
                                  maps[declaration.index].kind,
                                  [&](const MapExportHandler &h) {
                                    return h(*this, declaration.index, schema);
                                  });
  }
  if (declaration.domain == DeclarationRef::Domain::Ring &&
      declaration.index >= rings.size()) {
    blocking = true;
    return Dispatch<ExportFields>::error();
  }
  auto &list = declaration.domain == DeclarationRef::Domain::Record
                   ? registry.recordExporters
               : declaration.domain == DeclarationRef::Domain::Ring
                   ? registry.ringExporters
                   : registry.globalExporters;
  for (const auto &handler : list) {
    auto result = validate(*this, handler(*this, declaration.index, schema));
    if (result.state != Disposition::Declined)
      return result;
  }
  return Dispatch<ExportFields>::declined();
}
// E022: the fixed core keys a group may export, in Go's order.
const char *const kCoreExportKeys[] = {"kernel_types"};
bool Registry::addCoreExporter(StringRef key, CoreExportHandler handler) {
  bool known = llvm::is_contained(kCoreExportKeys, key);
  bool duplicate = llvm::any_of(coreExporters,
                                [&](const auto &e) { return e.first == key; });
  if (!known || duplicate) {
    valid = false;
    return false;
  }
  coreExporters.emplace_back(key.str(), std::move(handler));
  return true;
}
Dispatch<ExportFields> Consumer::dispatchProgramExport(size_t index,
                                                       bool schema) {
  if (index >= programs.size()) {
    blocking = true;
    return Dispatch<ExportFields>::error();
  }
  return dispatch<ExportFields>(*this, registry.programExporters,
                                programs[index].kind,
                                [&](const ProgramExportHandler &h) {
                                  return h(*this, index, schema);
                                });
}
Dispatch<ExportValue> Consumer::dispatchCoreExport(StringRef key, bool schema) {
  return dispatch<ExportValue>(*this, registry.coreExporters, key,
                               [&](const CoreExportHandler &h) {
                                 return h(*this, schema);
                               });
}
bool Consumer::rmwExempt(const ReadOrigin &origin, size_t targetMap) const {
  for (const auto &handler : registry.rmwExemptions)
    if (handler(*this, origin, targetMap))
      return true;
  return false;
}
LogicalResult Consumer::knownMap(Operation *node, size_t map) {
  if (failed(typed(node))) return failure();
  if (maps[map].className == "ArrayMap")
    return known(node, true);
  return known(node, CalleePolicy{maps[map].className + "#" +
                                  field(node, "strings", "name").str()});
}
FailureOr<Expr> Consumer::checkedMapKey(size_t map,
                                        llvm::ArrayRef<Operation *> args,
                                        Operation *site) {
  auto result = dispatchMapKey(map, args, site);
  if (result.state == Disposition::Error)
    return failure();
  if (result.state == Disposition::Handled) {
    auto key = std::make_shared<ScalarExpr>(**result.value);
    key->typedMapKey = true;
    return key;
  }
  if (maps[map].kind != "array" || args.size() != 1)
    return (void)error(site, "map key handler is not registered"), failure();
  auto key = scalar(args[0]);
  if (failed(key))
    return failure();
  if (failed(checked(
          range::checkArrayKey((*key)->range, rangeMap(map), {id(args[0])}),
          args[0])))
    return failure();
  return *key;
}
Value Consumer::emitMapKey(const Expr &key, size_t map) {
  // Registered key handlers own their exact typed key representation.
  return key->typedMapKey ? emitScalar(key) : scalarKey(key);
}
llvm::Expected<BodyResult> Consumer::transferBody(const BodyRequest &request) {
  if (!bodyTransfer)
    return llvm::createStringError("body transfer handler is not registered");
  ScopeGuard scope(*this);
  environment = request.entry;
  probing = request.mode == CheckMode::Probe;
  probeIssues.clear();
  Operation *irRoot = input;
  if (auto block = builder.getInsertionBlock()) {
    irRoot = block->getParentOp();
    while (irRoot && irRoot->getParentOp())
      irRoot = irRoot->getParentOp();
  }
  llvm::DenseSet<Operation *> before;
  if (irRoot)
    irRoot->walk([&](Operation *op) { before.insert(op); });
  auto result = bodyTransfer(*this, request);
  SmallVector<Operation *> newRoots;
  if (irRoot)
    irRoot->walk([&](Operation *op) {
      if (!before.count(op) && before.count(op->getParentOp()))
        newRoots.push_back(op);
    });
  for (auto *op : newRoots)
    op->erase();
  if (!result)
    return result.takeError();
  if (!newRoots.empty() ||
      (probing && (result->checked || !probeIssues.empty()))) {
    probeIssues.clear();
    return llvm::createStringError(
        "body transfer must not publish IR; Probe must not publish diagnostics "
        "or checked payload");
  }
  return std::move(*result);
}
} // namespace spinel::consumer
