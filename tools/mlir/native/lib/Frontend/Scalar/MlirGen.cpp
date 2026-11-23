//===- MlirGen.cpp - the native MLIR builder for a selected program ------===//
//
// E160 checkpoint 3 Stage B (P010 Phase 2).
//
// This is the half of the scalar front end the selection skeleton exists for:
// a selected ScalarProgram plus the sealed ContractModule it was selected from
// become a `builtin.module` of `func.func @sp_<name>(i64...) -> i64` bodies,
// built with mlir::OpBuilder.  Nothing here writes MLIR text.  Re-spelling the
// frozen generator's printf output would reproduce its *bytes* without
// reproducing its *IR*, and every later phase (a dialect, a pass, a verifier)
// consumes the IR — so the text is the wrong artifact to be faithful to.
//
// What we ARE faithful to is the structure: the committed
// test/Scalar/Inputs/*.expected.mlir are the frozen generator's
// `--int-overflow=none` output put through ab/normalize-mlir.sh (a pass-less
// mlir-opt round trip).  Normalisation rewrites SSA names, block labels and
// whitespace, so what has to agree is exactly what it cannot rewrite: the set
// and ORDER of blocks, the order of operations inside them, and the block
// ARGUMENTS — which for this generator means the environment threading, since
// every join and loop header carries the whole local environment as arguments.
// The mirrored source is tools/mlir/spinel-mlirgen.py, class FuncGen; the
// comments below name the member each part follows.
//
// OverflowMode is three-valued — {Raise, Wrap, None} — and all three are here
// (frozen binop() / div_guard() / neg()).  The FROZEN GENERATOR has a FOURTH
// mode, `trap`, but it is not a spelling of `--int-overflow`: it reaches the
// frozen FuncGen only through `--freestanding`, from a profile's `overflow:`
// or a `freestanding_def ..., overflow: :trap` declaration (frozen
// FS_OVERFLOW = trap | wrap).  This importer has no freestanding face, so
// `trap` cannot arrive here and the enum deliberately does not carry it — but
// "every mode" below means every mode OF THIS ENUM, not every mode of the
// frozen generator.  (F-188 is open against the frozen `trap` arm of `-@`;
// nothing in this file is affected by it.)
//   * `None`: `+ - *` are plain `arith.addi/subi/muli` with no overflow flag —
//     E018's defined two's-complement wrap, which deliberately matches no
//     stock mode (frozen binop(), the single bare `arith` emit that its
//     `wrap` and `none` paths now share);
//     `/ %` keep their floor correction but NOT the nil/zero guards
//     (frozen div_guard() is a no-op when the mode is "none").
//   * `Wrap`: `+ - *` carry no overflow flag either — F-185 fixed this to the
//     declared contract, DEFINED signed two's-complement wrapping, so `Wrap`
//     and `None` produce the same `+ - *` IR.  The `/ %` guards SURVIVE,
//     because sp_idiv / sp_imod are plain `static inline` functions and not
//     the mode-switched macros (frozen div_guard's own comment,
//     spinel_rt.h:171).
//   * `Raise`: `+ - *` are the SP_INT_NIL sentinel test followed by
//     `llvm.intr.s{add,sub,mul}.with.overflow`, each with a cold arm that
//     calls a noreturn runtime raiser; `/ %` keep the same guards `Wrap` has.
//   * unary `-@` is `arith.subi %c0, %v overflow<nsw>` in `Raise` and `None`
//     and bare `arith.subi %c0, %v` in `Wrap` (frozen neg(), which documents
//     why the check is absent and why F-185 dropped the flag under `Wrap`).
//     The frozen generator's freestanding-only `trap` mode also still carries
//     `overflow<nsw>` here — F-188 — but it never reaches this importer.
//
// E161 checkpoint 3C added ONE opt-in on top of all of the above:
// `emitCheckedArithmetic` (the CLI's `--emit-checked-arithmetic`, default
// FALSE).  When it is set, the `+ - *` arm of binop() — and nothing else —
// emits `spinel.checked_{add,sub,mul}` with the policy the mode maps to
// one-to-one (checkedPolicyOf below).  Everything the mode does OUTSIDE that
// arm is unchanged, which is why the opt-in still emits the nil-sentinel test
// in front of a `Raise` checked op, still leaves unary `-@` as `arith.subi`
// (F-186), and still leaves floor `/ %` and their guards in the standard
// dialects.  The opt-in does NOT lower: the target-specific expansion is the
// conversion pass's, reached through its enum factory by
// tools/spinel-checked-arith-lower.  With the flag unset this file emits
// exactly the bytes it emitted at E160 — the 30 default-path artefacts
// (5 fixtures x 3 modes x 2 lanes) are measured byte for byte by
// test/Scalar/checked-arith-optin.test's A-1 half.
//
// Two structural facts the expected files pin and an approximating
// implementation would miss, both straight out of the frozen generator:
//   * cold arms are COLLECTED, not written where they are branched to
//     (frozen: self.rblocks, spliced in by `self.blocks.extend(self.rblocks)`
//     after the body walk).  Every cold block of a function is therefore at
//     the END of that function's block list, in creation order, and the hot
//     path stays contiguous.
//   * the C string literals are interned MODULE-wide in first-use order
//     (frozen: Generator.cstring / self.strings), so `sp_cstr_1` is the one
//     `RangeError`/`ZeroDivisionError` global every cold arm in the module
//     shares.  The globals and the two `llvm.func` declarations are printed
//     BEFORE the bodies but are only KNOWN after them, which is why they are
//     inserted in front of the first `func.func` once the walk is over
//     (frozen: build() calls preamble() after the closure is generated).
//===----------------------------------------------------------------------===//
#include "spinel-mlir/Scalar/Importer.h"
#include "spinel-mlir/Core/BlockLoops.h"
#include "spinel-mlir/Core/Intrinsics.h"

#include "ScalarAst.h"

#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Dialect/ControlFlow/IR/ControlFlowOps.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/Dialect/LLVMIR/LLVMDialect.h"
#include "spinel-mlir/Dialect/Spinel/IR/SpinelDialect.h"
#include "mlir/IR/Builders.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/MLIRContext.h"
#include "mlir/IR/Matchers.h"

#include "llvm/ADT/STLExtras.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/ADT/StringRef.h"
#include "llvm/ADT/Twine.h"

#include <algorithm>
#include <cerrno>
#include <cstdint>
#include <cstdlib>
#include <limits>
#include <map>
#include <memory>
#include <set>
#include <cmath>
#include <string>
#include <vector>

using namespace llvm;
using namespace mlir;
using namespace spinel_mlir::contract;

namespace spinel_mlir::scalar {

// `mlir/Dialect/LLVMIR/LLVMDialect.h` forward-declares `llvm::Type` (for the
// translation boundary), which makes the unqualified `Type` in this file
// ambiguous between the two `using namespace` directives above.  Naming the
// one we mean once, here, is better than qualifying every use: everything in
// this file is MLIR IR, and a `Type` that meant llvm::Type would not compile
// in any of these positions anyway.
using mlir::Type;

namespace {

/// Decision 0018: a buffer element's width in bits, from its name; 0 for a
/// name that is not an element.
unsigned elementBits(StringRef elem) {
  return llvm::StringSwitch<unsigned>(elem)
      .Case("i8", 8).Case("u8", 8)
      .Case("i16", 16).Case("u16", 16)
      .Case("i32", 32).Case("u32", 32).Case("f32", 32)
      .Case("i64", 64).Case("u64", 64).Case("f64", 64)
      .Default(0);
}

/// The two runtime raisers, and the sentinel the host runtime uses for a nil
/// that reached an Integer slot (frozen: RAISE_CLS / RAISE_NIL_OP /
/// SP_INT_NIL, lib/sp_types.h:154 = INTPTR_MIN).
constexpr StringLiteral kRaiseCls = "sp_raise_cls";
constexpr StringLiteral kRaiseNilOp = "sp_raise_nil_int_op";
// DECISION 0014 §10: the recorder's two hooks of a verification build.
constexpr StringLiteral kRecordLoad = "spc_record_load";
constexpr StringLiteral kRecordStore = "spc_record_store";
constexpr int64_t kIntNil = std::numeric_limits<int64_t>::min();

/// frozen: NIL_WEIGHTS.  The sentinel test is the one branch the generator
/// weights: it is a host-convention check that is false on every real value,
/// and saying so keeps the cold arm off the hot path after lowering.  The
/// zero-divisor test is deliberately NOT weighted (frozen zero_check: "no
/// SP_UNLIKELY on this one — sp_idiv/sp_imod write it bare").
constexpr int32_t kNilWeights[2] = {1, 2000};

/// The environment threaded through the walk: every local of the current
/// method to the SSA value it holds on this path.  A std::map because the
/// frozen generator's block-argument order is `sorted(self.locals)`, so the
/// iteration order is part of the contract and not an implementation detail
/// (frozen: merge_block / args_of).
using Env = std::map<std::string, Value>;

/// The result of walking a statement (frozen: `(value, env, terminated)`).
/// `ok` false means a diagnostic has already been reported and the walk is
/// unwinding.
struct StmtResult {
  Value value;
  Env env;
  bool terminated = false;
  bool ok = true;
};

/// The result of walking an expression (frozen: `(value, env)`).
struct ExprResult {
  Value value;
  Env env;
  bool ok = true;
};

class ModuleGen;

/// One `func.func`.  Mirrors the frozen generator's FuncGen; the int-only
/// slice means every LOCAL is an i64 and the only other kind a VALUE can have
/// is i1 (a comparison or a short-circuit result), so FuncGen's `ltype` map
/// collapses to "all locals are i64" and `Val.kind` collapses to the MLIR type.
class FuncGen {
public:
  FuncGen(ModuleGen &gen, const ScalarMethod &method, func::FuncOp func)
      : gen_(gen), method_(method), func_(func) {}

  // One local type, fixed for every locals_ entry before walking because merge-block arguments use
  // it.
  Type typeOfLocal(StringRef name) {
    auto found = localTypes_.find(name.str());
    return found == localTypes_.end() ? integerType()
                                      : found->second;
  }

  bool run();

private:
  Type integerType() const;
  unsigned integerBits() const;
  unsigned countBits() const;
  int64_t minInteger() const;
  bool runBody();

  // -- small helpers, one per frozen FuncGen member ------------------------
  Location locOf(int64_t nodeId) const;
  const Node *node(int64_t id) const;

  bool fail(int64_t nodeId, StringRef category, const Twine &detail);

  /// frozen: const() — a FRESH `arith.constant` per literal occurrence.  The
  /// duplicates in the expected files (`%c1_i64` and `%c1_i64_0` in pair) are
  /// load bearing: no CSE happens here or in the pass-less normalisation, so
  /// materialising once and reusing would be a visible structural difference.
  Value constant(Location loc, int64_t value);

  /// A block that is not in the region yet.  FuncGen owns it until it is
  /// opened; on the failure path every unopened block is still pushed into the
  /// region (rather than deleted) so no branch is left with a dangling
  /// successor while the half-built module is torn down.
  Block *newBlock();

  /// Destroy a block the walk created and then found nothing branches to.
  /// Only used where that is established -- an unreachable block with a
  /// terminator in it survives dialect conversion unconverted, because the
  /// conversion walks from the entry, and a `func.return` left inside what has
  /// become an `llvm.func` fails to verify.
  void discardBlock(Block *block);

  /// frozen: open_block() — append to the function's block list and continue
  /// writing there.  The append ORDER is the printed order, and the printed
  /// order is what normalisation preserves, which is why every block is
  /// created detached and pushed only when the generator starts writing it.
  void openBlock(Block *block);

  /// frozen: merge_block() — a join or loop header carrying the whole
  /// environment as block arguments, plus an optional extra (the `if` value,
  /// or the i1 of a short circuit).  No SSA minimisation: mem2reg and
  /// SimplifyCFG fold the redundant arguments away downstream.
  Block *mergeBlock(ArrayRef<Type> extra, Env &envOut, Value &extraOut);

  // Build local types from the locals face. Refuse poly/unknown (one slot taking two types) with
  // the c04 wording.
  bool buildLocalTypes();
  Type paramTypeOf(llvm::StringRef name);
  Value zeroOf(Location loc, Type type);

  /// frozen: args_of() — the environment in `locals_` order, then the extra.
  SmallVector<Value> argsOf(const Env &env, Value extra) const;

  /// frozen: br() / cond_br() — a block with no arguments is only ever entered
  /// from a block that dominates it, so nothing is threaded to it.
  void branch(Location loc, Block *dest, const Env &env, Value extra);
  void condBranch(Location loc, Value cond, Block *trueDest, const Env &trueEnv,
                  Value trueExtra, Block *falseDest, const Env &falseEnv,
                  Value falseExtra);

  /// frozen: need_int() / need_num() / need_bool().  In the int-only slice
  /// need_int and need_num ask the same question.
  bool needInt(int64_t nodeId, Value v, const Twine &what);
  bool needBool(int64_t nodeId, Value v, const Twine &what);
  bool needNumeric(int64_t nodeId, Value v, const Twine &what);
  Value toFloat(Location loc, Value v);
  Value coerce(Location loc, Value v, Type want);
  Value bodyInteger(Location loc, Value v, bool isSigned);
  Value wideInteger(Location loc, Value v);
  Value wideConstant(Location loc, int64_t value) {
    return arith::ConstantOp::create(builder_, loc, builder_.getI64Type(), builder_.getI64IntegerAttr(value));
  }

  // -- the checked modes (frozen: "E022: the raise machinery") --------------

  /// frozen: cold_block() — a block that is NOT opened.  The generator keeps
  /// writing into the hot path; this block is filled through its own builder
  /// and spliced in at the end of the function, after every hot block.
  Block *coldBlock();

  /// frozen: raise_cls_block() — the cold arm shared by every RangeError and
  /// every ZeroDivisionError: two `llvm.mlir.addressof` of interned C strings,
  /// the noreturn call, and `llvm.unreachable`.
  Block *raiseClsBlock(Location loc, StringRef cls, StringRef msg);

  /// frozen: nil_check() — SP_INT_NIL_CK(a, b, op) (spinel_rt.h:168).  Either
  /// operand equal to the sentinel means a nil reached an Integer slot, which
  /// is the RUNTIME's error to report, not a value to compute with.  Emitted
  /// for `+ - *` in Raise and for `/ %` in Raise AND Wrap.
  void nilCheck(Location loc, Value a, Value b, StringRef op);

  /// frozen: zero_check() — `if (b == 0) sp_raise_cls("ZeroDivisionError", …)`.
  /// `op` is read only in `Abort`, where the hook is told which operator it was.
  void zeroCheck(Location loc, Value a, Value b, StringRef op = {});
  std::string trapDetail(StringRef opSpelling) const;
  Block *trapBlock(Location loc, int32_t code, Value a, Value b,
                   StringRef detail);

  /// frozen: div_guard() — the sp_idiv / sp_imod preamble, which survives
  /// `Wrap` because those are inline FUNCTIONS, not mode-switched macros.
  void divGuard(Location loc, Value a, Value b, StringRef op);

  /// frozen: overflow_op() — the `{i64, i1}` intrinsic pair clang emits for
  /// `__builtin_*_overflow`, the RangeError arm on the flag, and the value.
  /// `reported` is the operator `Abort` names to its hook when it is not `op`:
  /// unary `-` is computed as `0 - x` and reported as `-@`.
  Value overflowOp(Location loc, StringRef op, Value a, Value b,
                   StringRef reported = {});

  // -- the abort form (decision 0015) ---------------------------------------
  //
  // The core slice's failure channel: one hook that does not return, so the
  // signatures stay those of the hosted prototype.  Separate from the raise
  // arm because the hook is not the runtime, and from the status arm because
  // nothing is returned.

  bool abortMode() const;

  /// Decision 0042: the modes besides the status ABI that lower `&`, `|`, `^`
  /// and `~` (stage 1) and `<<` and `>>` (stage 2): the native `--core` route
  /// (`Abort`) and freestanding. The four bitwise operators cannot fail; a
  /// shift's failure goes where each mode sends an overflow.
  bool bitOperators() const;

  /// A cold arm that calls `kCoreFailHook(kind, op)` and is unreachable after.
  Block *coreFailBlock(Location loc, CoreFailKind kind, StringRef op);
  /// The cold block calling the failure hook with this kind and op code.
  Block *coreFailCodeBlock(Location loc, CoreFailKind kind, int32_t op);

  /// `cf.cond_br %fail, ^fail, ^cont` and continue in `^cont`.
  void coreFailGuard(Location loc, Value failed, CoreFailKind kind, StringRef op);

  // -- the status ABI (decision 0007 task 2) -------------------------------
  //
  // Nothing below is reachable in any other mode, and nothing above changes
  // shape because of it.  The failure channel here is a RETURN, not a call
  // that does not come back, which is why these are separate functions rather
  // than another argument to the raise and trap arms: those two hand control
  // to something else, and this one hands a value to the caller.

  bool statusMode() const;

  /// The trailing result pointer, which is the last block argument of the
  /// entry block.  Never a local: it is not in `locals_` and has no name in
  /// the source.
  Value resultPtr() const;

  /// A cold arm that returns `code` WITHOUT writing the result.  Decision 0007:
  /// the result is written only on SPINEL_CORE_OK, so a failure leaves the
  /// caller's variable exactly as the caller left it.
  Block *statusBlock(Location loc, CoreStatus code, StringRef what = {});

  /// `cf.cond_br %fail, ^status(code), ^cont` and continue in `^cont`.
  void statusGuard(Location loc, Value failed, CoreStatus code, StringRef what = {});

  /// The method's own value return: the result-domain check for the entry, the
  /// store, and `return 0`.
  void emitValueReturn(Location loc, Value v);

  /// The domain the result pointer is written in for THIS method: the
  /// contract's for the entry, i64 for every helper.
  StringRef resultDomain() const;

  /// A stack slot for a callee's result, allocated once in the entry block.
  /// In the entry block on purpose: a call inside a loop would otherwise grow
  /// the frame on every iteration.
  Value callSlot(Location loc);

  /// `a << b` / `a >> b` under decision 0042's S1, in every mode: a negative
  /// count shifts the other way, a right shift by the width or more is the
  /// sign fill, and a left shift that loses bits fails where the mode has a
  /// failure (status, abort, trap) and keeps the low bits where it wraps.
  Value shiftOp(Location loc, StringRef op, Value a, Value b);

  /// `a.abs` in every mode (decision 0042 stage 3).  `MIN.abs` has no value
  /// at the body width: it fails where the mode has a failure, and is `MIN`
  /// where it wraps.  `abs(INT32_MIN)` in a 64-bit body is 2147483648, an
  /// ordinary value.
  Value absOp(Location loc, Value a);

  /// `a ** n` in every mode (decision 0042 stage 3): the exact power, a
  /// failure where it is past the width, and a failure of its own for a
  /// negative exponent.  Straight-line: no loop, no branch but the failure
  /// arms.
  Value powOp(Location loc, Value a, Value b);

  /// A failure arm reached when `failed` holds; the code continues in a
  /// fresh block otherwise.
  void failGuard(Location loc, Value failed, Block *cold);

  /// The status `core_fail(:<category>)` names, or nullopt if this call is not
  /// one the boundary admits.
  std::optional<CoreStatus> coreFailCategory(const Node *n) const;

  /// Whether this function is the boundary entry, which is the only one that
  /// takes buffers: a helper receives what the entry passes it, and version 1
  /// admits no buffer-valued argument.
  bool isEntry() const;

  /// Fill `buffers_` from the contract's declared buffers.
  void buildStatusBuffers();
  /// Decision 0008 task 3: fill `buffers_` for a HELPER, from the borrows the
  /// eligibility checker derived. A helper has no contract, so this is the
  /// only thing that says its parameter is an address.
  void buildBorrowedBuffers();
  /// The borrow this method holds in `name`, or null.
  const ScalarBorrowedParam *borrowedParam(llvm::StringRef name) const;
  /// The MLIR argument index of Ruby parameter `i`. A borrowed parameter takes
  /// TWO argument slots -- the pointer and the hidden count -- so the two
  /// numberings stop agreeing after the first one.
  unsigned argSlot(size_t rubyIndex) const;
  /// DECISION 0044: the buffer Ruby parameter `i` is lent, or null.
  const ScalarLentBuffer *lentAt(size_t rubyIndex) const;
  /// The length a buffer this function holds is checked against: a declared
  /// buffer's `:len` parameter, or the length a lent buffer arrived with.
  Value bufferLength(llvm::StringRef bufName, const Env &env);

  // -- the walk -------------------------------------------------------------
  StmtResult stmts(const Node *node, Env env, bool wantValue);
  StmtResult stmt(const Node *node, Env env, bool wantValue);
  /// `invert` is `unless`: the SAME shape with the two arms swapped, not a
  /// negated condition (frozen: `if_stmt(..., invert=k == "UnlessNode")`).
  StmtResult ifStmt(const Node *node, Env env, bool wantValue, bool invert);
  /// `isUntil` is `until`: the header's conditional branch swaps its targets.
  StmtResult whileStmt(const Node *node, Env env, bool isUntil);
  /// DECISION 0041 stage 1: a loop whose body is a literal block.
  StmtResult blockLoopStmt(const Node *node, const core::BlockLoop &loop,
                           Env env, bool wantValue);
  /// The loop shape of a CallNode, if it has a literal block at all.
  core::BlockLoopShape blockLoopShape(const Node *node);
  ExprResult expr(const Node *node, Env env);
  ExprResult andOr(const Node *node, Env env, bool isAnd);
  ExprResult call(const Node *node, Env env);
  ExprResult binop(int64_t nodeId, StringRef op, Value a, Value b, Env env);
  // b[i] / b[i] = v: bounds use code 4, element narrowing code 3, matching the prototype path.
  // Decision 0041 stage 2 adds data-stack arrays.
  StmtResult arrayNew(const Node *write, const std::string &name, const Node *call, Env env);
  bool isArrayNewCall(const Node *c) {
    std::string callee, constant;
    int64_t r = -1;
    if (!c || c->kind != "CallNode" || !ast::getString(*c, "name", callee) || callee != "new" ||
        !ast::getReference(*c, "receiver", r))
      return false;
    const Node *recv = node(r);
    return recv && recv->kind == "ConstantReadNode" && ast::getString(*recv, "name", constant) &&
           constant == "Array";
  }
  ExprResult bufferAccess(const Node *n, llvm::StringRef name, int64_t receiverId,
                          llvm::ArrayRef<int64_t> args, Env env);
  // Platform extern calls, ported from frozen extern_call. Narrow arguments to declared width with
  // code-3 traps or wrap truncation; widen results exactly to internal width without a
  // policy/check. Decision 0022 word intrinsics lower in place through Core/Intrinsics.h.
  ExprResult intrinsicCall(const Node *n, const spinel_mlir::core::CoreIntrinsic &in,
                           ArrayRef<int64_t> args, Env env);
  ExprResult externCall(const Node *n, const ScalarExternDesc &ext,
                        llvm::ArrayRef<int64_t> args, Env env);
  /// Decision 0014: an application extern call, `Module.fn(args)`, in the
  /// status ABI: guards first, then `llvm.call @symbol` with the C ABI of the
  /// plan (a buffer is a pointer and a u32 count).
  ExprResult appExternCall(const Node *n, const ScalarAppExtern &ext,
                           llvm::ArrayRef<int64_t> args, Env env);
  /// A string literal as constant bytes: the pointer and the count, or false.
  bool literalBytes(const Node *n, Location loc, Value &ptr, Value &count, uint64_t &size);
  Value externNarrow(Location loc, Value v, llvm::StringRef pt, size_t idx,
                     const ScalarExternDesc &ext, bool &ok);
  // Recognize buf[off, n] shape only, independent of receiver or position.
  bool isViewShape(const Node *n) const;
  // One argument view: emit region bounds checks (code 4) and return (ptr, n). bounds: :unchecked
  // does not disable this call contract, which is not an index check.
  bool bufView(const Node *n, llvm::StringRef what, Env &env,
               std::string &bufName, Value &ptr, Value &len);

  /// frozen: render()'s "unreachable tail: still needs a terminator" arm.
  void terminateStragglers();

  ModuleGen &gen_;
  const ScalarMethod &method_;
  func::FuncOp func_;
  OpBuilder builder_{func_.getContext()};
  std::vector<std::unique_ptr<Block>> unopened_;
  /// frozen: self.rblocks.  Held apart from `unopened_` so that the ORDER is
  /// preserved: these go into the region last, all of them, after every block
  /// the walk opened.
  std::vector<std::unique_ptr<Block>> cold_;
  std::vector<std::string> params_; // declaration order
  std::vector<std::string> locals_; // frozen: sorted(collect_locals())
  /// The status ABI's stack slot for callee results, allocated at most once
  /// per function and reused by every call site.
  Value callSlot_;
  /// The buffer context this function holds: the entry's table, or a
  /// helper's argument; null when it has none.
  Value context_;
  /// DECISION 0041 STAGE 2. The data stack's address, when this function
  /// takes it; the bump offset as it was on entry, when this function makes
  /// arrays (stored back before every return); and the locals that hold one.
  Value scratch_;
  Value savedOffset_;
  std::set<std::string> arrayLocals_;
  /// Each declared buffer's count AS IT ARRIVED, captured from the parameter
  /// before the body can touch it.
  ///
  /// Measured: reading the count out of the environment instead let a body
  /// rebind the name and move its own bound. `n_src = 1000; src[500]` on a
  /// four-element buffer returned success and read 496 bytes past the end. The
  /// bound is a fact about the descriptor, so it is taken from the descriptor.
  std::map<std::string, Value> descriptorCount_;
  /// A 32-bit body's index bound per buffer: min(count, 2^31) as an i32,
  /// computed once where the count is captured. `index <u bound` is then one
  /// 32-bit compare that equals `0 <= index < count` for every count the
  /// wrapper admits (below 2^32, decision 0022 section 3): a negative index
  /// is at least 2^31 as unsigned, and a non-negative one is below 2^31.
  std::map<std::string, Value> descriptorBound32_;
  void captureBound32(Location loc, const std::string &buf);
  /// DECISION 0008 TASK 4. The loops enclosing the statement being walked,
  /// innermost last. `break` branches to the exit of the last one and `next`
  /// to its head; there are no labelled loops in this subset, so the nearest
  /// is the only one either can name.
  struct LoopCtx {
    Block *head = nullptr;
    Block *exit = nullptr;
  };
  std::vector<LoopCtx> loops_;
  // MLIR local types must be fixed before walking, for merge-block arguments.
  std::map<std::string, Type> localTypes_;

  // Buffer parameter description. Indexing is admitted only for names in this table;
  // local/expression receivers lie outside the subset.
  struct BufInfo {
    unsigned bits = 0;      ///< Element width; 32/64 for floats.
    // Preserve the declared element token (i32/u8/f32/...), because diagnostics name it. Do not
    // reconstruct it from bits and isSigned.
    std::string elem;
    bool isFloat = false;
    bool isSigned = true;   ///< Types such as :u8 are unsigned.
    std::string dir;        ///< in / out / inout
    std::string lenName;    ///< Name of the :len sizing this buffer.
    bool checked = true;    ///< False for bounds: :unchecked.
    /// Decision 0014 §5: reached from more than one context, so every load and
    /// store through it is atomic monotonic at element alignment.
    bool cross = false;
    /// Decision 0044: lent by the caller; its length is the hidden argument
    /// captured in `descriptorCount_`, and `lenName` is empty.
    bool lent = false;
    /// Decision 0044: the chain that lends a read-only buffer here (a store
    /// is refused), and the one that lends a write-only buffer (a read is).
    std::string inFrom, outFrom;
  };
  std::map<std::string, BufInfo> buffers_;

  /// The checked access, given VALUES. `buf[i] op= v` evaluates its index once
  /// and uses that one value for the load and the store; a null `stored` is a
  /// load. Declared after `BufInfo` because it names it.
  ExprResult bufferAccessValues(const Node *n, llvm::StringRef bufName,
                                const BufInfo &info, Value idxValue,
                                Value stored, Env env);
};

class ModuleGen {
public:
  ModuleGen(const ContractModule &module, const ScalarProgram &program,
            MLIRContext &context, OverflowMode mode, ScalarDiagnosticFn diag,
            bool emitCheckedArithmetic, StringRef trapHook,
            ScalarImportOptions options)
      : program_(program), context_(context), mode_(mode), diag_(diag),
        emitChecked_(emitCheckedArithmetic), trapHook_(trapHook.str()),
        options_(options) {
    for (const Node &node : module.nodes())
      nodes_[node.id] = &node;
    // Each node's own file, from the reader's file table and the node's
    // `node_file`, as Eligibility's diagnostics read it: a node of a
    // required file is located in that file, not in the root.
    for (const contract::Source &source : module.sources())
      files_[source.id] = source.path;
    // DECISION 0014 D5: the constant writes that sit in a module body, so a
    // bare-name lookup skips them (they are `Mod::NAME` and nothing else).
    for (const Node &node : module.nodes()) {
      if (node.kind != "ModuleNode") continue;
      int64_t bodyId = -1;
      if (!ast::getReference(node, "body", bodyId)) continue;
      auto it = nodes_.find(bodyId);
      const Node *body = it == nodes_.end() ? nullptr : it->second;
      std::vector<int64_t> stmts;
      if (!body || body->kind != "StatementsNode" ||
          !ast::getArray(*body, "body", stmts))
        continue;
      for (int64_t sid : stmts) inModuleBody_.insert(sid);
    }
    for (const NodeType &type : module.nodeTypes())
      types_[type.id] = &type;
    for (const ScalarMethod &method : program.methods())
      methods_[method.name().str()] = &method;
    for (const ScalarCallEdge &call : program.calls())
      callees_[call.callNode()] = call.callee().str();
    // Local types come from the locals face, matching frozen collect_locals. Retain poly/unknown so
    // FuncGen can refuse them with c04 wording.
    for (const Local &local : module.locals()) {
      localTypes_[{local.scope, local.name}] = local.type;
      if (local.nullableInt) nullableLocals_.insert({local.scope, local.name});
    }
  }

  // (scope, name) to inferred type spelling; empty if absent. Analysis found a path reading this local before assignment, where Ruby sees nil.
  bool localNullable(int64_t scope, StringRef name) const {
    return nullableLocals_.count({scope, name.str()}) != 0;
  }
  bool hasLocal(int64_t scope, StringRef name) const {
    return localTypes_.count({scope, name.str()}) != 0;
  }
  StringRef localType(int64_t scope, StringRef name) const {
    auto found = localTypes_.find({scope, name.str()});
    return found == localTypes_.end() ? StringRef() : StringRef(found->second);
  }

  /// Decision 0007 task 2: the value of a named literal constant.
  ///
  /// The eligibility checker has already refused anything but a single
  /// unconditional top-level `NAME = <integer literal>`, so a name that
  /// resolves to exactly one write here is the one it admitted. Two writes or
  /// none is a generator defect rather than a rejected input, and says so.
  static bool genBigInteger(const Node &n) {
    std::string text; return ast::getString(n, "bigval", text);
  }
  std::optional<int64_t> constantValue(StringRef name) const {
    std::optional<int64_t> found;
    for (const auto &entry : nodes_) {
      const Node &n = *entry.second;
      if (n.kind != "ConstantWriteNode") continue;
      // DECISION 0014 D5: a write inside a module body belongs to `Mod::NAME`
      // and is reached only through `constantPathValue`. A bare name never
      // resolves to one, here as at the boundary, or two modules carrying
      // `COUNT` would make each other's bare read ambiguous.
      if (inModuleBody_.count(n.id)) continue;
      std::string writeName;
      if (!ast::getString(n, "name", writeName) || writeName != name) continue;
      int64_t valueId = -1;
      if (!ast::getReference(n, "value", valueId)) return std::nullopt;
      const Node *v = node(valueId);
      int64_t value = 0;
      if (!v || v->kind != "IntegerNode" || genBigInteger(*v) || !ast::getInteger(*v, "value", value))
        return std::nullopt;
      if (found) return std::nullopt;  // two writes: refused upstream
      found = value;
    }
    return found;
  }

  /// DECISION 0014 D5: `Mod::NAME`, the board package's constants. The write
  /// is looked up inside the named module's own body rather than by name
  /// alone, so two modules may carry the same constant name. The eligibility
  /// checker has already refused anything but one integer literal there;
  /// finding none or two here is a generator defect and says so by failing.
  std::optional<int64_t> constantPathValue(StringRef module, StringRef name) const {
    std::optional<int64_t> found;
    for (const auto &entry : nodes_) {
      const Node &m = *entry.second;
      if (m.kind != "ModuleNode") continue;
      int64_t pathId = -1, bodyId = -1;
      if (!ast::getReference(m, "constant_path", pathId)) continue;
      const Node *path = node(pathId);
      std::string modName;
      if (!path || path->kind != "ConstantReadNode" ||
          !ast::getString(*path, "name", modName) || modName != module)
        continue;
      if (!ast::getReference(m, "body", bodyId)) continue;
      const Node *body = node(bodyId);
      if (!body || body->kind != "StatementsNode") continue;
      std::vector<int64_t> stmts;
      if (!ast::getArray(*body, "body", stmts)) continue;
      for (int64_t sid : stmts) {
        const Node *s = node(sid);
        std::string writeName;
        if (!s || s->kind != "ConstantWriteNode" ||
            !ast::getString(*s, "name", writeName) || writeName != name)
          continue;
        int64_t valueId = -1;
        if (!ast::getReference(*s, "value", valueId)) return std::nullopt;
        const Node *v = node(valueId);
        int64_t value = 0;
        if (!v || v->kind != "IntegerNode" || genBigInteger(*v) || !ast::getInteger(*v, "value", value))
          return std::nullopt;
        if (found) return std::nullopt;  // two writes: refused upstream
        found = value;
      }
    }
    return found;
  }

  // Contract type spelling to MLIR type. Without freestandingTypes, always i64, preserving default
  // callers output byte for byte.
  Type integerType() const { return IntegerType::get(&context_, options_.integerBits); }
  Type typeOf(StringRef contractType) const {
    if (!options_.freestandingTypes)
      return integerType();
    if (contractType == "float")
      return Type(mlir::Float64Type::get(&context_));
    if (contractType == "int_array" || contractType == "float_array")
      return Type(LLVM::LLVMPointerType::get(&context_));
    return integerType();
  }

  OwningOpRef<ModuleOp> run();

  const Node *node(int64_t id) const {
    auto found = nodes_.find(id);
    return found == nodes_.end() ? nullptr : found->second;
  }
  /// The file a node came from: its `node_file` in the reader's file table,
  /// or the root's when the node has none or names none.
  StringRef fileOf(int64_t id) const {
    int64_t file = -1;
    auto n = nodes_.find(id);
    if (n != nodes_.end() && ast::getInteger(*n->second, "node_file", file)) {
      auto found = files_.find(file);
      if (found != files_.end()) return found->second;
    }
    return sourceFile();
  }
  int64_t lineOf(int64_t id) const {
    auto found = types_.find(id);
    return found == types_.end() ? 0 : found->second->line;
  }
  int64_t columnOf(int64_t id) const {
    auto found = types_.find(id);
    return found == types_.end() ? 0 : found->second->column;
  }
  /// The nodes face's detail for `id`: for a node that names a local, the
  /// name of the analysis's slot.
  std::string analysedName(int64_t id) const {
    auto found = types_.find(id);
    return found == types_.end() ? std::string() : found->second->detail;
  }
  const ScalarMethod *method(StringRef name) const {
    auto found = methods_.find(name.str());
    return found == methods_.end() ? nullptr : found->second;
  }
  /// Decision 0026 step 4: the method the call node calls, from the
  /// program's resolved call edges; empty when it is no call into the
  /// closure.
  StringRef callee(int64_t callNode) const {
    auto found = callees_.find(callNode);
    return found == callees_.end() ? StringRef() : StringRef(found->second);
  }
  func::FuncOp function(StringRef name) const {
    auto found = functions_.find(name.str());
    return found == functions_.end() ? func::FuncOp() : found->second;
  }
  StringRef sourceFile() const { return program_.sourceFile(); }
  OverflowMode mode() const { return mode_; }

  /// E161 cp3C: the `--emit-checked-arithmetic` opt-in.  False for every
  /// caller that does not name it, which is what keeps the E160 bytes.
  bool emitCheckedArithmetic() const { return emitChecked_; }
  // Freestanding-only opt-in.
  const ScalarImportOptions &options() const { return options_; }
  // Profile trap hook, freestanding only; empty denotes hosted.
  StringRef trapHook() const { return trapHook_; }

  /// frozen: Generator.cstring() — intern a literal MODULE-wide, in first-use
  /// order, and hand back the symbol it will be emitted under.  The GlobalOp
  /// itself does not exist yet: the preamble is written after the walk, but
  /// prints before the bodies, so what a cold arm can hold now is the NAME.
  /// The returned reference is into the interning map, which is never rehashed
  /// in a way that moves its values (std::map nodes are stable).
  StringRef cstring(StringRef text) {
    auto found = strings_.find(text.str());
    if (found != strings_.end())
      return found->second;
    std::string symbol = ("sp_cstr_" + Twine(strings_.size())).str();
    auto inserted = strings_.emplace(text.str(), std::move(symbol));
    order_.push_back(&inserted.first->first);
    return inserted.first->second;
  }

  /// frozen: Generator.uses — declare only what we actually call.  A `Wrap`
  /// module with no `/` and no `%` imports neither raiser, and that is what
  /// keeps `fib.wrap.expected.mlir` free of both declarations.
  void useRaiseCls() { usesRaiseCls_ = true; }
  void useRaiseNilOp() { usesRaiseNilOp_ = true; }
  void useRecordCross() { usesRecordCross_ = true; }
  void useTrapHook() { usesTrapHook_ = true; }
  void useCoreFail() { usesCoreFail_ = true; }
  /// THE BUFFER CONTEXT. A helper's borrowed parameter that every call binds
  /// to the same entry buffer (its derived origin) takes no arguments of its
  /// own: the entry stores each such buffer's pointer and bound once, in a
  /// table in its frame, and every helper that needs one is passed the table.
  /// Answers that buffer's index in the status ABI's buffers, or -1 for a
  /// parameter passed as a pointer and a bound.
  int contextSlot(StringRef method, size_t index) const {
    if (mode_ != OverflowMode::Status || method == options_.status.entry) return -1;
    const ScalarBorrowedParam *b = options_.borrow(method, index);
    if (!b || b->origin.empty() || b->origin == "<literal>") return -1;
    const auto &bufs = options_.status.buffers;
    for (size_t k = 0; k < bufs.size(); ++k)
      if (bufs[k].name == b->origin) return static_cast<int>(k);
    return -1;
  }
  bool usesContext(StringRef method) const { return usesContext_.count(method.str()) != 0; }
  bool anyContext() const { return !usesContext_.empty(); }
  /// DECISION 0041 STAGE 2: whether `method` takes the data stack's address.
  bool takesScratch(StringRef method) const {
    return mode_ == OverflowMode::Status && options_.status.scratchBytes != 0 &&
           options_.status.scratchMethods.count(method.str()) != 0;
  }
  const std::set<size_t> &contextSlots() const { return contextSlots_; }
  /// The table's element: a pointer and a bound of the body's count width.
  Type contextElement() {
    return LLVM::LLVMStructType::getLiteral(&context_, {LLVM::LLVMPointerType::get(&context_),
                                                        IntegerType::get(&context_, options_.countBits() == 32 ? 32 : 64)});
  }
  Type contextType() {
    return LLVM::LLVMArrayType::get(contextElement(), options_.status.buffers.size());
  }
  /// Failure sites (a debugging aid, off unless the options name a global):
  /// before a failing path returns its status, it stores its site's id. The
  /// sites are numbered in the order they are met and listed for the caller.
  void storeFailureSite(OpBuilder &b, Location loc, CoreStatus code, StringRef what) {
    if (options_.failureSiteSymbol.empty()) return;
    ScalarFailureSite site;
    site.id = static_cast<int32_t>(++failureSiteCount_);
    if (auto flc = dyn_cast<FileLineColLoc>(loc)) {
      site.file = flc.getFilename().str();
      site.line = flc.getLine();
      site.column = flc.getColumn();
    }
    site.status = code;
    site.what = what.str();
    if (options_.failureSites) options_.failureSites->push_back(site);
    usesFailureSite_ = true;
    Value addr = LLVM::AddressOfOp::create(b, loc, LLVM::LLVMPointerType::get(b.getContext()),
                                           options_.failureSiteSymbol);
    Value id = arith::ConstantOp::create(b, loc, b.getI32Type(), b.getI32IntegerAttr(site.id));
    LLVM::StoreOp::create(b, loc, id, addr);
  }
  // Declare only platform externs actually called, once per module. Uncalled externs must not enter
  // the undefined-symbol set.
  void useExtern(const ScalarExternDesc &e) {
    if (externUses_.count(e.symbol))
      return;
    externUses_[e.symbol] = &e;
    externOrder_.push_back(e.symbol);
  }
  /// Decision 0014: one declaration per extern the closure calls.
  void useAppExtern(const ScalarAppExtern &e) {
    if (appExternUses_.count(e.symbol))
      return;
    appExternUses_[e.symbol] = &e;
    appExternOrder_.push_back(e.symbol);
  }

  /// One `scalar:<line>: <category>: <detail>` line — the selector's shape and
  /// the selector's sink, because to the caller of the CLI the scalar front end
  /// is one boundary, not two.
  bool reject(int64_t line, StringRef category, const Twine &detail) {
    diag_((Twine("scalar:") + Twine(line) + ": " + category + ": " + detail)
              .str());
    return false;
  }

private:
  /// frozen: preamble().  Written last, printed first.
  void emitPreamble(Operation *before);

  const ScalarProgram &program_;
  MLIRContext &context_;
  OverflowMode mode_;
  ScalarDiagnosticFn diag_;
  std::map<int64_t, const Node *> nodes_;
  std::map<int64_t, std::string> files_;
  std::set<int64_t> inModuleBody_;
  std::map<int64_t, const NodeType *> types_;
  std::map<std::string, const ScalarMethod *> methods_;
  std::map<int64_t, std::string> callees_;
  std::map<std::string, func::FuncOp> functions_;
  std::map<std::string, std::string> strings_; // literal -> symbol
  std::vector<const std::string *> order_;     // first-use order into strings_
  bool usesRaiseCls_ = false;
  bool usesRaiseNilOp_ = false;
  bool usesRecordCross_ = false;
  bool usesCoreFail_ = false;
  bool usesFailureSite_ = false;
  // The buffer context: the helpers that take it, and the entry buffers it
  // holds (by their index in the status ABI's buffers), recorded while the
  // signatures are built.
  std::set<std::string> usesContext_;
  std::set<size_t> contextSlots_;
  unsigned failureSiteCount_ = 0;
  bool emitChecked_ = false;
  std::string trapHook_;
  ScalarImportOptions options_;
  std::map<std::pair<int64_t, std::string>, std::string> localTypes_;
  std::set<std::pair<int64_t, std::string>> nullableLocals_;
  std::map<std::string, const ScalarExternDesc *> externUses_;
  std::vector<std::string> externOrder_;
  /// Decision 0014: the application externs called, declared once each in
  /// the preamble in first-use order.
  std::map<std::string, const ScalarAppExtern *> appExternUses_;
  std::vector<std::string> appExternOrder_;
  bool usesTrapHook_ = false;
};

// ---------------------------------------------------------------------------
// FuncGen
// ---------------------------------------------------------------------------

Type FuncGen::integerType() const { return gen_.integerType(); }
unsigned FuncGen::integerBits() const { return gen_.options().integerBits; }
unsigned FuncGen::countBits() const { return gen_.options().countBits(); }
int64_t FuncGen::minInteger() const {
  return integerBits() == 32 ? INT32_MIN : INT64_MIN;
}

const Node *FuncGen::node(int64_t id) const { return gen_.node(id); }

Location FuncGen::locOf(int64_t nodeId) const {
  return FileLineColLoc::get(
      StringAttr::get(builder_.getContext(), gen_.fileOf(nodeId)),
      static_cast<unsigned>(gen_.lineOf(nodeId)),
      static_cast<unsigned>(gen_.columnOf(nodeId)));
}

bool FuncGen::fail(int64_t nodeId, StringRef category, const Twine &detail) {
  return gen_.reject(gen_.lineOf(nodeId), category,
                     Twine("'") + method_.name() + "': " + detail);
}

Value FuncGen::constant(Location loc, int64_t value) {
  return arith::ConstantOp::create(
      builder_, loc, builder_.getIntegerAttr(integerType(), value));
}

Block *FuncGen::newBlock() {
  unopened_.push_back(std::make_unique<Block>());
  return unopened_.back().get();
}

// Build local types from the locals face, never generator guesses. Refuse poly/unknown slots with
// frozen wording independent of assignment order: s = 0; s = 1.5 and its reverse have the same
// diagnostic.
bool FuncGen::isEntry() const {
  return method_.name() == gen_.options().status.entry;
}

const ScalarBorrowedParam *FuncGen::borrowedParam(StringRef name) const {
  if (isEntry()) return nullptr;
  for (auto indexed : llvm::enumerate(params_))
    if (indexed.value() == name)
      return gen_.options().borrow(method_.name(), indexed.index());
  return nullptr;
}

unsigned FuncGen::argSlot(size_t rubyIndex) const {
  unsigned slot = 0;
  for (size_t i = 0; i < rubyIndex && i < params_.size(); ++i) {
    if (gen_.contextSlot(method_.name(), i) >= 0) continue; // in the context
    ++slot;
    if (!isEntry() && gen_.options().borrow(method_.name(), i)) ++slot;
    else if (lentAt(i)) ++slot;  // decision 0044: the length beside it
  }
  return slot;
}

const ScalarLentBuffer *FuncGen::lentAt(size_t rubyIndex) const {
  return rubyIndex < method_.parameters().size()
             ? method_.parameters()[rubyIndex].lent()
             : nullptr;
}

void FuncGen::buildBorrowedBuffers() {
  buffers_.clear();
  // DECISION 0014 §5, the atomic closure: a helper reachable with a cross
  // argument on ANY parameter makes EVERY buffer access in it atomic -- the
  // helper has one body, and that body must be correct for the call that
  // handed it shared storage. A private buffer accessed atomically loses
  // nothing but a few cycles; a cross buffer accessed plainly loses the
  // property.
  bool anyCross = false;
  for (auto indexed : llvm::enumerate(params_))
    if (const ScalarBorrowedParam *b = gen_.options().borrow(method_.name(), indexed.index()))
      if (b->cross) anyCross = true;
  for (auto indexed : llvm::enumerate(params_)) {
    const ScalarBorrowedParam *b =
        gen_.options().borrow(method_.name(), indexed.index());
    if (!b) continue;
    BufInfo info;
    info.elem = b->element;
    info.isFloat = false;
    info.isSigned = !StringRef(b->element).starts_with("u");
    info.bits = elementBits(b->element);
    info.dir = b->readOnly ? "in" : "inout";
    info.cross = anyCross;
    // The count is not a Ruby name here, so there is nothing to put in
    // `lenName`: the bound arrives as the hidden argument beside the pointer
    // and is captured straight into `descriptorCount_` below.
    info.lenName.clear();
    info.checked = true;
    buffers_[indexed.value()] = std::move(info);
  }
}

void FuncGen::buildStatusBuffers() {
  buffers_.clear();
  for (const ScalarStatusBuffer &b : gen_.options().status.buffers) {
    BufInfo info;
    info.elem = b.element;
    info.isFloat = false;
    info.isSigned = !StringRef(b.element).starts_with("u");
    info.bits = elementBits(b.element);
    info.dir = b.readOnly ? "in" : "inout";
    info.lenName = b.countName;
    info.cross = b.cross;
    // Decision 0007 rejects `bounds: unchecked` and equivalent opt-outs, so
    // there is no way to reach this with `checked` false and no flag to read.
    info.checked = true;
    buffers_[b.name] = info;
  }
}

bool FuncGen::buildLocalTypes() {
  localTypes_.clear();
  if (!gen_.options().freestandingTypes) {
    for (const std::string &name : locals_) {
      if (statusMode() && isEntry() && gen_.options().status.buffer(name)) {
        localTypes_[name] = Type(LLVM::LLVMPointerType::get(builder_.getContext()));
        continue;
      }
      if (statusMode() && borrowedParam(name)) {
        localTypes_[name] = Type(LLVM::LLVMPointerType::get(builder_.getContext()));
        continue;
      }
      if (arrayLocals_.count(name)) {
        localTypes_[name] = Type(LLVM::LLVMPointerType::get(builder_.getContext()));
        continue;
      }
      localTypes_[name] = integerType();
    }
    if (statusMode() && isEntry()) buildStatusBuffers();
    if (statusMode() && !isEntry()) buildBorrowedBuffers();
    // DECISION 0041 STAGE 2: an array is a writable buffer of the body's
    // integer width, counted by its size.
    for (const std::string &name : arrayLocals_) {
      BufInfo info;
      info.elem = integerBits() == 32 ? "i32" : "i64";
      info.bits = integerBits();
      info.isSigned = true;
      info.dir = "inout";
      info.checked = true;
      buffers_[name] = std::move(info);
    }
    return true;
  }
  const int64_t scope = method_.scope();
  // DECISION 0041: a name a block declares may live in a slot the analysis
  // renamed (BlockLoops.h, blockSlotName). Every slot the written name can
  // stand for in this method must agree on one type, and none may be read
  // before it is assigned.
  const std::vector<core::BlockLoop> blockLoops =
      node(method_.defNode())
          ? core::blockLoopsUnder(*node(method_.defNode()),
                                  [&](int64_t id) { return node(id); })
          : std::vector<core::BlockLoop>{};
  auto hasSlot = [&](StringRef slot) { return gen_.hasLocal(scope, slot); };
  for (const std::string &name : locals_) {
    StringRef ty = gen_.localType(scope, name);
    std::vector<std::string> slots;
    if (!ty.empty()) slots.push_back(name);
    for (const core::BlockLoop &loop : blockLoops) {
      if (!llvm::is_contained(loop.params, name) &&
          !llvm::is_contained(loop.locals, name))
        continue;
      const std::string slot = core::blockSlotName(
          name, loop, [&](int64_t id) { return node(id); },
          [&](int64_t id) { return gen_.analysedName(id); }, hasSlot);
      if (slot != name && hasSlot(slot)) slots.push_back(slot);
      // A block's own local starts afresh, as nil, on every call of the
      // block; a read before its assignment would see that nil.
      if (gen_.localNullable(scope, slot))
        return fail(method_.defNode(), "unsupported-block",
                    Twine("`") + name + "` is a local of a `" +
                        core::blockLoopName(loop.kind) +
                        "` block and is read before it is assigned on some "
                        "path; Ruby makes it afresh as nil on every "
                        "iteration, and nil is not in this subset");
    }
    for (const std::string &slot : slots) {
      StringRef other = gen_.localType(scope, slot);
      if (ty.empty()) ty = other;
      else if (other != ty)
        return fail(method_.defNode(), "unsupported-block",
                    Twine("`") + name + "` is " + ty + " in one place and " +
                        other + " in another (a block's `" + name +
                        "` has a slot of its own); one name has one type in "
                        "this subset");
    }
    if (ty == "poly" || ty == "unknown" || ty.empty()) {
      // Declarations own parameter types, even when inference reports unknown.
      const bool isParam = llvm::is_contained(params_, name);
      if (isParam) {
        localTypes_[name] = paramTypeOf(name);
        continue;
      }
      return fail(method_.defNode(), "unsupported-node",
                  Twine("assigned value assigns a Float to `") + name +
                      "`, which whole-program inference typed as an Integer. "
                      "A freestanding local has ONE type (there is no boxed "
                      "slot to hold both). (E077)");
    }
    localTypes_[name] = gen_.typeOf(ty);
  }

  // Buffer parameter table. Historically :len was the immediately following argument, already
  // checked at D1, so it could be taken from declaration order.
  buffers_.clear();
  if (const ScalarRootDesc *rd = gen_.options().root(method_.name())) {
    for (size_t i = 0; i < rd->params.size() && i < params_.size(); ++i) {
      if (rd->params[i].kind != ScalarParamDesc::Kind::Buffer)
        continue;
      BufInfo info;
      StringRef elem = rd->params[i].elem;
      info.elem = elem.str();
      info.isFloat = elem == "f32" || elem == "f64";
      info.isSigned = !elem.starts_with("u");
      info.bits = elementBits(elem);
      info.dir = rd->params[i].dir;
      // DECISION 0044, U1 (found during the review fix): an entry declared
      // `bounds: :unchecked` that a checked entry reaches is, for that call,
      // a helper of a checked root, and its body checks. It stays unchecked
      // when nothing checked reaches it. Its C boundary does not change.
      info.checked = rd->boundsChecked || method_.checkedReach();
      const int li = rd->params[i].lenIndex;
      if (li >= 0 && static_cast<size_t>(li) < params_.size())
        info.lenName = params_[li];
      if (info.bits == 0 || info.lenName.empty())
        return fail(method_.defNode(), "unsupported-node",
                    Twine("buffer element :") + elem +
                        " is outside the freestanding subset");
      buffers_[params_[i]] = std::move(info);
    }
  }
  // DECISION 0044: a buffer the callers lend this helper. Its element and
  // mode are what the calls lend; its length arrives beside the address.
  for (size_t i = 0; i < params_.size(); ++i) {
    const ScalarLentBuffer *l = lentAt(i);
    if (!l) continue;
    BufInfo info;
    StringRef elem = l->elem;
    info.elem = elem.str();
    info.isFloat = elem == "f32" || elem == "f64";
    info.isSigned = !elem.starts_with("u");
    info.bits = elementBits(elem);
    info.dir = l->dir;
    info.checked = l->checked;
    info.lent = true;
    info.inFrom = l->inFrom;
    info.outFrom = l->outFrom;
    if (info.bits == 0)
      return fail(method_.defNode(), "unsupported-node",
                  Twine("buffer element :") + elem +
                      " is outside the freestanding subset");
    buffers_[params_[i]] = std::move(info);
  }
  return true;
}

Value FuncGen::bufferLength(StringRef bufName, const Env &env) {
  auto info = buffers_.find(bufName.str());
  if (info == buffers_.end()) return Value();
  if (info->second.lent) {
    auto held = descriptorCount_.find(bufName.str());
    return held == descriptorCount_.end() ? Value() : held->second;
  }
  auto len = env.find(info->second.lenName);
  return len == env.end() ? Value() : len->second;
}

// Parameter types come from the declared function signature. Decision 0044 uses argSlot because a
// lent buffer occupies two arguments.
Type FuncGen::paramTypeOf(StringRef name) {
  for (auto indexed : enumerate(params_))
    if (indexed.value() == name)
      return func_.getArgument(argSlot(indexed.index())).getType();
  return integerType();
}

// Per-type unassigned defaults exist only to keep the environment total.
Value FuncGen::zeroOf(Location loc, Type type) {
  if (llvm::isa<mlir::FloatType>(type))
    return arith::ConstantOp::create(builder_, loc,
                                     builder_.getFloatAttr(type, 0.0));
  if (llvm::isa<LLVM::LLVMPointerType>(type))
    return LLVM::ZeroOp::create(builder_, loc, type);
  return arith::ConstantOp::create(builder_, loc,
                                   builder_.getIntegerAttr(type, 0));
}

void FuncGen::discardBlock(Block *block) {
  auto owned = llvm::find_if(unopened_, [&](const std::unique_ptr<Block> &held) {
    return held.get() == block;
  });
  if (owned != unopened_.end()) unopened_.erase(owned);
}

void FuncGen::openBlock(Block *block) {
  auto owned = llvm::find_if(unopened_, [&](const std::unique_ptr<Block> &held) {
    return held.get() == block;
  });
  if (owned != unopened_.end()) {
    owned->release();
    unopened_.erase(owned);
  }
  // The entry block arrives already linked (addEntryBlock puts it in the
  // region); re-linking it would splice the region's list onto itself.
  if (block->getParent() != &func_.getBody())
    func_.getBody().push_back(block);
  builder_.setInsertionPointToEnd(block);
}

Block *FuncGen::mergeBlock(ArrayRef<Type> extra, Env &envOut, Value &extraOut) {
  Block *block = newBlock();
  Location loc = builder_.getUnknownLoc();
  envOut.clear();
  // Build arguments with each local type. Without freestandingTypes, typeOfLocal always yields i64,
  // preserving the default output.
  for (const std::string &name : locals_)
    envOut[name] = block->addArgument(typeOfLocal(name), loc);
  extraOut = Value();
  for (Type type : extra)
    extraOut = block->addArgument(type, loc);
  return block;
}

SmallVector<Value> FuncGen::argsOf(const Env &env, Value extra) const {
  SmallVector<Value> values;
  for (const std::string &name : locals_)
    values.push_back(env.at(name));
  if (extra)
    values.push_back(extra);
  return values;
}

void FuncGen::branch(Location loc, Block *dest, const Env &env, Value extra) {
  SmallVector<Value> args;
  if (dest->getNumArguments())
    args = argsOf(env, extra);
  cf::BranchOp::create(builder_, loc, dest, args);
}

void FuncGen::condBranch(Location loc, Value cond, Block *trueDest,
                         const Env &trueEnv, Value trueExtra, Block *falseDest,
                         const Env &falseEnv, Value falseExtra) {
  SmallVector<Value> trueArgs, falseArgs;
  if (trueDest->getNumArguments())
    trueArgs = argsOf(trueEnv, trueExtra);
  if (falseDest->getNumArguments())
    falseArgs = argsOf(falseEnv, falseExtra);
  cf::CondBranchOp::create(builder_, loc, cond, trueDest, trueArgs, falseDest,
                           falseArgs);
}

// Decision 0044: what a value that is not a number IS, for the refusals
// below. A buffer used as a value is the one that was misnamed a boolean.
static const char *nonNumberKind(Type t) {
  if (llvm::isa<LLVM::LLVMPointerType>(t))
    return " is a buffer; a buffer can be indexed and passed to a helper "
           "that takes it, and is not a value";
  if (t.isInteger(1)) return " is a boolean";
  if (llvm::isa<mlir::FloatType>(t)) return " is a Float";
  return " is not an Integer";
}

bool FuncGen::needInt(int64_t nodeId, Value v, const Twine &what) {
  if (!v)
    return fail(nodeId, "unsupported-node",
                what + " has no value (nil is not in the subset)");
  if (!v.getType().isInteger(integerBits()))
    return fail(nodeId, "unsupported-node",
                what + nonNumberKind(v.getType()) +
                    "; only Integer values are in the subset");
  return true;
}

// Require a numeric value (i64 or f64). Without freestandingTypes this equals needInt because f64
// values cannot be constructed.
bool FuncGen::needNumeric(int64_t nodeId, Value v, const Twine &what) {
  if (!gen_.options().freestandingTypes)
    return needInt(nodeId, v, what);
  if (!v)
    return fail(nodeId, "unsupported-node",
                what + " has no value (nil is not in the subset)");
  if (v.getType().isInteger(integerBits()) || llvm::isa<mlir::Float64Type>(v.getType()))
    return true;
  return fail(nodeId, "unsupported-node",
              what + nonNumberKind(v.getType()) +
                  "; only Integer values are in the subset");
}

// Promote integer to floating context with sitofp, matching frozen Python. Never implicitly convert
// float to int: neither Ruby nor the frozen path does so; D2 names declaration/body mismatches.
Value FuncGen::toFloat(Location loc, Value v) {
  if (llvm::isa<mlir::Float64Type>(v.getType()))
    return v;
  return arith::SIToFPOp::create(builder_, loc, builder_.getF64Type(), v);
}

// Coerce only i64 to f64. The caller names/refuses other type mismatches.
Value FuncGen::coerce(Location loc, Value v, Type want) {
  if (!v || v.getType() == want)
    return v;
  if (llvm::isa<mlir::Float64Type>(want) && v.getType().isInteger(integerBits()))
    return toFloat(loc, v);
  return v;
}

Value FuncGen::wideInteger(Location loc, Value v) {
  if (v.getType().isInteger(64)) return v;
  return arith::ExtSIOp::create(builder_, loc, builder_.getI64Type(), v);
}

Value FuncGen::bodyInteger(Location loc, Value v, bool isSigned) {
  unsigned bits = llvm::cast<IntegerType>(v.getType()).getWidth();
  if (bits < integerBits())
    return isSigned ? Value(arith::ExtSIOp::create(builder_, loc, integerType(), v))
                    : Value(arith::ExtUIOp::create(builder_, loc, integerType(), v));
  if (bits == integerBits() && (isSigned || integerBits() == 64)) return v;
  Value narrow = bits == integerBits() ? v
      : Value(arith::TruncIOp::create(builder_, loc, integerType(), v));
  if (gen_.mode() == OverflowMode::Wrap) return narrow;
  Value bad;
  if (bits == integerBits()) {
    bad = arith::CmpIOp::create(builder_, loc, arith::CmpIPredicate::slt,
                                 v, constant(loc, 0));
  } else {
    Value back = arith::ExtSIOp::create(builder_, loc, v.getType(), narrow);
    bad = arith::CmpIOp::create(builder_, loc, arith::CmpIPredicate::ne, back, v);
    if (!isSigned) {
      Value negative = arith::CmpIOp::create(builder_, loc,
          arith::CmpIPredicate::slt, narrow, constant(loc, 0));
      bad = arith::OrIOp::create(builder_, loc, bad, negative);
    }
  }
  if (statusMode()) statusGuard(loc, bad, CoreStatus::Arithmetic, "narrowing to the body width");
  else {
    Block *cold = trapBlock(loc, 3, v, Value(),
        (Twine(method_.name()) + ": value does not fit target Integer").str());
    Block *cont = newBlock();
    cf::CondBranchOp::create(builder_, loc, bad, cold, ValueRange{}, cont, ValueRange{});
    openBlock(cont);
  }
  return narrow;
}

bool FuncGen::needBool(int64_t nodeId, Value v, const Twine &what) {
  if (!v)
    return fail(nodeId, "unsupported-node", what + " has no value");
  if (!v.getType().isInteger(1))
    // `while i` / `if n` on an Integer is truthy in Ruby for EVERY int
    // (0 included).  Refusing it is the frozen generator's rule (need_bool),
    // and it belongs here rather than in the selector: the selector asks what
    // KIND a node is, never what kind a value has.
    return fail(nodeId, "unsupported-node",
                what + " is an Integer used as a condition; Ruby truthiness of "
                       "Integers (0 is true) is not in the subset");
  return true;
}

// ---------------------------------------------------------------------------
// The checked modes (frozen FuncGen: "E022: the raise machinery")
// ---------------------------------------------------------------------------

Block *FuncGen::coldBlock() {
  cold_.push_back(std::make_unique<Block>());
  return cold_.back().get();
}

Block *FuncGen::raiseClsBlock(Location loc, StringRef cls, StringRef msg) {
  Block *block = coldBlock();
  OpBuilder cold(func_.getContext());
  cold.setInsertionPointToEnd(block);
  const Type ptr = LLVM::LLVMPointerType::get(cold.getContext());
  // The two literals are interned in THIS order, and the order is what the
  // `sp_cstr_N` numbering follows: "RangeError" before "integer overflow in +".
  Value clsPtr = LLVM::AddressOfOp::create(cold, loc, ptr, gen_.cstring(cls));
  Value msgPtr = LLVM::AddressOfOp::create(cold, loc, ptr, gen_.cstring(msg));
  LLVM::CallOp::create(cold, loc, TypeRange{}, StringRef(kRaiseCls),
                       ValueRange{clsPtr, msgPtr});
  // The raiser longjmps, so nothing follows it.  `llvm.unreachable` rather
  // than a `return 0`: a value here would be a lie about a path that does not
  // exist, and it is what lets the optimiser keep the arm out of the hot path.
  LLVM::UnreachableOp::create(cold, loc);
  gen_.useRaiseCls();
  return block;
}

// Full trap detail uses the Ruby method name, not sp_<fn>/spinel_<fn>. Lowering cannot see that
// name, so the importer constructs the attribute while both are known.
std::string FuncGen::trapDetail(StringRef opSpelling) const {
  return (Twine(method_.name()) + ": integer overflow in " + opSpelling).str();
}

// Cold profile-hook arm, matching frozen trap_block. Historical codes are 1..6; a/b are operands (0
// for an absent one), detail is a .rodata string. The hook never returns: end with
// llvm.unreachable.
Block *FuncGen::trapBlock(Location loc, int32_t code, Value a, Value b,
                          StringRef detail) {
  Block *block = coldBlock();
  OpBuilder cold(func_.getContext());
  cold.setInsertionPointToEnd(block);
  const Type ptr = LLVM::LLVMPointerType::get(cold.getContext());
  Value codeV = arith::ConstantOp::create(cold, loc, cold.getI32Type(),
                                          cold.getI32IntegerAttr(code));
  auto zero = [&]() -> Value {
    return arith::ConstantOp::create(cold, loc, cold.getI64Type(),
                                     cold.getI64IntegerAttr(0));
  };
  Value aV = a ? a : zero();
  Value bV = b ? b : zero();
  if (aV.getType().isInteger(32)) aV = arith::ExtSIOp::create(cold, loc, cold.getI64Type(), aV);
  if (bV.getType().isInteger(32)) bV = arith::ExtSIOp::create(cold, loc, cold.getI64Type(), bV);
  Value detailPtr =
      LLVM::AddressOfOp::create(cold, loc, ptr, gen_.cstring(detail));
  // Call the func.func hook with func.call: llvm.call cannot reference a func-dialect function and
  // reports an invalid LLVM function.
  func::CallOp::create(cold, loc, TypeRange{}, gen_.trapHook(),
                       ValueRange{codeV, aV, bV, detailPtr});
  LLVM::UnreachableOp::create(cold, loc);
  gen_.useTrapHook();
  return block;
}

void FuncGen::nilCheck(Location loc, Value a, Value b, StringRef op) {
  // frozen: the cold arm is built FIRST, so the operator's own literal is
  // interned before anything the continuation might intern.
  Block *cold = coldBlock();
  {
    OpBuilder builder(func_.getContext());
    builder.setInsertionPointToEnd(cold);
    const Type ptr = LLVM::LLVMPointerType::get(builder.getContext());
    Value opPtr = LLVM::AddressOfOp::create(builder, loc, ptr, gen_.cstring(op));
    // Both operands go to the raiser: which of the two was the nil is the
    // runtime's message to write, and it cannot write it without them.
    LLVM::CallOp::create(builder, loc, TypeRange{}, StringRef(kRaiseNilOp),
                         ValueRange{a, b, opPtr});
    LLVM::UnreachableOp::create(builder, loc);
  }
  gen_.useRaiseNilOp();

  Value nil = constant(loc, kIntNil);
  Value isNilA = arith::CmpIOp::create(builder_, loc, arith::CmpIPredicate::eq,
                                       a, nil);
  Value isNilB = arith::CmpIOp::create(builder_, loc, arith::CmpIPredicate::eq,
                                       b, nil);
  Value either = arith::OrIOp::create(builder_, loc, isNilA, isNilB);
  Block *cont = newBlock();
  cf::CondBranchOp::create(builder_, loc, either, cold, ValueRange{}, cont,
                           ValueRange{}, ArrayRef<int32_t>(kNilWeights));
  openBlock(cont);
}

void FuncGen::zeroCheck(Location loc, Value a, Value b, StringRef op) {
  // With a freestanding hook, zero division uses code 2, not raise. Frozen div_guard(a,b) ->
  // zero_check(b,a) -> trap_block(2,a,b,...) swaps twice: hook a is dividend and b divisor. Status
  // ABI instead reports its own ARITHMETIC value without a raiser/hook; its numeric collision with
  // trap code 2 does not equate the meanings.
  Block *cold =
      statusMode()
          ? statusBlock(loc, CoreStatus::Arithmetic, ("division by zero in " + op).str())
      : abortMode()
          ? coreFailBlock(loc, CoreFailKind::ZeroDivision, op)
          : (gen_.trapHook().empty()
                 ? raiseClsBlock(loc, "ZeroDivisionError", "divided by 0")
                 : trapBlock(loc, 2, a, b,
                             (Twine(method_.name()) + ": divided by 0").str()));
  Value zero = constant(loc, 0);
  Value isZero = arith::CmpIOp::create(builder_, loc, arith::CmpIPredicate::eq,
                                       b, zero);
  Block *cont = newBlock();
  cf::CondBranchOp::create(builder_, loc, isZero, cold, ValueRange{}, cont,
                           ValueRange{});
  openBlock(cont);
}

void FuncGen::divGuard(Location loc, Value a, Value b, StringRef op) {
  // Frozen div_guard tests hook presence first: freestanding always checks zero divisors regardless
  // of mode, without the hosted boxed-nil sentinel (nil is outside its subset). This explains the
  // observed div_zero_wrap code 2.
  if (statusMode() || abortMode()) {
    // No nil sentinel at this boundary -- decision 0007: native entry values
    // have none; decision 0015: an intermediate INT64_MIN is an ordinary value
    // in core -- so the zero divisor is the whole guard.
    zeroCheck(loc, a, b, op);
    return;
  }
  if (!gen_.trapHook().empty()) {
    zeroCheck(loc, a, b);
    return;
  }
  if (gen_.mode() == OverflowMode::None)
    return;
  nilCheck(loc, a, b, op);
  zeroCheck(loc, a, b);
}

Value FuncGen::overflowOp(Location loc, StringRef op, Value a, Value b,
                          StringRef reported) {
  MLIRContext *context = func_.getContext();
  const Type i64 = integerType();
  const Type i1 = builder_.getI1Type();
  const Type pair = LLVM::LLVMStructType::getLiteral(context, {i64, i1});

  Value checked;
  if (op == "+")
    checked = LLVM::SAddWithOverflowOp::create(builder_, loc, pair, a, b);
  else if (op == "-")
    checked = LLVM::SSubWithOverflowOp::create(builder_, loc, pair, a, b);
  else
    checked = LLVM::SMulWithOverflowOp::create(builder_, loc, pair, a, b);

  Value flag =
      LLVM::ExtractValueOp::create(builder_, loc, checked, ArrayRef<int64_t>{1});
  Block *cold =
      statusMode()
          ? statusBlock(loc, CoreStatus::Arithmetic, ("checked " + op).str())
      : abortMode()
          ? coreFailBlock(loc, CoreFailKind::Overflow,
                          reported.empty() ? op : reported)
          : raiseClsBlock(loc, "RangeError",
                          (Twine("integer overflow in ") + op).str());
  Block *cont = newBlock();
  // No weights on this one: an overflow is a property of the VALUES, not of
  // the calling convention, and the frozen generator does not claim to know
  // how often it happens (frozen overflow_op writes the branch bare).
  cf::CondBranchOp::create(builder_, loc, flag, cold, ValueRange{}, cont,
                           ValueRange{});
  openBlock(cont);
  return LLVM::ExtractValueOp::create(builder_, loc, checked,
                                      ArrayRef<int64_t>{0});
}

// ---------------------------------------------------------------------------
// The status ABI (decision 0007 task 2)
// ---------------------------------------------------------------------------

bool FuncGen::statusMode() const { return gen_.mode() == OverflowMode::Status; }

std::optional<CoreStatus> FuncGen::coreFailCategory(const Node *n) const {
  int64_t argumentsId = -1, block = -1;
  if (!ast::getReference(*n, "block", block) || block >= 0) return std::nullopt;
  if (!ast::getReference(*n, "arguments", argumentsId) || argumentsId < 0)
    return std::nullopt;
  const Node *args = node(argumentsId);
  if (!args || args->kind != "ArgumentsNode") return std::nullopt;
  std::vector<int64_t> values;
  if (!ast::getArray(*args, "arguments", values) || values.size() != 1)
    return std::nullopt;
  const Node *sym = node(values[0]);
  std::string category;
  if (!sym || sym->kind != "SymbolNode" ||
      !ast::getString(*sym, "value", category))
    return std::nullopt;
  // The same one spelling the selector and the eligibility checker admit,
  // written out here a third time because these are three separate pieces of
  // code -- and pinned by refusal fixtures rather than trusted to stay in step.
  if (category == "capacity") return CoreStatus::Capacity;
  return std::nullopt;
}

Value FuncGen::resultPtr() const {
  func::FuncOp fn = func_;
  return fn.getArgument(fn.getNumArguments() - 1);
}

StringRef FuncGen::resultDomain() const {
  const ScalarStatusAbi &abi = gen_.options().status;
  return method_.name() == abi.entry ? StringRef(abi.resultDomain)
                                     : StringRef("i64");
}

Block *FuncGen::statusBlock(Location loc, CoreStatus code, StringRef what) {
  Block *block = coldBlock();
  OpBuilder cold(func_.getContext());
  cold.setInsertionPointToEnd(block);
  gen_.storeFailureSite(cold, loc, code, what);
  // No store. Decision 0007: the result is written only on SPINEL_CORE_OK, so
  // a failing call leaves the caller's variable exactly as the caller left it.
  Value status = arith::ConstantOp::create(
      cold, loc, cold.getI32Type(),
      cold.getI32IntegerAttr(static_cast<int32_t>(code)));
  func::ReturnOp::create(cold, loc, status);
  return block;
}

void FuncGen::statusGuard(Location loc, Value failed, CoreStatus code, StringRef what) {
  Block *cold = statusBlock(loc, code, what);
  Block *cont = newBlock();
  cf::CondBranchOp::create(builder_, loc, failed, cold, ValueRange{}, cont,
                           ValueRange{});
  openBlock(cont);
}

bool FuncGen::abortMode() const { return gen_.mode() == OverflowMode::Abort; }

bool FuncGen::bitOperators() const {
  return abortMode() || gen_.options().freestandingTypes;
}

Block *FuncGen::coreFailBlock(Location loc, CoreFailKind kind, StringRef op) {
  const CoreFailOp code = llvm::StringSwitch<CoreFailOp>(op)
                              .Case("+", CoreFailOp::Add)
                              .Case("-", CoreFailOp::Sub)
                              .Case("*", CoreFailOp::Mul)
                              .Case("/", CoreFailOp::Div)
                              .Case("%", CoreFailOp::Mod)
                              .Case("-@", CoreFailOp::Neg)
                              .Case("<<", CoreFailOp::Shl)
                              .Case("abs", CoreFailOp::Abs)
                              .Case("**", CoreFailOp::Pow)
                              .Default(CoreFailOp::None);
  return coreFailCodeBlock(loc, kind, static_cast<int32_t>(code));
}

Block *FuncGen::coreFailCodeBlock(Location loc, CoreFailKind kind, int32_t code) {
  Block *block = coldBlock();
  OpBuilder cold(func_.getContext());
  cold.setInsertionPointToEnd(block);
  const Type i32 = cold.getI32Type();
  Value kindV = arith::ConstantOp::create(
      cold, loc, i32, cold.getI32IntegerAttr(static_cast<int32_t>(kind)));
  Value opV = arith::ConstantOp::create(cold, loc, i32, cold.getI32IntegerAttr(code));
  LLVM::CallOp::create(cold, loc, TypeRange{}, StringRef(kCoreFailHook),
                       ValueRange{kindV, opV});
  // The hook does not return. Nothing is stored and nothing is returned: the
  // signatures are the hosted prototype's, and there is no value to give it.
  LLVM::UnreachableOp::create(cold, loc);
  gen_.useCoreFail();
  return block;
}

void FuncGen::coreFailGuard(Location loc, Value failed, CoreFailKind kind,
                            StringRef op) {
  failGuard(loc, failed, coreFailBlock(loc, kind, op));
}

void FuncGen::failGuard(Location loc, Value failed, Block *cold) {
  Block *cont = newBlock();
  cf::CondBranchOp::create(builder_, loc, failed, cold, ValueRange{}, cont,
                           ValueRange{});
  openBlock(cont);
}

void FuncGen::captureBound32(Location loc, const std::string &buf) {
  if (countBits() != 32) return;
  Value count = descriptorCount_[buf];
  if (!count || !count.getType().isInteger(32)) return;
  Value cap = arith::ConstantOp::create(builder_, loc, builder_.getI32Type(),
                                        builder_.getI32IntegerAttr(INT32_MIN));
  descriptorBound32_[buf] = arith::MinUIOp::create(builder_, loc, count, cap);
}

Value FuncGen::callSlot(Location loc) {
  if (callSlot_)
    return callSlot_;
  // In the ENTRY block, before anything else: an alloca reached repeatedly --
  // a call inside a `while` -- would otherwise grow the frame on every
  // iteration. One slot serves every call site because a callee's result is
  // loaded immediately after the call returns and never outlives it.
  OpBuilder entry(func_.getContext());
  Block &first = func_.getBody().front();
  entry.setInsertionPointToStart(&first);
  Value one = arith::ConstantOp::create(entry, loc, entry.getI64Type(),
                                        entry.getI64IntegerAttr(1));
  callSlot_ = LLVM::AllocaOp::create(
      entry, loc, LLVM::LLVMPointerType::get(entry.getContext()),
      integerType(), one);
  return callSlot_;
}

void FuncGen::emitValueReturn(Location loc, Value v) {
  if (!statusMode()) {
    func::ReturnOp::create(
        builder_, loc, coerce(loc, v, func_.getFunctionType().getResult(0)));
    return;
  }

  // The result domain is checked HERE, at the return, and not at each
  // operation: an i32-result kernel may compute in i64 and only has to land
  // inside i32 at the boundary. Decision 0007 calls a narrowing of computed
  // values at a return ARITHMETIC, not ARGUMENT -- ARGUMENT is for an entry
  // scalar the caller supplied.
  // DECISION 0008 TASK 3: an internal helper's boolean travels in the same
  // Integer slot every other result uses, as 0 or 1. One slot type keeps the ABI
  // uniform; the caller turns it back into a condition below, and the value
  // never reaches the boundary.
  if (v && v.getType().isInteger(1))
    v = arith::ExtUIOp::create(builder_, loc, integerType(), v);
  const StringRef domain = resultDomain();
  Value stored = v;
  if (integerBits() == 32) {
    if (domain == "u32") {
      Value negative = arith::CmpIOp::create(builder_, loc, arith::CmpIPredicate::slt, v, constant(loc, 0));
      statusGuard(loc, negative, CoreStatus::Arithmetic, "result narrowing to u32");
    }
  } else if (domain != "i64") {
    const bool isSigned = domain == "i32";
    const int64_t lo = isSigned ? -2147483648LL : 0LL;
    const int64_t hi = isSigned ? 2147483647LL : 4294967295LL;
    Value tooLow = arith::CmpIOp::create(builder_, loc, arith::CmpIPredicate::slt,
                                         v, constant(loc, lo));
    Value tooHigh = arith::CmpIOp::create(builder_, loc, arith::CmpIPredicate::sgt,
                                          v, constant(loc, hi));
    statusGuard(loc, arith::OrIOp::create(builder_, loc, tooLow, tooHigh),
                CoreStatus::Arithmetic, ("result narrowing to " + domain).str());
    // Only after the range check: the truncation is then exact, and the
    // unsigned domain's bit pattern is the value the caller reads back as
    // `uint32_t`.
    stored = arith::TruncIOp::create(builder_, loc, builder_.getI32Type(), v);
  }
  LLVM::StoreOp::create(builder_, loc, stored, resultPtr());
  Value ok = arith::ConstantOp::create(
      builder_, loc, builder_.getI32Type(),
      builder_.getI32IntegerAttr(static_cast<int32_t>(CoreStatus::Ok)));
  func::ReturnOp::create(builder_, loc, ok);
}

Value FuncGen::shiftOp(Location loc, StringRef op, Value a, Value b) {
  // Decision 0042, S1: Ruby's rule wherever the value fits, which is the
  // pinned Spinel's `sp_int_shl` / `sp_int_shr` under `--int-overflow=raise`,
  // with one difference the record states: `a >> -n` is checked as `a << n`,
  // where the pin shifts with no check.
  //
  //   a << n   n >= 0: a * 2**n, failing past the width (also any n >= w
  //            with a != 0); n < 0: a >> -n
  //   a >> n   n >= 0: floor(a / 2**n), the sign fill for n >= w; n < 0:
  //            a << -n
  //
  // Branch-free: the direction and the magnitude of the count first, then
  // both shifts with counts kept inside 0..w-1 -- LLVM's shl and ashr are
  // poison at a count of the width or more -- and a select between them.
  // `n = MIN` has no negation; `0 - MIN` wraps back to MIN, which is at
  // least w as an unsigned number, so it is a large magnitude like any
  // other.
  const int64_t w = integerBits();
  auto cmp = [&](arith::CmpIPredicate p, Value x, Value y) -> Value {
    return arith::CmpIOp::create(builder_, loc, p, x, y);
  };
  auto select = [&](Value c, Value x, Value y) -> Value {
    return arith::SelectOp::create(builder_, loc, c, x, y);
  };
  Value zero = constant(loc, 0);
  Value negative = cmp(arith::CmpIPredicate::slt, b, zero);
  Value magnitude =
      select(negative, arith::SubIOp::create(builder_, loc, zero, b), b);
  Value large = cmp(arith::CmpIPredicate::uge, magnitude, constant(loc, w));
  // Leftward: `<<` with a count of 0 or more, `>>` with a negative one.
  Value leftward = op == "<<"
                       ? cmp(arith::CmpIPredicate::sge, b, zero)
                       : negative;

  // Rightward by w or more is the sign fill, which is the shift by w - 1.
  Value rightCount = select(large, constant(loc, w - 1), magnitude);
  Value right = arith::ShRSIOp::create(builder_, loc, a, rightCount);

  // Leftward: a value that does not shift back has lost bits. `-1 << (w-1)`
  // is MIN and shifts back; `1 << (w-1)` is the same bit pattern and does
  // not. By w or more, every bit is lost unless there were none.
  Value leftCount = select(large, zero, magnitude);
  Value shifted = arith::ShLIOp::create(builder_, loc, a, leftCount);
  Value back = arith::ShRSIOp::create(builder_, loc, shifted, leftCount);
  Value lost = select(large, cmp(arith::CmpIPredicate::ne, a, zero),
                      cmp(arith::CmpIPredicate::ne, back, a));
  // The wrapped value: the low bits, which are none by w or more.
  Value left = select(large, zero, shifted);
  Value result = select(leftward, left, right);

  Value failed = arith::AndIOp::create(builder_, loc, leftward, lost);
  if (statusMode()) {
    statusGuard(loc, failed, CoreStatus::Arithmetic, ("checked " + op).str());
  } else if (abortMode()) {
    // The pinned Spinel's text for both: `integer overflow in <<`.
    coreFailGuard(loc, failed, CoreFailKind::Overflow, "<<");
  } else if (gen_.mode() == OverflowMode::Trap ||
             gen_.mode() == OverflowMode::Raise) {
    // Trap: the profile's hook with the overflow code, as `MIN / -1` uses.
    failGuard(loc, failed,
              gen_.trapHook().empty()
                  ? raiseClsBlock(loc, "RangeError", "integer overflow in <<")
                  : trapBlock(loc, 1, a, b, trapDetail(op)));
  }
  // Wrap and None: the low bits, as the pinned Spinel's wrap mode gives them.
  return result;
}

// DECISION 0022 §1 and 0042 stage 4. A 32-bit form's operands are checked to
// be in the i32 range first -- a failure otherwise, ahead of any other
// outcome -- and a 32-bit body's values are in it by construction, so there
// the check is not emitted. Then the operation runs on machine words with no
// call, and the result is its low bits read back as signed. `core_fixed_div`
// alone may divide in 64 bits, which on a 32-bit target is the runtime's
// division helper. Each failure is the mode's own (intrinsicFail).
ExprResult FuncGen::intrinsicCall(const Node *n,
                                  const spinel_mlir::core::CoreIntrinsic &in,
                                  ArrayRef<int64_t> args, Env env) {
  using spinel_mlir::core::IntrinsicFailure;
  using spinel_mlir::core::IntrinsicOp;
  const Location loc = locOf(n->id);
  const std::string name(in.name);
  if (args.size() != in.arity) {
    fail(n->id, "unsupported-node",
         Twine("'") + name + "' with " + Twine(args.size()) + " arguments, expected " +
             Twine(in.arity));
    return ExprResult{Value(), std::move(env), false};
  }
  // The checkers refuse a 64-bit form on a 32-bit body; this is the backstop.
  if (in.wide && integerBits() == 32) {
    fail(n->id, "unsupported-node",
         Twine("'") + name + "' computes on 64-bit words and this body is 32 bits");
    return ExprResult{Value(), std::move(env), false};
  }
  // core_u32(LIT): a constant. The literal is not evaluated -- on a 32-bit
  // body it is wider than an Integer -- only read.
  if (in.literal) {
    const Node *lit = node(args[0]);
    int64_t value = 0;
    std::string big;
    std::optional<int64_t> v;
    if (lit && lit->kind == "IntegerNode" && ast::getInteger(*lit, "value", value)) {
      const bool hasBig = ast::getString(*lit, "bigval", big);
      v = spinel_mlir::core::u32LiteralValue(value, hasBig ? &big : nullptr);
    }
    if (!v) {
      fail(n->id, "unsupported-node",
           "core_u32 takes an Integer literal in 0..4294967295");
      return ExprResult{Value(), std::move(env), false};
    }
    return ExprResult{constant(loc, *v), std::move(env), true};
  }
  SmallVector<Value, 2> v;
  for (int64_t id : args) {
    ExprResult r = expr(node(id), std::move(env));
    env = std::move(r.env);
    if (!r.ok || !needNumeric(n->id, r.value, Twine("operand of ") + name))
      return ExprResult{Value(), std::move(env), false};
    v.push_back(r.value);
  }
  const Value first = v[0];
  const Value second = v.size() > 1 ? v[1] : v[0];
  // A failure, the mode's own way: ARITHMETIC on the status lane, the hook
  // with kind 4 on --core, and code 8 on freestanding under every policy (an
  // operand out of range has no wrapped meaning), or with no trap hook the
  // RangeError the other freestanding failures raise.
  auto intrinsicFail = [&](Value failed, IntrinsicFailure what) {
    const std::string text = spinel_mlir::core::failText(in, what);
    // The status lane's failure-site texts are 0022's, unchanged.
    if (statusMode())
      statusGuard(loc, failed, CoreStatus::Arithmetic,
                  what == IntrinsicFailure::Operand
                      ? std::string("word intrinsic operand outside i32")
                      : name + " count");
    else if (abortMode())
      failGuard(loc, failed,
                coreFailCodeBlock(loc, CoreFailKind::Intrinsic,
                                  spinel_mlir::core::failOp(in, what)));
    else
      failGuard(loc, failed,
                gen_.trapHook().empty()
                    ? raiseClsBlock(loc, "RangeError", text)
                    : trapBlock(loc, 8, first, second,
                                (Twine(method_.name()) + ": " + text).str()));
  };
  if (integerBits() != 32 && spinel_mlir::core::checksI32Operands(in))
    for (Value x : v) { // an i64 body's operand; constant() is i64 here
      Value below = arith::CmpIOp::create(builder_, loc, arith::CmpIPredicate::slt, x,
                                          constant(loc, INT32_MIN));
      Value above = arith::CmpIOp::create(builder_, loc, arith::CmpIPredicate::sgt, x,
                                          constant(loc, INT32_MAX));
      intrinsicFail(arith::OrIOp::create(builder_, loc, below, above),
                    IntrinsicFailure::Operand);
    }
  // The body's Integer is i32 or i64 (integerType()); the 32-bit word
  // operations run on i32, the fixed-point ones and the 64-bit forms on i64.
  const Type i32 = builder_.getI32Type();
  const Type i64 = builder_.getI64Type();
  const bool wide = integerBits() != 32;
  auto narrow = [&](Value x) -> Value {
    return wide ? Value(arith::TruncIOp::create(builder_, loc, i32, x)) : x;
  };
  auto widen = [&](Value x) -> Value {
    return wide ? Value(arith::ExtSIOp::create(builder_, loc, i64, x)) : x;
  };
  auto to64 = [&](Value x) -> Value {
    return wide ? x : Value(arith::ExtSIOp::create(builder_, loc, i64, x));
  };
  auto k64 = [&](int64_t c) -> Value {
    return arith::ConstantOp::create(builder_, loc, i64, builder_.getI64IntegerAttr(c));
  };
  auto k32 = [&](int32_t c) -> Value {
    return arith::ConstantOp::create(builder_, loc, i32, builder_.getI32IntegerAttr(c));
  };
  auto done = [&](Value r) { return ExprResult{r, std::move(env), true}; };
  auto ucmp = [&](arith::CmpIPredicate p) {
    return done(arith::CmpIOp::create(builder_, loc, p, narrow(v[0]), narrow(v[1])));
  };
  auto ucmp64 = [&](arith::CmpIPredicate p) {
    return done(arith::CmpIOp::create(builder_, loc, p, v[0], v[1]));
  };
  // A logical right shift whose count must be in 0..countMax, checked on the
  // operand as given.
  auto checkCount = [&](Value count) {
    Value below = arith::CmpIOp::create(builder_, loc, arith::CmpIPredicate::slt, count,
                                        constant(loc, 0));
    Value above = arith::CmpIOp::create(builder_, loc, arith::CmpIPredicate::sgt, count,
                                        constant(loc, in.countMax));
    intrinsicFail(arith::OrIOp::create(builder_, loc, below, above), IntrinsicFailure::Count);
  };
  // Ruby's `a << n` at `bits` (32 or 64), its low bits, for every n: a count
  // of `bits` or more gives 0, a negative one shifts right arithmetically by
  // min(-n, bits - 1). `a` is a value of that width; `count` is the body's.
  // Each arm's count is clamped into range so that no shift is poison.
  auto shiftLeft = [&](Value a, Value count, unsigned bits) -> Value {
    const Type t = a.getType();
    auto kt = [&](int64_t c) -> Value {
      return arith::ConstantOp::create(builder_, loc, t, builder_.getIntegerAttr(t, c));
    };
    auto inT = [&](Value x) -> Value {
      if (x.getType() == t) return x;
      return arith::TruncIOp::create(builder_, loc, t, x);
    };
    Value zeroC = constant(loc, 0);
    Value negative = arith::CmpIOp::create(builder_, loc, arith::CmpIPredicate::slt, count, zeroC);
    Value tooFar = arith::CmpIOp::create(builder_, loc, arith::CmpIPredicate::sge, count,
                                         constant(loc, bits));
    // left: the count when it is in 0..bits-1, else 0
    Value inRange = arith::AndIOp::create(
        builder_, loc,
        arith::XOrIOp::create(builder_, loc, negative,
                              arith::ConstantOp::create(builder_, loc, builder_.getI1Type(),
                                                        builder_.getBoolAttr(true))),
        arith::XOrIOp::create(builder_, loc, tooFar,
                              arith::ConstantOp::create(builder_, loc, builder_.getI1Type(),
                                                        builder_.getBoolAttr(true))));
    Value leftCount = arith::SelectOp::create(builder_, loc, inRange, count, zeroC);
    Value left = arith::ShLIOp::create(builder_, loc, a, inT(leftCount));
    // right: min(-n, bits - 1) for n < 0. -n is taken only where n is above
    // -(bits - 1), so it cannot overflow.
    Value deep = arith::CmpIOp::create(builder_, loc, arith::CmpIPredicate::sle, count,
                                       constant(loc, -static_cast<int64_t>(bits - 1)));
    Value shallow = arith::SelectOp::create(builder_, loc, deep, zeroC,
                                            arith::SubIOp::create(builder_, loc, zeroC, count));
    Value rightCount = arith::SelectOp::create(builder_, loc, deep, constant(loc, bits - 1),
                                               arith::SelectOp::create(builder_, loc, negative,
                                                                       shallow, zeroC));
    Value right = arith::ShRSIOp::create(builder_, loc, a, inT(rightCount));
    Value r = arith::SelectOp::create(builder_, loc, negative, right, left);
    return arith::SelectOp::create(builder_, loc, tooFar, kt(0), r);
  };
  switch (in.op) {
  case IntrinsicOp::W32Add:
    return done(widen(arith::AddIOp::create(builder_, loc, narrow(v[0]), narrow(v[1]))));
  case IntrinsicOp::W32Sub:
    return done(widen(arith::SubIOp::create(builder_, loc, narrow(v[0]), narrow(v[1]))));
  case IntrinsicOp::W32Mul:
    return done(widen(arith::MulIOp::create(builder_, loc, narrow(v[0]), narrow(v[1]))));
  case IntrinsicOp::W32Neg:
    return done(widen(arith::SubIOp::create(builder_, loc, k32(0), narrow(v[0]))));
  case IntrinsicOp::W32Shl:
    return done(widen(shiftLeft(narrow(v[0]), v[1], 32)));
  case IntrinsicOp::U32Lt: return ucmp(arith::CmpIPredicate::ult);
  case IntrinsicOp::U32Le: return ucmp(arith::CmpIPredicate::ule);
  case IntrinsicOp::U32Gt: return ucmp(arith::CmpIPredicate::ugt);
  case IntrinsicOp::U32Ge: return ucmp(arith::CmpIPredicate::uge);
  case IntrinsicOp::U32Shr:
    checkCount(v[1]);
    return done(widen(arith::ShRUIOp::create(builder_, loc, narrow(v[0]), narrow(v[1]))));
  case IntrinsicOp::FixedMul: {
    // both operands are i32, so the i64 product is exact: (-2^31)^2 = 2^62
    Value p = arith::MulIOp::create(builder_, loc, to64(v[0]), to64(v[1]));
    Value s = arith::ShRSIOp::create(builder_, loc, p, k64(16));
    return done(widen(arith::TruncIOp::create(builder_, loc, i32, s)));
  }
  case IntrinsicOp::FixedDiv: {
    // fixed.rb's fixed_div: saturate when (|a| >> 14) >= |b| (mathematical
    // absolute values, exact in i64), to I32_MIN when a ^ b < 0 and I32_MAX
    // otherwise -- so b == 0 always saturates; else (a << 16) / b truncated
    // toward zero, whose magnitude the guard keeps below 2^30. The divisor is
    // replaced by 1 on the saturating path, so nothing ever divides by zero.
    const Value a = to64(v[0]), b = to64(v[1]);
    Value zero = k64(0);
    auto absOf = [&](Value x) -> Value {
      Value neg = arith::CmpIOp::create(builder_, loc, arith::CmpIPredicate::slt, x, zero);
      return arith::SelectOp::create(builder_, loc, neg,
                                     arith::SubIOp::create(builder_, loc, zero, x), x);
    };
    Value sat = arith::CmpIOp::create(
        builder_, loc, arith::CmpIPredicate::sge,
        arith::ShRSIOp::create(builder_, loc, absOf(a), k64(14)), absOf(b));
    Value opposite = arith::CmpIOp::create(builder_, loc, arith::CmpIPredicate::slt,
                                           arith::XOrIOp::create(builder_, loc, a, b), zero);
    Value bound = arith::SelectOp::create(builder_, loc, opposite, k64(INT32_MIN), k64(INT32_MAX));
    Value num = arith::ShLIOp::create(builder_, loc, a, k64(16));
    Value den = arith::SelectOp::create(builder_, loc, sat, k64(1), b);
    Value q = arith::DivSIOp::create(builder_, loc, num, den);
    Value r = arith::SelectOp::create(builder_, loc, sat, bound, q);
    return done(widen(arith::TruncIOp::create(builder_, loc, i32, r)));
  }
  // The 64-bit forms: a 64-bit body only, where the body's Integer is i64 and
  // these arith operations wrap.
  case IntrinsicOp::W64Add:
    return done(arith::AddIOp::create(builder_, loc, v[0], v[1]));
  case IntrinsicOp::W64Sub:
    return done(arith::SubIOp::create(builder_, loc, v[0], v[1]));
  case IntrinsicOp::W64Mul:
    return done(arith::MulIOp::create(builder_, loc, v[0], v[1]));
  case IntrinsicOp::W64Neg:
    return done(arith::SubIOp::create(builder_, loc, k64(0), v[0]));
  case IntrinsicOp::W64Shl:
    return done(shiftLeft(v[0], v[1], 64));
  case IntrinsicOp::U64Lt: return ucmp64(arith::CmpIPredicate::ult);
  case IntrinsicOp::U64Le: return ucmp64(arith::CmpIPredicate::ule);
  case IntrinsicOp::U64Gt: return ucmp64(arith::CmpIPredicate::ugt);
  case IntrinsicOp::U64Ge: return ucmp64(arith::CmpIPredicate::uge);
  case IntrinsicOp::U64Shr:
    checkCount(v[1]);
    return done(arith::ShRUIOp::create(builder_, loc, v[0], v[1]));
  case IntrinsicOp::U32Literal:
    break; // handled above
  }
  fail(n->id, "unsupported-node", Twine("intrinsic '") + name + "'");
  return ExprResult{Value(), std::move(env), false};
}

Value FuncGen::absOp(Location loc, Value a) {
  // MIN is the one input with no magnitude at the body width. Every checked
  // mode fails on it first, its own way, so the negation below cannot
  // overflow there and keeps its `nsw`. `Wrap` and `None` give MIN back, as
  // the pinned Spinel's wrap mode does (`sp_int_abs`), so their negation is
  // a plain two's-complement one.
  const bool wraps = !statusMode() && !abortMode() &&
                     gen_.mode() != OverflowMode::Trap &&
                     gen_.mode() != OverflowMode::Raise;
  Value isMin = arith::CmpIOp::create(
      builder_, loc, arith::CmpIPredicate::eq, a,
      constant(loc, minInteger()));
  if (statusMode())
    statusGuard(loc, isMin, CoreStatus::Arithmetic, "abs of the minimum");
  else if (abortMode())
    coreFailGuard(loc, isMin, CoreFailKind::Overflow, "abs");
  else if (!wraps)
    failGuard(loc, isMin,
              gen_.trapHook().empty()
                  ? raiseClsBlock(loc, "RangeError", "integer overflow in abs")
                  : trapBlock(loc, 1, a, Value(), trapDetail("abs")));
  Value zero = constant(loc, 0);
  Value negative = arith::CmpIOp::create(builder_, loc, arith::CmpIPredicate::slt,
                                         a, zero);
  Value negated =
      wraps ? arith::SubIOp::create(builder_, loc, zero, a)
            : arith::SubIOp::create(builder_, loc, zero, a,
                                    arith::IntegerOverflowFlags::nsw);
  return arith::SelectOp::create(builder_, loc, negative, negated, a);
}

Value FuncGen::powOp(Location loc, Value a, Value b) {
  // Decision 0042 stage 3: the exact power, a failure where it is past the
  // width, and a negative exponent failing on its own (the pinned Spinel's
  // `sp_int_pow`: `RangeError`, `negative exponent`). Square-and-multiply,
  // straight-line, so decision 0010's report has no loop to count.
  //
  // The steps run from bit 0 up, so every partial product has the sign and
  // at most the magnitude of the whole result: a multiplication that
  // overflows means the result is past the width. A squaring counts only
  // while a higher bit remains, since only then is the square multiplied
  // in, and a result containing it is at least as large. `(-2) ** (w - 1)`
  // is MIN and does not fail: its squares are positive and stay below
  // `2 ** (w - 1)`.
  const int64_t w = integerBits();
  const bool checked = statusMode() || abortMode() ||
                       gen_.mode() == OverflowMode::Trap ||
                       gen_.mode() == OverflowMode::Raise;
  const Type i1 = builder_.getI1Type();
  const Type pair =
      LLVM::LLVMStructType::getLiteral(func_.getContext(), {integerType(), i1});
  auto cmp = [&](arith::CmpIPredicate p, Value x, Value y) -> Value {
    return arith::CmpIOp::create(builder_, loc, p, x, y);
  };
  auto select = [&](Value c, Value x, Value y) -> Value {
    return arith::SelectOp::create(builder_, loc, c, x, y);
  };
  auto both = [&](Value x, Value y) -> Value {
    return arith::AndIOp::create(builder_, loc, x, y);
  };
  auto either = [&](Value x, Value y) -> Value {
    return arith::OrIOp::create(builder_, loc, x, y);
  };
  Value overflow = arith::ConstantOp::create(builder_, loc, i1,
                                             builder_.getBoolAttr(false));
  // x * y: the wrapped product, with the overflow flag ORed into `overflow`
  // under `counts` in a checked mode.
  auto mul = [&](Value x, Value y, Value counts) -> Value {
    if (!checked)
      return arith::MulIOp::create(builder_, loc, x, y);
    Value p = LLVM::SMulWithOverflowOp::create(builder_, loc, pair, x, y);
    Value flag = LLVM::ExtractValueOp::create(builder_, loc, p,
                                              ArrayRef<int64_t>{1});
    overflow = either(overflow, counts ? both(counts, flag) : flag);
    return LLVM::ExtractValueOp::create(builder_, loc, p, ArrayRef<int64_t>{0});
  };

  Value result;
  Value negative;
  llvm::APInt constantExponent;
  const bool isConstant =
      matchPattern(b, mlir::m_ConstantInt(&constantExponent)) &&
      !constantExponent.isNegative() &&
      (!checked || constantExponent.slt(w));
  if (isConstant) {
    // An unrolled chain over the exponent's own bits: bit_length(e) - 1
    // squarings and popcount(e) - 1 multiplications.
    const uint64_t e = constantExponent.getZExtValue();
    Value base = a;
    for (unsigned k = 0; (e >> k) != 0; ++k) {
      if (k > 0)
        base = mul(base, base, Value());
      if ((e >> k) & 1)
        result = result ? mul(result, base, Value()) : base;
    }
    if (!result)
      result = constant(loc, 1);
  } else {
    Value zero = constant(loc, 0);
    Value one = constant(loc, 1);
    negative = cmp(arith::CmpIPredicate::slt, b, zero);
    // The exponent the chain reads. Checked, an exponent of w or more has a
    // value only for a base of -1, 0 or 1, where `a ** (2 + n % 2)` is the
    // same; every other base fails. Wrapping, every bit of n counts.
    Value n = b;
    unsigned steps = static_cast<unsigned>(w - 1);
    if (checked) {
      Value large = cmp(arith::CmpIPredicate::sge, b, constant(loc, w));
      Value parity = arith::AndIOp::create(builder_, loc, b, one);
      n = select(large,
                 arith::AddIOp::create(builder_, loc, constant(loc, 2), parity),
                 b);
      Value biased = arith::AddIOp::create(builder_, loc, a, one);
      Value wideBase = cmp(arith::CmpIPredicate::ugt, biased, constant(loc, 2));
      overflow = either(overflow, both(large, wideBase));
      steps = w == 64 ? 6 : 5;
    }
    auto bit = [&](unsigned k) -> Value {
      Value s = arith::ShRUIOp::create(builder_, loc, n, constant(loc, k));
      return cmp(arith::CmpIPredicate::ne,
                 arith::AndIOp::create(builder_, loc, s, one), zero);
    };
    result = select(bit(0), a, one);
    Value base = a;
    for (unsigned k = 1; k < steps; ++k) {
      Value above = cmp(arith::CmpIPredicate::ne,
                        arith::ShRUIOp::create(builder_, loc, n, constant(loc, k)),
                        zero);
      base = mul(base, base, above);
      Value set = bit(k);
      result = select(set, mul(result, base, set), result);
    }
  }

  // Each failure the mode's own way. The negative exponent first: it is
  // the pinned Spinel's first test, and its chain read junk bits.
  if (negative) {
    if (statusMode())
      statusGuard(loc, negative, CoreStatus::Arithmetic, "negative exponent in **");
    else if (abortMode())
      coreFailGuard(loc, negative, CoreFailKind::NegativeExponent, "**");
    else
      // Under every freestanding policy, `wrap` too: a negative exponent
      // has no wrapped value. Code 7 is this failure's own (decision 0042).
      failGuard(loc, negative,
                gen_.trapHook().empty()
                    ? raiseClsBlock(loc, "RangeError", "negative exponent")
                    : trapBlock(loc, 7, a, b,
                                (Twine(method_.name()) + ": negative exponent").str()));
  }
  if (checked) {
    if (statusMode())
      statusGuard(loc, overflow, CoreStatus::Arithmetic, "checked **");
    else if (abortMode())
      coreFailGuard(loc, overflow, CoreFailKind::Overflow, "**");
    else
      failGuard(loc, overflow,
                gen_.trapHook().empty()
                    ? raiseClsBlock(loc, "RangeError", "integer overflow in **")
                    : trapBlock(loc, 1, a, b, trapDetail("**")));
  }
  return result;
}

bool FuncGen::run() {
  const bool ok = runBody();
  // Failure path: hand every still-unopened block to the region instead of
  // freeing it, so the half-built function that is about to be destroyed holds
  // no branch pointing at freed memory.  Cold arms are handed over the same
  // way and for the same reason — a `cf.cond_br` already names them.
  for (std::unique_ptr<Block> &block : unopened_)
    func_.getBody().push_back(block.release());
  unopened_.clear();
  for (std::unique_ptr<Block> &block : cold_)
    func_.getBody().push_back(block.release());
  cold_.clear();
  // DECISION 0041 STAGE 2: free this method's arrays on every path -- the
  // value return, each failure status, and a callee's status passed up --
  // by storing back the offset it found. Last in, first out, so a nested
  // entry of the same context frees exactly what it made.
  if (ok && savedOffset_) {
    SmallVector<func::ReturnOp> returns;
    func_.walk([&](func::ReturnOp r) { returns.push_back(r); });
    for (func::ReturnOp r : returns) {
      OpBuilder at(r);
      LLVM::StoreOp::create(at, r.getLoc(), savedOffset_, scratch_);
    }
  }
  return ok;
}

/// frozen: run() — the entry block, the parameter environment, the nil->0
/// initialisation of every local with no value on entry, and the implicit
/// return of the body's last value.
bool FuncGen::runBody() {
  // frozen: FuncGen.__init__'s parameter walk.  The selector has already
  // refused everything but required positionals (nothing else can become a
  // ScalarParameter), so the names come straight off the selected signature.
  for (const ScalarParameter &parameter : method_.parameters())
    params_.push_back(parameter.name().str());

  const Node *def = node(method_.defNode());
  if (!def)
    return fail(method_.defNode(), "unsupported-node", "DefNode");

  // frozen: collect_locals() + sorted().  Every name assigned OR read anywhere
  // in the body, plus the parameters.
  {
    std::set<std::string> names(params_.begin(), params_.end());
    std::set<int64_t> seen;
    std::vector<int64_t> work{method_.defNode()};
    while (!work.empty()) {
      const int64_t current = work.back();
      work.pop_back();
      if (current < 0 || !seen.insert(current).second)
        continue;
      const Node *n = node(current);
      if (!n)
        continue;
      if (n->kind == "LocalVariableWriteNode" ||
          n->kind == "LocalVariableOperatorWriteNode" ||
          n->kind == "LocalVariableTargetNode" ||
          n->kind == "LocalVariableReadNode") {
        std::string name;
        if (!ast::getString(*n, "name", name))
          return fail(n->id, "unsupported-node", n->kind);
        names.insert(name);
      }
      for (const AstField &field : n->fields) {
        if (field.kind == AstField::Kind::Reference)
          work.push_back(std::get<int64_t>(field.value));
        else if (field.kind == AstField::Kind::Array)
          for (int64_t child : std::get<std::vector<int64_t>>(field.value))
            work.push_back(child);
      }
    }
    locals_.assign(names.begin(), names.end());
  }

  // DECISION 0041 STAGE 2: the locals this method makes arrays in, by the
  // checker's one admitted shape -- `a = Array.new(n, v)` as a statement of
  // the method's own body.
  arrayLocals_.clear();
  if (statusMode() && gen_.options().status.arrayMakers.count(method_.name().str())) {
    int64_t bodyId = -1;
    const Node *body = ast::getReference(*def, "body", bodyId) ? node(bodyId) : nullptr;
    std::vector<int64_t> stmtsIds;
    if (body && body->kind == "StatementsNode" && ast::getArray(*body, "body", stmtsIds))
      for (int64_t id : stmtsIds) {
        const Node *w = node(id);
        int64_t valueId = -1;
        std::string local;
        if (!w || w->kind != "LocalVariableWriteNode" ||
            !ast::getReference(*w, "value", valueId) || !ast::getString(*w, "name", local))
          continue;
        if (isArrayNewCall(node(valueId))) arrayLocals_.insert(local);
      }
  }
  if (!buildLocalTypes())
    return false;

  const Location loc = locOf(method_.defNode());
  openBlock(func_.addEntryBlock());

  Env env;
  // A borrowed parameter takes TWO argument slots, so the Ruby parameter list
  // and the MLIR argument list stop agreeing after the first one. `argSlot`
  // is the one place that mapping is computed.
  for (auto indexed : enumerate(params_)) {
    if (gen_.contextSlot(method_.name(), indexed.index()) >= 0) continue; // below
    Value value = func_.getArgument(argSlot(indexed.index()));
    if (integerBits() == 32 && value.getType().isInteger(64))
      value = arith::TruncIOp::create(builder_, loc, integerType(), value);
    env[indexed.value()] = value;
  }
  // Captured here, from the parameters, before any statement runs.
  descriptorCount_.clear();
  descriptorBound32_.clear();
  if (statusMode() && isEntry())
    for (const ScalarStatusBuffer &b : gen_.options().status.buffers) {
      // Decision 0014: an application's state buffer has the count its
      // declaration fixed. It is a constant of this function, not a
      // parameter, so nothing at the boundary can move it.
      if (b.constCount) {
        descriptorCount_[b.name] = countBits() == 32
            ? Value(arith::ConstantOp::create(builder_, loc, builder_.getI32Type(),
                                              builder_.getI32IntegerAttr(static_cast<int32_t>(static_cast<uint32_t>(*b.constCount)))))
            : wideConstant(loc, static_cast<int64_t>(*b.constCount));
        captureBound32(loc, b.name);
        continue;
      }
      auto found = std::find(params_.begin(), params_.end(), b.countName);
      if (found != params_.end()) {
        Value count = func_.getArgument(argSlot(found - params_.begin()));
        // A 32-bit body carries the count in 32 bits: on its 32-bit target
        // the wrapper refused a count with a nonzero upper word (decision
        // 0022 section 3), so the truncation drops only zeroes.
        if (countBits() == 32)
          count = arith::TruncIOp::create(builder_, loc, builder_.getI32Type(), count);
        descriptorCount_[b.name] = count;
        captureBound32(loc, b.name);
      }
    }
  // A helper's bound is the caller's descriptor, arriving beside the pointer.
  // It is never read out of the environment: `n_data = n_data + 100` in the
  // caller reassigns a Ruby local, and the descriptor is not that local.
  // THE BUFFER CONTEXT. The entry stores, once, the pointer and bound of
  // each buffer a helper reads through the context; a helper that takes the
  // context loads its parameters' from it.
  context_ = Value();
  if (statusMode() && isEntry() && gen_.anyContext()) {
    OpBuilder entry(func_.getContext());
    entry.setInsertionPointToStart(&func_.getBody().front());
    Value one = arith::ConstantOp::create(entry, loc, entry.getI64Type(), entry.getI64IntegerAttr(1));
    context_ = LLVM::AllocaOp::create(entry, loc, LLVM::LLVMPointerType::get(entry.getContext()),
                                      gen_.contextType(), one);
    const auto &bufs = gen_.options().status.buffers;
    for (size_t k : gen_.contextSlots()) {
      const std::string &name = bufs[k].name;
      Value at = LLVM::GEPOp::create(builder_, loc, LLVM::LLVMPointerType::get(builder_.getContext()),
                                     gen_.contextType(), context_,
                                     ArrayRef<LLVM::GEPArg>{0, static_cast<int32_t>(k), 0});
      LLVM::StoreOp::create(builder_, loc, env[name], at);
      Value cnt = LLVM::GEPOp::create(builder_, loc, LLVM::LLVMPointerType::get(builder_.getContext()),
                                      gen_.contextType(), context_,
                                      ArrayRef<LLVM::GEPArg>{0, static_cast<int32_t>(k), 1});
      LLVM::StoreOp::create(builder_, loc, descriptorCount_[name], cnt);
    }
  }
  if (statusMode() && !isEntry() && gen_.usesContext(method_.name())) {
    context_ = func_.getArgument(argSlot(params_.size()));
    for (auto indexed : enumerate(params_)) {
      const int k = gen_.contextSlot(method_.name(), indexed.index());
      if (k < 0) continue;
      Value at = LLVM::GEPOp::create(builder_, loc, LLVM::LLVMPointerType::get(builder_.getContext()),
                                     gen_.contextType(), context_, ArrayRef<LLVM::GEPArg>{0, k, 0});
      env[indexed.value()] = LLVM::LoadOp::create(builder_, loc, LLVM::LLVMPointerType::get(builder_.getContext()), at);
      Value cnt = LLVM::GEPOp::create(builder_, loc, LLVM::LLVMPointerType::get(builder_.getContext()),
                                      gen_.contextType(), context_, ArrayRef<LLVM::GEPArg>{0, k, 1});
      descriptorCount_[indexed.value()] =
          LLVM::LoadOp::create(builder_, loc, countBits() == 32 ? Type(builder_.getI32Type()) : Type(builder_.getI64Type()), cnt);
      captureBound32(loc, indexed.value());
    }
  }
  if (statusMode() && !isEntry())
    for (auto indexed : enumerate(params_))
      if (gen_.options().borrow(method_.name(), indexed.index()) &&
          gen_.contextSlot(method_.name(), indexed.index()) < 0)      {
        descriptorCount_[indexed.value()] =
            func_.getArgument(argSlot(indexed.index()) + 1);
        captureBound32(loc, indexed.value());
      }
  // DECISION 0044: a lent buffer's length, the argument after its address.
  for (auto indexed : enumerate(params_))
    if (lentAt(indexed.index()))
      descriptorCount_[indexed.value()] =
          func_.getArgument(argSlot(indexed.index()) + 1);
  // DECISION 0041 STAGE 2: the data stack's address arrives just before the
  // result pointer. A method that makes arrays keeps the offset it found.
  scratch_ = Value();
  savedOffset_ = Value();
  if (gen_.takesScratch(method_.name())) {
    scratch_ = func_.getArgument(func_.getNumArguments() - 2);
    if (!arrayLocals_.empty())
      savedOffset_ = LLVM::LoadOp::create(builder_, loc, integerType(), scratch_);
  }
  // Not yet assigned on entry: Ruby would see nil, which the subset rejects,
  // so this exists only to keep the environment TOTAL (a merge block's
  // arguments cover every local unconditionally).  The order is `locals_`
  // order, and it is observable — loopy's two leading zeroes are these.
  for (const std::string &name : locals_)
    if (!env.count(name))
      env[name] = zeroOf(loc, typeOfLocal(name));

  int64_t bodyId = -1;
  if (!ast::getReference(*def, "body", bodyId))
    return fail(method_.defNode(), "unsupported-node", def->kind);

  StmtResult result = stmts(node(bodyId), std::move(env), /*wantValue=*/true);
  if (!result.ok)
    return false;
  if (!result.terminated) {
    // A helper the checker derived as answering a boolean returns one; every
    // other method still has to answer a number. `emitValueReturn` widens the
    // i1 into the result slot.
    const bool boolResult = statusMode() && !isEntry() &&
                            method_.returnType() == "bool";
    if (boolResult) {
      if (!needBool(bodyId, result.value, "the method's implicit return value"))
        return false;
    } else if (!needNumeric(bodyId, result.value,
                            "the method's implicit return value")) {
      return false;
    }
    emitValueReturn(locOf(bodyId), result.value);
  }
  terminateStragglers();
  return true;
}

void FuncGen::terminateStragglers() {
  // frozen: render()'s `if b.term is None` arm.  A block the walk opened and
  // then abandoned (every path out of it returned) still has to be terminated
  // for the module to verify; the frozen generator gives it a `return 0`, and
  // so do we — an `llvm.unreachable` here would be a different module.
  for (Block &block : func_.getBody()) {
    if (!block.empty() && block.back().hasTrait<OpTrait::IsTerminator>())
      continue;
    OpBuilder tail(func_.getContext());
    tail.setInsertionPointToEnd(&block);
    const Location loc = func_.getLoc();
    if (statusMode()) {
      // No path reaches this block -- every path out of it already returned --
      // but it still needs a terminator. A `return 0` would mean SUCCESS WITH
      // THE RESULT UNWRITTEN, which is the one outcome the ABI must never
      // produce, so the straggler fails closed instead. `llvm.unreachable`
      // would be the other candidate and is rejected deliberately: if the
      // reachability reasoning is ever wrong, `unreachable` licenses the
      // optimiser to delete the path that got here, and this does not.
      Value status = arith::ConstantOp::create(
          tail, loc, tail.getI32Type(),
          tail.getI32IntegerAttr(static_cast<int32_t>(CoreStatus::Arithmetic)));
      func::ReturnOp::create(tail, loc, status);
      continue;
    }
    Value zero = arith::ConstantOp::create(
        tail, loc, tail.getIntegerAttr(integerType(), 0));
    func::ReturnOp::create(tail, loc, zero);
  }
}

/// frozen: stmts() — a statement list; only the LAST statement is asked for a
/// value, and a terminated statement ends the list.
StmtResult FuncGen::stmts(const Node *n, Env env, bool wantValue) {
  if (!n)
    return StmtResult{Value(), std::move(env), false, true};
  if (n->kind != "StatementsNode")
    return stmt(n, std::move(env), wantValue);

  std::vector<int64_t> body;
  if (!ast::getArray(*n, "body", body)) {
    fail(n->id, "unsupported-node", n->kind);
    return StmtResult{Value(), std::move(env), false, false};
  }
  Value value;
  for (size_t index = 0; index < body.size(); ++index) {
    const bool last = index + 1 == body.size();
    const Node *child = node(body[index]);
    if (!child) {
      fail(n->id, "unsupported-node", n->kind);
      return StmtResult{Value(), std::move(env), false, false};
    }
    StmtResult result = stmt(child, std::move(env), wantValue && last);
    if (!result.ok)
      return result;
    env = std::move(result.env);
    value = last ? result.value : Value();
    if (result.terminated)
      return StmtResult{result.value, std::move(env), true, true};
  }
  return StmtResult{value, std::move(env), false, true};
}

/// frozen: stmt().
StmtResult FuncGen::stmt(const Node *n, Env env, bool wantValue) {
  const StringRef kind = n->kind;

  if (kind == "CallNode" && statusMode()) {
    // Decision 0007 task 2: `core_fail(:<category>)` is a RETURN, so it lives
    // where `return` lives. In expression position it would be an expression
    // that terminates its own block, and the `if` arms and loop headers this
    // generator builds all expect a value to carry to their join -- so the
    // expression walk refuses it by name rather than reporting it as a call to
    // something outside the closure.
    int64_t receiver = -1;
    std::string name;
    if (ast::getReference(*n, "receiver", receiver) && receiver < 0 &&
        ast::getString(*n, "name", name) && name == "core_fail" &&
        !gen_.method("core_fail")) {
      const std::optional<CoreStatus> code = coreFailCategory(n);
      if (!code) {
        fail(n->id, "unsupported-node",
             "core_fail takes the one symbol literal :capacity");
        return StmtResult{Value(), std::move(env), false, false};
      }
      const Location loc = locOf(n->id);
      gen_.storeFailureSite(builder_, loc, *code, "core_fail(:capacity)");
      Value status = arith::ConstantOp::create(
          builder_, loc, builder_.getI32Type(),
          builder_.getI32IntegerAttr(static_cast<int32_t>(*code)));
      // No store, like every other failure: the result is written only on
      // SPINEL_CORE_OK.
      func::ReturnOp::create(builder_, loc, status);
      return StmtResult{Value(), std::move(env), true, true};
    }
  }

  // DECISION 0041 stage 1: a literal block on an iterator call is a loop, and
  // a loop is a statement.
  if (kind == "CallNode") {
    core::BlockLoopShape shape = blockLoopShape(n);
    if (shape.loop)
      return blockLoopStmt(n, *shape.loop, std::move(env), wantValue);
  }

  // DECISION 0008 TASK 4. `break` leaves the nearest loop and `next` restarts
  // it. Both terminate the block they are in, the same way a `return` does,
  // and both carry the environment to their destination -- the exit is a merge
  // block for exactly this reason.
  if (kind == "BreakNode" || kind == "NextNode") {
    if (loops_.empty()) {
      fail(n->id, "unsupported-node",
           Twine("`") + (kind == "BreakNode" ? "break" : "next") +
               "` is outside any loop");
      return StmtResult{Value(), std::move(env), false, false};
    }
    int64_t argumentsId = -1;
    if (ast::getReference(*n, "arguments", argumentsId) && argumentsId >= 0) {
      fail(n->id, "unsupported-node",
           Twine("`") + (kind == "BreakNode" ? "break" : "next") +
               "` carries a value; a loop produces nothing for it to become");
      return StmtResult{Value(), std::move(env), false, false};
    }
    const LoopCtx &loop = loops_.back();
    branch(locOf(n->id), kind == "BreakNode" ? loop.exit : loop.head, env,
           Value());
    return StmtResult{Value(), std::move(env), true, true};
  }

  // DECISION 0008 TASK 4. `buf[i] op= v`. The receiver and the index are
  // evaluated EXACTLY ONCE and that one index value is used for both the load
  // and the store, which is why the checked access takes values. The order is
  // the one the language document states and is measured by running it: bounds
  // first, then the load, then the checked compute, then the narrowing, then
  // the store -- and a failure at any of those three checks leaves the element
  // as it was, because the store is the last thing that happens.
  if (kind == "IndexOperatorWriteNode") {
    int64_t receiverId = -1, argumentsId = -1, valueId = -1;
    std::string op;
    std::vector<int64_t> idxArgs;
    if (!ast::getReference(*n, "receiver", receiverId) ||
        !ast::getReference(*n, "arguments", argumentsId) ||
        !ast::getReference(*n, "value", valueId) ||
        !ast::getString(*n, "binary_operator", op) || argumentsId < 0 ||
        !node(argumentsId) ||
        !ast::getArray(*node(argumentsId), "arguments", idxArgs) ||
        idxArgs.size() != 1) {
      fail(n->id, "unsupported-node", "`[]" + op + "=` has an unexpected shape");
      return StmtResult{Value(), std::move(env), false, false};
    }
    const Node *recv = receiverId >= 0 ? node(receiverId) : nullptr;
    std::string bufName;
    if (!recv || recv->kind != "LocalVariableReadNode" ||
        !ast::getString(*recv, "name", bufName)) {
      fail(n->id, "unsupported-node",
           "`[]" + op + "=` is only in the subset on a buffer parameter");
      return StmtResult{Value(), std::move(env), false, false};
    }
    auto found = buffers_.find(bufName);
    if (found == buffers_.end()) {
      fail(n->id, "unsupported-node",
           Twine("`") + bufName + "[...]" + op +
               "=` -- only a buffer parameter can be indexed");
      return StmtResult{Value(), std::move(env), false, false};
    }
    const BufInfo info = found->second;
    ExprResult idx = expr(node(idxArgs[0]), std::move(env));
    if (!idx.ok) return StmtResult{Value(), std::move(idx.env), false, false};
    if (!needInt(idxArgs[0], idx.value, "a buffer index"))
      return StmtResult{Value(), std::move(idx.env), false, false};
    const Value idxValue = idx.value;
    env = std::move(idx.env);
    // THE LOAD HAPPENS BEFORE THE RIGHT-HAND SIDE. `buf[i] op= rhs` is
    // `buf[i] = buf[i] op rhs`, and Ruby evaluates the element read FIRST --
    // so a right-hand side that writes buf[i] does not change the left
    // operand. Emitting the load after the call instead reads back whatever
    // the call left behind: measured, `buf[0] += rhs(buf)` with `rhs` storing
    // 6 and returning 5 gave 11 where CRuby gives 6, with status OK and no
    // diagnostic. The bounds check travels with the load, so it also happens
    // before the right-hand side runs, which is the order the comment above
    // states.
    ExprResult loaded =
        bufferAccessValues(n, bufName, info, idxValue, Value(), std::move(env));
    if (!loaded.ok) return StmtResult{Value(), std::move(loaded.env), false, false};
    env = std::move(loaded.env);
    ExprResult rhs = expr(node(valueId), std::move(env));
    if (!rhs.ok) return StmtResult{Value(), std::move(rhs.env), false, false};
    if (!needInt(valueId, rhs.value, "the right-hand side of `[]" + op + "=`"))
      return StmtResult{Value(), std::move(rhs.env), false, false};
    env = std::move(rhs.env);
    ExprResult computed =
        binop(n->id, op, loaded.value, rhs.value, std::move(env));
    if (!computed.ok)
      return StmtResult{Value(), std::move(computed.env), false, false};
    env = std::move(computed.env);
    ExprResult put = bufferAccessValues(n, bufName, info, idxValue,
                                        computed.value, std::move(env));
    if (!put.ok) return StmtResult{Value(), std::move(put.env), false, false};
    // {value, env, terminated, ok} -- this statement produces the stored
    // value, does not terminate its block, and succeeded.
    return StmtResult{put.value, std::move(put.env), false, true};
  }

  if (kind == "ReturnNode") {
    int64_t argumentsId = -1;
    std::vector<int64_t> items;
    if (!ast::getReference(*n, "arguments", argumentsId) || argumentsId < 0 ||
        !node(argumentsId) ||
        !ast::getArray(*node(argumentsId), "arguments", items) ||
        items.size() != 1) {
      fail(n->id, "unsupported-node",
           "`return` needs exactly one value (a bare `return` is nil, which is "
           "not in the subset)");
      return StmtResult{Value(), std::move(env), false, false};
    }
    ExprResult value = expr(node(items[0]), std::move(env));
    if (!value.ok)
      return StmtResult{Value(), std::move(value.env), false, false};
    if (!needInt(n->id, value.value, "return value"))
      return StmtResult{Value(), std::move(value.env), false, false};
    emitValueReturn(locOf(n->id), value.value);
    return StmtResult{Value(), std::move(value.env), true, true};
  }

  // E174 D-5: `unless` / `until` are the inverted spellings of the two nodes
  // already in the subset, and the frozen generator dispatches them through
  // the SAME two functions (`k in ("IfNode", "UnlessNode")`).  Writing a
  // second walker for them would be a second place for the block shape to
  // drift.
  if (kind == "IfNode" || kind == "UnlessNode")
    return ifStmt(n, std::move(env), wantValue, kind == "UnlessNode");

  if (kind == "WhileNode" || kind == "UntilNode")
    return whileStmt(n, std::move(env), kind == "UntilNode");

  // Lower x op= e with the same operation as x = x op e. Read x before evaluating e, preserving its
  // old value even if e writes x. Originally callers without the flag were refused by Selector
  // before this point.
  if (kind == "LocalVariableOperatorWriteNode") {
    std::string name, op;
    int64_t valueId = -1;
    if (!ast::getString(*n, "name", name) ||
        !ast::getString(*n, "binary_operator", op) ||
        !ast::getReference(*n, "value", valueId)) {
      fail(n->id, "unsupported-node", n->kind);
      return StmtResult{Value(), std::move(env), false, false};
    }
    // &&=/||= have binary_operator &&/||. Short-circuiting changes assignment semantics by skipping the right side, so refuse these separately.
    static const llvm::StringRef kOps[] = {"+", "-", "*", "/", "%"};
    // The checked route admits `<< >> & | ^` as calls, so `n <<= 1` has to
    // mean what `n = n << 1` means. It was admitted by the checker and refused
    // here, which is one statement getting two answers -- the same mismatch
    // `n += 1` had. `binop` below already lowers all of these in this mode;
    // only the gate was narrow.
    // Decision 0042: also where `binop` lowers the bitwise operators and the
    // shifts outside the status ABI, for the same reason.
    static const llvm::StringRef kBitOps[] = {"+",  "-", "*", "/", "%", "<<",
                                              ">>", "&", "|", "^", "**"};
    if (!llvm::is_contained(statusMode() || bitOperators()
                                ? ArrayRef<StringRef>(kBitOps)
                                : ArrayRef<StringRef>(kOps),
                            op)) {
      fail(n->id, "unsupported-node", n->kind);
      return StmtResult{Value(), std::move(env), false, false};
    }
    auto cur = env.find(name);
    if (cur == env.end()) {
      fail(n->id, "unresolved-local", name);
      return StmtResult{Value(), std::move(env), false, false};
    }
    const Value before = cur->second;
    ExprResult rhs = expr(node(valueId), std::move(env));
    if (!rhs.ok)
      return StmtResult{Value(), std::move(rhs.env), false, false};
    if (!needInt(n->id, before, Twine("the target of `") + name + " " + op + "=`") ||
        !needInt(n->id, rhs.value, Twine("the value of `") + name + " " + op + "=`"))
      return StmtResult{Value(), std::move(rhs.env), false, false};
    ExprResult res = binop(n->id, op, before, rhs.value, std::move(rhs.env));
    if (!res.ok)
      return StmtResult{Value(), std::move(res.env), false, false};
    Env next = std::move(res.env);
    next[name] = res.value;
    return StmtResult{res.value, std::move(next), false, true};
  }

  // For a,b = e1,e2, evaluate every right-hand side before writing any left-hand side. Changing b
  // first in a,b = b,a%b changes the expression; igcd(1071,462)=21 controls this ordering.
  if (kind == "MultiWriteNode") {
    std::vector<int64_t> lefts;
    int64_t valueId = -1;
    if (!ast::getArray(*n, "lefts", lefts) ||
        !ast::getReference(*n, "value", valueId) || valueId < 0) {
      fail(n->id, "unsupported-node", n->kind);
      return StmtResult{Value(), std::move(env), false, false};
    }
    const Node *rhsList = node(valueId);
    std::vector<int64_t> elements;
    if (!rhsList || rhsList->kind != "ArrayNode" ||
        !ast::getArray(*rhsList, "elements", elements) ||
        elements.size() != lefts.size()) {
      // Selector already refuses this shape; reaching it means contract data changed mid-pipeline.
      // Never silently accept.
      fail(n->id, "unsupported-node", n->kind);
      return StmtResult{Value(), std::move(env), false, false};
    }
    std::vector<Value> values;
    Env cur = std::move(env);
    for (int64_t id : elements) {
      ExprResult r = expr(node(id), std::move(cur));
      if (!r.ok)
        return StmtResult{Value(), std::move(r.env), false, false};
      if (!needInt(id, r.value, "a value in a parallel assignment"))
        return StmtResult{Value(), std::move(r.env), false, false};
      values.push_back(r.value);
      cur = std::move(r.env);
    }
    for (size_t i = 0; i < lefts.size(); ++i) {
      const Node *target = node(lefts[i]);
      std::string name;
      if (!target || target->kind != "LocalVariableTargetNode" ||
          !ast::getString(*target, "name", name)) {
        fail(n->id, "unsupported-node", n->kind);
        return StmtResult{Value(), std::move(cur), false, false};
      }
      cur[name] = values[i];
    }
    // Ruby parallel-assignment value is a heap Array, outside the subset. Refuse value-required
    // positions such as the last method expression here, instead of returning a null Value that
    // breaks a later stage.
    if (wantValue) {
      fail(n->id, "unsupported-node", n->kind);
      return StmtResult{Value(), std::move(cur), false, false};
    }
    return StmtResult{Value(), std::move(cur), false, true};
  }

  if (kind == "LocalVariableWriteNode") {
    std::string name;
    int64_t valueId = -1;
    if (!ast::getString(*n, "name", name) ||
        !ast::getReference(*n, "value", valueId)) {
      fail(n->id, "unsupported-node", n->kind);
      return StmtResult{Value(), std::move(env), false, false};
    }
    if (arrayLocals_.count(name) && isArrayNewCall(node(valueId)))
      return arrayNew(n, name, node(valueId), std::move(env));
    ExprResult value = expr(node(valueId), std::move(env));
    if (!value.ok)
      return StmtResult{Value(), std::move(value.env), false, false};
    // frozen: need_slot() — a local has ONE type, and in this slice that type
    // is i64, so binding a comparison's i1 to it is a refusal, not a retype:
    // every merge block already carries the slot as an i64 argument.
    if (!needNumeric(n->id, value.value,
                     Twine("the value assigned to `") + name + "`"))
      return StmtResult{Value(), std::move(value.env), false, false};
    Env next = std::move(value.env);
    // The local-type table decides the slot type. Promote only int to float; buildLocalTypes
    // already refuses the reverse with c04.
    Value bound = coerce(locOf(n->id), value.value, typeOfLocal(name));
    next[name] = bound;
    return StmtResult{bound, std::move(next), false, true};
  }

  if (kind == "StatementsNode")
    return stmts(n, std::move(env), wantValue);

  // frozen: expr_stmt().
  ExprResult value = expr(n, std::move(env));
  return StmtResult{value.value, std::move(value.env), false, value.ok};
}

/// frozen: if_stmt().  The shape the expected files pin down:
///   cond_br then, else                        (neither arm takes arguments)
///   then: ... br join(env [, value])
///   else: ... br join(env [, value])          (an ABSENT else branches the
///                                              entry environment through)
///   join(env' [, value']): ...
/// Both arms are walked from `entryEnv`, never from each other's result — the
/// join's argument list is the only path the environment takes between them.
/// fib is the smallest case: its `else` arm exists only to carry `n` into the
/// join, which is why the expected file has a bare `cf.br ^bb3(%arg0 : i64)`.
StmtResult FuncGen::ifStmt(const Node *n, Env env, bool wantValue,
                           bool invert) {
  int64_t predicateId = -1, thenId = -1, elseId = -1;
  if (!ast::getReference(*n, "predicate", predicateId) ||
      !ast::getReference(*n, "statements", thenId)) {
    fail(n->id, "unsupported-node", n->kind);
    return StmtResult{Value(), std::move(env), false, false};
  }
  // prism spells the other arm `subsequent` on an `IfNode` and `else_clause`
  // on an `UnlessNode`.  The frozen generator reads `subsequent` first and
  // falls back to `else_clause`, and its reader maps a Reference of -1 to
  // "absent", so a node carrying BOTH (`subsequent: -1` beside a real
  // `else_clause`) takes the else clause -- taking the -1 would silently drop
  // the arm.  A node that carries NEITHER field is not one of the two kinds
  // this walker was given (the caller's dispatch is the only way in), so a
  // missing pair stays a refusal rather than an absent arm.
  int64_t subsequentId = -1, elseClauseId = -1;
  const bool hasSubsequent =
      ast::getReference(*n, "subsequent", subsequentId);
  const bool hasElseClause =
      ast::getReference(*n, "else_clause", elseClauseId);
  if (!hasSubsequent && !hasElseClause) {
    fail(n->id, "unsupported-node", n->kind);
    return StmtResult{Value(), std::move(env), false, false};
  }
  elseId = subsequentId >= 0 ? subsequentId : elseClauseId;

  ExprResult cond = expr(node(predicateId), std::move(env));
  if (!cond.ok)
    return StmtResult{Value(), std::move(cond.env), false, false};
  if (!needBool(predicateId, cond.value, "`if` condition"))
    return StmtResult{Value(), std::move(cond.env), false, false};

  Env entryEnv = std::move(cond.env);
  Block *thenBlock = newBlock();
  Block *elseBlock = newBlock();
  const Location loc = locOf(n->id);
  // `unless` is `if` with the ARMS swapped, not a negated condition: the
  // predicate keeps its own value and the true edge goes to the else arm.
  condBranch(loc, cond.value, invert ? elseBlock : thenBlock, entryEnv, Value(),
             invert ? thenBlock : elseBlock, entryEnv, Value());

  Env joinEnv;
  Value joinValue;
  SmallVector<Type> extra;
  if (wantValue)
    extra.push_back(integerType());
  Block *join = mergeBlock(extra, joinEnv, joinValue);

  bool reached = false;
  auto arm = [&](Block *block, int64_t bodyId, bool isElse) -> bool {
    openBlock(block);
    const Node *body = bodyId < 0 ? nullptr : node(bodyId);
    if (body && isElse && body->kind == "ElseNode") {
      int64_t inner = -1;
      if (!ast::getReference(*body, "statements", inner))
        return fail(body->id, "unsupported-node", body->kind);
      body = inner < 0 ? nullptr : node(inner);
    }
    if (!body) {
      if (wantValue)
        return fail(n->id, "unsupported-node",
                    "`if` used as a value without an `else` (nil is not in the "
                    "subset)");
      branch(loc, join, entryEnv, Value());
      reached = true;
      return true;
    }
    StmtResult result =
        body->kind == "IfNode" // elsif chain (frozen: `IfNode` only)
            ? ifStmt(body, entryEnv, wantValue, /*invert=*/false)
            : stmts(body, entryEnv, wantValue);
    if (!result.ok)
      return false;
    if (!result.terminated) {
      Value carried;
      if (wantValue) {
        if (!needInt(body->id, result.value, "`if` branch value"))
          return false;
        carried = result.value;
      }
      branch(locOf(body->id), join, result.env, carried);
      reached = true;
    }
    return true;
  };

  if (!arm(thenBlock, thenId, /*isElse=*/false) ||
      !arm(elseBlock, elseId, /*isElse=*/true))
    return StmtResult{Value(), std::move(entryEnv), false, false};

  if (!reached && statusMode()) {
    // Both arms left the method, so nothing branches to the join. In the other
    // modes it is opened and given a `return 0` for parity with the frozen
    // generator; here it is destroyed instead, because an unreachable block
    // holding a `func.return` is skipped by the conversion to LLVM and then
    // fails to verify inside what has become an `llvm.func`. Measured on the
    // first `if b == 0 then return … else return … end` that reached it.
    discardBlock(join);
    return StmtResult{Value(), std::move(entryEnv), true, true};
  }
  openBlock(join);
  if (!reached) {
    // Both arms returned: nothing reaches the join, but MLIR still requires it
    // to be terminated (frozen: the same `return 0` the render tail emits).
    // In the status ABI that constant would be SPINEL_CORE_OK with no result
    // written, so this arm fails closed for the reason terminateStragglers
    // gives.
    if (statusMode()) {
      Value status = arith::ConstantOp::create(
          builder_, loc, builder_.getI32Type(),
          builder_.getI32IntegerAttr(static_cast<int32_t>(CoreStatus::Arithmetic)));
      func::ReturnOp::create(builder_, loc, status);
    } else {
      func::ReturnOp::create(builder_, loc, constant(loc, 0));
    }
    return StmtResult{Value(), std::move(entryEnv), true, true};
  }
  return StmtResult{joinValue, std::move(joinEnv), false, true};
}

/// frozen: while_stmt().  Header / body / exit, with the environment on the
/// HEADER's arguments — those are the loop-carried values.  `while` yields
/// nil, so the exit carries no value, and the environment after the loop is the
/// HEADER's: the loop leaves from the header test, not from the body.
StmtResult FuncGen::whileStmt(const Node *n, Env env, bool isUntil) {
  int64_t predicateId = -1, bodyId = -1;
  if (!ast::getReference(*n, "predicate", predicateId) ||
      !ast::getReference(*n, "statements", bodyId)) {
    fail(n->id, "unsupported-node", n->kind);
    return StmtResult{Value(), std::move(env), false, false};
  }
  // frozen: PM_LOOP_FLAGS_BEGIN_MODIFIER — `begin ... end while` is a POST-test
  // loop, a different block shape, and it is not in the subset.
  int64_t flags = 0;
  if (ast::getInteger(*n, "flags", flags) && (flags & 4)) {
    fail(n->id, "unsupported-node",
         "`begin ... end while` (post-test loop) is not in the subset");
    return StmtResult{Value(), std::move(env), false, false};
  }

  Env headEnv;
  Value noExtra;
  Block *head = mergeBlock({}, headEnv, noExtra);
  Block *body = newBlock();
  // The exit is a MERGE block, because `break` reaches it from inside the body
  // with an environment the loop head never saw. Before task 4 the only edge
  // into it was the condition's false one and a plain block was enough.
  Env exitEnv;
  Value noExtra2;
  Block *exit = mergeBlock({}, exitEnv, noExtra2);
  const Location loc = locOf(n->id);
  branch(loc, head, env, Value());

  openBlock(head);
  ExprResult cond = expr(node(predicateId), std::move(headEnv));
  if (!cond.ok)
    return StmtResult{Value(), std::move(cond.env), false, false};
  // frozen: "`%s` condition" % ("until" if until else "while") — the loop's
  // own spelling, so the refusal names what the caller wrote.
  if (!needBool(predicateId, cond.value,
                isUntil ? "`until` condition" : "`while` condition"))
    return StmtResult{Value(), std::move(cond.env), false, false};

  Env afterCond = cond.env;
  // `until` exits on the TRUE edge.
  condBranch(loc, cond.value, isUntil ? exit : body, afterCond, Value(),
             isUntil ? body : exit, afterCond, Value());

  openBlock(body);
  loops_.push_back(LoopCtx{head, exit});
  StmtResult inner = stmts(node(bodyId), afterCond, /*wantValue=*/false);
  loops_.pop_back();
  if (!inner.ok)
    return StmtResult{Value(), std::move(afterCond), false, false};
  if (!inner.terminated)
    branch(loc, head, inner.env, Value());

  openBlock(exit);
  return StmtResult{Value(), std::move(exitEnv), false, true};
}

core::BlockLoopShape FuncGen::blockLoopShape(const Node *n) {
  if (!n || n->kind != "CallNode") return {};
  return core::classifyBlockLoop(*n, [&](int64_t id) { return node(id); });
}

/// DECISION 0041 stage 1. The receiver and the limit are evaluated once,
/// before the loop, as Ruby does. A hidden counter, the head block's extra
/// argument, runs the loop: the block's parameters are bound from it at the
/// top of each iteration, so assigning a parameter in the body does not
/// change how many times the body runs.
///
///   head(k):  k < n (times, each)  |  k <= b (upto)  |  k >= b (downto)
///   body:     bind the parameters; the block's own locals start afresh
///   latch:    `next` lands here; upto/downto leave on k == b before
///             stepping, so a limit at the end of the Integer range ends the
///             loop instead of overflowing
StmtResult FuncGen::blockLoopStmt(const Node *n, const core::BlockLoop &loop,
                                  Env env, bool wantValue) {
  using K = core::BlockLoop::Kind;
  const Location loc = locOf(n->id);
  const StringRef name = core::blockLoopName(loop.kind);
  auto failed = [&](Env e) { return StmtResult{Value(), std::move(e), false, false}; };
  if (wantValue) {
    fail(n->id, "unsupported-block",
         Twine("the value of a `") + name +
             "` loop is used; a loop with a block is a statement in this "
             "subset, and its value (the receiver) is not given");
    return failed(std::move(env));
  }
  const bool overBuffer = loop.kind == K::Each || loop.kind == K::EachWithIndex;

  Value start, last, count;
  std::string bufName;
  if (overBuffer) {
    const Node *recv = node(loop.receiver);
    if (!recv || recv->kind != "LocalVariableReadNode" ||
        !ast::getString(*recv, "name", bufName) || !buffers_.count(bufName)) {
      fail(n->id, "unsupported-block",
           Twine("`") + name +
               "` is a loop only on a declared buffer parameter; this "
               "receiver is not one");
      return failed(std::move(env));
    }
    const BufInfo &info = buffers_.at(bufName);
    if (statusMode()) {
      if (integerBits() == 32 && descriptorBound32_.count(bufName))
        count = descriptorBound32_.at(bufName);
      else if (descriptorCount_.count(bufName))
        count = descriptorCount_.at(bufName);
    } else {
      (void)info;
      count = bufferLength(bufName, env);  // decision 0044: a lent one too
    }
    if (!count) {
      fail(n->id, "unsupported-block",
           Twine("buffer `") + bufName + "` has no count in scope for `" + name + "`");
      return failed(std::move(env));
    }
    start = constant(loc, 0);
  } else {
    ExprResult r = expr(node(loop.receiver), std::move(env));
    if (!r.ok) return failed(std::move(r.env));
    if (!needInt(loop.receiver, r.value, Twine("the receiver of `") + name + "`"))
      return failed(std::move(r.env));
    env = std::move(r.env);
    if (loop.kind == K::Times) {
      count = r.value;
      start = constant(loc, 0);
    } else {
      start = r.value;
      ExprResult l = expr(node(loop.limit), std::move(env));
      if (!l.ok) return failed(std::move(l.env));
      if (!needInt(loop.limit, l.value, Twine("the argument of `") + name + "`"))
        return failed(std::move(l.env));
      env = std::move(l.env);
      last = l.value;
    }
  }

  Env headEnv;
  Value k;
  Block *head = mergeBlock({integerType()}, headEnv, k);
  Block *body = newBlock();
  Env latchEnv;
  Value noExtra;
  Block *latch = mergeBlock({}, latchEnv, noExtra);
  Env exitEnv;
  Value noExtra2;
  Block *exit = mergeBlock({}, exitEnv, noExtra2);
  branch(loc, head, env, start);

  openBlock(head);
  Value more;
  switch (loop.kind) {
  case K::Times:
    more = arith::CmpIOp::create(builder_, loc, arith::CmpIPredicate::slt, k, count);
    break;
  case K::Upto:
    more = arith::CmpIOp::create(builder_, loc, arith::CmpIPredicate::sle, k, last);
    break;
  case K::Downto:
    more = arith::CmpIOp::create(builder_, loc, arith::CmpIPredicate::sge, k, last);
    break;
  case K::Each:
  case K::EachWithIndex: {
    // `k` is never negative here, so one unsigned compare against the count
    // is exact; the count may be the boundary's u64.
    Value kk = k;
    if (count.getType() != k.getType())
      kk = statusMode() ? wideInteger(loc, k) : k;
    more = arith::CmpIOp::create(builder_, loc, arith::CmpIPredicate::ult, kk, count);
    break;
  }
  }
  condBranch(loc, more, body, headEnv, Value(), exit, headEnv, Value());

  openBlock(body);
  Env bodyEnv = headEnv;
  // Ruby makes the block's own locals afresh on every call of the block.
  for (const std::string &local : loop.locals)
    if (bodyEnv.count(local)) bodyEnv[local] = zeroOf(loc, typeOfLocal(local));
  auto bind = [&](size_t i, Value v) {
    if (i >= loop.params.size()) return;
    const std::string &p = loop.params[i];
    if (bodyEnv.count(p)) bodyEnv[p] = coerce(loc, v, typeOfLocal(p));
  };
  if (overBuffer) {
    if (!loop.params.empty()) {
      ExprResult e = bufferAccessValues(n, bufName, buffers_.at(bufName), k,
                                        Value(), std::move(bodyEnv));
      if (!e.ok) return failed(std::move(e.env));
      bodyEnv = std::move(e.env);
      bind(0, e.value);
    }
    bind(1, k);
  } else {
    bind(0, k);
  }
  loops_.push_back(LoopCtx{latch, exit});
  StmtResult inner = loop.body >= 0
                         ? stmts(node(loop.body), bodyEnv, /*wantValue=*/false)
                         : StmtResult{Value(), bodyEnv, false, true};
  loops_.pop_back();
  if (!inner.ok) return failed(std::move(bodyEnv));
  if (!inner.terminated) branch(loc, latch, inner.env, Value());

  if (latch->hasNoPredecessors()) {
    // Every path through the body leaves the loop (`return` or `break` on
    // every iteration), so nothing steps the counter. The latch is destroyed,
    // as ifStmt destroys an unreached join: filled in, it would be an
    // unreachable block the conversion to LLVM skips and the translation
    // then refuses.
    discardBlock(latch);
    openBlock(exit);
    return StmtResult{Value(), std::move(exitEnv), false, true};
  }
  openBlock(latch);
  Value one = constant(loc, 1);
  switch (loop.kind) {
  case K::Times:
  case K::Each:
  case K::EachWithIndex: {
    // k < n before the step, so k + 1 <= n: no overflow is possible.
    Value next = arith::AddIOp::create(builder_, loc, k, one);
    branch(loc, head, latchEnv, next);
    break;
  }
  case K::Upto:
  case K::Downto: {
    Value atLast = arith::CmpIOp::create(builder_, loc, arith::CmpIPredicate::eq, k, last);
    Block *step = newBlock();
    condBranch(loc, atLast, exit, latchEnv, Value(), step, latchEnv, Value());
    openBlock(step);
    Value next = loop.kind == K::Upto
                     ? Value(arith::AddIOp::create(builder_, loc, k, one))
                     : Value(arith::SubIOp::create(builder_, loc, k, one));
    branch(loc, head, latchEnv, next);
    break;
  }
  }

  openBlock(exit);
  return StmtResult{Value(), std::move(exitEnv), false, true};
}

/// frozen: _expr().
ExprResult FuncGen::expr(const Node *n, Env env) {
  if (!n) {
    gen_.reject(gen_.lineOf(method_.defNode()), "unsupported-node",
                Twine("'") + method_.name() + "': empty expression");
    return ExprResult{Value(), std::move(env), false};
  }
  const StringRef kind = n->kind;

  // Parse float literal spelling here; contract retained it unchanged.
  if (kind == "FloatNode") {
    std::string spelling;
    double value = 0.0;
    if (!gen_.options().freestandingTypes ||
        !ast::getFloatSpelling(*n, "value", spelling) ||
        llvm::StringRef(spelling).getAsDouble(value)) {
      fail(n->id, "unsupported-node", "FloatNode");
      return ExprResult{Value(), std::move(env), false};
    }
    // Nonfinite literals are outside the subset. getAsDouble succeeds on 1e400 as inf, which would
    // otherwise enter a freestanding object. Frozen fs_f64_lit refuses repr inf/-inf/nan; a08_float
    // pins that behavior. Native initially accepted it until the comparison caught it.
    if (std::isinf(value) || std::isnan(value)) {
      const char *what = std::isnan(value) ? "nan" : (value < 0 ? "-inf" : "inf");
      // Frozen fs_f64_lit omits the method-name prefix. fail adds it, so call reject directly for
      // the same nonfinite-literal wording.
      gen_.reject(gen_.lineOf(n->id), "unsupported-node",
                  std::string("a non-finite Float literal (") + what +
                      ") is not in the freestanding subset");
      return ExprResult{Value(), std::move(env), false};
    }
    Value v = arith::ConstantOp::create(
        builder_, locOf(n->id), builder_.getF64FloatAttr(value));
    return ExprResult{v, std::move(env), true};
  }

  if (kind == "ConstantReadNode" && statusMode()) {
    std::string name;
    if (!ast::getString(*n, "name", name)) {
      fail(n->id, "unsupported-node", "ConstantReadNode");
      return ExprResult{Value(), std::move(env), false};
    }
    const std::optional<int64_t> value = gen_.constantValue(name);
    if (!value) {
      fail(n->id, "unsupported-node",
           Twine("the constant ") + name +
               " does not resolve to one top-level integer literal");
      return ExprResult{Value(), std::move(env), false};
    }
    return ExprResult{constant(locOf(n->id), *value), std::move(env), true};
  }

  // DECISION 0014 D5: `Mod::NAME`, one level, the board package's constants.
  // The checker has admitted the path; this resolves it inside that module.
  if (kind == "ConstantPathNode" && statusMode()) {
    std::string name, module;
    int64_t parentId = -1;
    const Node *parent =
        ast::getReference(*n, "parent", parentId) ? node(parentId) : nullptr;
    if (!ast::getString(*n, "name", name) || !parent ||
        parent->kind != "ConstantReadNode" ||
        !ast::getString(*parent, "name", module)) {
      fail(n->id, "unsupported-node", "ConstantPathNode");
      return ExprResult{Value(), std::move(env), false};
    }
    const std::optional<int64_t> value = gen_.constantPathValue(module, name);
    if (!value) {
      fail(n->id, "unsupported-node",
           Twine("the constant ") + module + "::" + name +
               " does not resolve to one integer literal in that module's body");
      return ExprResult{Value(), std::move(env), false};
    }
    return ExprResult{constant(locOf(n->id), *value), std::move(env), true};
  }

  // DECISION 0008 TASK 4: `true` and `false`. An i1, not 0 and 1: nothing in
  // this subset converts between a boolean and an integer, and the widening
  // that puts a helper's boolean into the i64 result slot is the ABI's, not a
  // source-level coercion.
  if ((kind == "TrueNode" || kind == "FalseNode") && statusMode()) {
    Value v = arith::ConstantOp::create(
        builder_, locOf(n->id), builder_.getI1Type(),
        builder_.getBoolAttr(kind == "TrueNode"));
    return ExprResult{v, std::move(env), true};
  }
  if (kind == "IntegerNode") {
    std::string big;
    if (ast::getString(*n, "bigval", big)) {
      fail(n->id, "unsupported-type", Twine("bignum literal ") + big +
           " is outside the target's " + Twine(integerBits()) + "-bit Integer");
      return ExprResult{Value(), std::move(env), false};
    }
  }
  if (kind == "IntegerNode" && statusMode()) {
    // The same rule the checker states: where `bigval` is present it is the
    // exact decimal text and `value` is saturated, so a literal is only a
    // literal when the two agree. Repeated here rather than assumed, because
    // reading `value` alone turns 9223372036854775808 into INT64_MAX.
    int64_t value = 0;
    std::string exact;
    if (!ast::getInteger(*n, "value", value)) {
      fail(n->id, "unsupported-node",
           "integer literal without a 64-bit value (bignum literals are not in "
           "the subset)");
      return ExprResult{Value(), std::move(env), false};
    }
    if (ast::getString(*n, "bigval", exact)) {
      errno = 0;
      char *end = nullptr;
      const long long parsed = std::strtoll(exact.c_str(), &end, 10);
      if (errno == ERANGE || !end || *end != '\0' ||
          static_cast<int64_t>(parsed) != value) {
        fail(n->id, "unsupported-node",
             Twine("the integer literal ") + exact +
                 " is outside signed " + Twine(integerBits()) + " bits");
        return ExprResult{Value(), std::move(env), false};
      }
    }
    return ExprResult{constant(locOf(n->id), value), std::move(env), true};
  }

  if (kind == "IntegerNode") {
    int64_t value = 0;
    if (!ast::getInteger(*n, "value", value)) {
      // The producer omits `value` for a literal that does not fit 64 bits.
      fail(n->id, "unsupported-node",
           "integer literal without a 64-bit value (bignum literals are not in "
           "the subset)");
      return ExprResult{Value(), std::move(env), false};
    }
    return ExprResult{constant(locOf(n->id), value), std::move(env), true};
  }

  if (kind == "LocalVariableReadNode") {
    std::string name;
    if (!ast::getString(*n, "name", name)) {
      fail(n->id, "unsupported-node", n->kind);
      return ExprResult{Value(), std::move(env), false};
    }
    auto found = env.find(name);
    if (found == env.end()) {
      fail(n->id, "unsupported-node",
           Twine("read of unknown local '") + name + "'");
      return ExprResult{Value(), std::move(env), false};
    }
    return ExprResult{found->second, std::move(env), true};
  }

  if (kind == "ParenthesesNode") {
    int64_t bodyId = -1;
    if (!ast::getReference(*n, "body", bodyId)) {
      fail(n->id, "unsupported-node", n->kind);
      return ExprResult{Value(), std::move(env), false};
    }
    StmtResult inner = stmts(node(bodyId), std::move(env), /*wantValue=*/true);
    if (!inner.ok)
      return ExprResult{Value(), std::move(inner.env), false};
    if (inner.terminated) {
      fail(n->id, "unsupported-node",
           "`return` inside a parenthesised expression");
      return ExprResult{Value(), std::move(inner.env), false};
    }
    return ExprResult{inner.value, std::move(inner.env), true};
  }

  if (kind == "IfNode" ||
      kind == "UnlessNode") { // ternary and value-position `if` / `unless`
    StmtResult inner = ifStmt(n, std::move(env), /*wantValue=*/true,
                              /*invert=*/kind == "UnlessNode");
    if (!inner.ok)
      return ExprResult{Value(), std::move(inner.env), false};
    if (inner.terminated) {
      fail(n->id, "unsupported-node",
           "`if` in value position where every branch returns");
      return ExprResult{Value(), std::move(inner.env), false};
    }
    return ExprResult{inner.value, std::move(inner.env), true};
  }

  if (kind == "AndNode" || kind == "OrNode")
    return andOr(n, std::move(env), kind == "AndNode");

  if (kind == "CallNode")
    return call(n, std::move(env));

  if (kind == "LocalVariableWriteNode") {
    StmtResult inner = stmt(n, std::move(env), /*wantValue=*/true);
    return ExprResult{inner.value, std::move(inner.env), inner.ok};
  }

  fail(n->id, "unsupported-node", n->kind);
  return ExprResult{Value(), std::move(env), false};
}

/// frozen: andor().  The short circuit is a join carrying the environment AND
/// an i1: `&&` branches straight to the join with the LEFT value when the left
/// is false, `||` when it is true, and the right-hand block always branches
/// with the right value.  logic.expected.mlir pins both directions at once.
ExprResult FuncGen::andOr(const Node *n, Env env, bool isAnd) {
  int64_t leftId = -1, rightId = -1;
  if (!ast::getReference(*n, "left", leftId) ||
      !ast::getReference(*n, "right", rightId)) {
    fail(n->id, "unsupported-node", n->kind);
    return ExprResult{Value(), std::move(env), false};
  }
  ExprResult left = expr(node(leftId), std::move(env));
  if (!left.ok)
    return ExprResult{Value(), std::move(left.env), false};
  if (!needBool(leftId, left.value,
                Twine("left operand of ") + (isAnd ? "&&" : "||")))
    return ExprResult{Value(), std::move(left.env), false};

  Env outer = std::move(left.env);
  Block *rhs = newBlock();
  Env joinEnv;
  Value joinValue;
  const Type i1 = builder_.getI1Type();
  Block *join = mergeBlock(i1, joinEnv, joinValue);
  const Location loc = locOf(n->id);
  if (isAnd)
    condBranch(loc, left.value, rhs, outer, Value(), join, outer, left.value);
  else
    condBranch(loc, left.value, join, outer, left.value, rhs, outer, Value());

  openBlock(rhs);
  ExprResult right = expr(node(rightId), outer);
  if (!right.ok)
    return ExprResult{Value(), std::move(right.env), false};
  if (!needBool(rightId, right.value,
                Twine("right operand of ") + (isAnd ? "&&" : "||")))
    return ExprResult{Value(), std::move(right.env), false};
  branch(locOf(rightId), join, right.env, right.value);

  openBlock(join);
  return ExprResult{joinValue, std::move(joinEnv), true};
}

/// frozen: call() — the operator arm (there is a receiver) and the
/// internal-call arm (there is not).  The selector has already closed both:
/// `isSupportedOperator` fixes the operator set and `unresolved-call` fixes the
/// callee set, so a surprise here is a disagreement between the two halves of
/// the front end, not a new input.
ExprResult FuncGen::call(const Node *n, Env env) {
  // DECISION 0041 stage 1: a loop reached as an expression has its value
  // used, which the subset does not give it.
  {
    core::BlockLoopShape shape = blockLoopShape(n);
    if (shape.loop) {
      fail(n->id, "unsupported-block",
           Twine("the value of a `") + core::blockLoopName(shape.loop->kind) +
               "` loop is used; a loop with a block is a statement in this "
               "subset, and its value (the receiver) is not given");
      return ExprResult{Value(), std::move(env), false};
    }
    if (shape.refusal) {
      fail(n->id, "unsupported-block", *shape.refusal);
      return ExprResult{Value(), std::move(env), false};
    }
  }
  std::string name;
  int64_t receiverId = -1, argumentsId = -1;
  if (!ast::getString(*n, "name", name) ||
      !ast::getReference(*n, "receiver", receiverId) ||
      !ast::getReference(*n, "arguments", argumentsId)) {
    fail(n->id, "unsupported-node", n->kind);
    return ExprResult{Value(), std::move(env), false};
  }
  std::vector<int64_t> args;
  if (argumentsId >= 0) {
    const Node *arguments = node(argumentsId);
    if (!arguments || !ast::getArray(*arguments, "arguments", args)) {
      fail(n->id, "unsupported-node", n->kind);
      return ExprResult{Value(), std::move(env), false};
    }
  }

  // Buffer indexing is admitted only on declared buffer parameters, not local/expression receivers.
  // Decision 0041 stage 2: an array size is its construction count.
  if (statusMode() && name == "size" && args.empty() && receiverId >= 0) {
    const Node *recv = node(receiverId);
    std::string bufName;
    if (recv && recv->kind == "LocalVariableReadNode" &&
        ast::getString(*recv, "name", bufName) && buffers_.count(bufName)) {
      auto held = descriptorCount_.find(bufName);
      if (held == descriptorCount_.end()) {
        fail(n->id, "unsupported-node", Twine("array `") + bufName + "` has no size here");
        return ExprResult{Value(), std::move(env), false};
      }
      return ExprResult{held->second, std::move(env), true};
    }
  }
  if ((gen_.options().freestandingTypes || statusMode()) &&
      (name == "[]" || name == "[]=")) {
    return bufferAccess(n, name, receiverId, args, std::move(env));
  }

  // DECISION 0014: `Module.fn(args)` on a declared extern module. The
  // receiver is a name the contract declared, not a value, and the checker
  // admitted the call against the declaration before this ran.
  if (statusMode() && receiverId >= 0) {
    const Node *recv = node(receiverId);
    std::string module;
    if (recv && recv->kind == "ConstantReadNode" &&
        ast::getString(*recv, "name", module) && gen_.options().isAppExternModule(module)) {
      const ScalarAppExtern *ext = gen_.options().appExtern(module, name);
      if (!ext) {
        fail(n->id, "unsupported-node",
             Twine("call to '") + module + "." + name + "', which the contract does not declare");
        return ExprResult{Value(), std::move(env), false};
      }
      return appExternCall(n, *ext, args, std::move(env));
    }
  }

  if (receiverId >= 0) {
    // frozen: `!` — `xori` against an i1 constant 1, in that ORDER (the
    // constant is emitted first).  It takes no arguments, so it is decided
    // before the arity check below, like the unary operators.
    if (name == "!") {
      ExprResult v = expr(node(receiverId), std::move(env));
      if (!v.ok)
        return ExprResult{Value(), std::move(v.env), false};
      if (!needBool(n->id, v.value, "operand of !"))
        return ExprResult{Value(), std::move(v.env), false};
      const Location loc = locOf(n->id);
      Value one = arith::ConstantOp::create(builder_, loc,
                                            builder_.getI1Type(),
                                            builder_.getBoolAttr(true));
      Value flipped = arith::XOrIOp::create(builder_, loc, v.value, one);
      return ExprResult{flipped, std::move(v.env), true};
    }
    if (name == "-@" || name == "+@") {
      ExprResult v = expr(node(receiverId), std::move(env));
      if (!v.ok)
        return ExprResult{Value(), std::move(v.env), false};
      if (!needNumeric(n->id, v.value,
                       Twine("operand of unary ") + name.substr(0, 1)))
        return ExprResult{Value(), std::move(v.env), false};
      if (name == "+@")
        return ExprResult{v.value, std::move(v.env), true};
      if (gen_.options().freestandingTypes &&
          llvm::isa<mlir::Float64Type>(v.value.getType())) {
        // Floating unary minus uses negf without checked arithmetic.
        Value neg = arith::NegFOp::create(builder_, locOf(n->id), v.value);
        return ExprResult{neg, std::move(v.env), true};
      }
      // frozen: neg() — `overflow<nsw>` in `Raise` and `None`, because stock
      // codegen emits a bare signed C `-` whose overflow is UB and which clang
      // duly exploits.  Matching stock means inheriting stock's UB there.
      // F-185: `Wrap` is the exception — its declared contract is DEFINED
      // signed two's-complement wrapping, so `-@` is bare.
      const Location loc = locOf(n->id);
      Value zero = constant(loc, 0);
      // Freestanding trap also routes unary-minus overflow to the hook. Borrow checked_sub shape
      // but preserve -@ in detail, matching overflow_op("-",0,x,detail_op="-@"). Observed hook
      // arguments were (1,0,x).
      if (statusMode() || abortMode()) {
        // `-INT64_MIN` has no i64 value. Checked like any other overflow, and
        // reported as ARITHMETIC (status) or as an overflow in `-@` (abort).
        Value negated = overflowOp(loc, "-", zero, v.value, "-@");
        return ExprResult{negated, std::move(v.env), true};
      }
      if (gen_.mode() == OverflowMode::Trap && gen_.emitCheckedArithmetic()) {
        Value negated = mlir::spinel::CheckedSubOp::create(
            builder_, loc, integerType(), zero, v.value,
            mlir::spinel::OverflowPolicy::Trap,
            builder_.getStringAttr(trapDetail("-@")));
        return ExprResult{negated, std::move(v.env), true};
      }
      Value negated =
          gen_.mode() == OverflowMode::Wrap
              ? arith::SubIOp::create(builder_, loc, zero, v.value)
              : arith::SubIOp::create(builder_, loc, zero, v.value,
                                      arith::IntegerOverflowFlags::nsw);
      return ExprResult{negated, std::move(v.env), true};
    }
    // Decision 0007 task 2: two more receiver-side operations, in the status
    // ABI only. `~` cannot fail; `abs` can, on the one input with no i64
    // magnitude.
    // Decision 0042: `~` (stage 1) and `abs` (stage 3) also on the native
    // `--core` route and on freestanding.
    if ((statusMode() || bitOperators()) && (name == "~" || name == "abs")) {
      if (!args.empty()) {
        fail(n->id, "unsupported-node",
             Twine("'") + name + "' with " + Twine(args.size()) + " arguments");
        return ExprResult{Value(), std::move(env), false};
      }
      ExprResult v = expr(node(receiverId), std::move(env));
      if (!v.ok)
        return ExprResult{Value(), std::move(v.env), false};
      if (v.value && llvm::isa<mlir::Float64Type>(v.value.getType())) {
        fail(n->id, "unsupported-node",
             Twine("operator '") + name + "' on a Float is outside the subset");
        return ExprResult{Value(), std::move(v.env), false};
      }
      if (!needInt(n->id, v.value, Twine("operand of ") + name))
        return ExprResult{Value(), std::move(v.env), false};
      const Location loc = locOf(n->id);
      if (name == "~") {
        // `~a` is `-a - 1`, exact for every i64, so it is a bare xor with -1.
        Value ones = constant(loc, -1);
        return ExprResult{arith::XOrIOp::create(builder_, loc, v.value, ones),
                          std::move(v.env), true};
      }
      return ExprResult{absOp(loc, v.value), std::move(v.env), true};
    }
    if (args.size() != 1) {
      fail(n->id, "unsupported-node",
           Twine("'") + name + "' with " + Twine(args.size()) + " arguments");
      return ExprResult{Value(), std::move(env), false};
    }
    ExprResult a = expr(node(receiverId), std::move(env));
    if (!a.ok)
      return ExprResult{Value(), std::move(a.env), false};
    ExprResult b = expr(node(args[0]), std::move(a.env));
    if (!b.ok)
      return ExprResult{Value(), std::move(b.env), false};
    if (!needNumeric(n->id, a.value, Twine("left operand of ") + name) ||
        !needNumeric(n->id, b.value, Twine("right operand of ") + name))
      return ExprResult{Value(), std::move(b.env), false};
    return binop(n->id, name, a.value, b.value, std::move(b.env));
  }

  // Check profile externs before top-level methods. D2 already excludes equal-name collisions, so
  // both cannot match here.
  if (gen_.options().freestandingTypes)
    if (const ScalarExternDesc *ext = gen_.options().extern_(name))
      return externCall(n, *ext, args, std::move(env));

  // DECISION 0022 and 0042 stage 4: a word intrinsic, on every CORE route --
  // a status entry, --core (abort mode) and freestanding -- and only when the
  // source defines no method of that name (the checkers refused that case as
  // a conflict before this runs).
  if ((statusMode() || abortMode() || gen_.options().freestandingTypes) &&
      !gen_.method(name))
    if (const auto *in = spinel_mlir::core::coreIntrinsic(name))
      return intrinsicCall(n, *in, args, std::move(env));

  // Receiverless: another top-level method of this file.  The selection edge is
  // what makes that true, and `sp_` is the canonical value ABI prefix.  The
  // callee is the edge's (decision 0026 step 4), not a second lookup of the
  // name; a call with no edge is not in the closure.
  const StringRef resolved = gen_.callee(n->id);
  func::FuncOp callee = resolved.empty() ? func::FuncOp() : gen_.function(resolved);
  const ScalarMethod *signature = resolved.empty() ? nullptr : gen_.method(resolved);
  if (!callee || !signature) {
    fail(n->id, "unsupported-node",
         Twine("call to '") + name + "', which is not in the selected closure");
    return ExprResult{Value(), std::move(env), false};
  }
  if (args.size() != signature->parameters().size()) {
    fail(n->id, "unsupported-node",
         Twine("call to '") + name + "' with " + Twine(args.size()) +
             " arguments, expected " + Twine(signature->parameters().size()));
    return ExprResult{Value(), std::move(env), false};
  }
  SmallVector<Value> values;
  // DECISION 0044: the buffers passed to a callee that is an entry too, each
  // with the position of its `:len` argument and the length held here.
  struct LentToEntry {
    size_t lenIndex;
    std::string bufName;
    Value held;
  };
  SmallVector<LentToEntry> lentToEntry;
  for (auto indexed : llvm::enumerate(args)) {
    const int64_t argumentId = indexed.value();
    // DECISION 0008 TASK 3: a borrowed buffer at this position. The pointer
    // and the BOUND both come from this frame's descriptor, and the bound is
    // taken from `descriptorCount_` -- captured from the parameter before the
    // body could touch it -- and never from the environment. That is what
    // makes `n_data = n_data + 100` in the caller unable to enlarge the
    // callee's bound: the Ruby local and the descriptor count are two
    // different things.
    // read from the context the callee is passed below
    if (gen_.contextSlot(resolved, indexed.index()) >= 0) continue;
    if (statusMode() && gen_.options().borrow(resolved, indexed.index())) {
      const Node *a = node(argumentId);
      std::string bufName;
      // DECISION 0014 §7: a string literal is constant bytes -- a read-only
      // u8 buffer the helper borrows, with its byte count as the hidden
      // descriptor. The checker admitted the position; here it lowers.
      if (a && a->kind == "StringNode") {
        Value litPtr, litCount;
        uint64_t size = 0;
        if (!literalBytes(a, locOf(argumentId), litPtr, litCount, size))
          return ExprResult{Value(), std::move(env), false};
        values.push_back(litPtr);
        // a 32-bit body passes a helper its hidden bound in 32 bits; a literal's
        // byte count is a small constant
        if (countBits() == 32 && litCount.getType().isInteger(64))
          litCount = arith::TruncIOp::create(builder_, locOf(argumentId), builder_.getI32Type(), litCount);
        values.push_back(litCount);
        continue;
      }
      if (!a || a->kind != "LocalVariableReadNode" ||
          !ast::getString(*a, "name", bufName) || !buffers_.count(bufName)) {
        fail(argumentId, "unsupported-node",
             Twine("argument ") + Twine(indexed.index()) + " of '" + name +
                 "' must be a buffer this function holds, named directly; "
                 "version 1 resolves a borrowed argument only as a parameter "
                 "by name");
        return ExprResult{Value(), std::move(env), false};
      }
      auto held = descriptorCount_.find(bufName);
      auto ptr = env.find(bufName);
      if (held == descriptorCount_.end() || ptr == env.end()) {
        fail(argumentId, "unsupported-node",
             Twine("buffer `") + bufName + "` has no descriptor captured here");
        return ExprResult{Value(), std::move(env), false};
      }
      values.push_back(ptr->second);
      values.push_back(held->second);
      continue;
    }
    // DECISION 0044: a buffer this function holds, at a position where the
    // callee takes one: a lent parameter of a helper (the address and the
    // length, L1), or a declared buffer of a callee that is an entry too (the
    // address alone; its `:len` is an argument of its own, checked below).
    const ScalarRootDesc *calleeRoot =
        gen_.options().freestandingTypes ? gen_.options().root(resolved) : nullptr;
    const bool calleeLent = signature->parameters()[indexed.index()].lent() != nullptr;
    const bool calleeBuffer =
        calleeRoot && indexed.index() < calleeRoot->params.size() &&
        calleeRoot->params[indexed.index()].kind == ScalarParamDesc::Kind::Buffer;
    if (calleeLent || calleeBuffer) {
      const Node *a = node(argumentId);
      std::string bufName;
      if (!a || a->kind != "LocalVariableReadNode" ||
          !ast::getString(*a, "name", bufName) || !buffers_.count(bufName) ||
          !env.count(bufName)) {
        fail(argumentId, "unsupported-node",
             Twine("argument ") + Twine(indexed.index()) + " of '" + name +
                 "' must be a buffer this function holds, named directly "
                 "(decision 0044)");
        return ExprResult{Value(), std::move(env), false};
      }
      Value length = bufferLength(bufName, env);
      if (!length) {
        fail(argumentId, "unsupported-node",
             Twine("buffer `") + bufName + "` has no length in scope");
        return ExprResult{Value(), std::move(env), false};
      }
      values.push_back(env[bufName]);
      if (calleeLent) {
        values.push_back(length);
      } else if (calleeRoot->params[indexed.index()].lenIndex >= 0) {
        lentToEntry.push_back({static_cast<size_t>(calleeRoot->params[indexed.index()].lenIndex),
                               bufName, length});
      }
      continue;
    }
    ExprResult v = expr(node(argumentId), std::move(env));
    if (!v.ok)
      return ExprResult{Value(), std::move(v.env), false};
    env = std::move(v.env);
    if (!needNumeric(argumentId, v.value, Twine("argument of ") + name))
      return ExprResult{Value(), std::move(env), false};
    values.push_back(coerce(locOf(argumentId), v.value,
                            callee.getFunctionType().getInput(values.size())));
  }
  const Location callLoc = locOf(n->id);
  // DECISION 0044: a call into the body of a callee that is an entry too goes
  // past that entry's wrapper. The `:len` it passes for each buffer must not
  // exceed the length this function holds for that buffer, or the callee's
  // own range check would compare against a length the caller made up.
  for (const LentToEntry &l : lentToEntry) {
    if (l.lenIndex >= values.size()) continue;
    Value passed = values[l.lenIndex];
    if (!passed.getType().isInteger(integerBits())) continue;
    Block *cold = trapBlock(callLoc, 4, passed, l.held,
                            (Twine(method_.name()) + ": the length passed to " + name +
                             " for `" + l.bufName + "` exceeds its length").str());
    Value over = arith::CmpIOp::create(builder_, callLoc, arith::CmpIPredicate::ugt,
                                       passed, l.held);
    Block *cont = newBlock();
    cf::CondBranchOp::create(builder_, callLoc, over, cold, ValueRange{}, cont,
                             ValueRange{});
    openBlock(cont);
  }
  if (statusMode()) {
    // The callee reports its own failure the same way this function does, so
    // the caller has to look. Propagating the callee's status unchanged --
    // rather than replacing it with one of this frame's own -- keeps the
    // category the failing operation chose.
    if (gen_.usesContext(resolved)) {
      if (!context_)
        return fail(n->id, "unsupported-node", Twine("'") + name + "' reads the buffer context, and this function holds none"),
               ExprResult{Value(), std::move(env), false};
      values.push_back(context_);
    }
    if (gen_.takesScratch(resolved)) {
      if (!scratch_)
        return fail(n->id, "unsupported-node", Twine("'") + name + "' takes the data stack, and this function holds none"),
               ExprResult{Value(), std::move(env), false};
      values.push_back(scratch_);
    }
    Value slot = callSlot(callLoc);
    values.push_back(slot);
    auto call = func::CallOp::create(builder_, callLoc, callee, values);
    Value status = call.getResult(0);
    Value failed = arith::CmpIOp::create(
        builder_, callLoc, arith::CmpIPredicate::ne, status,
        arith::ConstantOp::create(builder_, callLoc, builder_.getI32Type(),
                                  builder_.getI32IntegerAttr(0)));
    Block *propagate = coldBlock();
    {
      OpBuilder cold(func_.getContext());
      cold.setInsertionPointToEnd(propagate);
      func::ReturnOp::create(cold, callLoc, status);
    }
    Block *cont = newBlock();
    cf::CondBranchOp::create(builder_, callLoc, failed, propagate, ValueRange{},
                             cont, ValueRange{});
    openBlock(cont);
    Value loaded = LLVM::LoadOp::create(builder_, callLoc,
                                        integerType(), slot);
    // A helper declared to answer a boolean gives one back: the slot carried
    // 0 or 1, and a condition in this subset is an i1. Comparing here rather
    // than letting an i64 reach `needBool` keeps Ruby's integer truthiness
    // out of the subset, which is the rule that refusal exists for.
    if (signature->returnType() == "bool")
      loaded = arith::CmpIOp::create(
          builder_, callLoc, arith::CmpIPredicate::ne, loaded,
          arith::ConstantOp::create(builder_, callLoc, integerType(),
                                    builder_.getIntegerAttr(integerType(), 0)));
    return ExprResult{loaded, std::move(env), true};
  }
  auto op = func::CallOp::create(builder_, callLoc, callee, values);
  return ExprResult{op.getResult(0), std::move(env), true};
}

/// DECISION 0041 STAGE 2. `a = Array.new(n, v)`: the region's first word
/// is the bump offset, in the body's integer width, and the elements follow
/// it. A negative size is BOUNDS; a size the rest of the region cannot hold
/// is CAPACITY, before anything is written. Otherwise the n elements are
/// filled with v and the offset moves past them.
StmtResult FuncGen::arrayNew(const Node *write, const std::string &name, const Node *call, Env env) {
  const Location loc = locOf(write->id);
  auto bad = [&](const Twine &detail) {
    fail(write->id, "unsupported-node", detail);
    return StmtResult{Value(), std::move(env), false, false};
  };
  if (!scratch_) return bad("Core::Buffer without the data stack");
  int64_t argumentsId = -1;
  std::vector<int64_t> args;
  const Node *arguments = ast::getReference(*call, "arguments", argumentsId) ? node(argumentsId) : nullptr;
  if (!arguments || !ast::getArray(*arguments, "arguments", args) || args.size() != 2)
    return bad("Core::Buffer takes a count and a fill");
  ExprResult size = expr(node(args[0]), std::move(env));
  if (!size.ok) return StmtResult{Value(), std::move(size.env), false, false};
  env = std::move(size.env);
  if (!needNumeric(args[0], size.value, "the count of Core::Buffer"))
    return StmtResult{Value(), std::move(env), false, false};
  ExprResult fill = expr(node(args[1]), std::move(env));
  if (!fill.ok) return StmtResult{Value(), std::move(fill.env), false, false};
  env = std::move(fill.env);
  if (!needNumeric(args[1], fill.value, "the fill of Core::Buffer"))
    return StmtResult{Value(), std::move(env), false, false};
  const Type intTy = integerType();
  const unsigned wordBytes = integerBits() / 8;
  const uint64_t bytes = gen_.options().status.scratchBytes;
  auto constant = [&](int64_t v) {
    return Value(arith::ConstantOp::create(builder_, loc, intTy, builder_.getIntegerAttr(intTy, v)));
  };
  Value n = size.value;
  Value zero = constant(0);
  statusGuard(loc, arith::CmpIOp::create(builder_, loc, arith::CmpIPredicate::slt, n, zero),
              CoreStatus::Bounds, "a negative count for Core::Buffer");
  Value offset = LLVM::LoadOp::create(builder_, loc, intTy, scratch_);
  Value capacity = constant(static_cast<int64_t>(bytes - wordBytes));
  Value elementBytes = constant(wordBytes);
  Value room = arith::DivUIOp::create(builder_, loc,
                                      arith::SubIOp::create(builder_, loc, capacity, offset),
                                      elementBytes);
  statusGuard(loc, arith::CmpIOp::create(builder_, loc, arith::CmpIPredicate::ugt, n, room),
              CoreStatus::Capacity, "Core::Buffer past the data stack");
  const Type ptrTy = LLVM::LLVMPointerType::get(builder_.getContext());
  Value start = arith::AddIOp::create(builder_, loc, offset, constant(wordBytes));
  Value base = LLVM::GEPOp::create(builder_, loc, ptrTy, builder_.getI8Type(), scratch_,
                                   ArrayRef<LLVM::GEPArg>{start});
  // the fill: for i in 0...n, base[i] = v
  Block *head = newBlock();
  head->addArgument(intTy, loc);
  Block *body = newBlock();
  Block *done = newBlock();
  cf::BranchOp::create(builder_, loc, head, ValueRange{zero});
  openBlock(head);
  Value i = head->getArgument(0);
  cf::CondBranchOp::create(builder_, loc,
                           arith::CmpIOp::create(builder_, loc, arith::CmpIPredicate::slt, i, n),
                           body, ValueRange{}, done, ValueRange{});
  openBlock(body);
  Value at = LLVM::GEPOp::create(builder_, loc, ptrTy, intTy, base, ArrayRef<LLVM::GEPArg>{i});
  LLVM::StoreOp::create(builder_, loc, fill.value, at);
  cf::BranchOp::create(builder_, loc, head,
                       ValueRange{Value(arith::AddIOp::create(builder_, loc, i, constant(1)))});
  openBlock(done);
  Value used = arith::MulIOp::create(builder_, loc, n, elementBytes);
  LLVM::StoreOp::create(builder_, loc, arith::AddIOp::create(builder_, loc, offset, used), scratch_);
  env[name] = base;
  descriptorCount_[name] = n;
  captureBound32(loc, name);
  return StmtResult{base, std::move(env), false, true};
}

ExprResult FuncGen::bufferAccess(const Node *n, StringRef name,
                                 int64_t receiverId, ArrayRef<int64_t> args,
                                 Env env) {
  auto bad = [&](const Twine &detail) {
    fail(n->id, "unsupported-node", detail);
    return ExprResult{Value(), std::move(env), false};
  };
  const Node *recv = receiverId >= 0 ? node(receiverId) : nullptr;
  std::string bufName;
  if (!recv || recv->kind != "LocalVariableReadNode" ||
      !ast::getString(*recv, "name", bufName))
    return bad("`[]` is only in the subset on a declared buffer parameter");
  auto found = buffers_.find(bufName);
  if (found == buffers_.end())
    return bad(Twine("`") + bufName +
               "[...]` -- only a declared buffer parameter can be indexed");
  const BufInfo &info = found->second;
  if (name == "[]" && args.size() == 2)
    return bad(Twine(method_.name()) + ": `" + bufName +
               "[off, n]` is a buffer VIEW (E095, decision record D-11), and a "
               "view may appear ONLY in the argument position of a call whose "
               "declaration gives it a buffer parameter. It is not a value: it "
               "cannot be assigned, returned, indexed or operated on (D-11 s2-1).");
  const size_t want = name == "[]" ? 1u : 2u;
  if (args.size() != want)
    return bad(Twine("`") + name + "` with " + Twine(args.size()) +
               " argument(s)");

  ExprResult idx = expr(node(args[0]), std::move(env));
  if (!idx.ok)
    return ExprResult{Value(), std::move(idx.env), false};
  if (!needInt(args[0], idx.value, "a buffer index"))
    return ExprResult{Value(), std::move(idx.env), false};
  env = std::move(idx.env);

  Value stored;
  if (name == "[]=") {
    ExprResult v = expr(node(args[1]), std::move(env));
    if (!v.ok)
      return ExprResult{Value(), std::move(v.env), false};
    if (!needNumeric(args[1], v.value, "a value stored into a buffer"))
      return ExprResult{Value(), std::move(v.env), false};
    env = std::move(v.env);
    stored = v.value;
  }
  // The checked access itself takes VALUES, because `buf[i] op= v` has to
  // evaluate its index exactly once and then use that one value for both the
  // load and the store. Writing the bounds test and the narrowing a second
  // time there would be a second copy of a safety rule.
  return bufferAccessValues(n, bufName, info, idx.value, stored, std::move(env));
}

ExprResult FuncGen::bufferAccessValues(const Node *n, StringRef bufName,
                                       const BufInfo &info, Value idxValue,
                                       Value stored, Env env) {
  auto bad = [&](const Twine &detail) {
    fail(n->id, "unsupported-node", detail);
    return ExprResult{Value(), std::move(env), false};
  };
  const Location loc = locOf(n->id);
  const bool isLoad = !stored;
  const std::string bufKey = bufName.str();
  // DECISION 0044: a lent buffer keeps every mode that reaches it -- no store
  // through one lent from `:in`, no read through one lent from `:out`.
  if (!isLoad && info.lent && !info.inFrom.empty())
    return bad(Twine("stores into `") + bufName + "` (line " +
               Twine(gen_.lineOf(n->id)) + "), which is lent " + info.inFrom +
               "; a lent buffer keeps its mode (decision 0044)");
  if (isLoad && info.lent && !info.outFrom.empty())
    return bad(Twine("reads `") + bufName + "` (line " +
               Twine(gen_.lineOf(n->id)) + "), which is lent " + info.outFrom +
               "; a lent buffer keeps its mode (decision 0044)");

  // bounds: :unchecked removes only index checks; boundary wrapper codes 5/6 remain. Keep prototype
  // detail spelling.
  if (info.checked) {
    Value len;
    if (statusMode()) {
      auto captured = descriptorCount_.find(bufKey);
      if (captured == descriptorCount_.end())
        return bad(Twine("buffer `") + bufName +
                   "` has no descriptor count captured at entry");
      len = captured->second;
    } else {
      len = bufferLength(bufName, env);
      if (!len)
        return bad(Twine("buffer `") + bufName + "` has no `:len` in scope");
    }
    Block *cold =
        statusMode()
            ? statusBlock(loc, CoreStatus::Bounds, ("index into " + bufName).str())
            : trapBlock(loc, 4, idxValue, len,
                        (Twine(method_.name()) +
                         ": index out of bounds for " + bufName).str());
    // `0 <= index < count`, as TWO comparisons in the status mode: a signed one
    // for the lower end and an unsigned one for the upper.
    //
    // One unsigned compare would be equivalent only while every count fits
    // i64, and the count's domain at this boundary is the whole of u64. Above
    // INT64_MAX a negative index compares BELOW the count as unsigned and
    // would pass. The two tests do not depend on the count's magnitude at all.
    Value oob;
    if (statusMode() && integerBits() == 32 && descriptorBound32_.count(bufKey)) {
      // A 32-bit body: one unsigned compare against min(count, 2^31), which
      // admits and refuses exactly what the two comparisons below do.
      oob = arith::CmpIOp::create(builder_, loc, arith::CmpIPredicate::uge, idxValue,
                                  descriptorBound32_[bufKey]);
    } else {
      oob = arith::CmpIOp::create(builder_, loc, arith::CmpIPredicate::uge,
                                  statusMode() ? wideInteger(loc, idxValue) : idxValue, len);
    }
    if (statusMode() && !(integerBits() == 32 && descriptorBound32_.count(bufKey))) {
      Value zero = constant(loc, 0);
      Value negative = arith::CmpIOp::create(
          builder_, loc, arith::CmpIPredicate::slt, idxValue, zero);
      oob = arith::OrIOp::create(builder_, loc, negative, oob);
    }
    Block *cont = newBlock();
    cf::CondBranchOp::create(builder_, loc, oob, cold, ValueRange{}, cont,
                             ValueRange{});
    openBlock(cont);
  }

  const Type elemTy =
      info.isFloat
          ? (info.bits == 32 ? Type(builder_.getF32Type())
                             : Type(builder_.getF64Type()))
          : Type(builder_.getIntegerType(info.bits));
  Value base = env.count(bufKey) ? env[bufKey] : Value();
  if (!base)
    return bad(Twine("buffer `") + bufName + "` is not in scope");
  Value gep = LLVM::GEPOp::create(builder_, loc,
                                  LLVM::LLVMPointerType::get(builder_.getContext()),
                                  elemTy, base, ValueRange{idxValue});

  // DECISION 0014 §5: a cross buffer's accesses are atomic, monotonic, at the
  // element's own alignment -- one LDR/STR of the element width on the
  // target, never a pair or a multiple, so a reader in another context sees a
  // whole element or none. Nothing else changes: the bounds check and the
  // widening are the same.
  const unsigned crossAlign = info.cross ? info.bits / 8 : 0;
  const LLVM::AtomicOrdering ordering =
      info.cross ? LLVM::AtomicOrdering::monotonic : LLVM::AtomicOrdering::not_atomic;
  if (isLoad) {
    // DECISION 0014 §10 (a): in a verification build the recorder performs
    // the cross-context load itself, inside its critical section, and
    // returns the widened value: the access and its record are one
    // section, so no preempting store can be ordered between them.
    if (info.cross && gen_.options().recordCross && info.isFloat)
      return bad(Twine("buffer `") + bufName + "` is a cross-context float buffer, which the recording lowering does not carry");
    if (info.cross && gen_.options().recordCross) {
      Value width = arith::ConstantOp::create(
          builder_, loc, builder_.getI32IntegerAttr(static_cast<int32_t>(info.bits / 8)));
      Value isSigned = arith::ConstantOp::create(
          builder_, loc, builder_.getI32IntegerAttr(info.isSigned ? 1 : 0));
      Value wide = LLVM::CallOp::create(builder_, loc, TypeRange{builder_.getI64Type()},
                                        StringRef(kRecordLoad), ValueRange{gep, width, isSigned})
                       .getResult();
      gen_.useRecordCross();
      return ExprResult{bodyInteger(loc, wide, info.isSigned), std::move(env), true};
    }
    Value raw = LLVM::LoadOp::create(builder_, loc, elemTy, gep, crossAlign,
                                     /*isVolatile=*/false, /*isNonTemporal=*/false,
                                     /*isInvariant=*/false, /*isInvariantGroup=*/false,
                                     ordering);
    Value wide = raw;
    if (info.isFloat) {
      if (info.bits == 32)
        wide = arith::ExtFOp::create(builder_, loc, builder_.getF64Type(), raw);
    } else {
      wide = bodyInteger(loc, raw, info.isSigned);
    }
    return ExprResult{wide, std::move(env), true};
  }

  // Integer stores check narrowing with code 3, never silently truncate values outside the declared
  // element width. Wording follows the result-boundary narrowing rule.
  Value bodyStored = stored;
  if (!info.isFloat && integerBits() == 32) stored = wideInteger(loc, stored);
  Value narrow = stored;
  if (info.isFloat) {
    narrow = toFloat(loc, stored);
    if (info.bits == 32)
      narrow = arith::TruncFOp::create(builder_, loc, builder_.getF32Type(), narrow);
  } else {
    if (llvm::isa<mlir::Float64Type>(stored.getType()))
      return bad("a Float stored into an integer buffer");
    if (info.bits < 64) {
      Value truncated =
          arith::TruncIOp::create(builder_, loc, builder_.getIntegerType(info.bits),
                                  stored);
      Value back = info.isSigned
                       ? Value(arith::ExtSIOp::create(builder_, loc,
                                                      builder_.getI64Type(),
                                                      truncated))
                       : Value(arith::ExtUIOp::create(builder_, loc,
                                                      builder_.getI64Type(),
                                                      truncated));
      // Name the element type in the diagnostic, matching frozen "%s: value does not fit the %s
      // element of %s", so MCU failures identify the destination type. Decision 0007: narrowing a
      // computed store value is ARITHMETIC; check before storing so the write never occurs on
      // failure.
      Block *cold =
          statusMode()
              ? statusBlock(loc, CoreStatus::Arithmetic, "element store narrowing")
              : trapBlock(loc, 3, stored, Value(),
                          (Twine(method_.name()) +
                           ": value does not fit the " + info.elem +
                           " element of " + bufName).str());
      Value lost = arith::CmpIOp::create(builder_, loc, arith::CmpIPredicate::ne,
                                         back, stored);
      Block *cont = newBlock();
      cf::CondBranchOp::create(builder_, loc, lost, cold, ValueRange{}, cont,
                               ValueRange{});
      openBlock(cont);
      narrow = truncated;
    }
  }
  // DECISION 0014 §10 (a): in a verification build the recorder performs the
  // cross-context store itself, inside its critical section, with the value
  // already checked to fit the element; the record and the store are one.
  if (info.cross && gen_.options().recordCross && info.isFloat)
    return bad(Twine("buffer `") + bufName + "` is a cross-context float buffer, which the recording lowering does not carry");
  if (info.cross && gen_.options().recordCross) {
    Value width = arith::ConstantOp::create(
        builder_, loc, builder_.getI32IntegerAttr(static_cast<int32_t>(info.bits / 8)));
    LLVM::CallOp::create(builder_, loc, TypeRange{}, StringRef(kRecordStore),
                         ValueRange{gep, width, stored});
    gen_.useRecordCross();
    return ExprResult{bodyStored, std::move(env), true};
  }
  LLVM::StoreOp::create(builder_, loc, narrow, gep, crossAlign, /*isVolatile=*/false,
                        /*isNonTemporal=*/false, /*isInvariantGroup=*/false, ordering);
  // Ruby b[i] = v evaluates to v. Value use is outside this subset, but
  // return it directly to keep the environment valid.
  return ExprResult{bodyStored, std::move(env), true};
}

namespace {
unsigned externBits(StringRef t) {
  return llvm::StringSwitch<unsigned>(t)
      .Case("i8", 8).Case("u8", 8).Case("i16", 16).Case("u16", 16)
      .Case("i32", 32).Case("u32", 32).Case("i64", 64).Case("u64", 64)
      .Case("f32", 32).Case("f64", 64)
      .Default(0);
}
bool externSigned(StringRef t) { return !t.starts_with("u"); }
bool externFloat(StringRef t) { return t == "f32" || t == "f64"; }
} // namespace

// Convert one internal-width argument to its declared width. f32 rounds; integer narrowing matches
// result boundaries: trap code 3, or wrap truncation with no trap arm.
Value FuncGen::externNarrow(Location loc, Value v, StringRef pt, size_t idx,
                            const ScalarExternDesc &ext, bool &ok) {
  ok = true;
  if (pt == "f64")
    return v;
  if (pt == "f32")
    return arith::TruncFOp::create(builder_, loc, builder_.getF32Type(), v);
  const unsigned bits = externBits(pt);
  if (bits == 64 && integerBits() == 32) {
    ok = false;
    fail(-1, "int-width-boundary", "an i64 extern is refused when Integer is 32 bits; use i32");
    return {};
  }
  if (bits == integerBits()) {
    if (!externSigned(pt) && gen_.mode() != OverflowMode::Wrap) {
      Value negative = arith::CmpIOp::create(builder_, loc, arith::CmpIPredicate::slt,
                                             v, constant(loc, 0));
      Block *cold = trapBlock(loc, 3, v, Value(),
          (Twine(method_.name()) + ": negative value at unsigned extern boundary").str());
      Block *cont = newBlock();
      cf::CondBranchOp::create(builder_, loc, negative, cold, ValueRange{}, cont, ValueRange{});
      openBlock(cont);
    }
    return v;
  }
  Value t = arith::TruncIOp::create(builder_, loc, builder_.getIntegerType(bits), v);
  if (gen_.mode() == OverflowMode::Wrap)
    return t;
  Value back = externSigned(pt)
                   ? Value(arith::ExtSIOp::create(builder_, loc,
                                                  integerType(), t))
                   : Value(arith::ExtUIOp::create(builder_, loc,
                                                  integerType(), t));
  Block *cold = trapBlock(loc, 3, v, Value(),
                          (Twine(method_.name()) + ": argument " + Twine(idx) +
                           " of " + ext.name + " does not fit " + pt).str());
  Value bad = arith::CmpIOp::create(builder_, loc, arith::CmpIPredicate::ne,
                                    back, v);
  Block *cont = newBlock();
  cf::CondBranchOp::create(builder_, loc, bad, cold, ValueRange{}, cont,
                           ValueRange{});
  openBlock(cont);
  return t;
}

bool FuncGen::isViewShape(const Node *n) const {
  if (!n || n->kind != "CallNode")
    return false;
  std::string name;
  if (!ast::getString(*n, "name", name) || name != "[]")
    return false;
  int64_t recv = -1, argsId = -1;
  if (!ast::getReference(*n, "receiver", recv) || recv < 0)
    return false;
  if (!ast::getReference(*n, "arguments", argsId) || argsId < 0)
    return false;
  const Node *an = node(argsId);
  std::vector<int64_t> args;
  if (!an || !ast::getArray(*an, "arguments", args))
    return false;
  return args.size() == 2;
}

// Use unsigned n <= L followed by off <= L - n. The naive off <= L and off+n <= L accepts
// off=4,n=-4 because the sum is zero, then a negative length becomes a huge unsigned bound.
// Checking n first prevents subtraction underflow; boundary code 6 already refused negative L. The
// second comparison enforces nonnegative off and off+n <= L without addition.
bool FuncGen::bufView(const Node *n, StringRef what, Env &env,
                      std::string &bufName, Value &ptr, Value &len) {
  const Location loc = locOf(n->id);
  int64_t recvId = -1, argsId = -1;
  ast::getReference(*n, "receiver", recvId);
  ast::getReference(*n, "arguments", argsId);
  const Node *recv = node(recvId);
  const Node *an = node(argsId);
  std::vector<int64_t> args;
  if (!recv || !an || !ast::getArray(*an, "arguments", args) || args.size() != 2)
    return fail(n->id, "unsupported-node", "a malformed view");
  if (isViewShape(recv))
    return fail(n->id, "unsupported-node",
                Twine(method_.name()) + ": " + what +
                    " is a view OF A VIEW (`b[a, b][c, d]`). A view is not a "
                    "value (E095, D-11 s2-6).");
  if (recv->kind != "LocalVariableReadNode" ||
      !ast::getString(*recv, "name", bufName) || !buffers_.count(bufName))
    return fail(n->id, "unsupported-node",
                Twine(method_.name()) + ": " + what +
                    " is a two-argument subscript `x[off, n]`, which is a "
                    "buffer VIEW, but `x` is not a buffer parameter of this "
                    "kernel's own boundary (E095, D-11).");
  const BufInfo &info = buffers_.at(bufName);
  if (info.lent)
    return fail(n->id, "unsupported-node",
                Twine(method_.name()) + ": " + what + " takes a view of `" +
                    bufName + "`, a buffer lent to this helper; decision 0044 "
                    "lets a helper index a lent buffer and lend it on, not "
                    "take a view of it");
  if (info.dir != "in")
    return fail(n->id, "unsupported-node",
                Twine(method_.name()) + ": " + what + " takes a view of `" +
                    bufName + "`, which is declared `:" + info.dir +
                    "`. A view is allowed on an `:in` buffer only. Run the "
                    "same source as full Ruby and `" + bufName +
                    "[off, n]` is a COPY (E095, D-11 s2-2).");
  if (info.lenName.empty() || !env.count(info.lenName))
    return fail(n->id, "unsupported-node",
                Twine(method_.name()) + ": " + what + " takes a view of `" +
                    bufName + "`, which was declared without a `:len` after "
                    "it, so there is nothing to check the window against "
                    "(E077 D-5, E095).");

  // Ruby evaluates receiver, offset, then length. Place checks after both arguments, evaluating
  // even extern-call arguments exactly once in source order.
  ExprResult off = expr(node(args[0]), std::move(env));
  if (!off.ok) { env = std::move(off.env); return false; }
  env = std::move(off.env);
  if (!needInt(args[0], off.value, Twine("the offset of a view of `") + bufName + "`"))
    return false;
  ExprResult nv = expr(node(args[1]), std::move(env));
  if (!nv.ok) { env = std::move(nv.env); return false; }
  env = std::move(nv.env);
  if (!needInt(args[1], nv.value, Twine("the length of a view of `") + bufName + "`"))
    return false;

  Value L = env[info.lenName];
  const std::string head = (Twine(method_.name()) + ": " + what +
                            " takes the view `" + bufName + "[off, n]`").str();
  {
    Block *cold = trapBlock(loc, 4, nv.value, L,
                            head + "; n is outside the declared length of " + bufName);
    Value badv = arith::CmpIOp::create(builder_, loc, arith::CmpIPredicate::ugt,
                                       nv.value, L);
    Block *cont = newBlock();
    cf::CondBranchOp::create(builder_, loc, badv, cold, ValueRange{}, cont, ValueRange{});
    openBlock(cont);
  }
  Value lim = arith::SubIOp::create(builder_, loc, L, nv.value);
  {
    Block *cold = trapBlock(loc, 4, off.value, lim,
                            head + "; off + n runs past the declared length of " + bufName);
    Value badv = arith::CmpIOp::create(builder_, loc, arith::CmpIPredicate::ugt,
                                       off.value, lim);
    Block *cont = newBlock();
    cf::CondBranchOp::create(builder_, loc, badv, cold, ValueRange{}, cont, ValueRange{});
    openBlock(cont);
  }
  const Type elemTy =
      info.isFloat ? (info.bits == 32 ? Type(builder_.getF32Type())
                                      : Type(builder_.getF64Type()))
                   : Type(builder_.getIntegerType(info.bits));
  ptr = LLVM::GEPOp::create(builder_, loc,
                            LLVM::LLVMPointerType::get(builder_.getContext()),
                            elemTy, env[bufName], ValueRange{off.value});
  len = nv.value;
  return true;
}

bool FuncGen::literalBytes(const Node *n, Location loc, Value &ptr, Value &count,
                           uint64_t &size) {
  std::string text;
  if (!n || n->kind != "StringNode" || !ast::getString(*n, "content", text)) {
    fail(n ? n->id : -1, "unsupported-node", "a string literal with no readable content");
    return false;
  }
  // The generator interns the bytes as a private constant global (NUL added,
  // as for every literal it emits); the count passed is the literal's own
  // byte length, without that NUL.
  const Type ptrTy = LLVM::LLVMPointerType::get(builder_.getContext());
  ptr = LLVM::AddressOfOp::create(builder_, loc, ptrTy, gen_.cstring(text));
  size = text.size();
  count = wideConstant(loc, static_cast<int64_t>(size));
  return true;
}

ExprResult FuncGen::appExternCall(const Node *n, const ScalarAppExtern &ext,
                                  ArrayRef<int64_t> args, Env env) {
  const Location loc = locOf(n->id);
  const std::string full = ext.module + "." + ext.fn;
  auto bad = [&](const Twine &detail) {
    fail(n->id, "unsupported-node", detail);
    return ExprResult{Value(), std::move(env), false};
  };
  if (args.size() != ext.args.size())
    return bad(Twine("call to ") + full + " with " + Twine(args.size()) +
               " argument(s); the contract declares " + Twine(ext.args.size()));

  // The arguments, each as the guards see it (the i64 value, or the count of
  // a buffer) and as the C ABI receives it.
  struct Arg { Value value; Value count; Value ptr; };
  SmallVector<Arg> seen;
  SmallVector<Value> vals;
  for (size_t i = 0; i < args.size(); ++i) {
    const ScalarAppExternArg &d = ext.args[i];
    const Node *a = node(args[i]);
    const std::string what = ("argument " + Twine(i + 1) + " of " + full).str();
    if (d.isBuffer) {
      Value p, cnt;
      if (a && a->kind == "StringNode") {
        uint64_t size = 0;
        if (!literalBytes(a, loc, p, cnt, size))
          return ExprResult{Value(), std::move(env), false};
      } else {
        std::string bufName;
        if (!a || a->kind != "LocalVariableReadNode" ||
            !ast::getString(*a, "name", bufName) || !buffers_.count(bufName))
          return bad(what + " must be a buffer this function holds, named directly, or a literal");
        auto held = descriptorCount_.find(bufName);
        auto ptrIt = env.find(bufName);
        if (held == descriptorCount_.end() || ptrIt == env.end())
          return bad(Twine("buffer `") + bufName + "` has no descriptor captured here");
        p = ptrIt->second;
        cnt = held->second;
      }
      // A count is unsigned: a 32-bit body's is zero-extended, not sign-extended.
      if (cnt.getType().isInteger(32))
        cnt = arith::ExtUIOp::create(builder_, loc, builder_.getI64Type(), cnt);
      cnt = wideInteger(loc, cnt);
      // The C count is u32. A descriptor count is constant or bounded by the
      // caller's descriptor, both far below 2^32 for any real buffer; a count
      // that does not fit is refused as ARGUMENT rather than truncated.
      Value tooBig = arith::CmpIOp::create(builder_, loc, arith::CmpIPredicate::ugt, cnt,
                                           wideConstant(loc, 0xffffffffLL));
      statusGuard(loc, tooBig, CoreStatus::Argument, "extern count over u32");
      vals.push_back(p);
      vals.push_back(arith::TruncIOp::create(builder_, loc, builder_.getI32Type(), cnt));
      seen.push_back({cnt, cnt, p});
      continue;
    }
    ExprResult v = expr(a, std::move(env));
    if (!v.ok) return ExprResult{Value(), std::move(v.env), false};
    env = std::move(v.env);
    if (!needInt(args[i], v.value, what)) return ExprResult{Value(), std::move(env), false};
    v.value = wideInteger(loc, v.value);
    seen.push_back({v.value, Value(), Value()});
    if (d.domain == "i64") {
      vals.push_back(v.value);
      continue;
    }
    // Narrowing to i32 or u32 is range-checked, as a store into an element of
    // that width is: a value that does not fit is ARITHMETIC, never truncated.
    const bool isSigned = d.domain == "i32";
    Value lo = wideConstant(loc, isSigned ? std::numeric_limits<int32_t>::min() : 0);
    Value hi = wideConstant(loc, isSigned ? std::numeric_limits<int32_t>::max()
                                      : static_cast<int64_t>(std::numeric_limits<uint32_t>::max()));
    Value below = arith::CmpIOp::create(builder_, loc, arith::CmpIPredicate::slt, v.value, lo);
    Value above = arith::CmpIOp::create(builder_, loc, arith::CmpIPredicate::sgt, v.value, hi);
    statusGuard(loc, arith::OrIOp::create(builder_, loc, below, above), CoreStatus::Arithmetic, "extern argument narrowing");
    vals.push_back(arith::TruncIOp::create(builder_, loc, builder_.getI32Type(), v.value));
  }

  // THE GUARDS, in declared order, before the call. A false guard fails the
  // entry with its status and the extern is not called; nothing before the
  // call is undone (0007). Constant operands fold to an unconditional branch
  // at this site and nowhere else, so a call on an untaken path never fails
  // the entry and never refuses the build.
  auto operand = [&](StringRef s) -> Value {
    int64_t v = 0;
    if (!s.getAsInteger(10, v)) return wideConstant(loc, v);
    const bool len = s.consume_front("len(");
    if (len) s.consume_back(")");
    for (size_t i = 0; i < ext.args.size(); ++i)
      if (ext.args[i].name == s) return len ? seen[i].count : seen[i].value;
    return Value();
  };
  for (const ScalarAppGuard &g : ext.guards) {
    Value l = operand(g.lhs), r = operand(g.rhs);
    if (!l || !r)
      return bad(Twine("guard `") + g.lhs + " " + g.op + " " + g.rhs +
                 "` of " + full + " names an operand this call cannot supply");
    // A guard's operands are the call's values, integers all; `len()` is a
    // count, compared as an integer too.
    arith::CmpIPredicate holds =
        g.op == "<" ? arith::CmpIPredicate::slt : g.op == "<=" ? arith::CmpIPredicate::sle
        : g.op == ">" ? arith::CmpIPredicate::sgt : g.op == ">=" ? arith::CmpIPredicate::sge
        : g.op == "==" ? arith::CmpIPredicate::eq : arith::CmpIPredicate::ne;
    Value ok = arith::CmpIOp::create(builder_, loc, holds, l, r);
    Value one = arith::ConstantOp::create(builder_, loc, builder_.getI1Type(),
                                          builder_.getBoolAttr(true));
    Value failed = arith::XOrIOp::create(builder_, loc, ok, one);
    statusGuard(loc, failed, g.status == "bounds" ? CoreStatus::Bounds : CoreStatus::Argument,
                "extern guard " + g.lhs + " " + g.op + " " + g.rhs);
  }

  gen_.useAppExtern(ext);
  if (ext.returns.empty()) {
    LLVM::CallOp::create(builder_, loc, TypeRange{}, StringRef(ext.symbol), vals);
    // No value. The checker refused every read of a void extern's result, so
    // this stands in statement position only; zero keeps the environment
    // total.
    return ExprResult{constant(loc, 0), std::move(env), true};
  }
  const Type retTy = builder_.getIntegerType(ext.returns == "i64" ? 64 : 32);
  auto call = LLVM::CallOp::create(builder_, loc, TypeRange{retTy}, StringRef(ext.symbol), vals);
  Value res = call.getResult();
  res = bodyInteger(loc, res, ext.returns != "u32");
  return ExprResult{res, std::move(env), true};
}

ExprResult FuncGen::externCall(const Node *n, const ScalarExternDesc &ext,
                               ArrayRef<int64_t> args, Env env) {
  const Location loc = locOf(n->id);
  auto bad = [&](const Twine &detail) {
    fail(n->id, "unsupported-node", detail);
    return ExprResult{Value(), std::move(env), false};
  };
  if (integerBits() == 32 && ext.returns == "i64")
    return bad(Twine(method_.name()) +
               ": int-width-boundary: an i64 extern return is refused when Integer is 32 bits; use i32");
  if (args.size() != ext.params.size())
    return bad(Twine(method_.name()) + ": call to platform extern '" + ext.name +
               "' with " + Twine(args.size()) +
               " argument(s); the profile declares " + Twine(ext.params.size()) +
               " parameter(s). The profile is the boundary contract (E081).");

  SmallVector<Value> vals;
  SmallVector<Type> argTys;
  // Map each len argument index to the declared lengths of buffers it sizes.
  std::map<size_t, SmallVector<std::pair<std::string, Value>>> runBufs;
  for (size_t i = 0; i < args.size(); ++i) {
    const ScalarExternDesc::Param &pt = ext.params[i];
    const std::string what =
        ("argument " + Twine(i + 1) + " of platform extern '" + ext.name + "'").str();
    if (pt.kind == ScalarExternDesc::Param::Kind::Buffer) {
      // Historically only kernel boundary buffers could be passed: declarations supply the length
      // to check. Argument-local buf[off,n] views are allowed in the same position but are not
      // first-class values.
      const Node *a = node(args[i]);
      std::string bufName;
      Value viewPtr, viewLen;
      if (a && a->kind == "CallNode" && isViewShape(a)) {
        if (!bufView(a, what, env, bufName, viewPtr, viewLen))
          return ExprResult{Value(), std::move(env), false};
      } else if (!a || a->kind != "LocalVariableReadNode" ||
                 !ast::getString(*a, "name", bufName) || !buffers_.count(bufName)) {
        return bad(Twine(method_.name()) + ": " + what +
                   " is not a buffer parameter of this kernel's own boundary, "
                   "but the profile declares it a buffer. Only a buffer "
                   "parameter of this kernel's own boundary can be passed "
                   "where the extern declares a buffer (E083).");
      }
      const BufInfo &info = buffers_.at(bufName);
      if (info.lent)
        return bad(Twine(method_.name()) + ": " + what + " passes `" + bufName +
                   "`, a buffer lent to this helper; decision 0044 lets a "
                   "helper index a lent buffer and lend it on to another "
                   "helper, not pass it to a platform extern");
      std::string elem = info.isFloat ? (info.bits == 32 ? "f32" : "f64")
                                      : ((info.isSigned ? "i" : "u") +
                                         std::to_string(info.bits));
      if (elem != pt.elem)
        return bad(Twine(method_.name()) + ": " + what + " passes `" + bufName +
                   "`, a [:" + elem + "_buf, :" + info.dir +
                   "], where the profile declares [:" + pt.elem + "_buf, :" +
                   pt.dir + "]. The element type is the pointer's meaning; "
                   "there is no coercion at this boundary (E077/E083).");
      const bool dirOk = pt.dir == "in"    ? (info.dir == "in" || info.dir == "inout")
                         : pt.dir == "out" ? (info.dir == "out" || info.dir == "inout")
                                           : info.dir == "inout";
      if (!dirOk)
        return bad(Twine(method_.name()) + ": " + what + " passes `" + bufName +
                   "`, a [:" + elem + "_buf, :" + info.dir +
                   "], where the profile declares [:" + pt.elem + "_buf, :" +
                   pt.dir + "]. The direction contract crosses the boundary "
                   "with the pointer (E083, D-5's compile-time half).");
      if (info.lenName.empty() || !env.count(info.lenName))
        return bad(Twine(method_.name()) + ": " + what + " passes `" + bufName +
                   "`, which was declared without a `:len` after it, so the "
                   "call-site length check has nothing to compare against "
                   "(E077 D-5, E083).");
      // A view uses its own length for the buffer run, not the original declaration length.
      if (pt.lenIndex >= 0)
        runBufs[static_cast<size_t>(pt.lenIndex)].push_back(
            {bufName, viewLen ? viewLen : env[info.lenName]});
      vals.push_back(viewPtr ? viewPtr : env[bufName]);
      argTys.push_back(LLVM::LLVMPointerType::get(builder_.getContext()));
      continue;
    }

    ExprResult v = expr(node(args[i]), std::move(env));
    if (!v.ok)
      return ExprResult{Value(), std::move(v.env), false};
    env = std::move(v.env);
    if (!needNumeric(args[i], v.value, what))
      return ExprResult{Value(), std::move(env), false};

    if (pt.kind == ScalarExternDesc::Param::Kind::Len) {
      if (llvm::isa<mlir::Float64Type>(v.value.getType()))
        return bad(Twine(method_.name()) + ": " + what +
                   " is a Float, but the profile declares it `len` -- the "
                   "length of the buffer(s) before it, an Integer (E083).");
      // Passed length must not exceed any buffer length in this len run. One unsigned comparison
      // checks both ends, since negatives become huge unsigned values.
      for (auto &bv : runBufs[i]) {
        Block *cold = trapBlock(loc, 4, v.value, bv.second,
                                (Twine(method_.name()) + ": length argument " +
                                 Twine(i + 1) + " of " + ext.name +
                                 " exceeds the declared length of " + bv.first).str());
        Value over = arith::CmpIOp::create(builder_, loc,
                                           arith::CmpIPredicate::ugt, v.value,
                                           bv.second);
        Block *cont = newBlock();
        cf::CondBranchOp::create(builder_, loc, over, cold, ValueRange{}, cont,
                                 ValueRange{});
        openBlock(cont);
      }
      vals.push_back(integerBits() == 32 ? v.value
          : Value(arith::TruncIOp::create(builder_, loc, builder_.getI32Type(), v.value)));
      argTys.push_back(builder_.getI32Type());
      continue;
    }

    const bool wantFloat = externFloat(pt.elem);
    const bool isFloat = llvm::isa<mlir::Float64Type>(v.value.getType());
    if (wantFloat != isFloat)
      return bad(Twine(method_.name()) + ": " + what + " is " +
                 (isFloat ? "a Float" : "an Integer") +
                 ", but the profile declares it :" + pt.elem +
                 ". The declaration fixes the boundary WIDTH; it cannot change "
                 "the value's kind (E077/E081).");
    bool ok = true;
    Value narrowed = externNarrow(loc, v.value, pt.elem, i + 1, ext, ok);
    if (!ok)
      return ExprResult{Value(), std::move(env), false};
    vals.push_back(narrowed);
    argTys.push_back(externFloat(pt.elem)
                         ? (pt.elem == "f32" ? Type(builder_.getF32Type())
                                             : Type(builder_.getF64Type()))
                         : Type(builder_.getIntegerType(externBits(pt.elem))));
  }

  const Type retTy = externFloat(ext.returns)
                         ? (ext.returns == "f32" ? Type(builder_.getF32Type())
                                                 : Type(builder_.getF64Type()))
                         : Type(builder_.getIntegerType(externBits(ext.returns)));
  gen_.useExtern(ext);
  auto call = LLVM::CallOp::create(builder_, loc, TypeRange{retTy},
                                   StringRef(ext.symbol), vals);
  Value res = call.getResult();
  // Widen the result to internal width; widening is exact, with no check/policy.
  if (ext.returns == "f32")
    res = arith::ExtFOp::create(builder_, loc, builder_.getF64Type(), res);
  else if (!externFloat(ext.returns))
    res = bodyInteger(loc, res, externSigned(ext.returns));
  return ExprResult{res, std::move(env), true};
}

/// E161 cp3C: the ONE-TO-ONE, TOTAL map from this importer's OverflowMode to
/// the Spinel dialect's overflow policy.  Both enums are closed and both have
/// exactly the three values, so the map is a `switch` with **no `default`**:
/// a value added on either side stops compiling here rather than being folded
/// into a neighbour.  There is no "default policy" and no absorption of an
/// unknown mode — `importScalarProgram` already refuses a mode outside the
/// enum on the diagnostic channel, one layer up.
mlir::spinel::OverflowPolicy checkedPolicyOf(OverflowMode mode) {
  switch (mode) {
  case OverflowMode::Raise:
    return mlir::spinel::OverflowPolicy::Raise;
  case OverflowMode::Wrap:
    return mlir::spinel::OverflowPolicy::Wrap;
  case OverflowMode::None:
    return mlir::spinel::OverflowPolicy::None;
  case OverflowMode::Trap:
    return mlir::spinel::OverflowPolicy::Trap;
  }
  llvm_unreachable("OverflowMode outside {Raise, Wrap, None, Trap}");
}

/// frozen: binop().  `+ - *` are the mode's whole story: `Raise` tests the nil
/// sentinel and then the checked intrinsic, while `Wrap` and `None` alike carry
/// no overflow flag (defined two's-complement wrap).  `/` and `%` keep
/// Ruby's FLOORED semantics in every mode, spelled as the same correction
/// sequence sp_idiv / sp_imod use, and keep the nil and zero guards in the two
/// checked modes — `Wrap` folds the OVERFLOW check, not the division guards.
///
/// Under the E161 cp3C opt-in the `+ - *` arm — and ONLY that arm — is
/// replaced by a single `spinel.checked_*` carrying the policy.  Everything
/// else in this function is untouched: `/` and `%` keep their floor correction
/// and their guards in the standard dialects, and the comparisons stay
/// `arith.cmpi`.  The nil-sentinel guard is emitted BEFORE the checked op
/// under `Raise`, exactly where E160 emits it, because a Spinel checked op
/// carries the overflow policy and nothing else (the sentinel is a nil that
/// reached an Integer slot, which is a different failure).
ExprResult FuncGen::binop(int64_t nodeId, StringRef op, Value a, Value b,
                          Env env) {
  const Location loc = locOf(nodeId);
  auto done = [&](Value v) { return ExprResult{v, std::move(env), true}; };

  // If either operand is float, use floating arithmetic and sitofp for the integer, matching frozen
  // FuncGen. Do not check float overflow: float_no_trap expects +inf, not a trap.
  if (gen_.options().freestandingTypes &&
      (llvm::isa<mlir::Float64Type>(a.getType()) ||
       llvm::isa<mlir::Float64Type>(b.getType()))) {
    if (op == "%") {
      // Frozen wording verbatim (c01_fmod).
      fail(nodeId, "unsupported-node",
           "Float#% is floored modulo, which needs fmod from libm, and the "
           "profile says `libm: none` (P003 Phase 6 is where Math.* and "
           "friends get a libm)");
      return ExprResult{Value(), std::move(env), false};
    }
    Value x = toFloat(loc, a);
    Value y = toFloat(loc, b);
    if (op == "+") return done(arith::AddFOp::create(builder_, loc, x, y));
    if (op == "-") return done(arith::SubFOp::create(builder_, loc, x, y));
    if (op == "*") return done(arith::MulFOp::create(builder_, loc, x, y));
    if (op == "/") {
      // No zero-divisor guard: float_div0_no_trap expects NaN from 0.0 / 0, not a trap.
      return done(arith::DivFOp::create(builder_, loc, x, y));
    }
    // Use ordered comparison predicates, matching frozen Python.
    auto pred = llvm::StringSwitch<std::optional<arith::CmpFPredicate>>(op)
                    .Case("<", arith::CmpFPredicate::OLT)
                    .Case("<=", arith::CmpFPredicate::OLE)
                    .Case(">", arith::CmpFPredicate::OGT)
                    .Case(">=", arith::CmpFPredicate::OGE)
                    .Case("==", arith::CmpFPredicate::OEQ)
                    .Case("!=", arith::CmpFPredicate::ONE)
                    .Default(std::nullopt);
    if (pred)
      return done(arith::CmpFOp::create(builder_, loc, *pred, x, y));
    fail(nodeId, "unsupported-node",
         Twine("operator '") + op + "' on a Float is outside the subset");
    return ExprResult{Value(), std::move(env), false};
  }

  if (op == "+" || op == "-" || op == "*") {
    if (gen_.emitCheckedArithmetic()) {
      // `Raise` keeps the sentinel test in front, as E160 does.  `Wrap` and
      // `None` have none today and gain none here.
      if (gen_.mode() == OverflowMode::Raise)
        nilCheck(loc, a, b, op);
      const mlir::spinel::OverflowPolicy policy =
          checkedPolicyOf(gen_.mode());
      const Type i64 = integerType();
      // Dispatch on the operator already resolved by the walk, not mnemonic strings or target
      // names. Add detail only for trap, retaining the full frozen message and Ruby method name
      // unavailable to lowering. Hosted raise has no such attribute, preserving earlier output
      // bytes.
      const mlir::StringAttr detail =
          gen_.mode() == OverflowMode::Trap
              ? builder_.getStringAttr(trapDetail(op))
              : mlir::StringAttr();
      if (op == "+")
        return done(mlir::spinel::CheckedAddOp::create(builder_, loc, i64, a, b,
                                                       policy, detail));
      if (op == "-")
        return done(mlir::spinel::CheckedSubOp::create(builder_, loc, i64, a, b,
                                                       policy, detail));
      return done(mlir::spinel::CheckedMulOp::create(builder_, loc, i64, a, b,
                                                     policy, detail));
    }
    if (statusMode() || abortMode()) {
      // No sentinel test in front of it: there is no nil at this boundary to
      // test for. The overflow check is the whole guard, and its cold arm
      // returns ARITHMETIC (status) or calls the failure hook (abort) instead
      // of raising.
      return done(overflowOp(loc, op, a, b));
    }
    if (gen_.mode() == OverflowMode::Raise) {
      nilCheck(loc, a, b, op);
      return done(overflowOp(loc, op, a, b));
    }
    // F-185: `Wrap` and `None` are both DEFINED signed two's-complement
    // wrapping, so neither carries an overflow flag.  An `nsw` would licence
    // the optimiser to assume the overflow never happens, which is the
    // opposite of what `overflow: :wrap` asks for.
    const arith::IntegerOverflowFlags flags = arith::IntegerOverflowFlags::none;
    if (op == "+")
      return done(arith::AddIOp::create(builder_, loc, a, b, flags));
    if (op == "-")
      return done(arith::SubIOp::create(builder_, loc, a, b, flags));
    return done(arith::MulIOp::create(builder_, loc, a, b, flags));
  }

  if (op == "/" || op == "%") {
    // Ruby's Integer#/ floors and Integer#% takes the sign of the divisor;
    // LLVM's sdiv/srem truncate.  The correction is "if the remainder is
    // non-zero and its sign differs from the divisor's, step one toward
    // negative infinity" — the sequence spinel_rt.h's sp_idiv / sp_imod spell
    // in C.  `/` computes the quotient FIRST: the order of the two divisions
    // is not observable in the result but it is in the op list.
    divGuard(loc, a, b, op);
    // Decision 0007: `INT64_MIN / -1` is ARITHMETIC, and `INT64_MIN % -1` is
    // Ruby's zero. Measured first, and the reason both need saying: the two
    // are the SAME machine instruction on x86-64, and `idiv` raises #DE for
    // the pair whichever half of its result you wanted. A guard on `/` alone
    // left `%` killing the process with SIGFPE.
    Value divisor = b;
    Value wrappedDivision;
    if (statusMode() || abortMode() || integerBits() == 32) {
      Value isNegOne = arith::CmpIOp::create(builder_, loc,
                                            arith::CmpIPredicate::eq, b,
                                            constant(loc, -1));
      if (op == "/") {
        // The quotient `a / -1` is `-a`, which is outside i64 for exactly one
        // `a`. Refusing the pair is refusing that one case, not the operator.
        Value isMin = arith::CmpIOp::create(
            builder_, loc, arith::CmpIPredicate::eq, a,
            constant(loc, minInteger()));
        Value pair = arith::AndIOp::create(builder_, loc, isMin, isNegOne);
        if (abortMode())
          coreFailGuard(loc, pair, CoreFailKind::Overflow, "/");
        else if (statusMode())
          statusGuard(loc, pair, CoreStatus::Arithmetic, "minimum / -1");
        else if (gen_.mode() == OverflowMode::Wrap) {
          divisor = arith::SelectOp::create(builder_, loc, pair, constant(loc, 1), b);
          wrappedDivision = pair;
        } else {
          Block *cold = trapBlock(loc, 1, a, b, trapDetail("/"));
          Block *cont = newBlock();
          cf::CondBranchOp::create(builder_, loc, pair, cold, ValueRange{}, cont, ValueRange{});
          openBlock(cont);
        }
      } else {
        // `a % -1` is 0 for every `a` -- -1 divides everything -- so the
        // divisor is replaced by 1, whose remainder is also 0 for every `a`.
        // That is the special case the decision asks for, spelled as a value
        // rather than a branch: the instruction that would fault is never
        // issued with -1, and no successful input is refused.
        divisor = arith::SelectOp::create(builder_, loc, isNegOne,
                                          constant(loc, 1), b);
      }
    }
    Value quotient;
    if (op == "/") {
      quotient = arith::DivSIOp::create(builder_, loc, a, divisor);
      if (wrappedDivision)
        quotient = arith::SelectOp::create(builder_, loc, wrappedDivision, a, quotient);
    }
    Value remainder = arith::RemSIOp::create(builder_, loc, a, divisor);
    Value zero = constant(loc, 0);
    Value nonZero = arith::CmpIOp::create(
        builder_, loc, arith::CmpIPredicate::ne, remainder, zero);
    Value signs = arith::XOrIOp::create(builder_, loc, remainder, b);
    Value differ = arith::CmpIOp::create(builder_, loc,
                                         arith::CmpIPredicate::slt, signs, zero);
    Value adjust = arith::AndIOp::create(builder_, loc, nonZero, differ);
    if (op == "%") {
      Value wrapped = arith::AddIOp::create(builder_, loc, remainder, b);
      return done(
          arith::SelectOp::create(builder_, loc, adjust, wrapped, remainder));
    }
    Value one = constant(loc, 1);
    Value lowered = arith::SubIOp::create(builder_, loc, quotient, one);
    return done(
        arith::SelectOp::create(builder_, loc, adjust, lowered, quotient));
  }

  // Decision 0007 task 2 widened the admitted arithmetic for the status ABI.
  // Decision 0042 adds the native `--core` route and freestanding: `&`, `|`
  // and `^` in stage 1, and the shifts in stage 2, which each mode's own
  // failure delivery (or its wrap) completes.
  if (statusMode() || bitOperators()) {
    if (op == "<<" || op == ">>")
      return done(shiftOp(loc, op, a, b));
    if (op == "**")
      return done(powOp(loc, a, b));
    // `&`, `|`, `^` are exact in two's complement for every i64 pair -- Ruby
    // computes them on infinite-precision two's complement and the low 64 bits
    // agree -- so there is nothing to check and nothing to report. An explicit
    // mask such as `v & 0xffffffff` is this operation, not a wrap switch.
    if (op == "&")
      return done(arith::AndIOp::create(builder_, loc, a, b));
    if (op == "|")
      return done(arith::OrIOp::create(builder_, loc, a, b));
    if (op == "^")
      return done(arith::XOrIOp::create(builder_, loc, a, b));
  }

  arith::CmpIPredicate predicate = arith::CmpIPredicate::eq;
  if (op == "<")
    predicate = arith::CmpIPredicate::slt;
  else if (op == "<=")
    predicate = arith::CmpIPredicate::sle;
  else if (op == ">")
    predicate = arith::CmpIPredicate::sgt;
  else if (op == ">=")
    predicate = arith::CmpIPredicate::sge;
  else if (op == "==")
    predicate = arith::CmpIPredicate::eq;
  else if (op == "!=")
    predicate = arith::CmpIPredicate::ne;
  else {
    fail(nodeId, "unsupported-node",
         Twine("operator '") + op + "' is not in the subset");
    return ExprResult{Value(), std::move(env), false};
  }
  return done(arith::CmpIOp::create(builder_, loc, predicate, a, b));
}

// ---------------------------------------------------------------------------
// ModuleGen
// ---------------------------------------------------------------------------

/// frozen: preamble().  `llvm.func` rather than `func.func private` because
/// the noreturn/cold attributes are what keep the raise arms out of the hot
/// path, and only the LLVM dialect carries them (`passthrough`).  Note the
/// ASYMMETRY, which is the frozen generator's and not an oversight of ours:
/// `sp_raise_cls` is `noreturn, cold`, `sp_raise_nil_int_op` is `noreturn`
/// alone — the sentinel arm is already weighted at its branch, so marking the
/// callee cold as well would say the same thing twice.
void ModuleGen::emitPreamble(Operation *before) {
  if (order_.empty() && !usesRaiseCls_ && !usesRaiseNilOp_ && !usesRecordCross_ &&
      !usesCoreFail_ &&
      externOrder_.empty() && appExternOrder_.empty())
    return;
  OpBuilder builder(&context_);
  // Everything created from here lands immediately before the first
  // `func.func`, in creation order, because the insertion point does not move.
  builder.setInsertionPoint(before);
  const Location loc = builder.getUnknownLoc();
  const Type i8 = builder.getIntegerType(8);

  for (const std::string *text : order_) {
    // NUL-terminated: these are plain C string literals, exactly as the macro
    // passes them, and sp_raise_cls copies the message onto the string heap
    // itself (frozen raise_cls_block, spinel_rt.h:6712).
    std::string bytes = *text;
    bytes.push_back('\0');
    LLVM::GlobalOp::create(builder, loc, LLVM::LLVMArrayType::get(i8,
                                                                 bytes.size()),
                           /*isConstant=*/true, LLVM::Linkage::Private,
                           strings_[*text], builder.getStringAttr(bytes));
  }

  const Type ptr = LLVM::LLVMPointerType::get(&context_);
  const Type none = LLVM::LLVMVoidType::get(&context_);
  const Type i64 = builder.getI64Type();

  // Declare each called platform extern once per module. Profile owns the symbol; runtime
  // integration defines it (west links a C wrapper, wasm-ld makes an import).
  auto externTy = [&](StringRef t) -> Type {
    if (t == "f32") return builder.getF32Type();
    if (t == "f64") return builder.getF64Type();
    return builder.getIntegerType(externBits(t));
  };
  for (const std::string &sym : externOrder_) {
    const ScalarExternDesc &e = *externUses_.at(sym);
    SmallVector<Type> ins;
    for (const ScalarExternDesc::Param &p : e.params) {
      if (p.kind == ScalarExternDesc::Param::Kind::Buffer)
        ins.push_back(ptr);
      else if (p.kind == ScalarExternDesc::Param::Kind::Len)
        ins.push_back(builder.getI32Type());
      else
        ins.push_back(externTy(p.elem));
    }
    LLVM::LLVMFuncOp::create(builder, loc, sym,
                             LLVM::LLVMFunctionType::get(externTy(e.returns), ins));
  }
  // DECISION 0014: the application externs, one declaration each, with the C
  // ABI of the plan: a scalar is i32/u32/i64 by its domain, a buffer is a
  // pointer followed by a u32 count, and a void extern returns nothing.
  for (const std::string &sym : appExternOrder_) {
    const ScalarAppExtern &e = *appExternUses_.at(sym);
    SmallVector<Type> ins;
    for (const ScalarAppExternArg &a : e.args) {
      if (a.isBuffer) {
        ins.push_back(ptr);
        ins.push_back(builder.getI32Type());
      } else {
        ins.push_back(builder.getIntegerType(a.domain == "i64" ? 64 : 32));
      }
    }
    const Type ret = e.returns.empty()
                         ? none
                         : Type(builder.getIntegerType(e.returns == "i64" ? 64 : 32));
    LLVM::LLVMFuncOp::create(builder, loc, sym, LLVM::LLVMFunctionType::get(ret, ins));
  }
  auto passthrough = [&](ArrayRef<StringRef> names) {
    SmallVector<Attribute> attrs;
    for (StringRef name : names)
      attrs.push_back(builder.getStringAttr(name));
    return NamedAttribute(builder.getStringAttr("passthrough"),
                          builder.getArrayAttr(attrs));
  };
  if (usesRecordCross_) {
    // 0014 §10: `int64_t spc_record_load(const void *addr, uint32_t width, uint32_t
    // is_signed)` performs and records the load; `void spc_record_store(const
    // void *addr, uint32_t width, int64_t value)` the store. The glue's
    // recorder defines both.
    LLVM::LLVMFuncOp::create(builder, loc, StringRef(kRecordLoad),
                             LLVM::LLVMFunctionType::get(i64, {ptr, builder.getI32Type(), builder.getI32Type()}));
    LLVM::LLVMFuncOp::create(builder, loc, StringRef(kRecordStore),
                             LLVM::LLVMFunctionType::get(none, {ptr, builder.getI32Type(), i64}));
  }
  if (usesRaiseCls_) {
    const NamedAttribute attr = passthrough({"noreturn", "cold"});
    LLVM::LLVMFuncOp::create(builder, loc, kRaiseCls,
                             LLVM::LLVMFunctionType::get(none, {ptr, ptr}),
                             LLVM::Linkage::External, /*dsoLocal=*/false,
                             LLVM::CConv::C, /*comdat=*/SymbolRefAttr(), attr);
  }
  if (usesFailureSite_) {
    // The failure-site global, defined here and zero until a failure stores
    // its site; external, so the caller can read it after a failed call.
    LLVM::GlobalOp::create(builder, loc, builder.getI32Type(), /*isConstant=*/false,
                           LLVM::Linkage::External, options_.failureSiteSymbol,
                           builder.getI32IntegerAttr(0));
  }
  if (usesCoreFail_) {
    // Decision 0015: `void spc_core_fail(int32_t kind, int32_t op)`, noreturn.
    // Not `nounwind`: the hosted program defines it, and what it does to end
    // the program is the hosted program's business.
    const NamedAttribute attr = passthrough({"noreturn", "cold"});
    const Type i32 = builder.getI32Type();
    LLVM::LLVMFuncOp::create(builder, loc, StringRef(kCoreFailHook),
                             LLVM::LLVMFunctionType::get(none, {i32, i32}),
                             LLVM::Linkage::External, /*dsoLocal=*/false,
                             LLVM::CConv::C, /*comdat=*/SymbolRefAttr(), attr);
  }
  if (usesRaiseNilOp_) {
    const NamedAttribute attr = passthrough({"noreturn"});
    LLVM::LLVMFuncOp::create(builder, loc, kRaiseNilOp,
                             LLVM::LLVMFunctionType::get(none,
                                                         {i64, i64, ptr}),
                             LLVM::Linkage::External, /*dsoLocal=*/false,
                             LLVM::CConv::C, /*comdat=*/SymbolRefAttr(), attr);
  }
  // Profile trap hook has void(i32 code,i64 a,i64 b,const char *detail), noreturn. Use trapHook_,
  // not a literal name. Build func.func as boundary wrappers, prototype importer and lowering also
  // do; llvm.func here would duplicate the symbol under another op kind. This was observed with
  // trap policy, divzero guarding and boundary narrowing combined. Reuse an existing symbol of any
  // kind; before belongs to the module body, whose parent module supplies lookup.
  auto ownerModule = before->getParentOfType<ModuleOp>();
  if (usesTrapHook_ && !(ownerModule && ownerModule.lookupSymbol(trapHook_))) {
    auto ty = builder.getFunctionType({builder.getI32Type(), i64, i64, ptr}, {});
    auto fn = func::FuncOp::create(builder, loc, trapHook_, ty);
    fn.setPrivate();
    // Also declare nounwind: the freestanding hook neither returns nor unwinds, so noreturn/cold
    // omit a known property. Frozen Python supplied all three. Do not add it to hosted
    // sp_raise_cls, which raises and unwinds.
    fn->setAttr("passthrough", builder.getArrayAttr(
                                   {builder.getStringAttr("noreturn"),
                                    builder.getStringAttr("cold"),
                                    builder.getStringAttr("nounwind")}));
  }
}

OwningOpRef<ModuleOp> ModuleGen::run() {
  // The dialects the int-only slice can emit.  Loading them here rather than
  // asking the caller to keeps the entry point total: a caller that forgot one
  // would get an assertion deep inside a builder, not a diagnostic.  The LLVM
  // dialect joins the other three in cp3: `None` never reaches it, but the
  // decision is per PROGRAM and not per module, so refusing to load it until
  // the first cold arm appears would only move the assertion.
  context_.loadDialect<func::FuncDialect, arith::ArithDialect,
                       cf::ControlFlowDialect, LLVM::LLVMDialect>();
  // E161 cp3C: the Spinel dialect is loaded **only under the opt-in**.  The
  // default path must not gain a loaded dialect it never emits into: keeping
  // the load conditional makes "the default path is untouched" a property of
  // the CONTEXT and not only of the printed bytes, and the byte equality of
  // all 30 default-path artefacts is measured either way.
  if (emitChecked_)
    context_.loadDialect<mlir::spinel::SpinelDialect>();
  OpBuilder builder(&context_);
  OwningOpRef<ModuleOp> module = ModuleOp::create(builder.getUnknownLoc());

  const Type i64 = builder.getI64Type();
  builder.setInsertionPointToEnd(module->getBody());

  // Every function is DECLARED before any body is walked, so a call can name
  // its callee whatever the closure order is (self-recursion needs it too).
  // The order is program.methods() — the selector's FIFO closure order, which
  // selection.test pins against the frozen generator's own `order`.
  for (const ScalarMethod &method : program_.methods()) {
    // Build signatures from contract types. Without freestandingTypes, typeOf always returns i64
    // and default output remains byte-identical.
    SmallVector<Type> inputs;
    for (auto indexed : llvm::enumerate(method.parameters())) {
      const ScalarParameter &p = indexed.value();
      // A declared buffer is an address the CALLER owns. It is a pointer here
      // and nothing else: the count that bounds it is a separate parameter,
      // and no arithmetic on the address is in this subset.
      if (mode_ == OverflowMode::Status &&
          method.name() == options_.status.entry &&
          options_.status.buffer(p.name())) {
        inputs.push_back(LLVM::LLVMPointerType::get(&context_));
        continue;
      }
      // Physical descriptor counts retain their u64 carrier. A source-level
      // read uses the body width only after wrapper validation; the captured
      // descriptor itself never passes through that truncation.
      if (mode_ == OverflowMode::Status && method.name() == options_.status.entry) {
        bool isCount = false;
        for (const auto &b : options_.status.buffers)
          if (!b.constCount && b.countName == p.name()) isCount = true;
        if (isCount) {
          inputs.push_back(IntegerType::get(&context_, 64));
          continue;
        }
      }
      // DECISION 0008 TASK 3: a BORROWED buffer, in a helper that has no
      // contract. The pointer comes from the caller and so does the bound, as
      // a HIDDEN u64 immediately after it. Hidden because it is not a Ruby
      // parameter: the source's own scalar arguments stay exactly where they
      // are, and a helper cannot name this value, which is the point -- a
      // bound a body can name is a bound a body can move.
      if (contextSlot(method.name(), indexed.index()) >= 0) {
        // read from the entry's buffer context, passed once below
        usesContext_.insert(method.name().str());
        contextSlots_.insert(static_cast<size_t>(contextSlot(method.name(), indexed.index())));
        continue;
      }
      if (mode_ == OverflowMode::Status &&
          options_.borrow(method.name(), indexed.index())) {
        inputs.push_back(LLVM::LLVMPointerType::get(&context_));
        // In a 32-bit body the hidden bound is 32 bits too: every count it
        // carries came from a wrapper that refused a nonzero upper word.
        inputs.push_back(IntegerType::get(&context_, options_.countBits() == 32 ? 32 : 64));
        continue;
      }
      // DECISION 0044 (L1): a buffer lent to a freestanding helper is the
      // address and then the length its caller holds, at the body's Integer
      // width. The length is not a Ruby parameter, so the body cannot name it.
      if (p.lent()) {
        inputs.push_back(LLVM::LLVMPointerType::get(&context_));
        inputs.push_back(integerType());
        continue;
      }
      inputs.push_back(typeOf(p.type()));
    }
    Type ret = typeOf(method.returnType());
    (void)i64;
    // Decision 0007 task 2: in the status ABI every function in the closure --
    // the entry and its helpers alike -- takes a trailing result pointer and
    // returns an i32 status.  Uniform on purpose: a helper that returned its
    // value directly would have nowhere to report a failure, so the caller
    // would have to prove the helper cannot fail, and that proof does not
    // exist for arithmetic.
    // the buffer context, once, before the result pointer
    if (usesContext(method.name()))
      inputs.push_back(LLVM::LLVMPointerType::get(&context_));
    // DECISION 0041 STAGE 2: the data stack, once, before the result pointer
    if (takesScratch(method.name()))
      inputs.push_back(LLVM::LLVMPointerType::get(&context_));
    if (mode_ == OverflowMode::Status) {
      inputs.push_back(LLVM::LLVMPointerType::get(&context_));
      ret = IntegerType::get(&context_, 32);
    }
    auto loc = FileLineColLoc::get(StringAttr::get(&context_, fileOf(method.defNode())),
                                   static_cast<unsigned>(method.line()), 0);
    functions_[method.name().str()] =
        func::FuncOp::create(builder, loc, (Twine("sp_") + method.name()).str(),
                             builder.getFunctionType(inputs, ret));
  }

  for (const ScalarMethod &method : program_.methods()) {
    FuncGen body(*this, method, functions_[method.name().str()]);
    if (!body.run())
      return {};
  }

  // frozen: build() — the preamble is assembled from what the closure actually
  // interned and actually called, so it can only be written once every body
  // is.  It PRINTS first, which is why it is spliced in ahead of the first
  // function rather than appended.
  if (!program_.methods().empty())
    emitPreamble(functions_[program_.methods().front().name().str()]);
  return module;
}

} // namespace

OwningOpRef<ModuleOp> importScalarProgram(const ContractModule &module,
                                          const ScalarProgram &program,
                                          MLIRContext &context,
                                          OverflowMode mode,
                                          ScalarDiagnosticFn diag,
                                          bool emitCheckedArithmetic,
                                          StringRef trapHook,
                                          ScalarImportOptions options) {
  if (options.integerBits != 32 && options.integerBits != 64) {
    diag("scalar:0: int-width: Integer width must be 32 or 64");
    return {};
  }
  // The enum is closed, so a value outside it can only arrive through a cast
  // or through memory that is already wrong.  Say so on the diagnostic channel
  // the caller is already reading rather than asserting: an assert is compiled
  // out of the Release build the tests actually run, and a silent fall-through
  // to a default mode is exactly the failure `--int-overflow bogus` exists to
  // make loud.  The CLI closes the same door one layer up (usage, exit 2).
  // (Spelled as a comparison rather than a `switch` with a `default`, which
  // -Wcovered-switch-default rightly objects to on a closed enum.)
  const bool known = mode == OverflowMode::Raise ||
                     mode == OverflowMode::Wrap ||
                     mode == OverflowMode::None || mode == OverflowMode::Trap ||
                     mode == OverflowMode::Status ||
                     mode == OverflowMode::Abort;
  if (!known) {
    diag("scalar:0: internal-bad-overflow-mode: importScalarProgram was given "
         "an OverflowMode outside {Raise, Wrap, None, Trap, Status, Abort} (this "
         "is a caller defect, not a rejected input)");
    return {};
  }
  if (mode == OverflowMode::Abort) {
    // Decision 0015: one failure channel, the hook. The other channels'
    // switches would add a second one, and the declaration-shaped boundary
    // belongs to another lane.
    if (emitCheckedArithmetic || !trapHook.empty() ||
        options.freestandingTypes || !options.status.entry.empty()) {
      diag("scalar:0: internal-bad-overflow-mode: OverflowMode::Abort takes no "
           "checked-arithmetic opt-in, trap hook, freestanding types or status "
           "ABI; its failure channel is the one hook");
      return {};
    }
  }
  if (mode == OverflowMode::Status) {
    // The status ABI is described entirely by the boundary contract, and this
    // side never guesses any of it. An absent entry name or an unknown result
    // domain would otherwise silently produce a kernel with a different
    // signature from the header the same contract generated.
    if (options.status.entry.empty()) {
      diag("scalar:0: internal-bad-overflow-mode: OverflowMode::Status requires "
           "ScalarImportOptions::status.entry (the boundary contract names it)");
      return {};
    }
    const llvm::StringRef domain(options.status.resultDomain);
    if (domain != "i64" && domain != "i32" && domain != "u32") {
      diag("scalar:0: internal-bad-overflow-mode: OverflowMode::Status result "
           "domain must be i64, i32 or u32, not '" + options.status.resultDomain +
           "'");
      return {};
    }
    // The three switches that belong to the OTHER failure channels. Silently
    // ignoring one would leave a kernel that both returns a status and calls a
    // trap hook, which is two failure channels and no single answer.
    if (emitCheckedArithmetic) {
      diag("scalar:0: internal-bad-overflow-mode: OverflowMode::Status does not "
           "use spinel.checked_* (its policies are raise/wrap/none/trap, none of "
           "which returns a status)");
      return {};
    }
    if (!trapHook.empty()) {
      diag("scalar:0: internal-bad-overflow-mode: OverflowMode::Status takes no "
           "trap hook; a status boundary reports failure by returning");
      return {};
    }
    if (options.freestandingTypes) {
      diag("scalar:0: internal-bad-overflow-mode: OverflowMode::Status is not "
           "the freestanding declaration boundary; task 2 admits scalars only");
      return {};
    }
  }
  // Trap requires spinel.checked_* policy trap to carry its cold hook call. No direct
  // standard-dialect path exists; refuse caller misuse rather than silently wrapping.
  if (mode == OverflowMode::Trap && !emitCheckedArithmetic) {
    diag("scalar:0: internal-bad-overflow-mode: OverflowMode::Trap requires "
         "emitCheckedArithmetic (the trap arm exists only on spinel.checked_*)");
    return {};
  }
  if (mode == OverflowMode::Trap && trapHook.empty()) {
    diag("scalar:0: internal-bad-overflow-mode: OverflowMode::Trap requires a "
         "non-empty trap hook symbol (the profile owns the name)");
    return {};
  }
  return ModuleGen(module, program, context, mode, diag, emitCheckedArithmetic,
                   trapHook, options)
      .run();
}

} // namespace spinel_mlir::scalar
