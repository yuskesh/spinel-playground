// mlir-opt with SpBPF registered. The system tool lacks this dialect, so this executable is
// required to run passes and verify all SpBPF operations lower away; it closed an omission in the
// original file list.
#include "spinel-mlir/Dialect/SpBPF/IR/SpBPFDialect.h"
#include "spinel-mlir/Dialect/SpBPF/Transforms/Passes.h"

#include "mlir/InitAllDialects.h"
#include "mlir/InitAllPasses.h"
#include "mlir/Tools/mlir-opt/MlirOptMain.h"

int main(int argc, char **argv) {
  mlir::DialectRegistry registry;
  mlir::registerAllDialects(registry);
  registry.insert<mlir::spbpf::SpBPFDialect>();

  mlir::registerAllPasses();
  mlir::spbpf::registerSpBPFPasses();

  return mlir::asMainReturnCode(
      mlir::MlirOptMain(argc, argv, "spbpf optimizer driver\n", registry));
}
