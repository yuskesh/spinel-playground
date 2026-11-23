#include "spinel/Analysis/MathIntervalAnalysis.h"
#include "mlir/Analysis/DataFlow/ConstantPropagationAnalysis.h"
#include "mlir/Analysis/DataFlow/DeadCodeAnalysis.h"
#include "mlir/IR/BuiltinAttributes.h"
#include "mlir/Interfaces/CallInterfaces.h"
#include "mlir/Interfaces/ControlFlowInterfaces.h"
#include <functional>
#include <optional>

using namespace mlir;
namespace spinel::math {
namespace {
// This analysis has no widening. Reject CFG, region-loop, and call cycles
// before giving them to the solver. Both executable and dead blocks are
// inspected.
bool hasCycle(Operation *root) {
  bool cycle = false;
  root->walk([&](Operation *op) {
    if (auto branch = dyn_cast<RegionBranchOpInterface>(op)) {
      auto name = op->getName().getStringRef();
      // The E004 profile has no general region-loop semantics. The two known
      // acyclic SCF branches are safe; other region branches fail closed.
      if (name != "scf.if" && name != "scf.index_switch")
        cycle = true;
    }
    for (Region &region : op->getRegions()) {
      std::map<Block *, unsigned> color;
      std::function<bool(Block *)> dfs = [&](Block *b) {
        if (color[b] == 1)
          return true;
        if (color[b] == 2)
          return false;
        color[b] = 1;
        for (Block *next : b->getSuccessors())
          if (dfs(next))
            return true;
        color[b] = 2;
        return false;
      };
      for (Block &b : region)
        if (dfs(&b))
          cycle = true;
    }
  });
  std::map<Operation *, std::vector<Operation *>> calls;
  root->walk([&](CallOpInterface call) {
    Operation *caller = call->getParentOp();
    while (caller && !isa<CallableOpInterface>(caller))
      caller = caller->getParentOp();
    if (caller)
      if (Operation *callee = call.resolveCallable())
        calls[caller].push_back(callee);
  });
  std::map<Operation *, unsigned> color;
  std::function<bool(Operation *)> dfs = [&](Operation *op) {
    if (color[op] == 1)
      return true;
    if (color[op] == 2)
      return false;
    color[op] = 1;
    for (Operation *callee : calls[op])
      if (dfs(callee))
        return true;
    color[op] = 2;
    return false;
  };
  // DFS may add an external callee to calls. std::map iterators remain valid.
  for (const auto &entry : calls)
    if (dfs(entry.first))
      cycle = true;
  return cycle;
}

class Analysis final
    : public dataflow::SparseForwardDataFlowAnalysis<MathLattice> {
  std::optional<Failure> rejection;
  LogicalResult record(llvm::Error error) {
    llvm::handleAllErrors(std::move(error),
                          [&](const DomainError &e) { rejection = e.code; });
    return failure();
  }
  void update(MathLattice *l, const MathInterval &v) {
    propagateIfChanged(l, l->join(v));
  }

public:
  using SparseForwardDataFlowAnalysis::SparseForwardDataFlowAnalysis;
  std::optional<Failure> getRejection() const { return rejection; }
  void setToEntryState(MathLattice *l) override {
    update(l, MathInterval::unknown());
  }
  LogicalResult visitOperation(Operation *op,
                               ArrayRef<const MathLattice *> operands,
                               ArrayRef<MathLattice *> results) override {
    if (results.empty())
      return success();
    auto name = op->getName().getStringRef();
    if (name == "math_fixture.constant") {
      auto lo = op->getAttrOfType<StringAttr>("lo"),
           hi = op->getAttrOfType<StringAttr>("hi");
      if (!lo || !hi || results.size() != 1 || !operands.empty())
        return record(fail(Failure::InvalidTransfer));
      auto l = Integer::parse(lo.getValue().str());
      if (!l)
        return record(l.takeError());
      auto h = Integer::parse(hi.getValue().str());
      if (!h)
        return record(h.takeError());
      auto iv = Interval::create(*l, *h);
      if (!iv)
        return record(iv.takeError());
      update(results[0], MathInterval(*iv));
      return success();
    }
    static const std::map<std::string, unsigned> arity = {
        {"copy", 1}, {"neg", 1},  {"not", 1}, {"add", 2}, {"sub", 2},
        {"mul", 2},  {"join", 2}, {"and", 2}, {"or", 2},  {"xor", 2},
        {"div", 2},  {"rem", 2},  {"shl", 2}, {"shr", 2}};
    auto suffix =
        name.consume_front("math_fixture.") ? name.str() : std::string();
    auto found = arity.find(suffix);
    if (found == arity.end()) {
      for (auto *r : results)
        setToEntryState(r);
      return success();
    }
    if (results.size() != 1 || operands.size() != found->second)
      return record(fail(Failure::InvalidTransfer));
    for (const auto *v : operands)
      if (v->getValue().getState() == State::Uninitialized)
        return success();
    for (const auto *v : operands)
      if (v->getValue().getState() == State::Overdefined) {
        setToEntryState(results[0]);
        return success();
      }
    auto a = operands[0]->getValue().finite();
    if (!a)
      return record(a.takeError());
    llvm::Expected<Interval> result = *a;
    if (suffix == "neg")
      result = neg(*a);
    else if (suffix == "not")
      result = bitNot(*a);
    else if (suffix != "copy") {
      auto b = operands[1]->getValue().finite();
      if (!b)
        return record(b.takeError());
      if (suffix == "add")
        result = add(*a, *b);
      else if (suffix == "sub")
        result = sub(*a, *b);
      else if (suffix == "mul")
        result = mul(*a, *b);
      else if (suffix == "join")
        result = hull(*a, *b);
      else if (suffix == "and" || suffix == "or" || suffix == "xor")
        result = bit(suffix == "and"  ? "&"
                     : suffix == "or" ? "|"
                                      : "^",
                     *a, *b);
      else {
        // Fixture dialect facts make literal identity explicit: it cannot be
        // inferred merely because a computed interval happens to be a point.
        auto *def = op->getOperand(1).getDefiningOp();
        bool literal =
            def && def->getName().getStringRef() == "math_fixture.constant" &&
            b->isPoint();
        result = consume(suffix, *a, b->lo, literal);
      }
    }
    if (!result)
      return record(result.takeError());
    update(results[0], MathInterval(*result));
    return success();
  }
};
} // namespace
llvm::Error runMathIntervalAnalysis(Operation *root, DataFlowSolver &solver) {
  if (!root)
    return fail(Failure::MissingEvidence);
  if (hasCycle(root))
    return fail(Failure::CycleNotSupported);
  solver.load<dataflow::DeadCodeAnalysis>();
  solver.load<dataflow::SparseConstantPropagation>();
  auto *analysis = solver.load<Analysis>();
  if (failed(solver.initializeAndRun(root)))
    return fail(analysis->getRejection().value_or(Failure::SolverFailure));
  return llvm::Error::success();
}
llvm::Expected<MathInterval> queryMathInterval(const DataFlowSolver &solver,
                                               Value value) {
  auto *state = solver.lookupState<MathLattice>(value);
  if (!state || state->getValue().getState() == State::Uninitialized)
    return fail(Failure::MissingEvidence);
  return state->getValue();
}
} // namespace spinel::math
