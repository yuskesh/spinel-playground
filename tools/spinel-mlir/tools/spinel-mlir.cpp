#include "spinel/Conversion/InspectionOutput.h"
#include "spinel/Dialect/SpinelFacts/IR/SpinelFactsDialect.h"
#include "spinel/Import/Import.h"
#include "spinel/Conversion/LowerToEBPF.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/Verifier.h"
#include "mlir/Parser/Parser.h"
#include "mlir/Pass/PassManager.h"
#include "mlir/Pass/Pass.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/Path.h"
#include "llvm/Support/raw_ostream.h"

static bool publish(llvm::StringRef directory, mlir::ModuleOp module,
                    const spinel::Artifacts &artifacts) {
  if (llvm::sys::fs::exists(directory)) {
    llvm::errs() << "spinel-mlir: output directory already exists\n";
    return false;
  }
  llvm::SmallString<256> temp;
  auto ec = llvm::sys::fs::createUniqueDirectory(directory + ".tmp", temp);
  if (ec) {
    llvm::errs() << "spinel-mlir: create output temp: " << ec.message() << "\n";
    return false;
  }
  std::string ir;
  llvm::raw_string_ostream stream(ir);
  mlir::OpPrintingFlags flags;
  flags.enableDebugInfo(true, false);
  module.print(stream, flags);
  stream << "\n";
  bool ok = true;
  for (auto entry : {std::pair<llvm::StringRef, llvm::StringRef>{"xdpcount.mlir", ir},
                     {"xdpcount.schema.json", artifacts.schema},
                     {"xdpcount.maps.json", artifacts.maps}}) {
    llvm::SmallString<256> path(temp);
    llvm::sys::path::append(path, entry.first);
    llvm::raw_fd_ostream file(path, ec);
    if (ec) { ok = false; break; }
    file << entry.second;
    file.close();
    if (file.has_error()) {
      ec = file.error(); file.clear_error(); ok = false; break;
    }
  }
  if (ok) {
    ec = llvm::sys::fs::rename(temp, directory);
    ok = !ec;
  }
  if (!ok) {
    llvm::errs() << "spinel-mlir: publish artifacts: " << ec.message() << "\n";
    auto cleanup = llvm::sys::fs::remove_directories(temp);
    if (cleanup) llvm::errs() << "spinel-mlir: cleanup temp: " << cleanup.message() << "\n";
  }
  return ok;
}
int main(int argc, char **argv) {
  if (argc == 2 && llvm::StringRef(argv[1]) == "--build-info")
    return spinel::printBuildInfo();
  for (int i = 1; i < argc; ++i)
    if (llvm::StringRef(argv[i]) == "--inspect-dir")
      return spinel::runInspectionCLI(argc, argv);
  llvm::StringRef mode = argc > 1 ? argv[1] : "";
  bool emit = mode == "--emit-dir";
  if ((!emit && (argc != 3 || (mode != "--verify-only" && mode != "--check"))) ||
      (emit && argc != 4)) {
    llvm::errs() << "usage: spinel-mlir --verify-only|--check INPUT.mlir\n"
                    "       spinel-mlir --emit-dir OUTPUT INPUT.mlir\n";
    return 2;
  }
  mlir::DialectRegistry registry;
  registry.insert<spinel::ir::SpinelFactsDialect>();
  mlir::MLIRContext context(registry);
  auto module = mlir::parseSourceFile<mlir::ModuleOp>(argv[emit ? 3 : 2], &context);
  if (!module || mlir::failed(mlir::verify(*module)) ||
      mlir::failed(spinel::verifyImport(*module)))
    return 1;
  if (mode == "--verify-only") return 0;
  spinel::Artifacts artifacts;
  mlir::PassManager manager(&context);
  manager.addPass(spinel::createLowerToEBPFPass(artifacts));
  if (mlir::failed(manager.run(*module))) return 1;
  return !emit || publish(argv[2], *module, artifacts) ? 0 : 1;
}
