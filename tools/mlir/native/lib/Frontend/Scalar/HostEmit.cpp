// Host --emit ll|obj back half, preserving frozen lower() pipeline and spelling rather than its
// subprocess structure. Run mlir-opt/translation equivalents in process; only clang is spawned
// through the caller runTool.
#include "spinel-mlir/Scalar/HostEmit.h"

#include "mlir/Conversion/ArithToLLVM/ArithToLLVM.h"
#include "mlir/Conversion/ControlFlowToLLVM/ControlFlowToLLVM.h"
#include "mlir/Conversion/FuncToLLVM/ConvertFuncToLLVMPass.h"
#include "mlir/Conversion/ReconcileUnrealizedCasts/ReconcileUnrealizedCasts.h"
#include "mlir/Pass/PassManager.h"

#include "llvm/IR/Attributes.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/Module.h"
#include "mlir/Target/LLVMIR/Dialect/Builtin/BuiltinToLLVMIRTranslation.h"
#include "mlir/Target/LLVMIR/Dialect/LLVMIR/LLVMToLLVMIRTranslation.h"
#include "mlir/Target/LLVMIR/Export.h"

#include "llvm/IR/LLVMContext.h"
#include "llvm/IR/Module.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/raw_ostream.h"

using namespace spinel_mlir::scalar;

void spinel_mlir::scalar::buildCheckedArithStage(
    mlir::PassManager &pm, mlir::spinel::CheckedArithmeticTarget target,
    llvm::StringRef hookSymbol) {
  // Expand spinel.checked_* before standard-dialect lowering. Modules without the opt-in match no
  // patterns, so this step is harmless.
  pm.addPass(
      mlir::spinel::createLowerSpinelCheckedArithmeticPass(target, hookSymbol));
}

void spinel_mlir::scalar::buildLoweringPipeline(
    mlir::PassManager &pm, mlir::spinel::CheckedArithmeticTarget target,
    llvm::StringRef hookSymbol) {
  buildCheckedArithStage(pm, target, hookSymbol);
  // Same four mlir-opt passes in the same order as frozen Python.
  pm.addPass(mlir::createConvertFuncToLLVMPass());
  pm.addPass(mlir::createArithToLLVMConversionPass());
  pm.addPass(mlir::createConvertControlFlowToLLVMPass());
  pm.addPass(mlir::createReconcileUnrealizedCastsPass());
}

namespace {

// Print a module to one file. print returns no status; check stream errors explicitly rather than
// reaching a fatal destructor.
bool writeText(llvm::StringRef path,
               llvm::function_ref<void(llvm::raw_ostream &)> body,
               llvm::function_ref<void(llvm::StringRef)> diag) {
  std::error_code ec;
  llvm::raw_fd_ostream os(path, ec, llvm::sys::fs::OF_Text);
  if (ec) {
    diag("output-failure: cannot write " + path.str() + ": " + ec.message());
    return false;
  }
  body(os);
  os.close();
  if (os.has_error()) {
    std::string message = os.error().message();
    os.clear_error();
    diag("output-failure: cannot write " + path.str() + ": " + message);
    return false;
  }
  return true;
}

} // namespace

bool spinel_mlir::scalar::emitHostModule(
    mlir::ModuleOp module, const HostEmitRequest &req, RunToolFn runTool,
    TempPathFn tempPath, llvm::function_ref<void(llvm::StringRef)> diag) {
  if (req.kind == HostEmitRequest::Kind::Mlir)
    return writeText(req.outputPath,
                     [&](llvm::raw_ostream &os) {
                       module.print(os);
                       os << "\n";
                     },
                     diag);

  mlir::MLIRContext *context = module.getContext();
  mlir::PassManager pm(context);
  buildLoweringPipeline(pm, mlir::spinel::CheckedArithmeticTarget::Hosted,
                        /*hookSymbol=*/{});
  if (mlir::failed(pm.run(module))) {
    diag("lowering-failed: the module does not lower to the LLVM dialect (this "
         "is a generator defect, not a rejected input)");
    return false;
  }

  mlir::registerBuiltinDialectTranslation(*context);
  mlir::registerLLVMDialectTranslation(*context);
  llvm::LLVMContext llvmContext;
  auto llvmModule = mlir::translateModuleToLLVMIR(module, llvmContext);
  if (!llvmModule) {
    diag("translate-failed: the LLVM dialect module did not translate to LLVM "
         "IR (this is a generator defect, not a rejected input)");
    return false;
  }

  if (req.sanitizeAddress)
    for (llvm::Function &fn : llvmModule->functions())
      if (!fn.isDeclaration())
        fn.addFnAttr(llvm::Attribute::SanitizeAddress);
  if (req.noUnwind)
    for (llvm::Function &fn : llvmModule->functions())
      if (!fn.isDeclaration())
        fn.addFnAttr(llvm::Attribute::NoUnwind);

  // .ll is the same artifact for both kinds: Ll writes -o directly; Obj uses a temporary. Frozen Python passes that same IR to clang.
  const std::string llPath = req.kind == HostEmitRequest::Kind::Ll
                                 ? req.outputPath
                                 : tempPath("kern.ll");
  if (!writeText(llPath,
                 [&](llvm::raw_ostream &os) { llvmModule->print(os, nullptr); },
                 diag))
    return false;
  if (req.kind == HostEmitRequest::Kind::Ll)
    return true;

  if (req.clangPath.empty()) {
    diag("clang-missing: cannot locate clang for --emit obj (set LLVM_PREFIX "
         "or LLVM to an LLVM install, or put clang on PATH)");
    return false;
  }
  // Preserve frozen argv order: clang -O2 -Wno-override-module [-flto=thin] <clang args> -c <ll> -o
  // <out>. Caller arguments precede -c so flags such as -O0 can override earlier ones. The shared
  // prefix ends after <clang args>.
  auto prefix = [&]() {
    std::vector<std::string> v = {req.clangPath, "-O2", "-Wno-override-module"};
    if (req.lto)
      v.push_back("-flto=thin");
    for (const std::string &a : req.clangArgs)
      v.push_back(a);
    return v;
  };
  const std::string errPath = tempPath("cc.err");
  auto run = [&](const std::vector<std::string> &owned, llvm::StringRef input) {
    std::vector<llvm::StringRef> argv(owned.begin(), owned.end());
    if (runTool(req.clangPath, argv, "", errPath) != 0) {
      diag("compile-failed: " + req.clangPath + " could not compile " +
           input.str() + " (its stderr is at " + errPath + ")");
      return false;
    }
    return true;
  };

  // TWO STEPS WHEN THE CALLER ASKED FOR THE OPTIMISED IR, and the split is
  // where the middle end ends: step one stops after it and writes the IR, step
  // two generates the object from that IR with the middle end DISABLED, so the
  // optimisation runs exactly once and the object is the one-step object. The
  // byte-for-byte evidence is in HostEmit.h beside the field.
  if (!req.optimisedIrPath.empty()) {
    std::vector<std::string> ir = prefix();
    ir.push_back("-emit-llvm");
    ir.push_back("-c");
    ir.push_back(llPath);
    ir.push_back("-o");
    ir.push_back(req.optimisedIrPath);
    if (!run(ir, llPath))
      return false;
    std::vector<std::string> obj = prefix();
    // `-Xclang` because this is a frontend option: it stops the pass pipeline
    // from being built at all, rather than emptying it.
    obj.push_back("-Xclang");
    obj.push_back("-disable-llvm-passes");
    obj.push_back("-c");
    obj.push_back(req.optimisedIrPath);
    obj.push_back("-o");
    obj.push_back(req.outputPath);
    return run(obj, req.optimisedIrPath);
  }

  std::vector<std::string> owned = prefix();
  owned.push_back("-c");
  owned.push_back(llPath);
  owned.push_back("-o");
  owned.push_back(req.outputPath);
  if (!run(owned, llPath)) {
    return false;
  }
  return true;
}
