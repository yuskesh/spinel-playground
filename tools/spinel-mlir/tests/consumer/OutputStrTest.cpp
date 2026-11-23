// E039: `r = R.output_str(…)` / `if r` and the user string read into the
// reservation, before E040's uprobe root: a test-only uprobe root, `ctx.arg`
// and user-string hooks stand in for E040. positive: greetwatch's IR equals
// Go's (without locations, and with locations up to the file's basename), and
// a probe of the binding checks only; negative: the stderr equals Go's.
#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/IR/Verifier.h"
#include "mlir/Parser/Parser.h"
#include "spinel/Analysis/KernelTypes.h"
#include "spinel/Conversion/Consumer.h"
#include "spinel/Conversion/GroupGUprobe.h"
#include "spinel/Conversion/LowerToEBPF.h"
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
// Each op under the module, in order, with its location as basename:line:col
// (the producer records the source's full path; Go writes the basename). Block
// arguments and the module are left out: parsing Go's file gives them
// locations inside that .mlir file.
static std::string locations(ModuleOp module) {
  std::string out;
  llvm::raw_string_ostream os(out);
  module.walk([&](Operation *op) {
    if (op == module.getOperation())
      return;
    os << op->getName() << " ";
    if (auto f = dyn_cast<FileLineColLoc>(op->getLoc()))
      os << llvm::sys::path::filename(f.getFilename().getValue()) << ":"
         << f.getLine() << ":" << f.getColumn();
    else
      os << op->getLoc();
    os << "\n";
  });
  return out;
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

// Test-only stand-ins for E040: the uprobe root, `ctx.arg(n)` (u32 here, as
// greetwatch declares it) and the user-string hooks.
static std::string contextName;
static void installUprobeStub(Registry &r) {
  r.addRoot("uprobe", [](Consumer &c, Operation *n) {
    auto as = c.args(n);
    ProgramDecl p;
    p.kind = "uprobe";
    p.attachTarget = c.spelling(as[2], false).str();
    p.contextType = ebpf::ContextType::get(c.ctx, "uprobe");
    p.analysisContext = "obj_BPF::UprobeCtx";
    p.arch = "x86_64";
    auto name = c.spelling(as[0], true);
    Operation *def = nullptr;
    for (auto f : c.selectedTop)
      if (text(f, "kind") == "DefNode" && field(f, "strings", "name") == name)
        def = f;
    require(def != nullptr, "stub root finds its def");
    contextName = field(c.array(c.ref(def, "parameters"), "requireds")[0],
                        "strings", "name")
                      .str();
    p.finalizeBody = [def](Consumer &consumer) {
      ebpf::VerdictOp::create(consumer.builder, outputLoc(def), "done");
      return success();
    };
    return Dispatch<ProgramDecl>::handled(std::move(p));
  });
  r.addExpression("CallNode", [](Consumer &c, Operation *n) {
    auto recv = c.ref(n, "receiver");
    if (field(n, "strings", "name") != "arg" || !recv ||
        text(recv, "kind") != "LocalVariableReadNode" ||
        field(recv, "strings", "name") != contextName)
      return Dispatch<Expr>::declined();
    auto e = std::make_shared<ScalarExpr>();
    e->node = n;
    e->kind = "e039test.arg";
    e->literal = *c.integer(c.args(n)[0]);
    auto range =
        spinel::tracing::integerRange(32, false,
                                      spinel::tracing::IntegerSource::Argument);
    require(bool(range), "stub argument range");
    e->range = *range;
    return Dispatch<Expr>::handled(std::move(e));
  });
  r.addEmitter("e039test.arg", [](Consumer &c, const Expr &e) {
    auto loc = outputLoc(e->node);
    Value v = ebpf::UprobeArgOp::create(c.builder, loc,
                                        c.builder.getI32Type(),
                                        c.contextValue, e->literal);
    return Dispatch<Value>::handled(
        arith::ExtUIOp::create(c.builder, loc, c.builder.getI64Type(), v));
  });
  auto hooks = std::make_shared<UprobeHooks>();
  hooks->checkedUserString =
      [](Consumer &c,
         Operation *n) -> FailureOr<std::shared_ptr<const UserStringArg>> {
    if (field(n, "strings", "name") != "str_arg")
      return (void)c.error(n, "stub: not ctx.str_arg"), failure();
    auto arg = std::make_shared<UserStringArg>();
    arg->n = *c.integer(c.args(n)[0]);
    arg->node = n;
    return std::shared_ptr<const UserStringArg>(arg);
  };
  hooks->emitUserString = [](Consumer &c, const UserStringArg &a,
                             Location loc) -> FailureOr<Value> {
    return Value(ebpf::UprobeArgOp::create(
        c.builder, loc, ebpf::UserStrType::get(c.ctx), c.contextValue, a.n));
  };
  r.uprobe = hooks;
}

static bool isOutputStrBinding(Consumer &c, Operation *n) {
  auto v = c.ref(n, "value");
  return v && text(v, "kind") == "CallNode" &&
         (field(v, "strings", "name") == "output_str" ||
          field(v, "strings", "name") == "output_str_or_discard") &&
         field(n, "strings", "name") != "_";
}

int main(int argc, char **argv) {
  if ((argc != 4 && argc != 5) || (StringRef(argv[1]) != "positive" &&
                                   StringRef(argv[1]) != "negative")) {
    llvm::errs() << "usage: spinel-output-str-test positive FACTS GO.mlir | "
                    "negative FACTS GO.stderr [SOURCE_DIR]\n";
    return 2;
  }
  bool positive = StringRef(argv[1]) == "positive";
  workDir = llvm::sys::path::parent_path(argv[2]).str();
  if (workDir.empty())
    workDir = ".";
  MLIRContext context;
  context.loadDialect<ir::SpinelFactsDialect, ebpf::EBPFDialect,
                      arith::ArithDialect>();
  auto module = parseSourceFile<ModuleOp>(argv[2], &context);
  require(bool(module), "parse facts");
  // E082: the fixtures' source paths are under /src/; file 0 is moved into a
  // tracked capture dir so the uprobe target beside it (the same bytes) is
  // read from the repository. Only the basename reaches the output.
  if (argc == 5) {
    bool localized = false;
    for (auto source : module->getOps<ir::SourceOp>())
      if (source->getAttrOfType<IntegerAttr>("file_id").getInt() == 0) {
        llvm::SmallString<256> path(argv[4]);
        llvm::sys::path::append(path, llvm::sys::path::filename(
                                          text(source, "path")));
        source->setAttr("path", StringAttr::get(&context, path));
        localized = true;
      }
    require(localized, "file 0 localized");
  }
  Consumer consumer(*module);
  Registry r = consumer.registry;
  installUprobeStub(r);
  // The binding consumes `r = …` and the `if r` after it; a probe of it
  // checks only (E028).
  int bindingProbes = 0;
  bool inProbe = false;
  if (positive)
    r.statements.insert(
        r.statements.begin(),
        {"LocalVariableWriteNode",
         [&](Consumer &c, llvm::ArrayRef<Operation *> list, size_t i,
             unsigned depth) {
           if (inProbe || c.probing || !isOutputStrBinding(c, list[i]))
             return Dispatch<StatementResult>::declined();
           size_t ops = countOps(outputRoot(c)), printed = c.printedRejections;
           bool blocking = c.blocking;
           auto locals = c.locals.size();
           Dispatch<StatementResult> probe =
               Dispatch<StatementResult>::declined();
           {
             ScopeGuard scope(c);
             inProbe = true;
             c.probing = true;
             probe = c.dispatchStatement("LocalVariableWriteNode", list, i,
                                         depth);
             inProbe = false;
           }
           ++bindingProbes;
           require(probe.state == Disposition::Handled &&
                       probe.value->consumed == 2,
                   "probe of `r = output_str` consumes it and `if r`");
           require(countOps(outputRoot(c)) == ops, "binding: probe emits no IR");
           require(c.blocking == blocking, "binding: probe leaves blocking");
           require(c.printedRejections == printed,
                   "binding: probe prints nothing");
           require(c.locals.size() == locals, "binding: probe binds nothing");
           return Dispatch<StatementResult>::declined();
         }});
  consumer.useIsolatedRegistryForTesting(std::move(r));

  FailureOr<Artifacts> result = failure();
  auto err = captureStderr([&] { result = lowerWithDiagnosticGate(consumer); });
  if (!positive) {
    require(failed(result), "the run fails");
    auto want = readFile(argv[3]);
    if (err != want)
      llvm::outs() << "--- ours\n" << err << "--- Go\n" << want;
    require(err == want, "stderr equals Go's build.stderr byte for byte");
    return 0;
  }
  require(succeeded(result), "greetwatch lowers: " + err);
  require(err.empty(), "greetwatch prints nothing: " + err);
  require(succeeded(verify(*module)), "greetwatch verifies");
  require(bindingProbes == 1,
          "the binding was probed (" + std::to_string(bindingProbes) + ")");
  auto want = parseSourceFile<ModuleOp>(argv[3], &context);
  require(bool(want), "parse Go's greetwatch.mlir");
  auto ours = printNoLoc(*module), theirs = printNoLoc(*want);
  if (ours != theirs)
    llvm::outs() << "--- ours\n" << ours << "--- Go\n" << theirs;
  require(ours == theirs, "IR equals Go's (locations elided)");
  ours = locations(*module), theirs = locations(*want);
  if (ours != theirs)
    llvm::outs() << "--- ours\n" << ours << "--- Go\n" << theirs;
  require(ours == theirs, "every op's location equals Go's (file basename)");
  return 0;
}
