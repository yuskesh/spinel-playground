#pragma once
#include "spinel/Conversion/ConsumerExtensions.h"
#include "llvm/Support/Error.h"
namespace spinel::consumer {
// Owned semantic description; no generated SSA or short-lived block capture.
struct PacketLoopWindow {
  mlir::Operation *binding = nullptr, *branch = nullptr;
  Expr offset;
  int64_t length = 0;
  std::string name;
  size_t consumed = 2;
};
struct PacketLoopScope { virtual ~PacketLoopScope() = default; };
struct PacketLoopHooks {
  std::function<Dispatch<PacketLoopWindow>(
      Consumer &, llvm::ArrayRef<mlir::Operation *>, size_t, unsigned)> check;
  std::function<llvm::Expected<std::unique_ptr<PacketLoopScope>>(
      Consumer &, const PacketLoopWindow &)> enterCheck;
  std::function<mlir::LogicalResult(
      Consumer &, const PacketLoopWindow &,
      llvm::function_ref<mlir::LogicalResult()>,
      llvm::function_ref<mlir::LogicalResult()>)> emit;
};
} // namespace spinel::consumer
