//===- Importer.h - Spinel scalar program selection -----------*- C++ -*-===//
#ifndef SPINEL_MLIR_SCALAR_IMPORTER_H
#define SPINEL_MLIR_SCALAR_IMPORTER_H

#include "spinel-mlir/Contract/Model.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/OwningOpRef.h"
#include "llvm/ADT/ArrayRef.h"
#include "llvm/ADT/STLFunctionalExtras.h"
#include "llvm/ADT/StringRef.h"

#include <cstdint>
#include <optional>
#include <set>
#include <map>
#include <utility>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace llvm { class raw_ostream; }
namespace mlir { class MLIRContext; }

namespace spinel_mlir::scalar {

class ScalarProgramBuilder;

/// DECISION 0044: a buffer a freestanding helper's caller lends it.
///
/// Derived by the selector from the calls that reach the parameter (D1): the
/// freestanding route has no eligibility checker, so the derivation is the
/// importer's. The parameter is two arguments, the address and the length the
/// caller holds (L1); the length is not a Ruby name in the helper, so the
/// helper cannot move it.
struct ScalarLentBuffer {
  std::string elem;  ///< the element type every call lends (i8 ... f64)
  /// `in` when some call lends a read-only buffer, else `out` when some call
  /// lends an `:out` one, else `inout`.
  std::string dir;
  /// B1 with U1: false only when every entry that reaches this helper, through
  /// any chain of calls, is declared `bounds: :unchecked`.
  bool checked = true;
  /// The chain that lends a read-only (`:in`) buffer here, or empty: a store
  /// through this parameter is refused.
  std::string inFrom;
  /// The chain that lends a write-only (`:out`) buffer here, or empty: a read
  /// through this parameter is refused.
  std::string outFrom;
};

class ScalarParameter {
public:
  llvm::StringRef name() const { return name_; }
  llvm::StringRef type() const { return type_; }
  /// DECISION 0044: the lent buffer this parameter is, or null.
  const ScalarLentBuffer *lent() const { return lent_ ? &*lent_ : nullptr; }
private:
  friend class ScalarProgramBuilder;
  ScalarParameter(std::string name, std::string type,
                  std::optional<ScalarLentBuffer> lent = std::nullopt)
      : name_(std::move(name)), type_(std::move(type)), lent_(std::move(lent)) {}
  std::string name_, type_;
  std::optional<ScalarLentBuffer> lent_;
};

class ScalarMethod {
public:
  llvm::StringRef name() const { return name_; }
  int64_t scope() const { return scope_; }
  int64_t defNode() const { return defNode_; }
  int64_t line() const { return line_; }
  llvm::ArrayRef<ScalarParameter> parameters() const { return parameters_; }
  llvm::StringRef returnType() const { return returnType_; }
  bool scalarAbi() const { return scalarAbi_; }
  /// DECISION 0044, U1: an entry declared with checked bounds reaches this
  /// method through some chain of calls (the method itself included), so its
  /// buffer accesses check even where its own declaration says
  /// `bounds: :unchecked`. Set on the freestanding route only.
  bool checkedReach() const { return checkedReach_; }
private:
  friend class ScalarProgramBuilder;
  ScalarMethod(std::string name, int64_t scope, int64_t defNode, int64_t line,
               std::vector<ScalarParameter> parameters, std::string returnType,
               bool scalarAbi, bool checkedReach = false)
      : name_(std::move(name)), scope_(scope), defNode_(defNode), line_(line),
        parameters_(std::move(parameters)), returnType_(std::move(returnType)),
        scalarAbi_(scalarAbi), checkedReach_(checkedReach) {}
  std::string name_;
  int64_t scope_, defNode_, line_;
  std::vector<ScalarParameter> parameters_;
  std::string returnType_;
  bool scalarAbi_;
  bool checkedReach_ = false;
};

class ScalarCallEdge {
public:
  llvm::StringRef caller() const { return caller_; }
  llvm::StringRef callee() const { return callee_; }
  int64_t callNode() const { return callNode_; }
  int64_t line() const { return line_; }
  llvm::ArrayRef<int64_t> argumentNodes() const { return argumentNodes_; }
private:
  friend class ScalarProgramBuilder;
  ScalarCallEdge(std::string caller, std::string callee, int64_t callNode,
                 int64_t line, std::vector<int64_t> argumentNodes)
      : caller_(std::move(caller)), callee_(std::move(callee)),
        callNode_(callNode), line_(line),
        argumentNodes_(std::move(argumentNodes)) {}
  std::string caller_, callee_;
  int64_t callNode_, line_;
  std::vector<int64_t> argumentNodes_;
};

class ScalarProgram {
public:
  llvm::StringRef sourceFile() const { return sourceFile_; }
  llvm::ArrayRef<std::string> entries() const { return entries_; }
  llvm::ArrayRef<ScalarMethod> methods() const { return methods_; }
  llvm::ArrayRef<ScalarCallEdge> calls() const { return calls_; }
private:
  friend class ScalarProgramBuilder;
  ScalarProgram(std::string sourceFile, std::vector<std::string> entries,
                std::vector<ScalarMethod> methods,
                std::vector<ScalarCallEdge> calls)
      : sourceFile_(std::move(sourceFile)), entries_(std::move(entries)),
        methods_(std::move(methods)), calls_(std::move(calls)) {}
  std::string sourceFile_;
  std::vector<std::string> entries_;
  std::vector<ScalarMethod> methods_;
  std::vector<ScalarCallEdge> calls_;
};

using ScalarDiagnosticFn = llvm::function_ref<void(llvm::StringRef)>;

/// Integer overflow policy used by the scalar importer.
///
/// Four values.  The first three match the spellings `--int-overflow` accepts.
/// `Trap` is the FREESTANDING policy (a profile's `overflow:` or a
/// `freestanding_def ..., overflow: :trap`) and **the scalar CLI cannot spell
/// it** — there is no hosted trap.  E166 CP1 added it because the freestanding
/// emitter needs the same importer for the same bodies; the difference is that
/// `Trap` turns overflow into a call to the profile's hook instead of a raise,
/// and that call never returns.
/// `Status` is decision 0007 task 2: no raise, no trap, no sentinel.  Every
/// function in the closure becomes `(args..., result*) -> i32`, a failure
/// returns one of the boundary's own status values without writing the result,
/// and a caller checks the callee's status and propagates it.  It shares this
/// importer with the other modes because the BODIES are the same programs; it
/// does not share their failure channel, and none of their codes are forwarded
/// into it.
/// `Abort` is decision 0015: the native scalar core slice under the hosted
/// `--int-overflow=raise` contract.  Signatures stay `(i64...) -> i64`.  `+ - *`
/// and unary `-` are checked for overflow, `/ %` for a zero divisor, and
/// `INT64_MIN / -1` is an overflow while `INT64_MIN % -1` is 0.  A failure calls
/// the one hook `kCoreFailHook` with a `CoreFailKind` and a `CoreFailOp`, and
/// that call does not return.  There is no nil-sentinel test: `INT64_MIN` is an
/// ordinary value, inside the core object and as a result returned to the
/// hosted program (the pin includes upstream a07741ff1).
enum class OverflowMode { Raise, Wrap, None, Trap, Status, Abort };

/// Decision 0015: the failure hook of `OverflowMode::Abort`, the core object's
/// only undefined symbol.  Its C declaration is
/// `void spc_core_fail(int32_t kind, int32_t op) __attribute__((noreturn))`;
/// the hosted program defines it.  The numbers below are that interface's own,
/// listed once so the importer and the generated header cannot drift apart.
inline constexpr llvm::StringLiteral kCoreFailHook = "spc_core_fail";

enum class CoreFailKind : int32_t {
  Overflow = 1,     ///< `RangeError`, `integer overflow in <op>`
  ZeroDivision = 2, ///< `ZeroDivisionError`, `divided by 0`
  NegativeExponent = 3, ///< `RangeError`, `negative exponent` (decision 0042)
  /// `RangeError`, an intrinsic's own text (decision 0042 stage 4). The `op`
  /// is the intrinsic's failOp (Core/Intrinsics.h), not a CoreFailOp.
  Intrinsic = 4,
};

enum class CoreFailOp : int32_t {
  None = 0,
  Add = 1,
  Sub = 2,
  Mul = 3,
  Div = 4,
  Mod = 5,
  Neg = 6, ///< unary `-`, spelled `-@`
  Shl = 7, ///< `<<`, and `>>` with a negative count (decision 0042)
  Abs = 8, ///< `abs` (decision 0042)
  Pow = 9, ///< `**` (decision 0042)
};

/// Decision 0007 status values.  This ABI's own numbers, listed here once so
/// the importer and the generated header cannot drift apart.
enum class CoreStatus : int32_t {
  Ok = 0,
  Argument = 1,
  Arithmetic = 2,
  Bounds = 3,
  Capacity = 4,
};

// Freestanding-only opt-ins preserve scalar product acceptance/output for
// spinel-mlirgen, spinel-scalar-select and spinel-scalar-import. All default
// false, so existing callers keep their behavior without new arguments.
// One declared boundary parameter is copied by the caller because the scalar
// importer knows no freestanding_def. Len sizes preceding Buffer parameters;
// elem/dir matter only for Buffer.
struct ScalarParamDesc {
  enum class Kind { Int, Float, Buffer, Len };
  Kind kind = Kind::Int;
  std::string elem;  ///< Buffer element type (i8/u8/.../f32/f64).
  std::string dir;   ///< in / out / inout
  // Zero-based index of the :len sizing this buffer, not necessarily adjacent:
  // [[:i32_buf,:in],[:i32_buf,:out],:len,:i32] shares one length. Copy the declaration reader
  // result.
  int lenIndex = -1;
};

// Boundary for one root; returns uses declaration spelling (i32/f32/f64/...).
struct ScalarRootDesc {
  std::string name;
  std::vector<ScalarParamDesc> params;
  std::string returns;
  bool boundsChecked = true;  ///< False for bounds: :unchecked.
};

// One platform extern copied by the caller; the scalar importer does not know profiles.
struct ScalarExternDesc {
  std::string name;    ///< Name called from Ruby.
  std::string symbol;  ///< C symbol to link.
  std::string returns; ///< i32 / u32 / i64 / f32 / f64
  // One argument: elem <t>_buf means buffer, len means length; otherwise scalar.
  struct Param {
    enum class Kind { Scalar, Buffer, Len };
    Kind kind = Kind::Scalar;
    std::string elem;  ///< Scalar/buffer element type.
    std::string dir;   ///< Buffer direction.
    int lenIndex = -1; ///< Buffer: zero-based index of its len argument.
  };
  std::vector<Param> params;
};

/// The boundary the `Status` mode lowers to.  The ENTRY's result domain comes
/// from the contract; every other function in the closure carries an i64.
/// One buffer parameter of the checked boundary.
///
/// Named, not positional: the predecessor's `:len` bound to whichever argument
/// preceded it, so two buffers could quietly share one count. Here each buffer
/// names the scalar parameter that counts it, and the contract checks that
/// binding from both directions before any of this is built.
struct ScalarStatusBuffer {
  std::string name;      ///< the Ruby parameter name
  std::string element;   ///< `u8`, `i8`, `u16`, `i16`, `i32`, `u32` or `i64`
  bool readOnly = true;  ///< `in` is read-only; `inout` is not
  std::string countName; ///< the scalar parameter holding this buffer's count
  /// Decision 0014 (version 2): the count is a constant of the contract and no
  /// scalar parameter carries it; `cross` selects atomic accesses.
  std::optional<uint64_t> constCount;
  bool cross = false;
};

struct ScalarStatusAbi {
  std::string entry;        ///< the boundary entry method name
  std::string resultDomain; ///< `i64`, `i32` or `u32`
  std::vector<ScalarStatusBuffer> buffers;
  /// Decision 0041 stage 2: the context's data stack. `scratchBytes` is the
  /// region's size (0: none); `scratchMethods` take its address as a hidden
  /// pointer before the result pointer (the entry: after its buffers), and
  /// `arrayMakers` save the bump offset on entry and store it back before
  /// every return.
  uint64_t scratchBytes = 0;
  std::set<std::string> scratchMethods;
  std::set<std::string> arrayMakers;

  const ScalarStatusBuffer *buffer(llvm::StringRef name) const {
    for (const auto &b : buffers)
      if (b.name == name) return &b;
    return nullptr;
  }
};

/// One borrowed buffer parameter, as the eligibility checker derived it.
///
/// Decision 0008 task 3. The contract declares only the ENTRY's buffers; a
/// helper's come from the calls that reach it, and deriving that twice would
/// be two chances to disagree about what the closure is. So the checker
/// derives it once and this carries the answer across.
///
/// The COUNT is deliberately absent. How many elements there are belongs to
/// the descriptor the caller passed and travels with the call; a helper that
/// took its bound from a name in its own body could move its own bound.
struct ScalarBorrowedParam {
  std::string method;
  std::size_t index = 0;
  std::string element;   ///< u8 | i8 | u16 | i16 | i32 | u32 | i64
  bool readOnly = true;
  /// Decision 0014: reached with a cross buffer on some call, so every access
  /// through this parameter is atomic (the atomic closure, 0014 §5).
  bool cross = false;
  /// The entry buffer every call binds this parameter to, or empty when the
  /// calls bind different ones (the checker's derived origin). A parameter
  /// with an entry buffer's origin reads its pointer and bound from the
  /// entry's buffer context instead of a pair of arguments.
  std::string origin;
};

/// Decision 0014: one argument of an application extern, as the contract
/// declared it. A buffer is two C parameters, the pointer and a `u32` count.
struct ScalarAppExternArg {
  std::string name;
  bool isBuffer = false;
  std::string domain;    ///< i32 | u32 | i64 for a scalar; the element for a buffer
  bool readOnly = true;  ///< buffers: `in` is const
};

/// A run-time precondition, emitted before the call in declared order: a
/// false one fails the entry with `status` (`argument` or `bounds`) and the
/// extern is not called. Operands are a parameter name, an integer literal,
/// or `len(<buffer parameter>)`.
struct ScalarAppGuard {
  std::string lhs, op, rhs, status;
};

/// One extern an application entry may call as `<module>.<fn>`, lowered to
/// `llvm.call @symbol` with the C ABI of the 0014 plan.
struct ScalarAppExtern {
  std::string module, fn, symbol;
  std::vector<ScalarAppExternArg> args;
  std::string returns;  ///< i32 | u32 | i64, or empty for void
  std::vector<ScalarAppGuard> guards;
};

/// A debugging aid for the status ABI: one place a failure starts. `id` is
/// what the failing path stores in the failure-site global, 1 upwards in the
/// order the generator met the sites; a callee's failure passed up by its
/// caller stores nothing, so the global keeps the innermost site.
struct ScalarFailureSite {
  int32_t id = 0;
  std::string file;
  unsigned line = 0, column = 0;
  CoreStatus status = CoreStatus::Ok;
  std::string what;  ///< the operation, e.g. `checked *`, `index`, `core_fail(:capacity)`
};

struct ScalarImportOptions {
  /// Failure sites, off when empty: the name of an i32 global each failing
  /// path writes its site's id to before it returns its status. The object
  /// is unchanged when this is empty. The sites themselves are appended to
  /// `*failureSites`.
  std::string failureSiteSymbol;
  std::vector<ScalarFailureSite> *failureSites = nullptr;
  /// Decision 0019: Integer body width; boundary and buffer widths stay separate.
  unsigned integerBits = 64;
  /// Decision 0026 step 5: the target's pointer width, a setting of its own
  /// even where it equals `integerBits`. The kernel sets it from its target
  /// triple, the freestanding routes from the profile's triple, the native
  /// core route from the host it compiles for. No site of the lowering reads
  /// it yet: the two that refuse an i64 extern read `integerBits` and say
  /// "when Integer is 32 bits" (docs/core/lowering-inputs.md section 6).
  unsigned pointerBits = 64;
  /// The width of a buffer's count and of the hidden bound passed beside its
  /// pointer, in the body. It follows the Integer width, not the pointer
  /// width: a 32-bit body carries its counts in 32 bits because the wrapper
  /// refused a count with a nonzero upper word (decision 0022 section 3).
  unsigned countBits() const { return integerBits; }
  /// Non-empty `entry` selects the status ABI.  Read only when the mode is
  /// `OverflowMode::Status`, and required by it.
  ScalarStatusAbi status;
  /// Node id to the type the eligibility checker DERIVED from the contract's
  /// entry facts. Supplied rather than recomputed: the selector and the checker
  /// must agree about what the closure is, and two derivations are two chances
  /// to disagree. Empty for every other lane, which reads the producer's types
  /// exactly as before.
  std::map<int64_t, std::string> derivedTypes;
  /// Method name to its derived parameter types and result type, from the same
  /// derivation, for the signature the producer could not infer.
  std::map<std::string, std::pair<std::vector<std::string>, std::string>>
      derivedSignatures;
  /// Every borrowed buffer parameter in the closure, the entry's declared ones
  /// included, so one table answers the question for every method.
  std::vector<ScalarBorrowedParam> borrows;
  /// Decision 0026 step 4: call node id to the method it calls, as the
  /// eligibility checker resolved each call into the closure. When supplied
  /// (the CORE routes), the selector takes the program's call edges from it
  /// instead of resolving call names again. Absent for the freestanding
  /// routes, which run no eligibility check: the selector resolves their calls.
  std::optional<std::map<int64_t, std::string>> callEdges;
  /// Decision 0042: the native `--core` route (`OverflowMode::Abort`) admits
  /// `&`, `|`, `^` and `~` (stage 1), which are exact at every width, and `<<`
  /// and `>>` (stage 2), whose failures go to the abort hook. The status ABI
  /// and the freestanding types admit them without this; the hosted lanes do
  /// not.
  bool bitOperators = false;
  const ScalarBorrowedParam *borrow(llvm::StringRef method,
                                    std::size_t index) const {
    for (const auto &b : borrows)
      if (b.method == method && b.index == index) return &b;
    return nullptr;
  }
  /// Decision 0014: the externs of an application entry (version 2), in the
  /// contract's order. Empty for every other lane.
  std::vector<ScalarAppExtern> appExterns;
  /// Decision 0014: an application entry (a version 2 contract). Widens the
  /// closed node set by the string literal and admits `Module.fn` calls on
  /// the declared modules; false for every other lane.
  bool application = false;
  /// Decision 0014 §10 (a), verification builds: every cross-context access
  /// is performed by the recorder inside its critical section, together with
  /// its record -- a load becomes `i64 spc_record_load(ptr, i32 width, i32
  /// is_signed)`, a store `void spc_record_store(ptr, i32 width, i64 value)`
  /// -- so no other actor's access can be ordered between the access and its
  /// record. False for production and every other lane, whose atomic
  /// accesses are unchanged.
  bool recordCross = false;
  const ScalarAppExtern *appExtern(llvm::StringRef module, llvm::StringRef fn) const {
    for (const auto &e : appExterns)
      if (e.module == module && e.fn == fn) return &e;
    return nullptr;
  }
  bool isAppExternModule(llvm::StringRef module) const {
    for (const auto &e : appExterns)
      if (e.module == module) return true;
    return false;
  }
  bool borrowsAny(llvm::StringRef method) const {
    for (const auto &b : borrows)
      if (b.method == method) return true;
    return false;
  }
  // Enable typed values (i64/f64/buffer pointer/i1), floating arithmetic, buffer
  // index reads/writes and element narrowing. Default false admits integers only.
  // The former freestandingNodes option was removed: MultiWriteNode and
  // LocalVariableOperatorWriteNode entered the default set; this adds only
  // FloatNode. ArrayNode/LocalVariableTargetNode remain outside that set, admitted
  // only as MultiWriteNode value/lefts respectively. Thus xs = [1, 2, 3] remains
  // refused; r2_array is the control.
  bool freestandingTypes = false;
  // Entry-root boundaries, read only for freestandingTypes and copied from declarations. Other
  // methods are helpers typed by contract inference.
  std::vector<ScalarRootDesc> roots;
  // Declared platform externs, read only for freestandingTypes.
  std::vector<ScalarExternDesc> externs;

  const ScalarExternDesc *extern_(llvm::StringRef name) const {
    for (const ScalarExternDesc &e : externs)
      if (e.name == name)
        return &e;
    return nullptr;
  }

  const ScalarRootDesc *root(llvm::StringRef name) const {
    for (const ScalarRootDesc &r : roots)
      if (r.name == name)
        return &r;
    return nullptr;
  }
};

// Closed body-node set: seventeen by default, eighteen with freestandingTypes.
// validateNode admits only listed kinds. Expose the same predicate to the core
// sweep: a # spinel-tier: core file must check undeclared top-level defs too.
// One table avoids drift between two copies, as with cScalarType.
llvm::ArrayRef<llvm::StringRef> supportedNodeKinds(ScalarImportOptions options = {});

std::unique_ptr<ScalarProgram>
selectScalarProgram(const contract::ContractModule &module,
                    llvm::ArrayRef<std::string> entryNames,
                    ScalarDiagnosticFn diag, ScalarImportOptions options = {});

/// Test-only canonical dump, reconstructed from ScalarProgram accessors only.
void printSelection(const ScalarProgram &program, llvm::raw_ostream &os);

/// Build the module for a selected scalar program with the native MLIR
/// builders (func / arith / cf), not by re-spelling the frozen generator's
/// text.
///
/// For binary `+`, `-`, and `*`, `Raise` checks signed overflow and reports it
/// through the raising policy; `Wrap` and `None` both carry no overflow flag
/// and therefore define signed two's-complement wrap (F-185).  Unary `-@` is
/// unchecked in all three: `overflow<nsw>` under `Raise` and `None`, bare
/// under `Wrap`.
/// For nonzero divisors, division and remainder use Ruby floor semantics in
/// every mode: the quotient rounds toward negative infinity and the remainder
/// has the divisor's sign.  `Raise` and `Wrap` retain nil-sentinel and
/// zero-divisor guards; `None` omits both, so zero divisors are outside its
/// contract.  The mode is part of this single entry point so later lowering
/// can select the policy without introducing a second importer API.
///
/// `program` names the closure and the public signatures; the BODIES are read
/// out of the sealed `module` the selection came from — passing a program that
/// was selected from a different ContractModule is a caller defect, and the
/// node ids would not resolve.
///
/// Returns a null OwningOpRef after reporting through `diag` (one
/// `scalar:<line>: <category>: <detail>` line, the selector's shape) when the
/// body holds something the subset cannot lower.  The returned module is not
/// verified here; the caller decides what a verifier failure means.
///
/// `emitCheckedArithmetic` is the E161 checkpoint 3C OPT-IN and **defaults to
/// false**, so every caller that does not name it keeps the E160 output byte
/// for byte.  What the opt-in changes, and nothing else:
///
///   * BINARY `+`, `-`, `*` become `spinel.checked_{add,sub,mul}` carrying an
///     explicit overflow policy.  The policy comes from `mode` by a ONE-TO-ONE,
///     TOTAL map — `Raise`->`raise`, `Wrap`->`wrap`, `None`->`none`.  There is
///     no default policy and no absorption of an unknown mode: the map is a
///     closed switch over a closed enum.
///   * UNARY `-@` is NOT promoted (F-186).  It stays `arith.subi %c0, %v`, with
///     the same overflow flag the mode gives it today, because the unary case
///     is a separate semantic debt that E161 deliberately did not settle.
///     Floor `/` and `%` likewise stay in the standard dialects: the Spinel
///     dialect's closed set is add/sub/mul and holds no div/rem/neg.
///   * The NIL-SENTINEL guard is UNCHANGED.  A Spinel checked op carries the
///     overflow policy and nothing else, so under `Raise` the importer still
///     emits `nilCheck()` first and only then places the checked op — the same
///     shape E160 emits, with the overflow half replaced.
///
/// The opt-in does NOT lower.  What comes out is a module that still holds
/// Spinel ops; selecting a hosted or freestanding expansion is the job of the
/// conversion pass, called through its enum factory by a separate driver.
///
/// trapHook is the profile hook symbol meaningful only for Trap:
/// void(i32 code, i64 a, i64 b, ptr detail). A nonempty hook also sends / and %
/// zero-divisor failures to the hook (code 2), not raise, matching frozen
/// div_guard's hook-presence branch. Freestanding guards zero even under wrap.
mlir::OwningOpRef<mlir::ModuleOp>
importScalarProgram(const contract::ContractModule &module,
                    const ScalarProgram &program, mlir::MLIRContext &context,
                    OverflowMode mode,
                    ScalarDiagnosticFn diag,
                    bool emitCheckedArithmetic = false,
                    llvm::StringRef trapHook = {},
                    ScalarImportOptions options = {});

} // namespace spinel_mlir::scalar
#endif
