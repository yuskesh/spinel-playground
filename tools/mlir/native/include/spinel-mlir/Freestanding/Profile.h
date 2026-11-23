// Immutable typed model for tools/freestanding/profiles/*.yaml, rather than
// an arbitrary dialect-attribute dictionary. The 2026-08-31 decision chose
// direct native YAML over a Python dump or CLI flags: the schema has four
// sections, thirteen keys (nine required), all closed ranges; LLVM already
// provides YAMLParser.h; and only native parsing can report unknown-profile-key
// without Python refusing first. Generation also needs triple/layout/cflags.
// Duplicate only the thirteen-key validation, not the generator.
// Depend only on LLVMSupport, not MLIR. Only readFreestandingProfile constructs
// a model after all sections validate; never expose a partial one or silently
// fall back on unreadable values. Keep overflow/trap/bounds policy here, sharing
// no implementation lines with hosted checked-integer semantics.
#ifndef SPINEL_MLIR_FREESTANDING_PROFILE_H
#define SPINEL_MLIR_FREESTANDING_PROFILE_H

#include "spinel-mlir/Freestanding/Diagnostics.h"

#include "llvm/ADT/ArrayRef.h"
#include "llvm/ADT/StringRef.h"

#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace spinel_mlir::freestanding {

// One boundary argument; declarations and externs use the same grammar and therefore the same type.
struct FsParam {
  enum class Kind { Scalar, Len, Buffer };
  Kind kind = Kind::Scalar;
  std::string type;      ///< Scalar/buffer element type (i8..u32, f32, f64).
  std::string direction; ///< Buffers only: in / out / inout.
  int lenIndex = -1;     ///< Buffer: zero-based index of its len argument.
  int bufIndex = -1;     ///< Length: zero-based index of the first buffer in its run.
};

// One callable platform extern.
struct FsExtern {
  std::string name;   ///< Name called from Ruby.
  std::string symbol; ///< C symbol to link.
  std::string returns;
  std::vector<FsParam> params;
};

// Closed set; values themselves are contractual, so expose them in this header.
llvm::ArrayRef<llvm::StringRef> boundaryScalarTypes();  ///< 9
llvm::ArrayRef<llvm::StringRef> bufferElementTypes();   ///< 9
llvm::ArrayRef<llvm::StringRef> bufferDirections();     ///< 3 (in/out/inout)
llvm::ArrayRef<llvm::StringRef> overflowModes();        ///< 2 (trap/wrap)
llvm::ArrayRef<llvm::StringRef> boundsModes();          ///< 2 (trap/unchecked)
llvm::ArrayRef<llvm::StringRef> externTypes();          ///< 5
llvm::ArrayRef<llvm::StringRef> externReservedNames();  ///< 9

// One C-identifier predicate shared by extern symbols, trap hooks and export: names, avoiding
// divergent copies.
bool isCIdentifier(llvm::StringRef s);

// C spelling of boundary types. Headers and objects use separate generation
// paths, so keep their mapping in one place (the reason ABI checking exists).
// boundaryScalarTypes() defines the closed set. Unknown spelling returns empty
// so the caller can refuse it by name.
llvm::StringRef cScalarType(llvm::StringRef fsType);

class ProfileBuilder;
struct YNode;

class FreestandingProfile {
public:
  llvm::StringRef triple() const { return triple_; }
  llvm::StringRef cpu() const { return cpu_; }
  llvm::StringRef dataLayout() const { return dataLayout_; }
  llvm::ArrayRef<std::string> cflags() const { return cflags_; }

  llvm::StringRef boundary() const { return boundary_; }
  llvm::StringRef intWidth() const { return intWidth_; }
  llvm::StringRef overflow() const { return overflow_; }
  llvm::StringRef trapHook() const { return trapHook_; }

  llvm::StringRef libc() const { return libc_; }
  llvm::StringRef libm() const { return libm_; }
  llvm::StringRef compilerRt() const { return compilerRt_; }

  llvm::StringRef platformType() const { return platformType_; }
  // Allowed undefined symbols at link time; always includes the trap hook.
  llvm::ArrayRef<std::string> allowedSymbols() const { return allowed_; }
  llvm::ArrayRef<FsExtern> externs() const { return externs_; }
  const FsExtern *findExtern(llvm::StringRef name) const;

  // Whether resolved from platform-first form. Historical admission excluded
  // that form from the default route; once the reader accepted it, this predicate
  // carried that restriction until the later admission checkpoint.
  bool platformFirst() const { return platformFirst_; }
  // Base profile path read for platform-first form; empty for legacy form.
  llvm::StringRef basePath() const { return basePath_; }

private:
  // Only the reader constructs a model, preventing partial models from escaping, as with
  // ContractModule/ContractBuilder.
  friend class ProfileBuilder;
  friend std::unique_ptr<FreestandingProfile>
  validateProfile(llvm::StringRef path, const YNode &root, FsDiagnosticFn diag);
  // Only this function may mark platform-first provenance.
  friend void markPlatformFirst(FreestandingProfile &p,
                                llvm::StringRef basePath);
  FreestandingProfile() = default;

  std::string triple_, cpu_, dataLayout_;
  std::vector<std::string> cflags_;
  std::string boundary_, intWidth_, overflow_, trapHook_;
  std::string libc_, libm_, compilerRt_;
  std::string platformType_;
  std::vector<std::string> allowed_;
  std::vector<FsExtern> externs_;
  bool platformFirst_ = false;
  std::string basePath_;
};

// Sole YAML parse/validation entry. Refuse through diag at P1/P2 and return
// nullptr, never a partial model. Does not accept platform-first form: its
// expansion needs the tools/platform/spinel_platform.py ledger and lay outside
// the initial legacy-profile checkpoint. Refuse it explicitly, not silently.
std::unique_ptr<FreestandingProfile>
readFreestandingProfile(llvm::StringRef path, llvm::StringRef yamlText,
                        FsDiagnosticFn diag);

} // namespace spinel_mlir::freestanding

#endif // SPINEL_MLIR_FREESTANDING_PROFILE_H
