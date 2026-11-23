// Sole shared pass-registration point for library APIs and CLI, preventing independent mlir-opt
// command reconstruction. The foundation initially registered standard canonicalize/CSE transforms;
// dialect Transforms directories add spinel/spbpf passes here.
#ifndef SPINEL_MLIR_PASSES_H
#define SPINEL_MLIR_PASSES_H

namespace spinel_mlir {

void registerSpinelMLIRPasses();

} // namespace spinel_mlir

#endif // SPINEL_MLIR_PASSES_H
