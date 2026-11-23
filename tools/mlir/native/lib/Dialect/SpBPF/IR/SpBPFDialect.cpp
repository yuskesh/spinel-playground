// Register SpBPF dialect and verify only eBPF-specific properties not expressible by standard
// dialects; the refusal categories explain why each is custom.
#include "spinel-mlir/Dialect/SpBPF/IR/SpBPFDialect.h"

#include "mlir/IR/Builders.h"
#include "mlir/IR/DialectImplementation.h"
#include "llvm/ADT/DenseSet.h"
#include "llvm/ADT/StringExtras.h"
#include "llvm/ADT/TypeSwitch.h"

using namespace mlir;
using namespace mlir::spbpf;

#include "spinel-mlir/Dialect/SpBPF/IR/SpBPFOpsDialect.cpp.inc"

#define GET_TYPEDEF_CLASSES
#include "spinel-mlir/Dialect/SpBPF/IR/SpBPFOpsTypes.cpp.inc"

#define GET_OP_CLASSES
#include "spinel-mlir/Dialect/SpBPF/IR/SpBPFOps.cpp.inc"

// Known sets; initial slice was XDP with HASH/ARRAY.
namespace {

constexpr llvm::StringLiteral kProgramKinds[] = {"xdp"};
constexpr llvm::StringLiteral kMapKinds[] = {"hash", "array", "percpu_array"};
// XDP verdicts from include/uapi/linux/bpf.h xdp_action.
constexpr llvm::StringLiteral kXdpVerdicts[] = {"aborted", "drop", "pass", "tx",
                                                "redirect"};

std::string join(llvm::ArrayRef<llvm::StringLiteral> xs) {
  std::string out;
  for (auto [i, x] : llvm::enumerate(xs)) {
    if (i)
      out += ", ";
    out += "\"";
    out += x.str();
    out += "\"";
  }
  return out;
}

bool contains(llvm::ArrayRef<llvm::StringLiteral> xs, llvm::StringRef v) {
  return llvm::is_contained(xs, v);
}

} // namespace

namespace mlir {
namespace spbpf {

bool isKnownProgramKind(llvm::StringRef kind) {
  return contains(kProgramKinds, kind);
}
bool isKnownMapKind(llvm::StringRef kind) { return contains(kMapKinds, kind); }

bool isVerdictAllowedFor(llvm::StringRef programKind, llvm::StringRef action) {
  if (programKind == "xdp")
    return contains(kXdpVerdicts, action);
  return false;
}

// Direct packet reads require an attach kind that supplies a packet.
bool supportsPacketAccess(llvm::StringRef programKind) {
  return programKind == "xdp";
}

std::string knownProgramKinds() { return join(kProgramKinds); }
std::string knownMapKinds() { return join(kMapKinds); }
std::string knownVerdicts(llvm::StringRef programKind) {
  if (programKind == "xdp")
    return join(kXdpVerdicts);
  return "(none)";
}

} // namespace spbpf
} // namespace mlir

//===----------------------------------------------------------------------===//
// Dialect registration
//===----------------------------------------------------------------------===//
void SpBPFDialect::initialize() {
  addTypes<
#define GET_TYPEDEF_LIST
#include "spinel-mlir/Dialect/SpBPF/IR/SpBPFOpsTypes.cpp.inc"
      >();
  addOperations<
#define GET_OP_LIST
#include "spinel-mlir/Dialect/SpBPF/IR/SpBPFOps.cpp.inc"
      >();
}

//===----------------------------------------------------------------------===//
// spbpf.program
//===----------------------------------------------------------------------===//
LogicalResult ProgramOp::verify() {
  // Refusal 1: unknown program kind.
  if (!isKnownProgramKind(getKind()))
    return emitOpError() << "unknown program kind \"" << getKind()
                         << "\" (known: " << knownProgramKinds() << ")";

  // Entry has one context and zero or more loader-provided map handles. There is no map declaration
  // op; maps cross the boundary, closing the initial operation-list omission.
  Block &entry = getBody().front();
  if (entry.getNumArguments() < 1)
    return emitOpError() << "entry block must take a context argument";

  auto ctxTy = dyn_cast<ContextType>(entry.getArgument(0).getType());
  if (!ctxTy)
    return emitOpError() << "first entry block argument must be !spbpf.ctx<...>, "
                         << "got " << entry.getArgument(0).getType();
  if (ctxTy.getKind() != getKind())
    return emitOpError() << "context kind \"" << ctxTy.getKind()
                         << "\" does not match program kind \"" << getKind()
                         << "\"";
  auto mapArgs = entry.getArguments().drop_front();
  for (BlockArgument arg : mapArgs) {
    // Name attempts to bind the context as a map explicitly.
    if (isa<ContextType>(arg.getType()))
      return emitOpError() << "only the first entry block argument may be a "
                           << "context; argument #" << arg.getArgNumber()
                           << " is another !spbpf.ctx and cannot be bound to a "
                           << "map symbol";
    if (!isa<MapType>(arg.getType()))
      return emitOpError() << "entry block arguments after the context must be "
                           << "!spbpf.map<...> (map handles), got "
                           << arg.getType();
  }

  // Map arguments bind positionally to schema symbols. Initially only structure/duplicates were
  // checked without schema implementation; later schema verification owns existence and
  // kind/key/value consistency.
  ArrayAttr syms = getMapSymbolsAttr();
  size_t numSyms = syms ? syms.size() : 0;
  if (numSyms != mapArgs.size())
    return emitOpError() << "every map argument must be bound to a schema symbol: "
                         << mapArgs.size() << " map argument(s) but " << numSyms
                         << " symbol(s) in `maps`";
  llvm::SmallDenseSet<llvm::StringRef> seenSyms;
  if (syms) {
    for (Attribute a : syms) {
      auto flat = dyn_cast<FlatSymbolRefAttr>(a);
      if (!flat)
        return emitOpError() << "map symbols must be flat symbol references, got "
                             << a;
      if (!seenSyms.insert(flat.getValue()).second)
        return emitOpError() << "map symbol @" << flat.getValue()
                             << " is bound twice";
    }
  }

  if (!isa<VerdictOp>(entry.getTerminator()))
    return emitOpError() << "must be terminated by spbpf.verdict, got "
                         << entry.getTerminator()->getName();

  // Refusal 4: never directly use unchecked reservations. Successful reservations exist only as
  // if_reserved present-region block arguments, whose verifier handles linearity. Here restrict
  // maybe_reservation uses to if_reserved.
  bool bad = false;
  getBody().walk([&](Operation *op) {
    for (Value res : op->getResults()) {
      if (!isa<MaybeReservationType>(res.getType()))
        continue;
      unsigned checks = 0;
      for (Operation *user : res.getUsers()) {
        if (isa<RingbufIfReservedOp>(user)) {
          ++checks;
          continue;
        }
        bad = true;
        auto d = op->emitOpError()
                 << "an unchecked ring buffer reservation may only be consumed "
                 << "by spbpf.ringbuf.if_reserved, but it is used by '"
                 << user->getName() << "'";
        d.attachNote() << "bpf_ringbuf_reserve can return NULL; the kernel "
                          "rejects storing to or submitting a possibly-null "
                          "reservation";
      }
      if (checks != 1) {
        bad = true;
        auto d = op->emitOpError()
                 << "a ring buffer reservation must be checked exactly once by "
                 << "spbpf.ringbuf.if_reserved, found " << checks;
        if (checks == 0)
          d.attachNote() << "an unchecked reservation leaks ring buffer space";
      }
    }
  });
  return failure(bad);
}

//===----------------------------------------------------------------------===//
// spbpf.verdict
//===----------------------------------------------------------------------===//
LogicalResult VerdictOp::verify() {
  auto prog = (*this)->getParentOfType<ProgramOp>();
  if (!prog)
    return emitOpError() << "must be inside spbpf.program";
  llvm::StringRef kind = prog.getKind();
  if (!isKnownProgramKind(kind))
    return success(); // Program verification already refuses this; do not report twice.
  if (!isVerdictAllowedFor(kind, getAction()))
    return emitOpError() << "verdict \"" << getAction()
                         << "\" is not valid for program kind \"" << kind
                         << "\" (known: " << knownVerdicts(kind) << ")";
  return success();
}

// Map operations, refusal 2: key/value type mismatch.
namespace {

LogicalResult checkMapKind(Operation *op, MapType map) {
  if (!isKnownMapKind(map.getKind()))
    return op->emitOpError() << "unknown map kind \"" << map.getKind()
                             << "\" (known: " << knownMapKinds() << ")";
  return success();
}

LogicalResult checkKey(Operation *op, MapType map, Type key) {
  if (key != map.getKeyType())
    return op->emitOpError() << "key type " << key
                             << " does not match map key type "
                             << map.getKeyType();
  return success();
}

LogicalResult checkValue(Operation *op, MapType map, Type value) {
  if (value != map.getValueType())
    return op->emitOpError() << "value type " << value
                             << " does not match map value type "
                             << map.getValueType();
  return success();
}

} // namespace

LogicalResult MapLookupOp::verify() {
  auto map = cast<MapType>(getMap().getType());
  if (failed(checkMapKind(*this, map)) ||
      failed(checkKey(*this, map, getKey().getType())))
    return failure();
  auto res = cast<MaybeRefType>(getResult().getType());
  if (res.getPointee() != map.getValueType())
    return emitOpError() << "result " << getResult().getType()
                         << " does not reference the map value type "
                         << map.getValueType();
  return success();
}

LogicalResult MapUpdateOp::verify() {
  auto map = cast<MapType>(getMap().getType());
  if (failed(checkMapKind(*this, map)) ||
      failed(checkKey(*this, map, getKey().getType())))
    return failure();
  return checkValue(*this, map, getValue().getType());
}

LogicalResult MapAtomicAddOp::verify() {
  auto map = cast<MapType>(getMap().getType());
  if (failed(checkMapKind(*this, map)) ||
      failed(checkKey(*this, map, getKey().getType())) ||
      failed(checkValue(*this, map, getDelta().getType())))
    return failure();
  // Atomic add is meaningful only for integer map values.
  if (!map.getValueType().isSignlessInteger())
    return emitOpError() << "atomic add requires a signless integer map value "
                         << "type, got " << map.getValueType();
  return success();
}

// References, refusal 3: direct use of unchecked nullable references.
LogicalResult RefCheckOp::verify() {
  auto in = cast<MaybeRefType>(getRef().getType());

  if (getPresentRegion().empty() || getAbsentRegion().empty())
    return emitOpError() << "both the present and absent regions must have a body";

  Block &present = getPresentRegion().front();
  if (present.getNumArguments() != 1)
    return emitOpError() << "the present region must take exactly one argument "
                         << "(the borrowed reference), got "
                         << present.getNumArguments();
  auto borrowed = dyn_cast<BorrowedType>(present.getArgument(0).getType());
  if (!borrowed)
    return emitOpError() << "the present region argument must be "
                         << "!spbpf.borrowed<...>, got "
                         << present.getArgument(0).getType();
  if (borrowed.getPointee() != in.getPointee())
    return emitOpError() << "the borrowed reference must keep the pointee type: "
                         << in.getPointee() << " vs " << borrowed.getPointee();

  Block &absent = getAbsentRegion().front();
  if (absent.getNumArguments() != 0)
    return emitOpError() << "the absent region must take no arguments (there is "
                         << "no reference to borrow), got "
                         << absent.getNumArguments();

  // Check borrowed-reference escape; borrowed<T> lives only in the present region.
  BlockArgument ref = present.getArgument(0);
  for (Operation *user : ref.getUsers()) {
    if (!isa<RefLoadOp, RefStoreOp>(user))
      return emitOpError() << "a borrowed reference may only be consumed by "
                           << "spbpf.ref.{load,store}, but it is used by '"
                           << user->getName()
                           << "' (storing or forwarding it lets it escape the "
                              "check region)";
    if (!getPresentRegion().isAncestor(user->getParentRegion()))
      return emitOpError() << "a borrowed reference must be used inside the "
                           << "present region of its own spbpf.ref.check";
  }

  // Do not retain it across blocks.
  for (Block &blk : getPresentRegion())
    if (&blk != &present)
      for (BlockArgument arg : blk.getArguments())
        if (isa<BorrowedType>(arg.getType()))
          return emitOpError() << "a borrowed reference must not be carried "
                               << "across blocks as a block argument";

  return success();
}

LogicalResult YieldOp::verify() {
  auto parent = dyn_cast<RefCheckOp>((*this)->getParentOp());
  if (!parent) {
    // ringbuf.if_reserved regions do not yield values.
    if (!getResults().empty())
      return emitOpError() << "spbpf.ringbuf.if_reserved yields no values";
    return success();
  }
  // Close the most direct borrowed-reference escape through region yields.
  for (Value v : getResults())
    if (isa<BorrowedType>(v.getType()))
      return emitOpError() << "a borrowed reference must not escape the check "
                           << "region (it is only valid inside the present "
                              "region of spbpf.ref.check)";
  if (getResults().getTypes() != parent.getResultTypes())
    return emitOpError() << "yielded types do not match the results of the "
                         << "enclosing spbpf.ref.check";
  return success();
}

LogicalResult RefLoadOp::verify() {
  Type t = getRef().getType();
  if (isa<MaybeRefType>(t)) {
    auto d = emitOpError() << "operand is an unchecked nullable reference " << t;
    d.attachNote() << "check it with spbpf.ref.check first; the kernel verifier "
                      "rejects dereferencing a possibly-null map lookup result";
    return failure();
  }
  auto b = dyn_cast<BorrowedType>(t);
  if (!b)
    return emitOpError() << "operand must be !spbpf.borrowed<...>, got " << t;
  if (b.getPointee() != getResult().getType())
    return emitOpError() << "result type " << getResult().getType()
                         << " does not match the borrowed pointee "
                         << b.getPointee();
  return success();
}

LogicalResult RingbufIfReservedOp::verify() {
  auto in = cast<MaybeReservationType>(getReservation().getType());

  if (getPresentRegion().empty() || getAbsentRegion().empty())
    return emitOpError() << "both the present and absent regions must have a body";

  Block &present = getPresentRegion().front();
  if (present.getNumArguments() != 1)
    return emitOpError() << "the present region must take exactly one argument "
                         << "(the reservation), got " << present.getNumArguments();
  auto got = dyn_cast<ReservationType>(present.getArgument(0).getType());
  if (!got)
    return emitOpError() << "the present region argument must be "
                         << "!spbpf.reservation<...>, got "
                         << present.getArgument(0).getType();
  if (got.getRecordType() != in.getRecordType())
    return emitOpError() << "the reservation must keep the record type: "
                         << in.getRecordType() << " vs " << got.getRecordType();

  Block &absent = getAbsentRegion().front();
  if (absent.getNumArguments() != 0)
    return emitOpError() << "the absent region must take no arguments (there is "
                         << "no reservation), got " << absent.getNumArguments();

  // The absent region cannot store/submit/discard: there is no reservation.
  bool bad = false;
  getAbsentRegion().walk([&](Operation *op) {
    if (isa<RingbufStoreOp, RingbufStoreFieldOp, RingbufSubmitOp, RingbufDiscardOp>(op)) {
      bad = true;
      op->emitOpError() << "cannot be used in the absent region: there is no "
                           "reservation when the reserve failed";
    }
  });
  if (bad)
    return failure();

  // Successful reservations cannot escape their region.
  BlockArgument res = present.getArgument(0);
  for (Operation *user : res.getUsers()) {
    if (!isa<RingbufStoreOp, RingbufStoreFieldOp, RingbufSubmitOp, RingbufDiscardOp>(user))
      return emitOpError() << "a reservation may only be used by "
                           << "spbpf.ringbuf.{store,store_field,submit,discard}, but it is "
                           << "used by '" << user->getName() << "'";
    if (!getPresentRegion().isAncestor(user->getParentRegion()))
      return emitOpError() << "a reservation must be used inside the present "
                           << "region of its own spbpf.ringbuf.if_reserved";
  }
  for (Block &blk : getPresentRegion())
    if (&blk != &present)
      for (BlockArgument arg : blk.getArguments())
        if (isa<ReservationType>(arg.getType()))
          return emitOpError() << "a reservation must not be carried across "
                               << "blocks as a block argument";

  // Require exactly one consumption on every present-region CFG path. The ownership pass checks
  // path dependence; reject simple use-count errors here first.
  unsigned consumers = 0;
  for (Operation *user : res.getUsers())
    if (isa<RingbufSubmitOp>(user) || isa<RingbufDiscardOp>(user))
      ++consumers;
  if (consumers != 1) {
    auto d = emitOpError()
             << "the reservation must be consumed exactly once by "
             << "spbpf.ringbuf.submit or spbpf.ringbuf.discard, found "
             << consumers;
    if (consumers == 0)
      d.attachNote() << "an unconsumed reservation leaks ring buffer space";
    else
      d.attachNote() << "a reservation is linear; consuming it twice is a "
                        "use-after-free in the kernel";
    return failure();
  }
  return success();
}

LogicalResult RingbufStoreOp::verify() {
  auto res = cast<ReservationType>(getReservation().getType());
  if (isa<RecordType>(res.getRecordType()))
    return emitOpError() << "a record reservation is written field by field "
                         << "with spbpf.ringbuf.store_field, not as one value";
  if (res.getRecordType() != getValue().getType())
    return emitOpError() << "stored value " << getValue().getType()
                         << " does not match the reserved record type "
                         << res.getRecordType();
  return success();
}

LogicalResult RingbufStoreFieldOp::verify() {
  auto res = cast<ReservationType>(getReservation().getType());
  auto rec = dyn_cast<RecordType>(res.getRecordType());
  if (!rec)
    return emitOpError() << "field stores need a record reservation "
                         << "(!spbpf.record<...>), got " << res.getRecordType()
                         << " — a scalar reservation is written with "
                         << "spbpf.ringbuf.store";
  int64_t off = getOffset();
  unsigned bytes = cast<IntegerType>(getValue().getType()).getWidth() / 8;
  if (off < 0 || off + (int64_t)bytes > rec.getSize())
    return emitOpError() << "field store at offset " << off << " (" << bytes
                         << " bytes) does not fit record \"" << rec.getSymbol()
                         << "\" (" << rec.getSize() << " bytes)";
  return success();
}

LogicalResult RefStoreOp::verify() {
  Type t = getRef().getType();
  if (isa<MaybeRefType>(t)) {
    auto d = emitOpError() << "operand is an unchecked nullable reference " << t;
    d.attachNote() << "check it with spbpf.ref.check first; the kernel verifier "
                      "rejects dereferencing a possibly-null map lookup result";
    return failure();
  }
  auto b = dyn_cast<BorrowedType>(t);
  if (!b)
    return emitOpError() << "operand must be !spbpf.borrowed<...>, got " << t;
  if (b.getPointee() != getValue().getType())
    return emitOpError() << "stored value type " << getValue().getType()
                         << " does not match the borrowed pointee "
                         << b.getPointee();
  return success();
}

// Packet reads.
LogicalResult PacketLoadOp::verify() {
  auto ctx = cast<ContextType>(getCtx().getType());
  if (!isKnownProgramKind(ctx.getKind()))
    return emitOpError() << "unknown context kind \"" << ctx.getKind()
                         << "\" (known: " << knownProgramKinds() << ")";
  if (!supportsPacketAccess(ctx.getKind()))
    return emitOpError() << "program kind \"" << ctx.getKind()
                         << "\" has no packet to read";
  return success();
}
