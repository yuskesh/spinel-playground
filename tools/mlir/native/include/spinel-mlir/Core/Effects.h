//===- Effects.h - an application entry's effects, derived --------*- C++ -*-===//
//
// Decision 0014 §6. An entry's report says what it does to its state and how
// often it calls each extern: which of its buffers it writes, transitively
// through helpers and through `inout` extern arguments, and each extern's call
// count per invocation, the sum over its sites of the product of the enclosing
// derived bounds. Both are derived from the admitted closure and the loop
// analysis; nothing here is declared by the application.
//
//===----------------------------------------------------------------------===//
#ifndef SPINEL_MLIR_CORE_EFFECTS_H
#define SPINEL_MLIR_CORE_EFFECTS_H

#include "spinel-mlir/Contract/Model.h"
#include "spinel-mlir/Core/Boundary.h"
#include "spinel-mlir/Core/Eligibility.h"
#include "spinel-mlir/Core/LoopBounds.h"

#include <map>
#include <string>
#include <vector>

namespace spinel_mlir::core {

struct ExternUse {
  size_t externIndex = 0;
  std::string callsExpr;  ///< over entry parameters; empty when not derived
  bool derived = false;
  std::string reason;     ///< why not, when not derived
  size_t sites = 0;
};

struct EntryEffects {
  /// Entry buffer name to whether the entry writes it, transitively.
  std::map<std::string, bool> bufferWritten;
  std::vector<ExternUse> externs;  ///< in the contract's extern order
};

/// `admitted` must be the report that admitted `contract`'s entry, and
/// `loops` the loop analysis over the same closure.
EntryEffects deriveEffects(const contract::ContractModule &module,
                           const EligibilityReport &admitted,
                           const LoopBoundResult &loops,
                           const BoundaryContract &contract);

} // namespace spinel_mlir::core
#endif // SPINEL_MLIR_CORE_EFFECTS_H
