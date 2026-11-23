// SpBPF dialect entry, collecting generated declarations.
#ifndef SPINEL_MLIR_DIALECT_SPBPF_IR_SPBPFDIALECT_H
#define SPINEL_MLIR_DIALECT_SPBPF_IR_SPBPFDIALECT_H

#include "mlir/Bytecode/BytecodeOpInterface.h"
#include "mlir/IR/BuiltinTypes.h"
#include "mlir/IR/Dialect.h"
#include "mlir/IR/OpDefinition.h"
#include "mlir/IR/SymbolTable.h"
#include "mlir/Interfaces/SideEffectInterfaces.h"

#include "spinel-mlir/Dialect/SpBPF/IR/SpBPFOpsDialect.h.inc"

#define GET_TYPEDEF_CLASSES
#include "spinel-mlir/Dialect/SpBPF/IR/SpBPFOpsTypes.h.inc"

#define GET_OP_CLASSES
#include "spinel-mlir/Dialect/SpBPF/IR/SpBPFOps.h.inc"

namespace mlir {
namespace spbpf {

// Known sets are printed in verifier diagnostics so unknown values also explain the available
// choices.
bool isKnownProgramKind(llvm::StringRef kind);
bool isKnownMapKind(llvm::StringRef kind);
bool isVerdictAllowedFor(llvm::StringRef programKind, llvm::StringRef action);
bool supportsPacketAccess(llvm::StringRef programKind);
std::string knownProgramKinds();
std::string knownMapKinds();
std::string knownVerdicts(llvm::StringRef programKind);

} // namespace spbpf
} // namespace mlir

#endif // SPINEL_MLIR_DIALECT_SPBPF_IR_SPBPFDIALECT_H
