//===- Codegen.h - optimisation and object emission -------------*- C++ -*-===//
//
// The freestanding emitter and the grad generator used to hand their LLVM IR
// to clang (`clang -c kern.ll`) and to ask clang for the data layout. This is
// that step for spinel-fs-codegen, the only executable that links it (and the
// five backends): the profile's cflags are mapped to a TargetMachine
// (CPU, features, float ABI, ABI name, optimisation level), the module is
// optimised with the PassBuilder's default pipeline and the object is written
// by the TargetMachine.
//
// The flags are the clang spellings the profiles already carry. The table that
// says what each one means is in Codegen.cpp, in one place; a flag it does not
// list is refused with a diagnostic, never ignored.
//===----------------------------------------------------------------------===//
#ifndef SPINEL_MLIR_FREESTANDING_CODEGEN_H
#define SPINEL_MLIR_FREESTANDING_CODEGEN_H

#include "llvm/ADT/ArrayRef.h"
#include "llvm/ADT/StringRef.h"
#include "llvm/Passes/OptimizationLevel.h"
#include "llvm/Support/CodeGen.h"

#include <memory>
#include <optional>
#include <string>

namespace llvm {
class Module;
class TargetMachine;
} // namespace llvm

namespace spinel_mlir::freestanding {

/// What a list of clang flags means for one triple, as clang's driver would
/// have told its backend for an LLVM IR input.
struct CodegenConfig {
  std::string triple;   ///< normalised, as clang normalises it
  std::string cpu;
  std::string features; ///< comma-separated; each feature appears once
  std::string abiName;
  bool softFloat = false;
  llvm::OptimizationLevel optLevel = llvm::OptimizationLevel::O0;
  /// The last -O is -Os: every defined function is optimised for size.
  bool optSize = false;
  /// -ffreestanding / -fno-builtin: the optimiser may not form library calls.
  bool noBuiltins = false;
  bool emitAddrsig = false;
  llvm::Reloc::Model reloc = llvm::Reloc::Static;
};

/// Maps `flags` (clang spellings, in order; the last -O wins) for `triple`.
/// Returns nullopt with `error` set when a flag is unknown or does not apply
/// to the triple, or when the triple is not one this table describes.
std::optional<CodegenConfig>
codegenConfigFromFlags(llvm::StringRef triple,
                       llvm::ArrayRef<std::string> flags, std::string &error);

std::unique_ptr<llvm::TargetMachine>
createCodegenTargetMachine(const CodegenConfig &config, std::string &error);

/// The data layout `config`'s TargetMachine assumes, or nullopt with `error`.
std::optional<std::string> codegenDataLayout(const CodegenConfig &config,
                                             std::string &error);

/// Sets the module's triple to the normalised one, refuses a module whose data
/// layout differs from the TargetMachine's, runs the optimisation pipeline and
/// writes an object file to `objPath`.
bool optimizeAndEmitObject(llvm::Module &module, const CodegenConfig &config,
                           llvm::StringRef objPath, std::string &error);

} // namespace spinel_mlir::freestanding

#endif
