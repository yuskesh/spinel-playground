// Internal owning YAML tree shared by profile and ledger readers. PlatformLedger reads
// menus.yaml/base through the same tree/builder as ProfileReader, avoiding divergent copies. Do not
// expose this as an installed public header: YNode is intermediate validation state; only complete
// FreestandingProfile crosses the boundary.
#ifndef SPINEL_MLIR_LIB_FREESTANDING_PROFILEYAML_H
#define SPINEL_MLIR_LIB_FREESTANDING_PROFILEYAML_H

#include "spinel-mlir/Freestanding/Diagnostics.h"
#include "spinel-mlir/Freestanding/Profile.h"

#include "llvm/ADT/ArrayRef.h"
#include "llvm/ADT/STLExtras.h"
#include "llvm/ADT/StringRef.h"
#include "llvm/Support/YAMLParser.h"

#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace spinel_mlir::freestanding {

// Copy streaming YAML to an owning tree in one pass. Advancing MappingNode iterators skips the
// current value; retaining yaml::Node pointers for later loses unparsed nested content and causes
// Unexpected token. This broke every params: [[f64_buf,in],len,...] in base.yaml during
// implementation. Copy values immediately; subsequent validation depends only on the owning tree.
struct YNode {
  enum class Kind { Scalar, Sequence, Mapping, Bad };
  Kind kind = Kind::Bad;
  std::string scalar;
  std::vector<YNode> seq;
  std::vector<std::pair<std::string, YNode>> map;

  bool isScalar() const { return kind == Kind::Scalar; }
  bool isSeq() const { return kind == Kind::Sequence; }
  bool isMap() const { return kind == Kind::Mapping; }
  const YNode *find(llvm::StringRef key) const {
    for (const auto &kv : map)
      if (kv.first == key)
        return &kv.second;
    return nullptr;
  }
};

// Duplicate mapping keys: PyYAML silently used last-wins while native retained first, selecting
// different overflow policies even when A/B verdicts matched. The 2026-09-01 decision refuses
// duplicates at P1. dup records the first duplicate key path.
YNode convert(llvm::yaml::Node *node, const std::string &path,
              std::string *dup);

// Parse exactly one YAML document. Document-count errors, duplicate keys and nonmapping roots
// report classified P1 diagnostics and nullopt. Preserve initial wording, fixed by sixty
// cases/pins.
std::optional<YNode> parseProfileYaml(llvm::StringRef path,
                                      llvm::StringRef yamlText,
                                      FsDiagnosticFn diag);

// Validate legacy target/abi/runtime/platform schema from P1 onward. Excludes the platform-first
// refusal, which callers decide before entering. Refusal returns nullptr through diag.
std::unique_ptr<FreestandingProfile>
validateProfile(llvm::StringRef path, const YNode &root, FsDiagnosticFn diag);

// Resolver-only marker for platform-first provenance; sole function permitted to alter
// FreestandingProfile private state.
void markPlatformFirst(FreestandingProfile &p, llvm::StringRef basePath);

class ProfileBuilder {
public:
  ProfileBuilder(llvm::StringRef path, FsDiagnosticFn diag)
      : path_(path), diag_(diag), profile_(new FreestandingProfile()) {}

  bool reject(Stage stage, Category category, llvm::StringRef subject,
              int argPos, const llvm::Twine &detail) {
    Rejection r;
    r.stage = stage;
    r.category = category;
    r.subject = subject.str();
    r.argPos = argPos;
    r.detail = (path_ + ": " + detail).str();
    diag_(r);
    return false;
  }

  std::unique_ptr<FreestandingProfile> take() { return std::move(profile_); }
  FreestandingProfile &p() { return *profile_; }

private:
  std::string path_;
  FsDiagnosticFn diag_;
  std::unique_ptr<FreestandingProfile> profile_;
};

// Closed-set utilities shared by profile/ledger readers.
inline bool contains(llvm::ArrayRef<llvm::StringRef> set, llvm::StringRef v) {
  return llvm::is_contained(set, v);
}

inline std::string joinSet(llvm::ArrayRef<llvm::StringRef> set,
                           llvm::StringRef sep) {
  std::string out;
  for (size_t i = 0; i < set.size(); ++i) {
    if (i)
      out += sep.str();
    out += set[i].str();
  }
  return out;
}

// Sort strings and join with sep. Diagnostic enumeration must be deterministic, independent of
// mapping traversal order.
std::string joinSorted(std::vector<std::string> names, llvm::StringRef sep);

} // namespace spinel_mlir::freestanding

#endif // SPINEL_MLIR_LIB_FREESTANDING_PROFILEYAML_H
