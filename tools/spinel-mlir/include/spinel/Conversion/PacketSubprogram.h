#pragma once
#include "spinel/Conversion/ConsumerExtensions.h"
namespace spinel::consumer {
struct PacketFunctionWindow {
  std::string name;
  int64_t length = 0;
  mlir::Value value;
};
struct PacketSubprogramScope { virtual ~PacketSubprogramScope() = default; };
struct PacketSubprogramHooks {
  std::function<Dispatch<int64_t>(Consumer &, llvm::StringRef)> checkedWindow;
  std::function<llvm::Expected<std::unique_ptr<PacketSubprogramScope>>(
      Consumer &, mlir::Operation *, llvm::StringRef,
      std::optional<PacketFunctionWindow>)> enter;
};
} // namespace spinel::consumer
