#pragma once
#include "spinel/Conversion/ConsumerExtensions.h"
namespace spinel::consumer {
struct Registry;
void registerFmodRet(Registry &);
mlir::LogicalResult emitFmodTerminal(Consumer &, mlir::Location, const Expr &,
                                   mlir::Value fired, bool guarded,
                                   std::optional<int64_t> guardValue);
}
