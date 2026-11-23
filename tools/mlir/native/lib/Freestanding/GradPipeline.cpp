// In-process Enzyme execution.
#include "spinel-mlir/Freestanding/GradPipeline.h"

#include "llvm/ADT/StringSet.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Operator.h"
#include "llvm/IR/PassManager.h"
#include "llvm/Passes/PassBuilder.h"
// This header moved from llvm/Passes/PassPlugin.h in LLVM 22.
#include "llvm/Plugins/PassPlugin.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/Error.h"
#include "llvm/Transforms/IPO/GlobalDCE.h"
#include "llvm/Transforms/IPO/Internalize.h"

using namespace llvm;

namespace spinel_mlir::freestanding {
namespace {

// Pipeline spelling is verbatim from frozen spinel-gradfs main.
constexpr const char *kCleanupPipeline =
    "cgscc(inline),function(mem2reg,sroa,early-cse,"
    "instcombine<no-verify-fixpoint>,simplifycfg),globaldce";
constexpr const char *kInternalizePipeline = "internalize,globaldce";

// Find cl::opt by name and set it through the same path as opt CLI. Changes to plugin type/default
// then have one adaptation point.
bool setClOption(StringRef name, StringRef value, std::string &error) {
  auto &opts = cl::getRegisteredOptions();
  auto it = opts.find(name);
  if (it == opts.end()) {
    error = ("the Enzyme plugin does not register -" + name +
             " -- the version moved (E167 pins v0.0.290)")
                .str();
    return false;
  }
  if (it->second->addOccurrence(0, name, value)) {
    error = ("cannot set -" + name + "=" + value).str();
    return false;
  }
  return true;
}

bool runPipeline(Module &m, StringRef pipeline, const PassPlugin *plugin,
                 std::string &error) {
  PassBuilder pb;
  if (plugin)
    plugin->registerPassBuilderCallbacks(pb);
  LoopAnalysisManager lam;
  FunctionAnalysisManager fam;
  CGSCCAnalysisManager cgam;
  ModuleAnalysisManager mam;
  pb.registerModuleAnalyses(mam);
  pb.registerCGSCCAnalyses(cgam);
  pb.registerFunctionAnalyses(fam);
  pb.registerLoopAnalyses(lam);
  pb.crossRegisterProxies(lam, fam, cgam, mam);
  ModulePassManager mpm;
  if (Error e = pb.parsePassPipeline(mpm, pipeline)) {
    error = ("cannot parse the pass pipeline '" + pipeline +
             "': " + toString(std::move(e)))
                .str();
    return false;
  }
  mpm.run(m, mam);
  return true;
}

std::vector<std::string> definedWithPrefix(const Module &m, StringRef prefix,
                                           StringRef notPrefix) {
  std::vector<std::string> out;
  for (const Function &f : m) {
    if (f.isDeclaration())
      continue;
    StringRef n = f.getName();
    if (!n.starts_with(prefix))
      continue;
    if (!notPrefix.empty() && n.starts_with(notPrefix))
      continue;
    out.push_back(n.str());
  }
  llvm::sort(out);
  out.erase(std::unique(out.begin(), out.end()), out.end());
  return out;
}

} // namespace

bool runEnzyme(Module &m, StringRef pluginPath, bool fastMath,
               std::string &error) {
  auto plugin = PassPlugin::Load(pluginPath.str());
  if (!plugin) {
    error = ("cannot load the Enzyme plugin " + pluginPath + ": " +
             toString(plugin.takeError()))
                .str();
    return false;
  }
  // Determinism switch: explicitly set false because Enzyme defaults true. fast permits
  // reassociation/FMA contraction, and target-dependent fusion would break bit-identical gradients.
  if (!setClOption("enzyme-fast-math", fastMath ? "1" : "0", error))
    return false;
  return runPipeline(m, "enzyme", &*plugin, error);
}

bool runGradCleanup(Module &m, std::string &error) {
  return runPipeline(m, kCleanupPipeline, nullptr, error);
}

bool runGradInternalize(Module &m, ArrayRef<std::string> keep,
                        std::string &error) {
  // Match frozen opt -passes=internalize,globaldce -internalize-public-api-list=<keep>, using the
  // same passes/order but an InternalizePass predicate rather than cl::list. Shared libLLVM may
  // omit that registered option (observed); global options also leak prior keep values on repeated
  // calls. A predicate is local to each invocation.
  llvm::StringSet<> keepSet;
  for (const std::string &k : keep)
    keepSet.insert(k);
  ModulePassManager mpm;
  mpm.addPass(InternalizePass([&keepSet](const GlobalValue &gv) {
    return keepSet.contains(gv.getName());
  }));
  mpm.addPass(GlobalDCEPass());
  PassBuilder pb;
  LoopAnalysisManager lam;
  FunctionAnalysisManager fam;
  CGSCCAnalysisManager cgam;
  ModuleAnalysisManager mam;
  pb.registerModuleAnalyses(mam);
  pb.registerCGSCCAnalyses(cgam);
  pb.registerFunctionAnalyses(fam);
  pb.registerLoopAnalyses(lam);
  pb.crossRegisterProxies(lam, fam, cgam, mam);
  mpm.run(m, mam);
  (void)error;
  (void)kInternalizePipeline;
  return true;
}

std::vector<std::string> adjointNames(const Module &m) {
  return definedWithPrefix(m, "diffe", "");
}

std::vector<std::string> forwardAdjointNames(const Module &m) {
  return definedWithPrefix(m, "fwddiffe", "");
}

unsigned fastMathSites(const Module &m) {
  unsigned n = 0;
  for (const Function &f : m)
    for (const BasicBlock &bb : f)
      for (const Instruction &i : bb)
        if (const auto *op = dyn_cast<FPMathOperator>(&i))
          if (op->getFastMathFlags().any())
            ++n;
  return n;
}

unsigned allocaCount(const Module &m) {
  unsigned n = 0;
  for (const Function &f : m)
    for (const BasicBlock &bb : f)
      for (const Instruction &i : bb)
        if (isa<AllocaInst>(&i))
          ++n;
  return n;
}

} // namespace spinel_mlir::freestanding
