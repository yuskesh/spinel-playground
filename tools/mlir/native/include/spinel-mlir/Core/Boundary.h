//===- Boundary.h - version-1 CORE buffer boundary contract -----*- C++ -*-===//
//
// Decision 0007.  The contract file is the entry face for the checked
// numeric/buffer boundary: it names a source snapshot, one entry method, that
// method's parameters by NAME, each parameter's scalar domain or buffer element
// type and access mode, each buffer's own count parameter, and the result type.
//
// It is versioned independently of the analysis dump (Contract/Reader.h reads
// spinel-typedump's four faces; this reads a separate file with its own
// version line).  The encoding below is an implementation choice; what it may
// accept is not.  Every field is required to be recognised, singular and
// resolved -- unknown keys, repeated keys, missing parameters, duplicate
// parameter names, unsupported modes, unresolved roots and invalid types are
// errors, never defaults.
//
// Nothing here executes or lowers anything.  A parsed BoundaryContract plus the
// header generated from it is a DESCRIPTION of a boundary; calling it an
// executable CORE boundary would be wrong until Tasks 2-4 exist.
//
//===----------------------------------------------------------------------===//
#ifndef SPINEL_MLIR_CORE_BOUNDARY_H
#define SPINEL_MLIR_CORE_BOUNDARY_H

#include "spinel-mlir/Contract/Model.h"

#include "llvm/ADT/STLFunctionalExtras.h"
#include "llvm/ADT/StringRef.h"

#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace llvm {
class raw_ostream;
} // namespace llvm

namespace spinel_mlir::core {

/// The scalar domains a parameter or result may declare.  `u64` exists for
/// buffer counts, which are unsigned element counts at the C boundary; it is
/// not admitted as a result type.
enum class ScalarDomain { I32, U32, I64, U64 };

/// Buffer element types: the four decision 0007 admits and the three narrow
/// ones decision 0018 adds.  Adding a width here widens the accepted contract,
/// which only a decision may do.
enum class ElementType { U8, I32, U32, I64, I8, U16, I16 };

/// Access mode.  `out` is NOT in version 1: a write-only promise is misleading
/// when a failure can leave a partial prefix, so a buffer that is written must
/// also be initialised by the caller and declared `inout`.
enum class AccessMode { In, InOut };

struct ScalarParam {
  std::string name;
  ScalarDomain domain;
  /// Set when this parameter is some buffer's element count.  A count belongs
  /// to exactly one buffer; the buffer names it, and the binding is checked
  /// from both directions.
  std::string countsFor;
};

struct BufferParam {
  std::string name;
  ElementType element;
  AccessMode mode;
  /// The NAME of the scalar parameter carrying this buffer's element count.
  /// Named rather than positional: the predecessor's `:len` bound to whichever
  /// parameter preceded it, so two buffers could silently share one length.
  /// Empty in version 2, where the count is a constant of the contract.
  std::string countParam;
  /// Version 2 (decision 0014): the count as a constant, `count const <N>`.
  /// An application's state buffers have sizes fixed by its declarations, so
  /// no count travels at the C boundary.
  std::optional<uint64_t> constCount;
  /// Version 2: reached from more than one context, so every access is atomic
  /// (0014 §5). A cross buffer never reaches an extern.
  bool cross = false;
};

/// One parameter in declaration order, which is also the order of the generated
/// C signature.  Order is preserved because a C signature has one; the binding
/// of counts to buffers is by name and does not depend on it.
struct Param {
  enum class Kind { Scalar, Buffer } kind;
  size_t index = 0; ///< index into scalars or buffers
};

/// Version 2 (decision 0014): one argument of an extern, as declared.
struct ExternArg {
  std::string name;
  Param::Kind kind = Param::Kind::Scalar;
  ScalarDomain scalar = ScalarDomain::I32; ///< when `kind` is Scalar
  ElementType element = ElementType::U8;   ///< when `kind` is Buffer
  AccessMode mode = AccessMode::In;        ///< when `kind` is Buffer
};

/// A run-time precondition of an extern: `guard <lhs> <op> <rhs> else <status>`.
/// The kernel emits it before the call; a false guard fails the entry with the
/// named 0007 status (`argument` or `bounds`) and the extern is not called.
/// Operands are kept as written: a parameter name, an integer literal, or
/// `len(<buffer parameter>)`.
struct Guard {
  std::string lhs, op, rhs;
  std::string onFalse;
};

/// A build-time requirement of an extern: `static <lhs> <op> <rhs> else
/// <diagnostic>`. It must be decidable from constant operands at every call
/// site, and a false one refuses the build with `diagnostic`.
struct StaticRequirement {
  std::string lhs, op, rhs;
  std::string diagnostic;
};

/// Version 2: one extern the entry may call, `<Module>.<fn>`, bound to the C
/// symbol its provider defines.
struct ExternDecl {
  std::string module, fn, symbol;
  std::vector<ExternArg> args;
  std::optional<ScalarDomain> returns;
  bool isrOk = false;
  std::vector<Guard> guards;
  std::vector<StaticRequirement> statics;
  std::string bound;         ///< `iterations <expr>`, as written after `bound`
  /// Decision 0021 (owner, 2026-10-20): `bound iterations unknown "<reason>"`,
  /// an extern whose work has no derived bound. The calling entry's
  /// loop_bound verdict is then `unknown`, naming this extern and the reason.
  bool boundUnknown = false;
  std::string boundReason;
  std::string evidencePath;  ///< the provider evidence file, as written
};

struct BoundaryContract {
  unsigned version = 0;
  std::string rootPath;     ///< the source path AS DECLARED, for the header
  std::string rootResolved; ///< rootPath resolved against `sourceRoot`
  /// SHA-256 of the bytes that were actually analysed.  Set by
  /// `resolveBoundaryEntry` from the caller's snapshot, never by the parser:
  /// a digest taken from a separate read of the path names whatever that path
  /// held at the moment of that read, which is not the same thing.
  std::string rootDigest;
  /// SHA-256 of the contract file's bytes as `prepareBoundary` read them, the
  /// one read it makes. Empty when the contract was parsed from text directly.
  /// Recorded by the build report; nothing generated from the contract uses it.
  std::string contractDigest;
  std::string entry;      ///< the method name
  std::optional<ScalarDomain> result; ///< absent means the contract declares none
  std::vector<ScalarParam> scalars;
  std::vector<BufferParam> buffers;
  std::vector<Param> order;
  /// Version 2: `thread` or `interrupt`. Empty in version 1.
  std::string context;
  /// Version 2: the externs the entry may call, in declaration order.
  std::vector<ExternDecl> externs;
  /// Decision 0041 stage 2: `scratch <bytes>`, the size of the entry's
  /// context's data stack. The entry then takes one more argument, after its
  /// buffers: the address of that region, whose first word is the bump
  /// offset.
  std::optional<uint64_t> scratchBytes;

  bool isApplication() const { return version == 2; }
  const ScalarParam *findScalar(llvm::StringRef name) const;
  const BufferParam *findBuffer(llvm::StringRef name) const;
  const ExternDecl *findExtern(llvm::StringRef module, llvm::StringRef fn) const;
};

/// `<file>:<line>: <category>: <detail>`, one diagnostic per defect, in the
/// shape the contract reader already uses so a reader of either recognises it.
using BoundaryDiagnosticFn = llvm::function_ref<void(llvm::StringRef)>;

/// Parse and validate the contract FILE.  Every field-level defect is reported;
/// a partly understood contract is never published.  `sourceRoot` is the
/// directory relative paths resolve against, so a contract does not depend on
/// the caller's working directory.
///
/// This performs NO I/O on the source.  It records the declared path and the
/// path it resolves to; opening the source is the caller's single read, and
/// the caller copies those bytes into a snapshot it owns before anything
/// analyses them.  A readability probe here would be a second, separate read
/// of the same path, which authenticates nothing and invites the reader of
/// this code to believe otherwise.
///
/// Resolving the entry against the source needs the analysed AST and is
/// `resolveBoundaryEntry`.
std::optional<BoundaryContract> parseBoundaryContract(llvm::StringRef text,
                                                      llvm::StringRef fileName,
                                                      llvm::StringRef sourceRoot,
                                                      BoundaryDiagnosticFn diag);

/// Bind the contract's entry and parameter names to the analysed source.
///
/// Uses the existing ContractModule AST -- the same structure the eligibility
/// checker walks -- and NOT a scan of the text.  A textual scan of lines
/// beginning `def ` accepts an unindented definition inside `if false`, and a
/// `def` inside a heredoc, as top level; and decision 0007 forbids adding a
/// Ruby parser here in the first place.  An unconditional top-level definition
/// is one that appears directly in the program's own statement list.
///
/// `digest` is the SHA-256 of the exact bytes that produced `module` -- the
/// caller's own snapshot copy, not a re-read of the declared path -- and is
/// recorded on the contract so the header names the bytes that were checked.
bool resolveBoundaryEntry(BoundaryContract &c,
                          const contract::ContractModule &module,
                          llvm::StringRef digest, BoundaryDiagnosticFn diag);

/// Everything between reading the contract file and holding a resolved
/// contract: the owned snapshot, the analysis, the digest and the entry.
///
/// One implementation, because the snapshot discipline is the part that must
/// not drift. Two copies of it are two places for one of them to start reading
/// the declared path a second time, and a drifted snapshot guard is
/// indistinguishable from no snapshot guard.
struct PreparedBoundary {
  unsigned integerBits = 64;
  BoundaryContract contract;
  std::unique_ptr<contract::ContractModule> module;
};

/// `contractPath` is the contract file; `sourceRoot` the directory its `root`
/// resolves against; `reader` the contract reader executable. Returns nullopt
/// after reporting every defect through `diag`.
std::optional<PreparedBoundary> prepareBoundary(llvm::StringRef contractPath,
                                                llvm::StringRef sourceRoot,
                                                llvm::StringRef reader,
                                                BoundaryDiagnosticFn diag,
                                                unsigned targetBits = 64, unsigned profileBits = 0,
                                                llvm::StringRef int64Allow = "");

/// The canonical single-line identity of a contract: version, entry, result and
/// every parameter in order.  Two contracts with the same identity generate the
/// same C signature.  Used to bind a generated header to the contract it came
/// from, and to refuse a header/contract mismatch before anything is linked.
std::string boundaryIdentity(const BoundaryContract &c);

/// Emit the C header for this contract.  `targetLayout` records the widths the
/// header was generated for; a consumer built for a different layout must not
/// silently link against it.
void emitBoundaryHeader(const BoundaryContract &c, llvm::StringRef contractPath,
                        llvm::StringRef targetLayout, llvm::raw_ostream &os);

/// The layout string for the host this tool is running on.
std::string hostTargetLayout();

/// The layout string a target triple implies: its pointer width and its `long`
/// width (`ptr32-i64-32long` for `thumbv8m.main-none-eabi`).  The kernel
/// derives this from the triple clang reports for the caller's arguments, and
/// requires the caller's `--layout` to agree with it (decision 0014, Task 2):
/// a header stating the host's widths for a 32-bit object was the failure.
std::string targetLayoutFor(llvm::StringRef triple);

/// The pointer width of a target triple, 32 or 64.
unsigned targetPointerBits(llvm::StringRef triple);

/// Decision 0014: the extern prototype header of a version 2 contract, which a
/// provider includes so that a definition disagreeing with the declared C ABI
/// fails to compile.
void emitExternHeader(const BoundaryContract &c, llvm::StringRef contractPath,
                      llvm::raw_ostream &os);

llvm::StringRef scalarDomainName(ScalarDomain d);
llvm::StringRef elementTypeName(ElementType e);
llvm::StringRef accessModeName(AccessMode m);
llvm::StringRef scalarCType(ScalarDomain d);
llvm::StringRef elementCType(ElementType e);

} // namespace spinel_mlir::core

#endif // SPINEL_MLIR_CORE_BOUNDARY_H
