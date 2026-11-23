// Build the Enzyme shim directly with IRBuilder instead of emitting C and
// calling clang. Preserve semantics: zero shadows and ASSIGN (not accumulate),
// use enzyme_dup for active arguments and enzyme_const otherwise; Hessian-vector
// products use forward-over-reverse. Reuse the kernel triple and data layout
// from the same profile, avoiding the frozen pipeline's layout-mismatch hole.
// Direct IR avoids another hazard: without -ffreestanding -fno-builtin, clang's
// loop-idiom pass could turn shadow zeroing into memset, refused by libc:none.
// Build the loop directly and omit loop-idiom from cleanup, removing that path.
#ifndef SPINEL_MLIR_FREESTANDING_GRADSHIM_H
#define SPINEL_MLIR_FREESTANDING_GRADSHIM_H

#include "spinel-mlir/Freestanding/Declaration.h"
#include "spinel-mlir/Freestanding/GradDeclaration.h"

#include "llvm/ADT/ArrayRef.h"
#include "llvm/IR/Module.h"

#include <string>
#include <vector>

namespace spinel_mlir::freestanding {

// One declaration accepted by G1-fs; pnames are def arguments in boundary order.
struct GradTarget {
  const FsGradDecl *grad = nullptr;
  const FsDecl *fs = nullptr;
  std::vector<std::string> pnames;
};

// A :len sizes the immediately preceding run of buffers. Return the index of the :len sizing
// params[idx], or -1 if absent.
int lenGoverning(llvm::ArrayRef<FsParam> params, size_t idx);

// Build the shim into module; using the kernel module is equivalent to linking
// a separate one. This implementation nevertheless uses a separate module and
// Linker to preserve the frozen pipeline's stage count. Failure returns false
// plus a one-line error. Function codegen attributes come from profile cflags:
// frozen clang leaves attributes such as -Os -> optsize on shim.c functions.
// Direct IR must supply them too, or inlining changes the artifact structure.
// Observed without optsize: the adjoint inlined into the gradient wrapper and
// the object referenced one additional symbol.
struct ShimCodegenAttrs {
  bool optSize = false;  ///< `-Os`
  bool minSize = false;  ///< `-Oz`
  std::string cpu;       ///< -mcpu= / -march=; target-transform information affects inlining cost.
  std::string features;  ///< Profile target-features; omit when empty.
};

// Derive those attributes from profile target.cflags spelling.
ShimCodegenAttrs shimAttrsFromCflags(llvm::ArrayRef<std::string> cflags);

bool buildEnzymeShim(llvm::Module &module, llvm::ArrayRef<GradTarget> targets,
                     const ShimCodegenAttrs &attrs, std::string &error);

} // namespace spinel_mlir::freestanding

#endif // SPINEL_MLIR_FREESTANDING_GRADSHIM_H
