// E001: preserve Ruby locations; discard only parser-generated input locations.
#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/Verifier.h"
#include "mlir/Parser/Parser.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/Path.h"
#include "llvm/Support/raw_ostream.h"

namespace {
constexpr llvm::StringLiteral reserved = "__spinel_ir_normalize_input__.mlir";
struct TemporaryDirectory {
  llvm::SmallString<128> path;
  ~TemporaryDirectory() {
    if (!path.empty())
      llvm::sys::fs::remove_directories(path);
  }
};
// Inspect locations after parsing, so escaped spellings and location aliases
// cannot hide a reserved filename. Ruby and other explicit source names survive.
bool hasReservedLocation(mlir::Location location) {
  bool found = false;
  location->walk([&](mlir::Location nested) {
    if (auto file = llvm::dyn_cast<mlir::FileLineColLoc>(nested))
      found |= llvm::sys::path::filename(file.getFilename().getValue()) == reserved;
    return mlir::WalkResult::advance();
  });
  return found;
}
} // namespace

int main(int argc, char **argv) {
  if (argc != 2) {
    llvm::errs() << "usage: spinel-ir-normalize INPUT.mlir\n";
    return 2;
  }
  mlir::DialectRegistry registry;
  registry.insert<mlir::ebpf::EBPFDialect, mlir::arith::ArithDialect>();
  mlir::MLIRContext context(registry);
  auto buffer = llvm::MemoryBuffer::getFile(argv[1]);
  if (!buffer) {
    llvm::errs() << "normalizer-input-io: " << buffer.getError().message() << "\n";
    return 2;
  }
  // A separate source name for preflight makes every reserved filename here
  // explicit. The same immutable snapshot is used for the actual parse below.
  auto probe = mlir::parseSourceString<mlir::ModuleOp>(
      (*buffer)->getBuffer(), &context, "__spinel_ir_preflight__");
  if (!probe || mlir::failed(mlir::verify(*probe))) {
    llvm::errs() << "normalizer-invalid-input\n";
    return 1;
  }
  bool collision = false;
  probe->walk([&](mlir::Operation *op) {
    collision |= hasReservedLocation(op->getLoc());
    for (auto &region : op->getRegions())
      for (auto &block : region)
        for (auto arg : block.getArguments())
          collision |= hasReservedLocation(arg.getLoc());
  });
  if (collision) {
    llvm::errs() << "normalizer-reserved-location: " << reserved << "\n";
    return 2;
  }
  TemporaryDirectory temporary;
  if (auto error = llvm::sys::fs::createUniqueDirectory("spinel-ir-normalize", temporary.path)) {
    llvm::errs() << "normalizer-temporary-io: " << error.message() << "\n";
    return 2;
  }
  llvm::SmallString<128> input(temporary.path);
  llvm::sys::path::append(input, reserved);
  std::error_code error;
  {
    llvm::raw_fd_ostream copy(input, error);
    if (error) {
      llvm::errs() << "normalizer-temporary-io: " << error.message() << "\n";
      return 2;
    }
    copy << (*buffer)->getBuffer();
    copy.close();
    if (copy.has_error()) {
      llvm::errs() << "normalizer-temporary-write\n";
      copy.clear_error();
      return 2;
    }
  }
  auto module = mlir::parseSourceFile<mlir::ModuleOp>(input, &context);
  if (!module || mlir::failed(mlir::verify(*module))) {
    llvm::errs() << "normalizer-invalid-snapshot\n";
    return 1;
  }
  auto clean = [&](mlir::Location loc) -> mlir::Location {
    if (auto file = llvm::dyn_cast<mlir::FileLineColLoc>(loc))
      if (file.getFilename().getValue() == input)
        return mlir::UnknownLoc::get(&context);
    return loc;
  };
  module->walk([&](mlir::Operation *op) {
    op->setLoc(clean(op->getLoc()));
    for (auto &region : op->getRegions())
      for (auto &block : region)
        for (auto arg : block.getArguments())
          arg.setLoc(clean(arg.getLoc()));
  });
  mlir::OpPrintingFlags flags;
  flags.printGenericOpForm().enableDebugInfo(true, false);
  module->print(llvm::outs(), flags);
  llvm::outs() << "\n";
  return 0;
}
