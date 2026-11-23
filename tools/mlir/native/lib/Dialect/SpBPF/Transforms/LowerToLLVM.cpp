// Lower SpBPF to LLVM dialect. Only the target-profile table knows helper numbers and availability
// by program kind, not frontend/dialect/schema. Like libbpf, inttoptr a constant helper id then
// indirect-call it; BPF lowers that to call immediate. Maps are .maps globals referenced with
// addressof for loader fd relocations. BTF was added by the later object-emission stage.
#include "spinel-mlir/Dialect/SpBPF/Transforms/Passes.h"

#include "spinel-mlir/Dialect/SpBPF/IR/SpBPFDialect.h"

#include "mlir/Conversion/LLVMCommon/TypeConverter.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Dialect/ControlFlow/IR/ControlFlowOps.h"
#include "mlir/Dialect/LLVMIR/LLVMDialect.h"
#include "mlir/IR/Builders.h"
#include "mlir/IR/IRMapping.h"
#include "llvm/ADT/StringMap.h"

namespace mlir {
namespace spbpf {
#define GEN_PASS_DEF_CONVERTSPBPFTOLLVM
#include "spinel-mlir/Dialect/SpBPF/Transforms/Passes.h.inc"
} // namespace spbpf
} // namespace mlir

using namespace mlir;
using namespace mlir::spbpf;

namespace {

// Target profile owns helper numbers and availability.
enum class Helper { MapLookup, MapUpdate, KtimeGetNs, RingbufReserve,
                    RingbufSubmit, RingbufDiscard };

// Helper ids from Linux bpf_func_id.
unsigned helperNumber(Helper h) {
  switch (h) {
  case Helper::MapLookup:
    return 1; // BPF_FUNC_map_lookup_elem
  case Helper::MapUpdate:
    return 2; // BPF_FUNC_map_update_elem
  case Helper::KtimeGetNs:
    return 5; // BPF_FUNC_ktime_get_ns
  case Helper::RingbufReserve:
    return 131; // BPF_FUNC_ringbuf_reserve
  case Helper::RingbufSubmit:
    return 132; // BPF_FUNC_ringbuf_submit
  case Helper::RingbufDiscard:
    return 133; // BPF_FUNC_ringbuf_discard
  }
  return 0;
}

const char *helperName(Helper h) {
  switch (h) {
  case Helper::MapLookup:
    return "map_lookup_elem";
  case Helper::MapUpdate:
    return "map_update_elem";
  case Helper::KtimeGetNs:
    return "ktime_get_ns";
  case Helper::RingbufReserve:
    return "ringbuf_reserve";
  case Helper::RingbufSubmit:
    return "ringbuf_submit";
  case Helper::RingbufDiscard:
    return "ringbuf_discard";
  }
  return "?";
}

// Availability by program kind; initially xdp only.
bool helperAllowedFor(StringRef programKind, Helper h) {
  if (programKind == "xdp")
    return true;
  return false;
}

// Map xdp_action verdict spellings to return values.
int xdpVerdictValue(StringRef action) {
  if (action == "aborted")
    return 0;
  if (action == "drop")
    return 1;
  if (action == "pass")
    return 2;
  if (action == "tx")
    return 3;
  if (action == "redirect")
    return 4;
  return -1;
}

// Conversion implementation.
struct Lowering {
  ModuleOp module;
  OpBuilder builder;
  StringRef programKind;
  llvm::StringMap<LLVM::GlobalOp> mapGlobals;
  bool failed = false;

  explicit Lowering(ModuleOp m) : module(m), builder(m.getContext()) {}

  Type ptrTy() { return LLVM::LLVMPointerType::get(module.getContext()); }
  Type i64Ty() { return builder.getI64Type(); }
  Type i32Ty() { return builder.getI32Type(); }

  // Emit schema map symbols as .maps globals. The later emission stage supplies BTF-backed
  // definitions; here ensure referenced symbols exist.
  LLVM::GlobalOp mapGlobal(StringRef symbol, Location loc) {
    auto it = mapGlobals.find(symbol);
    if (it != mapGlobals.end())
      return it->second;
    OpBuilder::InsertionGuard g(builder);
    builder.setInsertionPointToStart(module.getBody());
    auto ty = LLVM::LLVMArrayType::get(builder.getI8Type(), 1);
    auto global = LLVM::GlobalOp::create(
        builder, loc, ty, /*isConstant=*/false, LLVM::Linkage::External,
        symbol, /*value=*/Attribute());
    global.setSection(".maps");
    mapGlobals[symbol] = global;
    return global;
  }

  // Use the caller builder. The Lowering builder has no insertion point; confusing them previously
  // created unlinked operations.
  Value helperCall(OpBuilder &b, Location loc, Helper h, ValueRange args,
                   Type resultTy) {
    if (!helperAllowedFor(programKind, h)) {
      failed = true;
      module.emitError() << "helper " << helperName(h)
                         << " is not available for program kind \""
                         << programKind << "\"";
      return {};
    }
    Value num = LLVM::ConstantOp::create(b, loc, b.getI64Type(),
                                         b.getI64IntegerAttr(helperNumber(h)));
    Value fn = LLVM::IntToPtrOp::create(b, loc, ptrTy(), num);
    SmallVector<Type> argTys;
    for (Value a : args)
      argTys.push_back(a.getType());
    SmallVector<Type> resTys;
    if (resultTy)
      resTys.push_back(resultTy);
    auto fnTy = LLVM::LLVMFunctionType::get(
        resultTy ? resultTy : LLVM::LLVMVoidType::get(module.getContext()),
        argTys);
    SmallVector<Value> callArgs;
    callArgs.push_back(fn);
    callArgs.append(args.begin(), args.end());
    auto call = LLVM::CallOp::create(b, loc, fnTy, callArgs);
    return resultTy ? call.getResult() : Value();
  }

};

} // namespace

namespace {

struct ConvertSpBPFToLLVMPass
    : public mlir::spbpf::impl::ConvertSpBPFToLLVMBase<
          ConvertSpBPFToLLVMPass> {
  void runOnOperation() override;
};

} // namespace

// Per-program conversion.
namespace {

class ProgramLowering {
public:
  ProgramLowering(ProgramOp prog, Lowering &ctx)
      : prog_(prog), ctx_(ctx), b_(prog.getContext()) {}

  LogicalResult run();

private:
  Value remap(Value v) {
    auto it = map_.find(v);
    return it == map_.end() ? Value() : it->second;
  }
  void bind(Value from, Value to) { map_[from] = to; }

  LogicalResult convertBlock(Block &src, Block *dst);
  LogicalResult convertOp(Operation &op);

  Value allocaFor(Type t, Location loc);
  Value spillInt(Value v, Location loc);

  ProgramOp prog_;
  Lowering &ctx_;
  OpBuilder b_;
  DenseMap<Value, Value> map_;
  LLVM::LLVMFuncOp func_;
  Block *entry_ = nullptr;
  // ref.check merge destination, targeted by yield.
  SmallVector<std::pair<Block *, SmallVector<Value>>> joinStack_;
};

Value ProgramLowering::allocaFor(Type t, Location loc) {
  OpBuilder::InsertionGuard g(b_);
  b_.setInsertionPointToStart(entry_);
  Value one = LLVM::ConstantOp::create(b_, loc, b_.getI64Type(),
                                       b_.getI64IntegerAttr(1));
  return LLVM::AllocaOp::create(b_, loc, ctx_.ptrTy(), t, one);
}

Value ProgramLowering::spillInt(Value v, Location loc) {
  Value slot = allocaFor(v.getType(), loc);
  LLVM::StoreOp::create(b_, loc, v, slot);
  return slot;
}

LogicalResult ProgramLowering::run() {
  Location loc = prog_.getLoc();
  ctx_.programKind = prog_.getKind();

  // program becomes llvm.func @name(ptr) -> i32 with an attach-specific section.
  auto fnTy = LLVM::LLVMFunctionType::get(b_.getI32Type(), {ctx_.ptrTy()});
  {
    OpBuilder::InsertionGuard g(b_);
    b_.setInsertionPoint(prog_);
    func_ = LLVM::LLVMFuncOp::create(b_, loc, prog_.getSymName(), fnTy);
    func_.setSection(prog_.getKind());
  }
  entry_ = func_.addEntryBlock(b_);

  Block &srcEntry = prog_.getBody().front();
  bind(srcEntry.getArgument(0), entry_->getArgument(0));

  // Replace map arguments with global addressof relocations.
  b_.setInsertionPointToStart(entry_);
  ArrayAttr syms = prog_.getMapSymbolsAttr();
  for (auto [i, arg] : llvm::enumerate(srcEntry.getArguments().drop_front())) {
    auto flat = cast<FlatSymbolRefAttr>(syms[i]);
    auto global = ctx_.mapGlobal(flat.getValue(), loc);
    Value addr = LLVM::AddressOfOp::create(b_, loc, global);
    bind(arg, addr);
  }

  if (failed(convertBlock(srcEntry, entry_)))
    return failure();
  prog_.erase();
  return success();
}

LogicalResult ProgramLowering::convertBlock(Block &src, Block *dst) {
  b_.setInsertionPointToEnd(dst);
  for (Operation &op : src) {
    if (failed(convertOp(op)))
      return failure();
  }
  return success();
}

LogicalResult ProgramLowering::convertOp(Operation &op) {
  Location loc = op.getLoc();

  if (auto verdict = dyn_cast<VerdictOp>(op)) {
    int v = xdpVerdictValue(verdict.getAction());
    Value c = LLVM::ConstantOp::create(b_, loc, b_.getI32Type(),
                                       b_.getI32IntegerAttr(v));
    LLVM::ReturnOp::create(b_, loc, ValueRange{c});
    return success();
  }

  if (auto lookup = dyn_cast<MapLookupOp>(op)) {
    Value m = remap(lookup.getMap());
    Value keyPtr = spillInt(remap(lookup.getKey()), loc);
    Value r = ctx_.helperCall(b_, loc, Helper::MapLookup, {m, keyPtr},
                              ctx_.ptrTy());
    if (!r)
      return failure();
    bind(lookup.getResult(), r);
    return success();
  }

  if (auto update = dyn_cast<MapUpdateOp>(op)) {
    Value m = remap(update.getMap());
    Value keyPtr = spillInt(remap(update.getKey()), loc);
    Value valPtr = spillInt(remap(update.getValue()), loc);
    Value flags = LLVM::ConstantOp::create(b_, loc, b_.getI64Type(),
                                           b_.getI64IntegerAttr(0));
    if (!ctx_.helperCall(b_, loc, Helper::MapUpdate, {m, keyPtr, valPtr, flags},
                         b_.getI64Type()))
      return failure();
    return success();
  }

  if (auto add = dyn_cast<MapAtomicAddOp>(op)) {
    // Standard BPF sequence: lookup, null check, atomicrmw add.
    Value m = remap(add.getMap());
    Value keyPtr = spillInt(remap(add.getKey()), loc);
    Value slot = ctx_.helperCall(b_, loc, Helper::MapLookup, {m, keyPtr},
                                 ctx_.ptrTy());
    if (!slot)
      return failure();
    Value null = LLVM::ZeroOp::create(b_, loc, ctx_.ptrTy());
    Value ok = LLVM::ICmpOp::create(b_, loc, LLVM::ICmpPredicate::ne, slot,
                                    null);
    Block *cur = b_.getInsertionBlock();
    Block *addBlk = cur->splitBlock(b_.getInsertionPoint());
    Block *cont = addBlk->splitBlock(addBlk->begin());
    b_.setInsertionPointToEnd(cur);
    LLVM::CondBrOp::create(b_, loc, ok, addBlk, ValueRange{}, cont,
                           ValueRange{});
    b_.setInsertionPointToEnd(addBlk);
    LLVM::AtomicRMWOp::create(b_, loc, LLVM::AtomicBinOp::add, slot,
                              remap(add.getDelta()),
                              LLVM::AtomicOrdering::monotonic);
    LLVM::BrOp::create(b_, loc, cont);
    b_.setInsertionPointToEnd(cont);
    return success();
  }

  if (auto load = dyn_cast<RefLoadOp>(op)) {
    Value p = remap(load.getRef());
    Value v = LLVM::LoadOp::create(b_, loc, load.getResult().getType(), p);
    bind(load.getResult(), v);
    return success();
  }

  if (auto reserve = dyn_cast<RingbufReserveOp>(op)) {
    auto resTy = cast<ReservationType>(reserve.getResult().getType());
    // Reservation types carry size: integer width or schema size embedded in a record. Separate
    // schema verification checks agreement. Only those two types occur; never silently default to
    // eight bytes.
    int64_t bytes = 0;
    if (auto it = dyn_cast<IntegerType>(resTy.getRecordType()))
      bytes = it.getWidth() / 8;
    else if (auto rt = dyn_cast<RecordType>(resTy.getRecordType()))
      bytes = rt.getSize();
    if (bytes <= 0) {
      op.emitError() << "cannot size a reservation of "
                     << resTy.getRecordType();
      return failure();
    }
    Value rb = LLVM::AddressOfOp::create(
        b_, loc, ctx_.mapGlobal(reserve.getRingbuf(), loc));
    Value size = LLVM::ConstantOp::create(b_, loc, b_.getI64Type(),
                                          b_.getI64IntegerAttr(bytes));
    Value flags = LLVM::ConstantOp::create(b_, loc, b_.getI64Type(),
                                           b_.getI64IntegerAttr(0));
    Value r = ctx_.helperCall(b_, loc, Helper::RingbufReserve, {rb, size, flags},
                              ctx_.ptrTy());
    if (!r)
      return failure();
    bind(reserve.getResult(), r);
    return success();
  }

  // Check reservation null exactly once at if_reserved region entry. store/submit/discard occur
  // only in present, so introduce no hidden per-use branches; the former temporary workaround hid
  // control flow, now explicit in the dialect.
  if (auto store = dyn_cast<RingbufStoreOp>(op)) {
    LLVM::StoreOp::create(b_, loc, remap(store.getValue()),
                          remap(store.getReservation()));
    return success();
  }

  if (auto sf = dyn_cast<RingbufStoreFieldOp>(op)) {
    Value base = remap(sf.getReservation());
    Value at = LLVM::GEPOp::create(
        b_, loc, ctx_.ptrTy(), b_.getI8Type(), base,
        ArrayRef<LLVM::GEPArg>{static_cast<int32_t>(sf.getOffset())});
    LLVM::StoreOp::create(b_, loc, remap(sf.getValue()), at);
    return success();
  }

  if (auto kt = dyn_cast<KtimeOp>(op)) {
    Value v = ctx_.helperCall(b_, loc, Helper::KtimeGetNs, {}, b_.getI64Type());
    if (!v)
      return failure();
    bind(kt.getResult(), v);
    return success();
  }

  if (auto rs = dyn_cast<RefStoreOp>(op)) {
    LLVM::StoreOp::create(b_, loc, remap(rs.getValue()), remap(rs.getRef()));
    return success();
  }

  if (auto submit = dyn_cast<RingbufSubmitOp>(op)) {
    Value flags = LLVM::ConstantOp::create(b_, loc, b_.getI64Type(),
                                           b_.getI64IntegerAttr(0));
    if (!ctx_.helperCall(b_, loc, Helper::RingbufSubmit,
                         {remap(submit.getReservation()), flags},
                         b_.getI64Type()))
      return failure();
    return success();
  }

  if (auto discard = dyn_cast<RingbufDiscardOp>(op)) {
    Value flags = LLVM::ConstantOp::create(b_, loc, b_.getI64Type(),
                                           b_.getI64IntegerAttr(0));
    if (!ctx_.helperCall(b_, loc, Helper::RingbufDiscard,
                         {remap(discard.getReservation()), flags},
                         b_.getI64Type()))
      return failure();
    return success();
  }

  // Lower successful-reservation checking to an actual null branch, as for ref.check.
  if (auto ifres = dyn_cast<RingbufIfReservedOp>(op)) {
    Value maybe = remap(ifres.getReservation());
    Value null = LLVM::ZeroOp::create(b_, loc, ctx_.ptrTy());
    Value have = LLVM::ICmpOp::create(b_, loc, LLVM::ICmpPredicate::ne, maybe,
                                      null);
    Block *cur = b_.getInsertionBlock();
    Block *presentBlk = cur->splitBlock(b_.getInsertionPoint());
    Block *absentBlk = presentBlk->splitBlock(presentBlk->begin());
    Block *cont = absentBlk->splitBlock(absentBlk->begin());

    b_.setInsertionPointToEnd(cur);
    LLVM::CondBrOp::create(b_, loc, have, presentBlk, ValueRange{}, absentBlk,
                           ValueRange{});

    Block &srcPresent = ifres.getPresentRegion().front();
    bind(srcPresent.getArgument(0), maybe);
    joinStack_.push_back({cont, {}});
    b_.setInsertionPointToEnd(presentBlk);
    for (Operation &inner : srcPresent)
      if (failed(convertOp(inner)))
        return failure();

    Block &srcAbsent = ifres.getAbsentRegion().front();
    b_.setInsertionPointToEnd(absentBlk);
    for (Operation &inner : srcAbsent)
      if (failed(convertOp(inner)))
        return failure();
    joinStack_.pop_back();

    b_.setInsertionPointToEnd(cont);
    return success();
  }

  if (auto packet = dyn_cast<PacketLoadOp>(op)) {
    // xdp_md data/data_end are __u32, whose four-byte reads the verifier rewrites to pointers.
    // Eight-byte reads fail invalid bpf_context access off=4 size=8 (observed on a kernel). Read
    // u32, widen to 64 bits, then inttoptr, as C (void *)(long)ctx->data does.
    Value ctx = remap(packet.getCtx());
    Value dataP = LLVM::GEPOp::create(b_, loc, ctx_.ptrTy(), b_.getI32Type(),
                                      ctx, ArrayRef<LLVM::GEPArg>{0});
    Value endP = LLVM::GEPOp::create(b_, loc, ctx_.ptrTy(), b_.getI32Type(),
                                     ctx, ArrayRef<LLVM::GEPArg>{1});
    auto asPtr = [&](Value raw) {
      Value wide = LLVM::ZExtOp::create(b_, loc, b_.getI64Type(), raw);
      return LLVM::IntToPtrOp::create(b_, loc, ctx_.ptrTy(), wide).getResult();
    };
    Value data = asPtr(LLVM::LoadOp::create(b_, loc, b_.getI32Type(), dataP));
    Value end = asPtr(LLVM::LoadOp::create(b_, loc, b_.getI32Type(), endP));
    Value off = remap(packet.getOffset());
    Value off64 = LLVM::ZExtOp::create(b_, loc, b_.getI64Type(), off);
    Value at = LLVM::GEPOp::create(b_, loc, ctx_.ptrTy(), b_.getI8Type(), data,
                                   ArrayRef<LLVM::GEPArg>{off64});
    Type resTy = packet.getResult().getType();
    unsigned width = cast<IntegerType>(resTy).getWidth() / 8;
    Value past = LLVM::GEPOp::create(
        b_, loc, ctx_.ptrTy(), b_.getI8Type(), at,
        ArrayRef<LLVM::GEPArg>{static_cast<int32_t>(width)});
    Value inBounds = LLVM::ICmpOp::create(b_, loc, LLVM::ICmpPredicate::ule,
                                          past, end);
    Block *cur = b_.getInsertionBlock();
    Block *loadBlk = cur->splitBlock(b_.getInsertionPoint());
    Block *cont = loadBlk->splitBlock(loadBlk->begin());
    Value phi = cont->addArgument(resTy, loc);
    b_.setInsertionPointToEnd(cur);
    Value zero = LLVM::ConstantOp::create(b_, loc, resTy,
                                          b_.getIntegerAttr(resTy, 0));
    LLVM::CondBrOp::create(b_, loc, inBounds, loadBlk, ValueRange{}, cont,
                           ValueRange{zero});
    b_.setInsertionPointToEnd(loadBlk);
    Value v = LLVM::LoadOp::create(b_, loc, resTy, at);
    LLVM::BrOp::create(b_, loc, ValueRange{v}, cont);
    b_.setInsertionPointToEnd(cont);
    bind(packet.getResult(), phi);
    return success();
  }

  if (auto check = dyn_cast<RefCheckOp>(op)) {
    // Lower the region structure into an actual null branch.
    Value ref = remap(check.getRef());
    Value null = LLVM::ZeroOp::create(b_, loc, ctx_.ptrTy());
    Value present = LLVM::ICmpOp::create(b_, loc, LLVM::ICmpPredicate::ne, ref,
                                         null);
    Block *cur = b_.getInsertionBlock();
    Block *presentBlk = cur->splitBlock(b_.getInsertionPoint());
    Block *absentBlk = presentBlk->splitBlock(presentBlk->begin());
    Block *cont = absentBlk->splitBlock(absentBlk->begin());
    for (Type t : check.getResultTypes())
      cont->addArgument(t, loc);

    b_.setInsertionPointToEnd(cur);
    LLVM::CondBrOp::create(b_, loc, present, presentBlk, ValueRange{},
                           absentBlk, ValueRange{});

    // Present-region borrowed block arguments become raw pointers.
    Block &srcPresent = check.getPresentRegion().front();
    bind(srcPresent.getArgument(0), ref);
    joinStack_.push_back({cont, {}});
    b_.setInsertionPointToEnd(presentBlk);
    for (Operation &inner : srcPresent)
      if (failed(convertOp(inner)))
        return failure();

    Block &srcAbsent = check.getAbsentRegion().front();
    b_.setInsertionPointToEnd(absentBlk);
    for (Operation &inner : srcAbsent)
      if (failed(convertOp(inner)))
        return failure();
    joinStack_.pop_back();

    b_.setInsertionPointToEnd(cont);
    for (auto [i, res] : llvm::enumerate(check.getResults()))
      bind(res, cont->getArgument(i));
    return success();
  }

  if (auto yield = dyn_cast<YieldOp>(op)) {
    SmallVector<Value> vals;
    for (Value v : yield.getResults())
      vals.push_back(remap(v));
    LLVM::BrOp::create(b_, loc, vals, joinStack_.back().first);
    return success();
  }

  // Clone non-SpBPF operations such as arith unchanged except for remapping operands.
  IRMapping m;
  for (Value v : op.getOperands())
    if (Value r = remap(v))
      m.map(v, r);
  Operation *cloned = b_.clone(op, m);
  for (auto [i, res] : llvm::enumerate(op.getResults()))
    bind(res, cloned->getResult(i));
  return success();
}

} // namespace

void ConvertSpBPFToLLVMPass::runOnOperation() {
  ModuleOp module = getOperation();
  Lowering ctx(module);

  SmallVector<ProgramOp> programs;
  module.walk([&](ProgramOp p) { programs.push_back(p); });
  for (ProgramOp p : programs) {
    ProgramLowering pl(p, ctx);
    if (failed(pl.run()) || ctx.failed) {
      signalPassFailure();
      return;
    }
  }
}
