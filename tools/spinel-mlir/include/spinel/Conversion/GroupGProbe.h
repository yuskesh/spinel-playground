#pragma once
#include "spinel/Conversion/ConsumerExtensions.h"

namespace spinel::consumer {
// Registered exactly once by E020's registerGroupG. No process-global state.
void registerGroupGProbe(Registry &registry);
// Diagnostic-only continuation after a rejected direct tracing-string binding.
void diagnoseRejectedTracingStringLocal(Consumer &, llvm::ArrayRef<mlir::Operation *>,
    size_t index, unsigned depth, size_t beforeDiagnostics);
} // namespace spinel::consumer
