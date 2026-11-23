// In-process undefined-symbol gate for freestanding objects. Unlike frozen
// tools/freestanding/undef-check.py, use LLVMObject without spawning Python;
// apply the same nine rule stages and reason strings.
// Historically this intentionally duplicated Python module sets as C++ static
// tables, an exception to the single-source rule. undef-check.py and
// spinel_alloc_free.py hashes were pinned in cp4/identity.tsv so Python changes
// failed the gate, as for menus.yaml. Do not pretend to follow automatically:
// a visible failure is more honest.
// Stage G checks the completed object, unlike P1/P2 input declarations and B/C
// body-subset checks, so it has a separate classification.
#ifndef SPINEL_MLIR_FREESTANDING_UNDEFGATE_H
#define SPINEL_MLIR_FREESTANDING_UNDEFGATE_H

#include "spinel-mlir/Freestanding/Profile.h"

#include "llvm/ADT/StringRef.h"

#include <string>
#include <vector>

namespace spinel_mlir::freestanding {

// One TSV row, with the same four columns as frozen undef-check.py.
struct UndefRow {
  std::string verdict; ///< ALLOW | DENY
  std::string object;  ///< Object basename; omit paths for environment independence.
  std::string symbol;
  std::string reason;
};

// Policy values only. Only the reader can construct FreestandingProfile, but
// spinel-fs-check --undef must also work without a profile or with CLI overrides,
// as frozen undef-check.py does. The gate reads only these five fields; use
// this struct without weakening the profile's construction invariant.
struct UndefPolicy {
  std::string triple;
  std::string libc = "none";
  std::string libm = "none";
  std::string compilerRt = "allow";
  std::vector<std::string> allowed;
};

// Copy policy from FreestandingProfile without changing existing callers.
UndefPolicy undefPolicyOf(const FreestandingProfile &profile);

// Policy overload; runUndefGate(objPath, profile, ...) is a thin wrapper.
bool runUndefGate(llvm::StringRef objPath, const UndefPolicy &policy,
                  std::vector<UndefRow> &rows, std::string *infraError);

// Classify objPath undefined symbols by profile policy; append rows sorted by
// symbol, as frozen undefined() does. Return true iff no row is DENY. Unreadable
// or unrecognized object format is infrastructure, not invalid input: set
// infraError and return false; the caller reports Infrastructure, not Rejection.
bool runUndefGate(llvm::StringRef objPath, const FreestandingProfile &profile,
                  std::vector<UndefRow> &rows, std::string *infraError);

// Serialize rows to frozen-compatible TSV: header, rows and a final newline.
std::string formatUndefTsv(llvm::ArrayRef<UndefRow> rows);

} // namespace spinel_mlir::freestanding

#endif // SPINEL_MLIR_FREESTANDING_UNDEFGATE_H
