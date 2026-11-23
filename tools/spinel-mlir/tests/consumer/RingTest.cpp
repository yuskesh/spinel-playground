// E029: ring_mc / t_ring lowered through the lowerToEBPF gate equal the Go
// oracle (IR without locations, schema and maps.json byte for byte), and a
// probe of each ring output checks only.
#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/IR/Verifier.h"
#include "mlir/Parser/Parser.h"
#include "spinel/Conversion/LowerToEBPF.h"
#include "spinel/Conversion/Ring.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/Path.h"
#include "llvm/Support/raw_ostream.h"
#include <cstdlib>
#include <fcntl.h>
#include <functional>
#include <unistd.h>
using namespace spinel;
using namespace spinel::consumer;
using namespace mlir;

static void require(bool ok, const std::string &name) {
  // stdout: a failure inside captureStderr must still reach the log.
  if (!ok) {
    llvm::outs() << "FAIL " << name << "\n";
    llvm::outs().flush();
    std::exit(1);
  }
  llvm::outs() << "ok " << name << "\n";
}

static std::string workDir;

static std::string captureStderr(const std::function<void()> &fn) {
  std::string pattern = workDir + "/stderr-XXXXXX";
  std::vector<char> path(pattern.begin(), pattern.end());
  path.push_back('\0');
  int fd = mkstemp(path.data());
  if (fd < 0)
    require(false, "mkstemp");
  llvm::errs().flush();
  int saved = dup(2);
  dup2(fd, 2);
  fn();
  llvm::errs().flush();
  dup2(saved, 2);
  close(saved);
  close(fd);
  auto buffer = llvm::MemoryBuffer::getFile(path.data());
  unlink(path.data());
  return buffer ? (*buffer)->getBuffer().str() : std::string();
}

static std::string readFile(const std::string &path) {
  auto buffer = llvm::MemoryBuffer::getFile(path);
  require(bool(buffer), "read " + path);
  return (*buffer)->getBuffer().str();
}

static size_t countOps(Operation *root) {
  size_t n = 0;
  root->walk([&](Operation *) { ++n; });
  return n;
}

static Operation *outputRoot(Consumer &c) {
  Operation *op = c.builder.getInsertionBlock()->getParentOp();
  while (op->getParentOp())
    op = op->getParentOp();
  return op;
}

static std::string printNoLoc(ModuleOp module) {
  std::string out;
  llvm::raw_string_ostream os(out);
  module.print(os);
  std::string clean;
  for (size_t i = 0; i < out.size();) {
    if (out.compare(i, 4, "loc(") == 0) {
      int depth = 0;
      size_t j = i;
      for (; j < out.size(); ++j) {
        if (out[j] == '(')
          ++depth;
        else if (out[j] == ')' && --depth == 0)
          break;
      }
      i = j + 1;
      while (!clean.empty() && clean.back() == ' ')
        clean.pop_back();
      continue;
    }
    clean += out[i++];
  }
  return clean;
}

static bool isRingOutput(Consumer &c, Operation *n) {
  if (!n || text(n, "kind") != "CallNode" ||
      field(n, "strings", "name") != "output")
    return false;
  auto found = c.evidence.find(c.id(n));
  return found != c.evidence.end() &&
         text(found->second.front(), "callee") == "RingBuf#output";
}

struct ProbeState {
  size_t ops, printed;
  bool blocking;
};
static ProbeState snapshot(Consumer &c) {
  return {countOps(outputRoot(c)), c.printedRejections, c.blocking};
}
static void requireProbeClean(Consumer &c, const ProbeState &before,
                              const std::string &what) {
  require(countOps(outputRoot(c)) == before.ops, what + ": probe emits no IR");
  require(c.blocking == before.blocking, what + ": probe leaves blocking");
  require(c.printedRejections == before.printed,
          what + ": probe prints nothing");
  require(c.probeIssues.empty(), what + ": probe records no issue");
}

// A value's identity without SSA names: its defining op, attributes, types
// and operands, recursively (record.make results opaque when asked).
class Fingerprints {
  llvm::DenseMap<Value, std::string> memo;
  bool opaqueRecords;

public:
  explicit Fingerprints(bool opaque) : opaqueRecords(opaque) {}
  std::string of(Value v) {
    auto found = memo.find(v);
    if (found != memo.end())
      return found->second;
    std::string out;
    llvm::raw_string_ostream os(out);
    if (auto arg = dyn_cast<BlockArgument>(v)) {
      auto *owner = arg.getOwner()->getParentOp();
      os << "arg" << arg.getArgNumber() << "@" << owner->getName() << "/"
         << arg.getOwner()->getParent()->getRegionNumber() << ":"
         << arg.getType();
    } else {
      auto *def = v.getDefiningOp();
      if (opaqueRecords && isa<ebpf::RecordMakeOp>(def))
        os << "record";
      else
        os << op(def) << "#" << cast<OpResult>(v).getResultNumber();
    }
    return memo[v] = out;
  }
  std::string op(Operation *op) {
    std::string out;
    llvm::raw_string_ostream os(out);
    os << op->getName() << " " << op->getAttrDictionary() << " (";
    for (auto operand : op->getOperands())
      os << of(operand) << ", ";
    os << ") -> (";
    for (auto t : op->getResultTypes())
      os << t << ", ";
    os << ") in " << (op->getParentOp() ? op->getParentOp()->getName().getStringRef() : "");
    return out;
  }
};

// E029 H6 M-ring-field-swap: the mutant's record.make operands are the base's
// with the first two swapped, and every other op is unchanged as a multiset.
static int compareSwap(MLIRContext &context, const char *base,
                       const char *mutant) {
  auto a = parseSourceFile<ModuleOp>(base, &context);
  auto b = parseSourceFile<ModuleOp>(mutant, &context);
  require(a && b, "parse both arms");
  auto makes = [](ModuleOp m) {
    Fingerprints fp(false);
    std::vector<std::vector<std::string>> out;
    m.walk([&](ebpf::RecordMakeOp op) {
      std::vector<std::string> operands;
      for (auto v : op->getOperands())
        operands.push_back(fp.of(v));
      out.push_back(std::move(operands));
    });
    return out;
  };
  auto others = [](ModuleOp m) {
    Fingerprints fp(true);
    std::vector<std::string> out;
    m.walk([&](Operation *op) {
      if (!isa<ebpf::RecordMakeOp, ModuleOp>(op))
        out.push_back(fp.op(op));
    });
    llvm::sort(out);
    return out;
  };
  auto ma = makes(*a), mb = makes(*b);
  require(!ma.empty() && ma.size() == mb.size(),
          "same number of record.make in both arms (" +
              std::to_string(ma.size()) + ")");
  for (size_t i = 0; i < ma.size(); ++i) {
    auto &x = ma[i], &y = mb[i];
    require(x.size() >= 2 && x[0] != x[1],
            "record.make " + std::to_string(i) +
                ": two distinct leading values (the swap is observable)");
    auto want = x;
    std::swap(want[0], want[1]);
    require(y == want, "record.make " + std::to_string(i) +
                           ": the first two values are swapped");
  }
  require(others(*a) == others(*b),
          "every op other than record.make is unchanged");
  llvm::outs() << "ok swap: " << ma.size()
               << " record.make(s) with the first two values swapped\n";
  return 0;
}

int main(int argc, char **argv) {
  if (argc == 4 && StringRef(argv[1]) == "--swap") {
    MLIRContext context;
    context.loadDialect<ebpf::EBPFDialect, arith::ArithDialect>();
    return compareSwap(context, argv[2], argv[3]);
  }
  if (argc != 2) {
    llvm::errs() << "usage: spinel-ring-test FACTS.mlir | --swap BASE MUTANT\n";
    return 2;
  }
  workDir = llvm::sys::path::parent_path(argv[1]).str();
  if (workDir.empty())
    workDir = ".";
  MLIRContext context;
  context.loadDialect<ir::SpinelFactsDialect, ebpf::EBPFDialect,
                      arith::ArithDialect>();
  auto module = parseSourceFile<ModuleOp>(argv[1], &context);
  require(bool(module), "parse facts");

  std::string source;
  for (auto op : module->getOps<ir::SourceOp>())
    if (op->getAttrOfType<IntegerAttr>("file_id").getInt() == 0)
      source = llvm::sys::path::filename(text(op, "path")).str();
  std::string id, stem;
  if (source == "mc.rb")
    id = "cmd_spinelbpf_testdata_ring_mc", stem = "mc";
  else if (source == "t_ring.rb")
    id = "cmd_spinelbpf_testdata_ring_t_ring", stem = "t_ring";
  require(!id.empty(), "known ring case: " + source);
  std::string oracle = std::string(SPINEL_E029_ORACLE) + "/" + id + "/" + stem;

  Consumer consumer(*module);
  Registry r = consumer.registry;
  int expressionProbes = 0, statementProbes = 0;
  bool inProbe = false;
  r.expressions.insert(
      r.expressions.begin(),
      {"CallNode", [&](Consumer &c, Operation *n) {
         if (inProbe || c.probing || !isRingOutput(c, n))
           return Dispatch<Expr>::declined();
         auto before = snapshot(c);
         Dispatch<Expr> probe = Dispatch<Expr>::declined();
         {
           ScopeGuard scope(c);
           inProbe = true;
           c.probing = true;
           probe = c.dispatchExpression("CallNode", n);
           inProbe = false;
         }
         ++expressionProbes;
         require(probe.state == Disposition::Handled && probe.value &&
                     (*probe.value)->range.isBool,
                 "probe of a ring output condition is a handled bool");
         requireProbeClean(c, before, "condition");
         return Dispatch<Expr>::declined();
       }});
  r.statements.insert(
      r.statements.begin(),
      {"LocalVariableWriteNode",
       [&](Consumer &c, llvm::ArrayRef<Operation *> list, size_t i,
           unsigned depth) {
         if (inProbe || c.probing || !isRingOutput(c, c.ref(list[i], "value")))
           return Dispatch<StatementResult>::declined();
         auto before = snapshot(c);
         Dispatch<StatementResult> probe =
             Dispatch<StatementResult>::declined();
         {
           ScopeGuard scope(c);
           inProbe = true;
           c.probing = true;
           probe = c.dispatchStatement("LocalVariableWriteNode", list, i, depth);
           inProbe = false;
         }
         ++statementProbes;
         require(probe.state == Disposition::Handled,
                 "probe of `_ = R.output(…)` is handled");
         requireProbeClean(c, before, "`_ =`");
         return Dispatch<StatementResult>::declined();
       }});
  consumer.useIsolatedRegistryForTesting(std::move(r));

  FailureOr<Artifacts> result = failure();
  auto err = captureStderr([&] { result = lowerWithDiagnosticGate(consumer); });
  require(succeeded(result), stem + " lowers: " + err);
  require(err.empty(), stem + " prints nothing (no warning, no SB017): " + err);
  require(succeeded(verify(*module)), stem + " verifies");
  // mc: one `unless`; t_ring: `if` + `unless` and one `_ =`.
  require(expressionProbes == (stem == "mc" ? 1 : 2),
          "every ring condition was probed (" +
              std::to_string(expressionProbes) + ")");
  require(statementProbes == (stem == "mc" ? 0 : 1),
          "every `_ =` ring output was probed (" +
              std::to_string(statementProbes) + ")");

  auto want = parseSourceFile<ModuleOp>(oracle + ".mlir", &context);
  require(bool(want), "parse oracle " + oracle + ".mlir");
  auto ours = printNoLoc(*module), theirs = printNoLoc(*want);
  if (ours != theirs)
    llvm::errs() << "--- ours\n" << ours << "--- oracle\n" << theirs;
  require(ours == theirs, stem + " IR equals the Go oracle (locations elided)");
  require(result->schema == readFile(oracle + ".schema.json"),
          stem + " schema equals the Go oracle byte for byte");
  require(result->maps == readFile(oracle + ".maps.json"),
          stem + " maps.json equals the Go oracle byte for byte");
  return 0;
}
