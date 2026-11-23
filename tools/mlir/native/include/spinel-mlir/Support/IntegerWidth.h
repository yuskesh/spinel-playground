#ifndef SPINEL_MLIR_SUPPORT_INTEGER_WIDTH_H
#define SPINEL_MLIR_SUPPORT_INTEGER_WIDTH_H

#include "llvm/ADT/StringRef.h"
#include "llvm/TargetParser/Triple.h"

namespace spinel_mlir {
// Decision 0019: the declaration belongs to the source's first line only.
inline bool declaresInt64(llvm::StringRef source) {
  return source.split('\n').first.rtrim("\r") == "# spinel: int64";
}
inline unsigned targetIntegerPointerBits(llvm::StringRef triple) {
  const llvm::Triple t(triple);
  if (t.isX32() || t.isArch32Bit()) return 32;
  if (t.isArch64Bit()) return 64;
  return 0;
}
inline unsigned profileIntegerBits(llvm::StringRef width) {
  if (width == "i32-internal") return 32;
  if (width == "i64-internal") return 64;
  return 0;
}
} // namespace spinel_mlir
#endif
