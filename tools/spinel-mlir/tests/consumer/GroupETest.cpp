// E028: group E's add_or_init lowering, probe-safe status statements and the
// diagnostic-less failure gate of lowerToEBPF.
#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/IR/AsmState.h"
#include "mlir/IR/Verifier.h"
#include "mlir/Parser/Parser.h"
#include "spinel/Conversion/Consumer.h"
#include "spinel/Conversion/LowerToEBPF.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/Path.h"
#include "llvm/Support/raw_ostream.h"
#include <cstdio>
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

// Runs fn with fd 2 redirected to a file in the work directory and returns
// what was written.
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

static OwningOpRef<ModuleOp> parse(MLIRContext &context, const char *path) {
  auto module = parseSourceFile<ModuleOp>(path, &context);
  require(bool(module), std::string("parse ") + path);
  return module;
}

static std::string printNoLoc(ModuleOp module) {
  std::string out;
  llvm::raw_string_ostream os(out);
  module.print(os, OpPrintingFlags().elideLargeElementsAttrs());
  // Drop locations: the oracle text and ours print loc(...) differently.
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

static bool isAddOrInitWrite(Consumer &c, Operation *node) {
  auto value = c.ref(node, "value");
  return value && text(value, "kind") == "CallNode" &&
         field(value, "strings", "name") == "add_or_init";
}

int main(int argc, char **argv) {
  if (argc != 2) {
    llvm::errs() << "usage: spinel-group-e-test FACTS.mlir\n";
    return 2;
  }
  workDir = llvm::sys::path::parent_path(argv[1]).str();
  if (workDir.empty())
    workDir = ".";
  MLIRContext context;
  context.loadDialect<ir::SpinelFactsDialect, ebpf::EBPFDialect,
                      arith::ArithDialect>();

  // E048: valueOperand's i32Text prints a negative literal directly at i32.
  {
    auto input = parse(context, argv[1]);
    Consumer c(*input);
    auto output = ModuleOp::create(UnknownLoc::get(&context));
    c.builder.setInsertionPointToStart(output.getBody());
    MapDecl map;
    map.bits = 32;
    map.isSigned = true;
    c.maps.push_back(map);
    auto literal = std::make_shared<ScalarExpr>();
    literal->node = input->getOperation();
    literal->kind = "literal";
    literal->literal = -5;
    auto value = c.scalarStore(literal, 0);
    auto constant = value.getDefiningOp<arith::ConstantIntOp>();
    require(bool(constant) && value.getType().isInteger(32) &&
                constant.value() == -5,
            "E048 negative i32 literal is a direct width-matched constant");
    auto printed = printNoLoc(output);
    require(printed.find("arith.constant -5 : i32") != std::string::npos &&
                printed.find("trunci") == std::string::npos,
            "E048 i32Text spelling and absence of truncation");
    output.erase();
  }

  // (a)+(b): mc lowers through the gate with the production ktime helper
  // (E033 — E017 addendum B); each add_or_init statement is first
  // re-dispatched as a probe, which must check only.
  {
    auto module = parse(context, argv[1]);
    Consumer consumer(*module);
    Registry r = consumer.registry;
    int probes = 0;
    bool inProbe = false;
    r.statements.insert(
        r.statements.begin(),
        {"LocalVariableWriteNode",
         [&](Consumer &c, llvm::ArrayRef<Operation *> list, size_t i,
             unsigned depth) {
           if (inProbe || !isAddOrInitWrite(c, list[i]))
             return Dispatch<StatementResult>::declined();
           size_t ops = countOps(outputRoot(c));
           size_t printed = c.printedRejections;
           bool blocking = c.blocking;
           Dispatch<StatementResult> probe = Dispatch<StatementResult>::declined();
           {
             ScopeGuard scope(c);
             inProbe = true;
             c.probing = true;
             probe = c.dispatchStatement("LocalVariableWriteNode", list, i,
                                         depth);
             inProbe = false;
           }
           ++probes;
           require(probe.state == Disposition::Handled,
                   "probe add_or_init statement is handled");
           require(countOps(outputRoot(c)) == ops, "probe emits no IR");
           require(c.blocking == blocking, "probe leaves blocking unset");
           require(c.printedRejections == printed, "probe prints nothing");
           require(c.probeIssues.empty(), "probe records no issue");
           return Dispatch<StatementResult>::declined();
         }});
    consumer.useIsolatedRegistryForTesting(std::move(r));
    FailureOr<Artifacts> result = failure();
    auto err = captureStderr(
        [&] { result = lowerWithDiagnosticGate(consumer); });
    require(succeeded(result), "mc lowers with the production ktime: " + err);
    require(err.find("SB017") == std::string::npos,
            "gate silent on a successful run");
    require(probes == 2, "both add_or_init statements were probed");
    require(succeeded(verify(*module)), "lowered mc verifies");
    auto oracle = parse(context, SPINEL_E028_MC_ORACLE);
    auto ours = printNoLoc(*module), want = printNoLoc(*oracle);
    if (ours != want)
      llvm::errs() << "--- ours\n" << ours << "--- oracle\n" << want;
    require(ours == want, "mc IR equals the Go oracle (locations elided)");
  }

  // (c) the gate. Each scenario fails the first statement of the program.
  struct Scenario {
    const char *name;
    std::function<void(Consumer &, Operation *)> act;
    bool sb017;
    const char *expect;
  };
  Scenario scenarios[] = {
      {"diagnostic-less failure", [](Consumer &, Operation *) {}, true, ""},
      {"printed SB diagnostic",
       [](Consumer &c, Operation *n) {
         (void)c.diagnostic(n, "SB001", "UnsupportedConstruct", "e028 control");
       },
       false, "rejected SB001 (UnsupportedConstruct): e028 control"},
      {"MLIR error",
       [](Consumer &, Operation *n) { n->emitError("e028 mlir control"); },
       false, "error: e028 mlir control"},
      {"probe issue only",
       [](Consumer &c, Operation *n) {
         c.probing = true;
         (void)c.diagnostic(n, "SB001", "UnsupportedConstruct", "e028 probe");
         c.probing = false;
       },
       true, ""},
      {"warning only",
       [](Consumer &, Operation *) {
         llvm::errs() << "spinelbpf: warning: e028 warning control\n";
       },
       true, "spinelbpf: warning: e028 warning control"},
      {"blocking only", [](Consumer &c, Operation *) { c.blocking = true; },
       true, ""},
  };
  const std::string sb017 =
      "mc.rb: rejected SB017 (InternalEmitter): consumer lowering failed "
      "without a diagnostic (phase=consumer-lowering)\n";
  for (auto &s : scenarios)
    for (bool gated : {true, false}) {
      auto module = parse(context, argv[1]);
      Consumer consumer(*module);
      Registry r = consumer.registry;
      bool fired = false;
      auto stop = [&](Consumer &c, llvm::ArrayRef<Operation *> list, size_t i,
                      unsigned) {
        if (fired)
          return Dispatch<StatementResult>::declined();
        fired = true;
        s.act(c, list[i]);
        return Dispatch<StatementResult>::error();
      };
      for (auto kind : {"CallNode", "LocalVariableWriteNode", "IfNode"})
        r.statements.insert(r.statements.begin(), {kind, stop});
      consumer.useIsolatedRegistryForTesting(std::move(r));
      FailureOr<Artifacts> result = failure();
      auto err = captureStderr([&] {
        result = gated ? lowerWithDiagnosticGate(consumer) : consumer.run();
      });
      std::string name = std::string(s.name) + (gated ? " (gate)" : " (run)");
      require(fired && failed(result), name + ": run failed");
      size_t n = 0;
      for (size_t p = err.find("SB017"); p != std::string::npos;
           p = err.find("SB017", p + 1))
        ++n;
      bool want = gated && s.sb017;
      require(n == (want ? 1u : 0u), name + ": SB017 count " +
                                         std::to_string(n) + " in: " + err);
      if (want)
        require(err.size() >= sb017.size() &&
                    err.compare(err.size() - sb017.size(), sb017.size(),
                                sb017) == 0,
                name + ": SB017 is the last line, exact text");
      if (*s.expect)
        require(err.find(s.expect) != std::string::npos,
                name + ": the control's own output is kept");
    }
  return 0;
}
