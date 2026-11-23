#pragma once
#include "spinel/Conversion/Consumer.h"

namespace spinel::consumer {
// Audit only pristine entry-file nodes. Library definitions are never audited
// as user redefinitions. This does not emit or alter producer facts.
LogicalResult auditProgramSource(Consumer &, llvm::ArrayRef<Operation *>);
} // namespace spinel::consumer
