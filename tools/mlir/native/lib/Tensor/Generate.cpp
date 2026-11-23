// Generate tensor modules, matching frozen _build_assign/_build_reduce/_expr operations and
// attributes for byte identity after roundtrip.
#include "Generate.h"

#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/Dialect/Linalg/IR/Linalg.h"
#include "mlir/Dialect/Math/IR/Math.h"
#include "mlir/Dialect/SCF/IR/SCF.h"
#include "mlir/Dialect/Tensor/IR/Tensor.h"
#include "mlir/IR/Builders.h"
#include "mlir/IR/AffineExpr.h"
#include "mlir/IR/BuiltinTypes.h"
#include "mlir/IR/Verifier.h"

#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/StringMap.h"
#include "llvm/ADT/DenseSet.h"
#include "llvm/ADT/STLExtras.h"
#include "llvm/ADT/StringExtras.h"

#include <functional>
#include <limits>
#include <map>
#include <tuple>

using namespace mlir;

namespace spinel_mlir::tensor {
namespace {

const contract::AstField *findField(const contract::Node &n, llvm::StringRef key) {
  for (const contract::AstField &f : n.fields)
    if (f.key == key) return &f;
  return nullptr;
}
bool getReference(const contract::Node &n, llvm::StringRef key, int64_t &out) {
  const contract::AstField *f = findField(n, key);
  if (!f || f->kind != contract::AstField::Kind::Reference) return false;
  out = std::get<int64_t>(f->value);
  return true;
}
bool getString(const contract::Node &n, llvm::StringRef key, std::string &out) {
  const contract::AstField *f = findField(n, key);
  if (!f || f->kind != contract::AstField::Kind::String) return false;
  out = std::get<std::string>(f->value);
  return true;
}
bool getArray(const contract::Node &n, llvm::StringRef key,
              std::vector<int64_t> &out) {
  const contract::AstField *f = findField(n, key);
  if (!f || f->kind != contract::AstField::Kind::Array) return false;
  out = std::get<std::vector<int64_t>>(f->value);
  return true;
}
bool getFloatSpelling(const contract::Node &n, llvm::StringRef key,
                      std::string &out) {
  for (const contract::AstField &f : n.fields)
    if (f.key == key && f.kind == contract::AstField::Kind::FloatSpelling) {
      out = std::get<std::string>(f.value);
      return true;
    }
  return false;
}

// Build reducer initializers with APFloat to preserve Python text values: zero, negative infinity
// and positive infinity.
float reducerInit(llvm::StringRef root) {
  if (root == "max") return -std::numeric_limits<float>::infinity();
  if (root == "min") return std::numeric_limits<float>::infinity();
  return 0.0f;
}

} // namespace

bool tensorHasAutoPadVia(const std::vector<TensorDecl> &decls) {
  // has_auto: auto without border:zero is device-independent, so do not introduce a device axis.
  return llvm::any_of(decls, [](const TensorDecl &d) {
    return d.padVia == "auto" && d.border == "zero";
  });
}

llvm::ArrayRef<llvm::StringRef> tensorPadDeviceProfiles() {
  static const llvm::StringRef kProfiles[] = {"cpu", "metal"};
  return kProfiles;
}

OwningOpRef<ModuleOp>
generateTensorModule(const contract::ContractModule &module,
                     const std::vector<TensorDecl> &decls,
                     const std::vector<TensorBody> &bodies,
                     MLIRContext &context, llvm::StringRef device,
                     std::vector<PadChoice> &padChoice, DeclDiagnosticFn diag) {
  context.loadDialect<func::FuncDialect, linalg::LinalgDialect,
                      arith::ArithDialect, mlir::tensor::TensorDialect,
                      math::MathDialect, scf::SCFDialect>();
  OpBuilder b(&context);
  auto loc = FileLineColLoc::get(&context, module.sourceFile(), 1, 0);
  OwningOpRef<ModuleOp> root = ModuleOp::create(b, loc);
  auto f32 = b.getF32Type();
  auto fast = arith::FastMathFlagsAttr::get(&context,
                                            arith::FastMathFlags::contract);
  // u8 boundaries are ui8, internals i8: arith requires signless operands. tensor.bitcast crosses
  // the boundary; arith.extui restores unsigned meaning inside.
  Type ui8 = b.getIntegerType(8, /*isSigned=*/false);
  Type i8 = b.getI8Type();
  auto tyOf = [&](int rank, llvm::StringRef dt, bool boundary) -> Type {
    Type elt = dt == "u8" ? (boundary ? ui8 : i8) : Type(f32);
    if (rank == 0) return elt;
    return RankedTensorType::get(llvm::SmallVector<int64_t>(rank, ShapedType::kDynamic),
                                 elt);
  };

  auto node = [&](int64_t id) -> const contract::Node * {
    if (id < 0) return nullptr;
    for (const contract::Node &n : module.nodes())
      if (n.id == id) return &n;
    return nullptr;
  };
  bool failed_ = false;
  auto give = [&](const llvm::Twine &why) {
    if (!failed_) { failed_ = true; diag(why.str()); }
    return OwningOpRef<ModuleOp>{};
  };

  for (size_t di = 0; di < decls.size(); ++di) {
    const TensorDecl &d = decls[di];
    const TensorBody &body = bodies[di];

    // Refuse unimplemented forms rather than building an incorrect module. Callers record
    // pending.tsv; the gap shrinks as stages land.
    if (body.hasUnimplementedPrologue)
      return give(d.where() + ": E177 CP3 (mode / tap / bilinear / hist) is not built yet");

    // Resolve pad_via:auto once per declaration, like TensorFunc.__init__, so all windows
    // materialize identically. Main normally builds both device profiles if auto+zero lacks a
    // device, so this empty-device branch is unreachable there; retain the frozen rule.
    std::string padvia = d.padVia, padwhy;
    if (padvia == "auto") {
      if (d.border != "zero") {
        padvia = "index";
        padwhy = "border: :" + d.border +
                 " has only the index lowering (tensor.pad fills with one constant)";
      } else if (device.empty()) {
        return give(d.where() +
                    ": pad_via: :auto needs a device profile, and this generator run "
                    "was given none. The automatic choice is device-dependent BY "
                    "MEASUREMENT (E042 s8.2: :pad_op is 13.0% faster on the CPU "
                    "backend, :index is 11.6% faster on Metal), so there is no "
                    "device-free answer to emit. Pass --device cpu|metal for a single "
                    "module, or --vmfb, which builds one module per backend and is "
                    "what a program actually consumes");
      } else {
        padvia = device == "cpu" ? "pad_op" : "index";
        padwhy = "device profile " + device.str();
      }
      padChoice.push_back({d.name, padvia, padwhy});
    }

    // Lookup parameter dtype by position; dtypes aligns with params.
    auto dtypeAt = [&](size_t i) -> llvm::StringRef {
      return i < d.dtypes.size() ? llvm::StringRef(d.dtypes[i]) : llvm::StringRef(d.dtype);
    };
    auto dtypeOf = [&](llvm::StringRef nm) -> llvm::StringRef {
      auto it = llvm::find(body.paramNames, nm.str());
      if (it == body.paramNames.end()) return "f32";
      return dtypeAt(std::distance(body.paramNames.begin(), it));
    };

    // ---- Signature -----------------------------------------------------------
    llvm::SmallVector<Type> argTys;
    for (size_t pi = 0; pi < d.params.size(); ++pi)
      argTys.push_back(tyOf(rankOf(d.params[pi]), dtypeAt(pi), /*boundary=*/true));
    // Map matvec CallNode ids to ins positions for regions. fixed_tree forbids matvec, leaving this
    // empty there.
    llvm::DenseMap<int64_t, unsigned> mvSlot;
    // Windows deduplicate by (src,win,op), even when repeated in source.
    std::map<std::tuple<std::string, std::string, std::string>, unsigned> wnSlot;
    // Other prologue tensors deduplicate by (op,src,axis,mat,idx,wgt).
    std::map<std::tuple<std::string, std::string, int, std::string, std::string,
                        std::string>,
             unsigned>
        dSlot;

    // Region expression environment maps parameters to region values; scalars remain function
    // arguments.
    bool bad = false;
    std::string badWhy;
    // Captured scalar set: for commutative multiply/add, swap captured RHS ahead of noncaptured
    // LHS, matching frozen _is_capture and text spelling.
    llvm::DenseSet<Value> captures;
    const ValueRange *regionArgsRef = nullptr;
    std::function<Value(OpBuilder &, Location, int64_t,
                        const std::map<std::string, Value> &)> walk;
    walk = [&](OpBuilder &nb, Location nl, int64_t id,
               const std::map<std::string, Value> &env) -> Value {
      if (bad) return Value();
      const contract::Node *n = node(id);
      // Parentheses are transparent; Body already checked a single expression.
      while (n && (n->kind == "ParenthesesNode" || n->kind == "StatementsNode")) {
        std::vector<int64_t> inner;
        if (n->kind == "StatementsNode") {
          getArray(*n, "body", inner);
        } else {
          int64_t x = -1;
          if (getReference(*n, "body", x) && x >= 0) inner.push_back(x);
        }
        std::vector<int64_t> live;
        for (int64_t i : inner) if (node(i)) live.push_back(i);
        if (live.size() != 1) { bad = true; badWhy = "parenthesised group"; return Value(); }
        n = node(live[0]);
      }
      if (!n) { bad = true; badWhy = "empty expression"; return Value(); }
      if (n->kind == "LocalVariableReadNode") {
        std::string nm;
        getString(*n, "name", nm);
        auto it = env.find(nm);
        if (it == env.end()) { bad = true; badWhy = "unknown operand " + nm; return Value(); }
        return it->second;
      }
      if (n->kind == "FloatNode") {
        std::string sp;
        if (!getFloatSpelling(*n, "value", sp)) { bad = true; badWhy = "float"; return Value(); }
        llvm::APFloat v(static_cast<float>(std::stod(sp)));
        return arith::ConstantOp::create(nb, nl, nb.getF32Type(),
                                         nb.getFloatAttr(nb.getF32Type(), v));
      }
      if (n->kind != "CallNode") { bad = true; badWhy = n->kind; return Value(); }
      std::string op;
      getString(*n, "name", op);
      // matvec is a prologue tensor; the region reads its ins position.
      if (op == "matvec") {
        auto it = mvSlot.find(n->id);
        if (it == mvSlot.end()) { bad = true; badWhy = "matvec slot"; return Value(); }
        return regionArgsRef->operator[](it->second);
      }
      int64_t recvId = -1;
      getReference(*n, "receiver", recvId);
      std::vector<int64_t> args;
      int64_t argsId = -1;
      if (getReference(*n, "arguments", argsId) && argsId >= 0)
        if (const contract::Node *an = node(argsId)) getArray(*an, "arguments", args);
      // mode_mul/tap_mul/bilinear/hist use prologue results, looked up by canonical key rebuilt
      // from receiver/arguments. Duplicate source occurrences have no second sources node id.
      if (op == "mode_mul" || op == "tap_mul" || op == "bilinear" || op == "hist") {
        std::string srcNm;
        if (const contract::Node *rn = node(recvId)) getString(*rn, "name", srcNm);
        int axis = 0;
        std::string mat, ix, wg;
        auto nameOf = [&](size_t k, std::string &out) {
          if (args.size() > k)
            if (const contract::Node *an = node(args[k])) getString(*an, "name", out);
        };
        if (op == "mode_mul" || op == "tap_mul") {
          std::string ax;
          if (!args.empty())
            if (const contract::Node *an = node(args[0])) getString(*an, "value", ax);
          axis = ax == "d1" ? 1 : 0;
        }
        if (op == "mode_mul") nameOf(1, mat);
        if (op == "tap_mul") { nameOf(1, ix); nameOf(2, wg); }
        auto it = dSlot.find(std::make_tuple(op, srcNm, axis, mat, ix, wg));
        if (it == dSlot.end()) { bad = true; badWhy = op + " slot"; return Value(); }
        return regionArgsRef->operator[](it->second);
      }
      // conv2d/depthwise use canonical prologue keys, not node ids, because duplicate windows are
      // absent from sources.
      if (op == "conv2d" || op == "depthwise") {
        std::string srcNm, wnm;
        if (const contract::Node *rn = node(recvId))
          getString(*rn, "name", srcNm);
        if (args.size() == 1)
          if (const contract::Node *an = node(args[0])) getString(*an, "value", wnm);
        auto it = wnSlot.find(std::make_tuple(srcNm, wnm, op));
        if (it == wnSlot.end()) { bad = true; badWhy = op + " slot"; return Value(); }
        return regionArgsRef->operator[](it->second);
      }
      if (op == "relu" || op == "abs" || op == "sqrt") {
        Value x = walk(nb, nl, recvId, env);
        if (bad) return Value();
        if (op == "abs") return math::AbsFOp::create(nb, nl, x);
        if (op == "sqrt") return math::SqrtOp::create(nb, nl, x);
        // relu: `arith.maximumf x, 0.0`
        Value zero = arith::ConstantOp::create(
            nb, nl, nb.getF32Type(), nb.getFloatAttr(nb.getF32Type(), 0.0));
        return arith::MaximumFOp::create(nb, nl, x, zero);
      }
      // Comparisons yield f32 1.0/0.0 masks, not i1: x.ge(t)*255.0 thresholds pixels while keeping
      // regions f32-in/f32-out and the operation set closed.
      if (op == "ge") {
        if (args.size() != 1) { bad = true; badWhy = "arity of " + op; return Value(); }
        Value a = walk(nb, nl, recvId, env);
        Value bv = walk(nb, nl, args[0], env);
        if (bad) return Value();
        Value c = arith::CmpFOp::create(nb, nl, arith::CmpFPredicate::OGE, a, bv);
        Value one = arith::ConstantOp::create(nb, nl, nb.getF32Type(),
                                              nb.getFloatAttr(nb.getF32Type(), 1.0));
        Value zero = arith::ConstantOp::create(nb, nl, nb.getF32Type(),
                                               nb.getFloatAttr(nb.getF32Type(), 0.0));
        return arith::SelectOp::create(nb, nl, c, one, zero);
      }
      if (args.size() != 1) { bad = true; badWhy = "arity of " + op; return Value(); }
      Value l = walk(nb, nl, recvId, env);
      Value r = walk(nb, nl, args[0], env);
      if (bad) return Value();
      // Frozen Python: `if op in ("*", "+") and _is_capture(rhs) and not
      // _is_capture(lhs): lhs, rhs = rhs, lhs`
      if ((op == "*" || op == "+") && captures.contains(r) && !captures.contains(l))
        std::swap(l, r);
      if (op == "*") return arith::MulFOp::create(nb, nl, l, r, fast);
      if (op == "+") return arith::AddFOp::create(nb, nl, l, r, fast);
      if (op == "-") return arith::SubFOp::create(nb, nl, l, r, fast);
      if (op == "/") return arith::DivFOp::create(nb, nl, l, r, fast);
      if (op == "**") return math::PowFOp::create(nb, nl, l, r, fast);
      bad = true; badWhy = "operator " + op;
      return Value();
    };

    if (d.reduction == "fixed_tree") {
      // fixed_tree creates __ft_pre (elementwise inner expression plus output vec) and __ft_step
      // (one level). Pad to B*m with identity, take B strided views and combine with a fixed binary
      // tree. Each output has a fixed B-1 arithmetic sequence, leaving no backend reassociation
      // freedom.
      auto vecTy = RankedTensorType::get({ShapedType::kDynamic}, f32);
      // -- pre --
      llvm::SmallVector<Type> preTys(argTys.begin(), argTys.end());
      preTys.push_back(vecTy);
      b.setInsertionPointToEnd(root->getBody());
      auto preFn = func::FuncOp::create(b, loc, d.name + "__ft_pre",
                                        b.getFunctionType(preTys, {vecTy}));
      Block *preEntry = preFn.addEntryBlock();
      b.setInsertionPointToStart(preEntry);
      llvm::SmallVector<Value> preIns;
      llvm::SmallVector<std::string> preNames;
      for (const TensorSource &s : body.sources) {
        if (s.kind != TensorSource::Kind::Param) continue;
        auto it = llvm::find(body.paramNames, s.name);
        preIns.push_back(
            preEntry->getArgument(std::distance(body.paramNames.begin(), it)));
        preNames.push_back(s.name);
      }
      llvm::SmallVector<AffineMap> preMaps(preIns.size() + 1,
                                           AffineMap::getMultiDimIdentityMap(1, &context));
      llvm::SmallVector<utils::IteratorType> preIters{utils::IteratorType::parallel};
      Value preOut = preEntry->getArgument(preTys.size() - 1);
      auto preGen = linalg::GenericOp::create(
          b, loc, TypeRange{vecTy}, preIns, ValueRange{preOut}, preMaps, preIters,
          [&](OpBuilder &nb, Location nl, ValueRange regionArgs) {
            regionArgsRef = &regionArgs;
            std::map<std::string, Value> env;
            for (size_t i = 0; i < preNames.size(); ++i) env[preNames[i]] = regionArgs[i];
            for (size_t i = 0; i < d.params.size(); ++i)
              if (d.params[i] == "scalar") {
                env[body.paramNames[i]] = preEntry->getArgument(i);
                captures.insert(preEntry->getArgument(i));
              }
            Value v = walk(nb, nl, body.exprNode, env);
            linalg::YieldOp::create(nb, nl, v ? v : regionArgs.back());
          });
      if (bad) return give(d.where() + ": E177 cannot build `" + badWhy + "`");
      func::ReturnOp::create(b, loc, preGen.getResult(0));

      // -- step --
      b.setInsertionPointToEnd(root->getBody());
      auto stepFn = func::FuncOp::create(b, loc, d.name + "__ft_step",
                                         b.getFunctionType({vecTy, vecTy}, {vecTy}));
      Block *se = stepFn.addEntryBlock();
      b.setInsertionPointToStart(se);
      Value x = se->getArgument(0), outv = se->getArgument(1);
      const int64_t B = d.treeArity;
      Value c0 = arith::ConstantOp::create(b, loc, b.getIndexType(), b.getIndexAttr(0));
      Value cB = arith::ConstantOp::create(b, loc, b.getIndexType(), b.getIndexAttr(B));
      Value ident = arith::ConstantOp::create(
          b, loc, f32, b.getFloatAttr(f32, llvm::APFloat(reducerInit(body.root))));
      Value n = mlir::tensor::DimOp::create(b, loc, x, c0);
      Value m = mlir::tensor::DimOp::create(b, loc, outv, c0);
      Value tot = arith::MulIOp::create(b, loc, m, cB);
      Value padAmt = arith::SubIOp::create(b, loc, tot, n);
      auto padOp = mlir::tensor::PadOp::create(
          b, loc, vecTy, x, llvm::ArrayRef<OpFoldResult>{b.getIndexAttr(0)},
          llvm::ArrayRef<OpFoldResult>{padAmt}, ident, /*nofold=*/false);
      Value padded = padOp.getResult();
      llvm::SmallVector<Value> slices;
      for (int64_t k = 0; k < B; ++k)
        slices.push_back(mlir::tensor::ExtractSliceOp::create(
            b, loc, vecTy, padded,
            llvm::ArrayRef<OpFoldResult>{b.getIndexAttr(k)},
            llvm::ArrayRef<OpFoldResult>{m},
            llvm::ArrayRef<OpFoldResult>{b.getIndexAttr(B)}));
      llvm::SmallVector<AffineMap> stepMaps(
          B + 1, AffineMap::getMultiDimIdentityMap(1, &context));
      llvm::SmallVector<utils::IteratorType> stepIters{utils::IteratorType::parallel};
      auto stepGen = linalg::GenericOp::create(
          b, loc, TypeRange{vecTy}, slices, ValueRange{outv}, stepMaps, stepIters,
          [&](OpBuilder &nb, Location nl, ValueRange regionArgs) {
            llvm::SmallVector<Value> level(regionArgs.begin(),
                                           regionArgs.begin() + B);
            while (level.size() > 1) {
              llvm::SmallVector<Value> next;
              for (size_t i = 0; i < level.size(); i += 2) {
                if (i + 1 == level.size()) { next.push_back(level[i]); continue; }
                next.push_back(
                    body.root == "max"
                        ? Value(arith::MaximumFOp::create(nb, nl, level[i], level[i + 1]))
                    : body.root == "min"
                        ? Value(arith::MinimumFOp::create(nb, nl, level[i], level[i + 1]))
                        : Value(arith::AddFOp::create(nb, nl, level[i], level[i + 1], fast)));
              }
              level = std::move(next);
            }
            linalg::YieldOp::create(nb, nl, level.front());
          });
      func::ReturnOp::create(b, loc, stepGen.getResult(0));
      continue;
    }


    Type retTy = d.dest >= 0 ? argTys[d.dest] : Type(f32);
    // Reset insertion to module body before creating each function. Otherwise the second func.func
    // forms inside the first block, then push_back detaches it; this segfaulted beyond the
    // one-declaration prototype.
    b.setInsertionPointToEnd(root->getBody());
    auto fn = func::FuncOp::create(b, loc, d.name,
                                   b.getFunctionType(argTys, {retTy}));
    Block *entry = fn.addEntryBlock();
    b.setInsertionPointToStart(entry);

    const std::string destName =
        d.dest >= 0 ? body.paramNames[d.dest] : std::string();
    auto argOf = [&](llvm::StringRef nm) -> Value {
      auto it = llvm::find(body.paramNames, nm.str());
      return entry->getArgument(std::distance(body.paramNames.begin(), it));
    };

    // Bitcast ui8 to i8 in parameter order before other prologue operations, matching
    // _build_assign.
    llvm::StringMap<Value> bitcast;
    for (size_t pi = 0; pi < d.params.size(); ++pi) {
      if (rankOf(d.params[pi]) < 1 || dtypeAt(pi) != "u8") continue;
      Value src = entry->getArgument(pi);
      bitcast[body.paramNames[pi]] = mlir::tensor::BitcastOp::create(
          b, loc, tyOf(rankOf(d.params[pi]), "u8", /*boundary=*/false), src);
    }
    // Use bitcast values in ins/outs for u8, matching _opnd.
    auto opndOf = [&](llvm::StringRef nm) -> Value {
      auto it = bitcast.find(nm);
      return it == bitcast.end() ? argOf(nm) : it->second;
    };

    // Insert prologue constants at the beginning, reversing creation order as frozen
    // pro.insert(0,...) does. Roundtrip preserves op ordering (observed c2,cst,c1,c0); constants
    // requested during region construction still belong in prologue.
    Operation *proHead = nullptr;
    auto notePro = [&](Operation *op) { if (!proHead) proHead = op; };
    auto hoist = [&](Operation *op) {
      if (proHead) op->moveBefore(proHead);
      proHead = op;
    };
    llvm::DenseMap<int64_t, Value> idxConst;
    Value zerofV;
    auto idxc = [&](int64_t k) -> Value {
      auto it = idxConst.find(k);
      if (it != idxConst.end()) return it->second;
      OpBuilder::InsertionGuard g(b);
      b.setInsertionPointToEnd(entry);
      Value c = arith::ConstantOp::create(b, loc, b.getIndexType(), b.getIndexAttr(k));
      hoist(c.getDefiningOp());
      idxConst[k] = c;
      return c;
    };
    auto zerof = [&]() -> Value {
      if (zerofV) return zerofV;
      OpBuilder::InsertionGuard g(b);
      b.setInsertionPointToEnd(entry);
      zerofV = arith::ConstantOp::create(b, loc, f32, b.getFloatAttr(f32, 0.0));
      hoist(zerofV.getDefiningOp());
      return zerofV;
    };

    // Materialize windows.
    const int64_t CH = d.channels;
    auto nhwcTy = RankedTensorType::get(
        {1, ShapedType::kDynamic, ShapedType::kDynamic, CH}, f32);
    // Read image parameter H/W once, matching _dims.
    llvm::StringMap<std::pair<Value, Value>> dimCache;
    auto dimsOf = [&](llvm::StringRef nm) -> std::pair<Value, Value> {
      auto it = dimCache.find(nm);
      if (it != dimCache.end()) return it->second;
      Value c0 = idxc(0), c1 = idxc(1);
      Value h = mlir::tensor::DimOp::create(b, loc, opndOf(nm), c0);
      notePro(h.getDefiningOp());
      Value w = mlir::tensor::DimOp::create(b, loc, opndOf(nm), c1);
      auto r = std::make_pair(h, w);
      dimCache[nm] = r;
      return r;
    };
    // Widen unsigned u8 elements to f32 inside the region: byte 200 becomes 200.0.
    auto widen = [&](OpBuilder &nb, Location nl, Value v, bool isU8) -> Value {
      if (!isU8) return v;
      Value x = arith::ExtUIOp::create(nb, nl, nb.getI32Type(), v);
      return arith::UIToFPOp::create(nb, nl, nb.getF32Type(), x);
    };

    std::string padBad;
    // Deduplicate by (src,ph,pw), shared by both Sobel convolutions.
    std::map<std::tuple<std::string, int64_t, int64_t>, Value> padCache;
    auto emitPad = [&](llvm::StringRef srcName, int64_t ph, int64_t pw) -> Value {
      auto key = std::make_tuple(srcName.str(), ph, pw);
      auto it = padCache.find(key);
      if (it != padCache.end()) return it->second;
      auto hw = dimsOf(srcName);
      Value h = hw.first, w = hw.second;
      const bool u8 = dtypeOf(srcName) == "u8";
      Value z = zerof();
      auto id4 = AffineMap::getMultiDimIdentityMap(4, &context);
      llvm::SmallVector<utils::IteratorType> par4(4, utils::IteratorType::parallel);

      if (padvia == "pad_op") {
        // One generic lifts rank-3 to NHWC and widens; tensor.pad fills boundaries with constants.
        auto lift = AffineMap::get(4, 0,
                                   {getAffineDimExpr(1, &context),
                                    getAffineDimExpr(2, &context),
                                    getAffineDimExpr(3, &context)},
                                   &context);
        Value e0 = mlir::tensor::EmptyOp::create(
            b, loc, nhwcTy.getShape(), f32, ValueRange{h, w});
        notePro(e0.getDefiningOp());
        auto lifted = linalg::GenericOp::create(
            b, loc, TypeRange{nhwcTy}, ValueRange{opndOf(srcName)}, ValueRange{e0},
            llvm::SmallVector<AffineMap>{lift, id4}, par4,
            [&](OpBuilder &nb, Location nl, ValueRange ra) {
              linalg::YieldOp::create(nb, nl, widen(nb, nl, ra[0], u8));
            });
        auto padOp = mlir::tensor::PadOp::create(
            b, loc, nhwcTy, lifted.getResult(0),
            llvm::ArrayRef<OpFoldResult>{b.getIndexAttr(0), b.getIndexAttr(ph),
                                         b.getIndexAttr(pw), b.getIndexAttr(0)},
            llvm::ArrayRef<OpFoldResult>{b.getIndexAttr(0), b.getIndexAttr(ph),
                                         b.getIndexAttr(pw), b.getIndexAttr(0)},
            z, /*nofold=*/false);
        padCache[key] = padOp.getResult();
        return padOp.getResult();
      }

      // Index form: one generic performs lifting, widening and boundary handling.
      Value hp = arith::AddIOp::create(b, loc, h, idxc(2 * ph));
      notePro(hp.getDefiningOp());
      Value wp = arith::AddIOp::create(b, loc, w, idxc(2 * pw));
      Value e0 = mlir::tensor::EmptyOp::create(b, loc, nhwcTy.getShape(), f32,
                                               ValueRange{hp, wp});
      auto gen = linalg::GenericOp::create(
          b, loc, TypeRange{nhwcTy}, ValueRange{}, ValueRange{e0},
          llvm::SmallVector<AffineMap>{id4}, par4,
          [&](OpBuilder &nb, Location nl, ValueRange ra) {
            Value i1 = linalg::IndexOp::create(nb, nl, 1);
            Value i2 = linalg::IndexOp::create(nb, nl, 2);
            Value i3 = linalg::IndexOp::create(nb, nl, 3);
            Value idxH, idxW;
            llvm::SmallVector<Value, 2> inb;
            const std::pair<Value, Value> axes[2] = {{i1, h}, {i2, w}};
            const int64_t pads[2] = {ph, pw};
            for (int a = 0; a < 2; ++a) {
              Value i = axes[a].first, n_ = axes[a].second;
              Value m = arith::SubIOp::create(nb, nl, n_, idxc(1));   // n-1
              Value sv = arith::SubIOp::create(nb, nl, i, idxc(pads[a]));
              Value res;
              if (d.border == "reflect") {
                // reflect-101: i<0 -> -i ; i>n-1 -> 2(n-1)-i
                Value c0 = idxc(0);
                Value neg = arith::SubIOp::create(nb, nl, c0, sv);
                Value lt = arith::CmpIOp::create(nb, nl, arith::CmpIPredicate::slt,
                                                 sv, c0);
                Value a1 = arith::SelectOp::create(nb, nl, lt, neg, sv);
                Value m2 = arith::AddIOp::create(nb, nl, m, m);
                Value rev = arith::SubIOp::create(nb, nl, m2, a1);
                Value gt = arith::CmpIOp::create(nb, nl, arith::CmpIPredicate::sgt,
                                                 a1, m);
                res = arith::SelectOp::create(nb, nl, gt, rev, a1);
              } else {
                Value lo = arith::MaxSIOp::create(nb, nl, sv, idxc(0));
                res = arith::MinSIOp::create(nb, nl, lo, m);
                if (d.border == "zero")
                  inb.push_back(arith::CmpIOp::create(
                      nb, nl, arith::CmpIPredicate::eq, res, sv));
              }
              (a == 0 ? idxH : idxW) = res;
            }
            Value v = mlir::tensor::ExtractOp::create(
                nb, nl, opndOf(srcName), ValueRange{idxH, idxW, i3});
            Value fv = widen(nb, nl, v, u8);
            if (!inb.empty()) {
              Value both = inb[0];
              for (size_t k = 1; k < inb.size(); ++k)
                both = arith::AndIOp::create(nb, nl, both, inb[k]);
              fv = arith::SelectOp::create(nb, nl, both, fv, z);
            }
            linalg::YieldOp::create(nb, nl, fv);
          });
      padCache[key] = gen.getResult(0);
      return gen.getResult(0);
    };

    // Window coefficients become dense arith constants: conv2d HWCF (KH,KW,1,1), depthwise HWC
    // (KH,KW,C), same window on every channel.
    auto denseFilter = [&](const std::vector<std::vector<float>> &coef,
                           llvm::StringRef kind) -> Value {
      const int64_t kh = coef.size(), kw = coef.empty() ? 0 : coef[0].size();
      llvm::SmallVector<int64_t> shape;
      llvm::SmallVector<llvm::APFloat> vals;
      if (kind == "conv2d") {
        shape = {kh, kw, 1, 1};
        for (const auto &r : coef)
          for (float c : r) vals.push_back(llvm::APFloat(c));
      } else {
        shape = {kh, kw, CH};
        for (const auto &r : coef)
          for (float c : r)
            for (int64_t k = 0; k < CH; ++k) vals.push_back(llvm::APFloat(c));
      }
      auto ty = RankedTensorType::get(shape, f32);
      Value cst = arith::ConstantOp::create(
          b, loc, ty, DenseElementsAttr::get(ty, vals));
      notePro(cst.getDefiningOp());
      return cst;
    };

    // Additional prologue preparation: _dim intentionally has a cache separate from _dims.
    // Previously pinned window modules would renumber SSA values if these helpers were unified.
    std::map<std::pair<std::string, int64_t>, Value> dimK;
    auto dimOf = [&](llvm::StringRef nm, int64_t k) -> Value {
      auto key = std::make_pair(nm.str(), k);
      auto it = dimK.find(key);
      if (it != dimK.end()) return it->second;
      Value c = idxc(k);
      Value v = mlir::tensor::DimOp::create(b, loc, opndOf(nm), c);
      notePro(v.getDefiningOp());
      dimK[key] = v;
      return v;
    };
    auto ten3Ty = RankedTensorType::get(
        {ShapedType::kDynamic, ShapedType::kDynamic, ShapedType::kDynamic}, f32);
    auto vec1Ty = RankedTensorType::get({ShapedType::kDynamic}, f32);
    auto dimExpr = [&](unsigned i) { return getAffineDimExpr(i, &context); };
    llvm::SmallVector<utils::IteratorType> par3(3, utils::IteratorType::parallel);

    // n-mode product: one generic contracts rank-3 axis ax with a matrix. d0..d2 are output axes;
    // d3 is reduction.
    auto emitMode = [&](const TensorSource &s) -> Value {
      const int ax = s.axis;
      const bool u8 = dtypeOf(s.name) == "u8";
      llvm::SmallVector<Value, 3> dims{dimOf(s.name, 0), dimOf(s.name, 1),
                                       dimOf(s.name, 2)};
      dims[ax] = dimOf(s.mat, 1);
      Value e0 = mlir::tensor::EmptyOp::create(b, loc, ten3Ty.getShape(), f32,
                                               ValueRange{dims[0], dims[1], dims[2]});
      Value f0 = linalg::FillOp::create(b, loc, ValueRange{zerof()}, ValueRange{e0})
                     .getResult(0);
      llvm::SmallVector<AffineExpr, 3> sd{dimExpr(0), dimExpr(1), dimExpr(2)};
      sd[ax] = dimExpr(3);
      auto smap = AffineMap::get(4, 0, sd, &context);
      auto wmap = AffineMap::get(
          4, 0, {dimExpr(3), dimExpr(static_cast<unsigned>(ax))}, &context);
      auto omap = AffineMap::get(4, 0, {dimExpr(0), dimExpr(1), dimExpr(2)}, &context);
      llvm::SmallVector<utils::IteratorType> iters{
          utils::IteratorType::parallel, utils::IteratorType::parallel,
          utils::IteratorType::parallel, utils::IteratorType::reduction};
      return linalg::GenericOp::create(
                 b, loc, TypeRange{ten3Ty}, ValueRange{opndOf(s.name), argOf(s.mat)},
                 ValueRange{f0}, llvm::SmallVector<AffineMap>{smap, wmap, omap}, iters,
                 [&](OpBuilder &nb, Location nl, ValueRange ra) {
                   Value v = widen(nb, nl, ra[0], u8);
                   Value pr = arith::MulFOp::create(nb, nl, v, ra[1], fast);
                   Value sm = arith::AddFOp::create(nb, nl, ra[2], pr, fast);
                   linalg::YieldOp::create(nb, nl, sm);
                 })
          .getResult(0);
    };

    // Banded resampling uses an scf.for over k inside an all-parallel region, not a reduction
    // iterator: data-dependent indexing combined with reduction caused IREE metal-spirv SEGV.
    // Dynamic K and sequential explicit accumulation are stronger than the reduction-iterator
    // promise.
    auto emitTap = [&](const TensorSource &s) -> Value {
      const int ax = s.axis;
      const bool u8 = dtypeOf(s.name) == "u8";
      const std::string dst = destName;
      llvm::SmallVector<Value, 3> dims{dimOf(s.name, 0), dimOf(s.name, 1),
                                       dimOf(s.name, 2)};
      dims[ax] = dimOf(dst, ax);
      Value nm1 = arith::SubIOp::create(b, loc, dimOf(s.name, ax), idxc(1));
      notePro(nm1.getDefiningOp());
      Value ktaps = dimOf(s.idx, 1);
      Value e0 = mlir::tensor::EmptyOp::create(b, loc, ten3Ty.getShape(), f32,
                                               ValueRange{dims[0], dims[1], dims[2]});
      auto id3 = AffineMap::getMultiDimIdentityMap(3, &context);
      return linalg::GenericOp::create(
                 b, loc, TypeRange{ten3Ty}, ValueRange{}, ValueRange{e0},
                 llvm::SmallVector<AffineMap>{id3}, par3,
                 [&](OpBuilder &nb, Location nl, ValueRange ra) {
                   llvm::SmallVector<Value, 3> pos;
                   for (int j = 0; j < 3; ++j)
                     pos.push_back(linalg::IndexOp::create(nb, nl, j));
                   auto forOp = scf::ForOp::create(
                       nb, nl, idxc(0), ktaps, idxc(1), ValueRange{zerof()},
                       [&](OpBuilder &fb, Location fl, Value kv, ValueRange it) {
                         Value av = it[0];
                         Value ix = mlir::tensor::ExtractOp::create(
                             fb, fl, argOf(s.idx), ValueRange{pos[ax], kv});
                         Value wt = mlir::tensor::ExtractOp::create(
                             fb, fl, argOf(s.wgt), ValueRange{pos[ax], kv});
                         // Clamp tap positions here: host-provided matrices can be wrong.
                         // Out-of-bounds tensor.extract is undefined; this interface must reject or
                         // clamp bad input, never silently read another buffer.
                         Value pi = arith::FPToSIOp::create(fb, fl, fb.getI32Type(), ix);
                         Value px = arith::IndexCastOp::create(fb, fl,
                                                               fb.getIndexType(), pi);
                         Value lo = arith::MaxSIOp::create(fb, fl, px, idxc(0));
                         Value hi = arith::MinSIOp::create(fb, fl, lo, nm1);
                         llvm::SmallVector<Value, 3> rd(pos.begin(), pos.end());
                         rd[ax] = hi;
                         Value v = mlir::tensor::ExtractOp::create(
                             fb, fl, opndOf(s.name), ValueRange{rd[0], rd[1], rd[2]});
                         Value fv = widen(fb, fl, v, u8);
                         Value pr = arith::MulFOp::create(fb, fl, fv, wt, fast);
                         Value sm = arith::AddFOp::create(fb, fl, av, pr, fast);
                         scf::YieldOp::create(fb, fl, ValueRange{sm});
                       });
                   linalg::YieldOp::create(nb, nl, forOp.getResult(0));
                 })
          .getResult(0);
    };

    // Bilinear: one all-parallel generic computes source coordinates from both shapes and reads
    // four taps. Half-pixel coordinates match jax.image.resize/PIL/OpenCV/torch
    // align_corners=False.
    auto emitBilinear = [&](const TensorSource &s) -> Value {
      const bool u8 = dtypeOf(s.name) == "u8";
      Value oh = dimOf(destName, 0), ow = dimOf(destName, 1);
      Value oc = dimOf(s.name, 2);
      Value e0 = mlir::tensor::EmptyOp::create(b, loc, ten3Ty.getShape(), f32,
                                               ValueRange{oh, ow, oc});
      // Source dimensions requested while building a region must still appear in prologue, matching
      // frozen emit_pro. Fetch them in the same order before building the generic; otherwise
      // builders insert them inside. This single difference shifted a 640-line module.
      Value sh0 = dimOf(s.name, 0), sh1 = dimOf(s.name, 1);
      auto id3 = AffineMap::getMultiDimIdentityMap(3, &context);
      return linalg::GenericOp::create(
                 b, loc, TypeRange{ten3Ty}, ValueRange{}, ValueRange{e0},
                 llvm::SmallVector<AffineMap>{id3}, par3,
                 [&](OpBuilder &nb, Location nl, ValueRange ra) {
                   auto cf = [&](double v) {
                     return arith::ConstantOp::create(nb, nl, f32,
                                                      nb.getFloatAttr(f32, v));
                   };
                   Value half = cf(0.5), one = cf(1.0), zf = cf(0.0);
                   Value ic = linalg::IndexOp::create(nb, nl, 2);
                   struct Axis { Value i0, i1, w0, w1; };
                   Axis axes[2];
                   const std::pair<Value, Value> shape[2] = {{sh0, oh}, {sh1, ow}};
                   for (int a = 0; a < 2; ++a) {
                     Value nin = shape[a].first, nout = shape[a].second;
                     Value i = linalg::IndexOp::create(nb, nl, a);
                     Value ii = arith::IndexCastOp::create(nb, nl, nb.getI32Type(), i);
                     Value fi = arith::SIToFPOp::create(nb, nl, f32, ii);
                     Value ni = arith::IndexCastOp::create(nb, nl, nb.getI32Type(), nin);
                     Value nf = arith::SIToFPOp::create(nb, nl, f32, ni);
                     Value mi = arith::IndexCastOp::create(nb, nl, nb.getI32Type(), nout);
                     Value mf = arith::SIToFPOp::create(nb, nl, f32, mi);
                     // Runtime dimension ratio requires this division inside the kernel. Earlier
                     // measurements found Metal arith.divf not correctly rounded; lacking
                     // precomputed coefficients entails this operation.
                     Value sc = arith::DivFOp::create(nb, nl, nf, mf);
                     Value ch = arith::AddFOp::create(nb, nl, fi, half, fast);
                     Value sp = arith::MulFOp::create(nb, nl, ch, sc, fast);
                     Value sm = arith::SubFOp::create(nb, nl, sp, half, fast);
                     Value lim = arith::SubFOp::create(nb, nl, nf, one, fast);
                     Value lo = arith::MaxNumFOp::create(nb, nl, sm, zf);
                     Value hi = arith::MinNumFOp::create(nb, nl, lo, lim);
                     Value fl = math::FloorOp::create(nb, nl, hi);
                     Value dd = arith::SubFOp::create(nb, nl, hi, fl, fast);
                     Value i0i = arith::FPToSIOp::create(nb, nl, nb.getI32Type(), fl);
                     Value i0x = arith::IndexCastOp::create(nb, nl, nb.getIndexType(),
                                                            i0i);
                     Value nmo = arith::SubIOp::create(nb, nl, nin, idxc(1));
                     Value i0 = arith::MinSIOp::create(nb, nl, i0x, nmo);
                     Value i1a = arith::AddIOp::create(nb, nl, i0, idxc(1));
                     Value i1 = arith::MinSIOp::create(nb, nl, i1a, nmo);
                     Value w0 = arith::SubFOp::create(nb, nl, one, dd, fast);
                     axes[a] = Axis{i0, i1, w0, dd};
                   }
                   Value taps[2][2];
                   for (int ty = 0; ty < 2; ++ty)
                     for (int tx = 0; tx < 2; ++tx) {
                       Value yi = ty == 0 ? axes[0].i0 : axes[0].i1;
                       Value xi = tx == 0 ? axes[1].i0 : axes[1].i1;
                       Value v = mlir::tensor::ExtractOp::create(
                           nb, nl, opndOf(s.name), ValueRange{yi, xi, ic});
                       taps[ty][tx] = widen(nb, nl, v, u8);
                     }
                   // Process axis 0 before axis 1, matching two mode_mul operations. The routes
                   // should differ only in where weights are calculated, which the comparison
                   // measures.
                   Value cols[2];
                   for (int tx = 0; tx < 2; ++tx) {
                     Value a0 = arith::MulFOp::create(nb, nl, taps[0][tx],
                                                      axes[0].w0, fast);
                     Value a1 = arith::MulFOp::create(nb, nl, taps[1][tx],
                                                      axes[0].w1, fast);
                     cols[tx] = arith::AddFOp::create(nb, nl, a0, a1, fast);
                   }
                   Value b0 = arith::MulFOp::create(nb, nl, cols[0], axes[1].w0, fast);
                   Value b1 = arith::MulFOp::create(nb, nl, cols[1], axes[1].w1, fast);
                   linalg::YieldOp::create(
                       nb, nl, Value(arith::AddFOp::create(nb, nl, b0, b1, fast)));
                 })
          .getResult(0);
    };

    // Histogram: bins parallel, both pixel axes reduction, no scatter. f32 counts are exact here
    // through 2^24=16,777,216; a 4K frame has 8,294,400 pixels, so even one bin containing every
    // pixel stays representable.
    auto emitHist = [&](const TensorSource &s) -> Value {
      Value nbins = dimOf(destName, 0);
      Value e0 = mlir::tensor::EmptyOp::create(b, loc, vec1Ty.getShape(), f32,
                                               ValueRange{nbins});
      Value f0 = linalg::FillOp::create(b, loc, ValueRange{zerof()}, ValueRange{e0})
                     .getResult(0);
      auto imap = AffineMap::get(4, 0, {dimExpr(1), dimExpr(2), dimExpr(3)}, &context);
      auto omap = AffineMap::get(4, 0, {dimExpr(0)}, &context);
      llvm::SmallVector<utils::IteratorType> iters{
          utils::IteratorType::parallel, utils::IteratorType::reduction,
          utils::IteratorType::reduction, utils::IteratorType::reduction};
      return linalg::GenericOp::create(
                 b, loc, TypeRange{vec1Ty}, ValueRange{opndOf(s.name)}, ValueRange{f0},
                 llvm::SmallVector<AffineMap>{imap, omap}, iters,
                 [&](OpBuilder &nb, Location nl, ValueRange ra) {
                   Value bi0 = linalg::IndexOp::create(nb, nl, 0);
                   Value bi = arith::IndexCastOp::create(nb, nl, nb.getI32Type(), bi0);
                   Value av = arith::ExtUIOp::create(nb, nl, nb.getI32Type(), ra[0]);
                   Value eq = arith::CmpIOp::create(nb, nl, arith::CmpIPredicate::eq,
                                                    av, bi);
                   Value one = arith::ConstantOp::create(nb, nl, f32,
                                                         nb.getFloatAttr(f32, 1.0));
                   Value zero = arith::ConstantOp::create(nb, nl, f32,
                                                          nb.getFloatAttr(f32, 0.0));
                   Value dv = arith::SelectOp::create(nb, nl, eq, one, zero);
                   // No fastmath, matching frozen output.
                   linalg::YieldOp::create(
                       nb, nl, Value(arith::AddFOp::create(nb, nl, ra[1], dv)));
                 })
          .getResult(0);
    };

    auto emitWindow = [&](const TensorSource &s) -> Value {
      auto wit = d.windows.find(s.win);
      if (wit == d.windows.end()) { padBad = "window :" + s.win; return Value(); }
      const auto &coef = wit->second;
      const int64_t kh = coef.size(), kw = coef.empty() ? 0 : coef[0].size();
      Value pad = emitPad(s.name, kh / 2, kw / 2);
      auto hw = dimsOf(s.name);
      Value flt = denseFilter(coef, s.op);
      Value e1 = mlir::tensor::EmptyOp::create(b, loc, nhwcTy.getShape(), f32,
                                               ValueRange{hw.first, hw.second});
      Value f1 = linalg::FillOp::create(b, loc, ValueRange{zerof()}, ValueRange{e1})
                     .getResult(0);
      auto ones = DenseIntElementsAttr::get(
          RankedTensorType::get({2}, b.getIntegerType(64)), {int64_t(1), int64_t(1)});
      if (s.op == "conv2d")
        return linalg::Conv2DNhwcHwcfOp::create(
                   b, loc, TypeRange{nhwcTy}, ValueRange{pad, flt}, ValueRange{f1},
                   ones, ones)
            .getResult(0);
      return linalg::DepthwiseConv2DNhwcHwcOp::create(
                 b, loc, TypeRange{nhwcTy}, ValueRange{pad, flt}, ValueRange{f1},
                 ones, ones)
          .getResult(0);
    };

    // ins follows first source appearance excluding destination. Build tensor-level matvec/window
    // prologues first, in a single srcs-order loop so mixed forms interleave as frozen
    // _build_assign does.
    llvm::SmallVector<const TensorSource *> srcs;
    for (const TensorSource &s : body.sources) {
      if (s.kind == TensorSource::Kind::Param && !destName.empty() &&
          s.name == destName)
        continue;
      if (s.kind == TensorSource::Kind::Param &&
          llvm::find(body.paramNames, s.name) == body.paramNames.end())
        continue;
      srcs.push_back(&s);
    }

    llvm::SmallVector<Value> ins;
    llvm::SmallVector<std::string> insNames;
    llvm::SmallVector<bool> insU8;
    llvm::SmallVector<AffineMap> insMaps;
    const int er = body.ewRank;
    auto identity = AffineMap::getMultiDimIdentityMap(er, &context);
    // Map rank-er region indices to window results with (d0,..)->(0,d0,..). Neighborhood access is
    // inside convolution, not this region.
    auto windowMap = [&]() -> AffineMap {
      llvm::SmallVector<AffineExpr> res;
      res.push_back(getAffineConstantExpr(0, &context));
      for (int i = 0; i < er; ++i) res.push_back(getAffineDimExpr(i, &context));
      return AffineMap::get(er, 0, res, &context);
    };

    for (const TensorSource *sp : srcs) {
      const TensorSource &s = *sp;
      if (s.kind == TensorSource::Kind::Matvec) {
        // linalg.matvec outs is a zero-filled tensor with one element per row.
        Value c0 = idxc(0);
        Value zero = zerof();
        Value rows = mlir::tensor::DimOp::create(b, loc, argOf(s.mat), c0);
        notePro(rows.getDefiningOp());
        Value empty = mlir::tensor::EmptyOp::create(
            b, loc, llvm::SmallVector<int64_t>{ShapedType::kDynamic}, f32,
            ValueRange{rows});
        Value filled =
            linalg::FillOp::create(b, loc, ValueRange{zero}, ValueRange{empty})
                .getResult(0);
        Value mv = linalg::MatvecOp::create(
                       b, loc, TypeRange{filled.getType()},
                       ValueRange{argOf(s.mat), argOf(s.vec)}, ValueRange{filled})
                       .getResult(0);
        mvSlot[s.node] = ins.size();
        ins.push_back(mv);
        insNames.push_back("");   // Region lookup uses node ids.
        insU8.push_back(false);
        insMaps.push_back(identity);
        continue;
      }
      if (s.kind == TensorSource::Kind::Window) {
        Value cv = emitWindow(s);
        if (!cv) return give(d.where() + ": E177 cannot build `" + padBad + "`");
        wnSlot[std::make_tuple(s.name, s.win, s.op)] = ins.size();
        ins.push_back(cv);
        insNames.push_back("");   // Region lookup uses canonical keys.
        insU8.push_back(false);   // Convolution results are f32.
        insMaps.push_back(windowMap());
        continue;
      }
      if (s.kind != TensorSource::Kind::Param) {
        // Regions read other prologue tensors through identity maps.
        Value v = s.kind == TensorSource::Kind::Mode       ? emitMode(s)
                  : s.kind == TensorSource::Kind::Tap      ? emitTap(s)
                  : s.kind == TensorSource::Kind::Bilinear ? emitBilinear(s)
                                                           : emitHist(s);
        dSlot[std::make_tuple(s.op, s.name, s.axis, s.mat, s.idx, s.wgt)] = ins.size();
        ins.push_back(v);
        insNames.push_back("");
        insU8.push_back(false);   // Prologue results are f32.
        insMaps.push_back(identity);
        continue;
      }
      ins.push_back(opndOf(s.name));
      insNames.push_back(s.name);
      insU8.push_back(dtypeOf(s.name) == "u8");
      insMaps.push_back(identity);
    }

    // Widen u8 block arguments before expression walking. The walk reads eltval without knowing
    // bytes were involved.
    auto widenIns = [&](OpBuilder &nb, Location nl, ValueRange regionArgs,
                        std::map<std::string, Value> &env) {
      for (size_t i = 0; i < insNames.size(); ++i)
        if (!insNames[i].empty())
          env[insNames[i]] = widen(nb, nl, regionArgs[i], insU8[i]);
    };
    // f32-to-u8 epilogue orders ROUND, CLAMP, narrow. fptoui is undefined out of range, so clamp
    // after rounding is essential. maxnumf/minnumf prevent NaN from reaching conversion.
    auto quantise = [&](OpBuilder &nb, Location nl, Value val) -> Value {
      Value q;
      if (d.quant == "half_up") {
        Value h = arith::ConstantOp::create(nb, nl, f32, nb.getFloatAttr(f32, 0.5));
        Value a = arith::AddFOp::create(nb, nl, val, h);
        q = math::FloorOp::create(nb, nl, a);
      } else {
        q = math::RoundEvenOp::create(nb, nl, val);
      }
      Value lo = arith::ConstantOp::create(nb, nl, f32, nb.getFloatAttr(f32, 0.0));
      Value hi = arith::ConstantOp::create(nb, nl, f32, nb.getFloatAttr(f32, 255.0));
      Value c1 = arith::MaxNumFOp::create(nb, nl, q, lo);
      Value c2 = arith::MinNumFOp::create(nb, nl, c1, hi);
      return arith::FPToUIOp::create(nb, nl, i8, c2);
    };

    if (body.root == "assign") {
      llvm::SmallVector<AffineMap> maps(insMaps.begin(), insMaps.end());
      maps.push_back(identity);
      llvm::SmallVector<utils::IteratorType> iters(er, utils::IteratorType::parallel);
      Value dest = opndOf(destName);
      const bool destU8 = dtypeOf(destName) == "u8";
      // Widen a u8 destination only if read, as frozen pdtype/source membership does; otherwise it
      // adds a dead extui.
      const bool destRead = llvm::any_of(body.sources, [&](const TensorSource &s) {
        return s.kind == TensorSource::Kind::Param && s.name == destName;
      });
      auto generic = linalg::GenericOp::create(
          b, loc, TypeRange{dest.getType()}, ins, ValueRange{dest}, maps, iters,
          [&](OpBuilder &nb, Location nl, ValueRange regionArgs) {
            regionArgsRef = &regionArgs;
            std::map<std::string, Value> env;
            widenIns(nb, nl, regionArgs, env);
            env[destName] = widen(nb, nl, regionArgs.back(), destU8 && destRead);
            for (size_t i = 0; i < d.params.size(); ++i)
              if (d.params[i] == "scalar") {
                env[body.paramNames[i]] = entry->getArgument(i);
                captures.insert(entry->getArgument(i));
              }
            Value v = walk(nb, nl, body.exprNode, env);
            if (!v) { linalg::YieldOp::create(nb, nl, regionArgs.back()); return; }
            linalg::YieldOp::create(nb, nl, destU8 ? quantise(nb, nl, v) : v);
          });
      if (bad) return give(d.where() + ": E177 stage (1) cannot build `" + badWhy + "`");
      Value res = generic.getResult(0);
      if (destU8)
        res = mlir::tensor::BitcastOp::create(b, loc, argTys[d.dest], res);
      func::ReturnOp::create(b, loc, res);
      continue;
    }

    // ---- Reduction (default mode) --------------------------------------------
    Value init = arith::ConstantOp::create(
        b, loc, f32, b.getFloatAttr(f32, llvm::APFloat(reducerInit(body.root))));
    auto zeroD = RankedTensorType::get({}, f32);
    Value empty = mlir::tensor::EmptyOp::create(b, loc, zeroD, ValueRange{});
    Value filled =
        linalg::FillOp::create(b, loc, ValueRange{init}, ValueRange{empty})
            .getResult(0);
    llvm::SmallVector<AffineMap> maps(insMaps.begin(), insMaps.end());
    maps.push_back(AffineMap::get(er, 0, {}, &context));
    llvm::SmallVector<utils::IteratorType> iters(er, utils::IteratorType::reduction);
    auto generic = linalg::GenericOp::create(
        b, loc, TypeRange{zeroD}, ins, ValueRange{filled}, maps, iters,
        [&](OpBuilder &nb, Location nl, ValueRange regionArgs) {
          regionArgsRef = &regionArgs;
          std::map<std::string, Value> env;
          widenIns(nb, nl, regionArgs, env);
          for (size_t i = 0; i < d.params.size(); ++i)
            if (d.params[i] == "scalar") {
              env[body.paramNames[i]] = entry->getArgument(i);
              captures.insert(entry->getArgument(i));
            }
          Value v = walk(nb, nl, body.exprNode, env);
          if (!v) { linalg::YieldOp::create(nb, nl, regionArgs.back()); return; }
          // Preserve combine(out,expr) operand order from frozen text.
          Value acc = regionArgs.back();
          Value combined =
              body.root == "max" ? Value(arith::MaximumFOp::create(nb, nl, acc, v))
              : body.root == "min" ? Value(arith::MinimumFOp::create(nb, nl, acc, v))
                                   : Value(arith::AddFOp::create(nb, nl, acc, v, fast));
          linalg::YieldOp::create(nb, nl, combined);
        });
    if (bad) return give(d.where() + ": E177 stage (1) cannot build `" + badWhy + "`");
    Value scalar = mlir::tensor::ExtractOp::create(b, loc, generic.getResult(0),
                                                   ValueRange{});
    func::ReturnOp::create(b, loc, scalar);
  }
  if (mlir::failed(mlir::verify(*root)))
    return give("generated module failed verification");
  return root;
}

} // namespace spinel_mlir::tensor
