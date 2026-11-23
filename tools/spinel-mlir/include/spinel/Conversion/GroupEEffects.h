#pragma once
#include "spinel/Conversion/ConsumerExtensions.h"
namespace spinel::consumer {
struct MapDecl;
// Check has no IR/usage publication; a statement effect has no result SSA.
Dispatch<Expr> checkCounterAdd(Consumer &,mlir::Operation *);
mlir::LogicalResult emitCounterAdd(Consumer &,const Expr &);
// Assignment-only status checks; the caller owns local binding and emission.
Dispatch<Expr> checkStatusWrite(Consumer &,mlir::Operation *);
std::string discardedHashStatus(const MapDecl &, llvm::StringRef);
} // namespace spinel::consumer
