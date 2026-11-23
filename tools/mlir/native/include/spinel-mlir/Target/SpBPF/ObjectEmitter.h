// Emit BPF ELF with BTF (BPF Type Format). Require bpfel, -mcpu=v1, stable
// symbols, .maps, program section, license, relocations and .BTF. BTF derives
// from DWARF: removing debug information removed .BTF in observed output.
// The main task is therefore building DWARF from the schema, not hand-writing BTF.
#ifndef SPINEL_MLIR_TARGET_SPBPF_OBJECTEMITTER_H
#define SPINEL_MLIR_TARGET_SPBPF_OBJECTEMITTER_H

#include "spinel-mlir/Target/SpBPF/Schema.h"

#include "mlir/IR/BuiltinOps.h"
#include "mlir/Support/LLVM.h"
#include "llvm/Support/raw_ostream.h"

#include <functional>
#include <string>

namespace spbpf {

// Emission diagnostics without exposing MLIR types across the boundary.
struct Diagnostics {
  std::function<void(llvm::StringRef message)> sink;
  bool failed = false;

  void error(const llvm::Twine &msg) {
    failed = true;
    if (sink)
      sink(msg.str());
  }
};

// Artifact section names stay generic: .spbpf_records corresponds to .spnl_records. Both use
// witness pointers in a dedicated section to retain record types in BTF.
inline constexpr llvm::StringLiteral kMapsSection = ".maps";
inline constexpr llvm::StringLiteral kLicenseSection = "license";
inline constexpr llvm::StringLiteral kRecordsSection = ".spbpf_records";

// Write BPF ELF with BTF from an LLVM-dialect module and canonical schema.
mlir::LogicalResult emitObject(mlir::ModuleOp module, const Schema &schema,
                               llvm::raw_pwrite_stream &os,
                               Diagnostics &diags,
                               llvm::StringRef license = "GPL");

} // namespace spbpf

#endif // SPINEL_MLIR_TARGET_SPBPF_OBJECTEMITTER_H
