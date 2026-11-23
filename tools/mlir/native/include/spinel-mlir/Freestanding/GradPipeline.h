// Run Enzyme in process. Frozen spinel-gradfs spawns opt three times; native
// runs the same passes in one process:
// 1. enzyme, loaded with PassPlugin::Load;
// 2. cgscc(inline),function(mem2reg,sroa,early-cse,
//    instcombine<no-verify-fixpoint>,simplifycfg),globaldce;
// 3. internalize,globaldce with the public API list.
// Keep each pipeline spelling in one place, copied verbatim into
// PassBuilder::parsePassPipeline, so edits cannot silently diverge.
#ifndef SPINEL_MLIR_FREESTANDING_GRADPIPELINE_H
#define SPINEL_MLIR_FREESTANDING_GRADPIPELINE_H

#include "llvm/ADT/ArrayRef.h"
#include "llvm/ADT/StringRef.h"
#include "llvm/IR/Module.h"

#include <string>
#include <vector>

namespace spinel_mlir::freestanding {

// Load the Enzyme plugin and run enzyme once. fastMath matches frozen
// -enzyme-fast-math=<0|1>; default false must be explicit because Enzyme defaults
// to true. It is the determinism switch. Missing/incompatible plugins return
// false and error; the caller fails visibly with rc 1, without a fallback route.
bool runEnzyme(llvm::Module &module, llvm::StringRef pluginPath, bool fastMath,
               std::string &error);

/// Cleanup pipeline, verbatim from frozen Python.
bool runGradCleanup(llvm::Module &module, std::string &error);

// internalize,globaldce: exports outside keep become internal.
bool runGradInternalize(llvm::Module &module,
                        llvm::ArrayRef<std::string> keep, std::string &error);

// Sorted unique names of define @diffe* / @fwddiffe*. Collect immediately after
// Enzyme: cleanup may inline them, making adjoint presence optimizer-dependent.
// This is why frozen Python splits the stages.
std::vector<std::string> adjointNames(const llvm::Module &module);
std::vector<std::string> forwardAdjointNames(const llvm::Module &module);

// G5 counts floating-point IR instructions with fast-math flags, unlike frozen regex text counting;
// changes in spelling do not affect it.
unsigned fastMathSites(const llvm::Module &module);

// Number of alloca instructions: build.tsv alloca_in_module.
unsigned allocaCount(const llvm::Module &module);

} // namespace spinel_mlir::freestanding

#endif // SPINEL_MLIR_FREESTANDING_GRADPIPELINE_H
