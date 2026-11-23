// Build a linked module from Ruby, matching frozen build_whole_ll. Spawn only
// spinel -c and clang; extract archives and link in process with object::Archive
// and Linker instead of llvm-ar x / llvm-link. Keep the Module, avoiding llvm-dis.
#ifndef SPINEL_MLIR_REALTIME_WHOLEMODULE_H
#define SPINEL_MLIR_REALTIME_WHOLEMODULE_H

#include "llvm/ADT/StringRef.h"
#include "llvm/IR/LLVMContext.h"
#include "llvm/IR/Module.h"

#include <memory>
#include <string>
#include <vector>

namespace spinel_mlir::realtime {

struct BuildOptions {
  std::string spinelBin;   ///< vendor/spinel/bin/spinel
  std::string spinelDir;   ///< vendor/spinel
  std::string llvmBin;     ///< $LLVM_PREFIX/bin
  std::string bcDir;       ///< tools/llvm/build
  std::string intOverflow; ///< "" | raise | wrap | promote
  std::vector<std::string> linkBc;
  std::string work;        ///< Intermediate-file directory.
  bool verbose = false;
};

/// A translation unit already compiled to IR (`whole`), linked with the
/// runtime bitcode archive and opts.linkBc exactly as buildWholeModule links
/// its own: the archive's members in name order, the last of a name winning.
/// `threads` selects libspinel_rt_mt_lto.a. Used for an IR the caller built
/// itself, such as gradgen's TU after the GC-root elision pass.
std::unique_ptr<llvm::Module> linkRuntime(std::unique_ptr<llvm::Module> whole,
                                          bool threads, const BuildOptions &opts,
                                          llvm::LLVMContext &ctx,
                                          std::string &error);

// Ruby -> generated C -> .tu.ll -> module linked with runtime bitcode. Failure returns nullptr and
// the frozen error wording; stage names the failed step.
std::unique_ptr<llvm::Module> buildWholeModule(llvm::StringRef source,
                                               const BuildOptions &opts,
                                               llvm::LLVMContext &ctx,
                                               std::string &error);

// Read an already linked .ll or .bc module.
std::unique_ptr<llvm::Module> parseInput(llvm::StringRef path,
                                         llvm::LLVMContext &ctx,
                                         std::string &error);

} // namespace spinel_mlir::realtime

#endif // SPINEL_MLIR_REALTIME_WHOLEMODULE_H
