// Refuse path-dependent reservation consumption. The original verifier counted submit/discard uses
// only, allowing submission on one branch. Walk every post-reservation CFG path for exactly one
// submit/discard. Nested ref.check present/absent regions count as consuming only if all consume;
// partial consumption is immediately path-dependent.
#include "spinel-mlir/Dialect/SpBPF/Transforms/Passes.h"

#include "spinel-mlir/Dialect/SpBPF/IR/SpBPFDialect.h"

#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/DenseSet.h"

namespace mlir {
namespace spbpf {
#define GEN_PASS_DEF_SPBPFVERIFYOWNERSHIP
#include "spinel-mlir/Dialect/SpBPF/Transforms/Passes.h.inc"
} // namespace spbpf
} // namespace mlir

using namespace mlir;
using namespace mlir::spbpf;

namespace {

// How this operation consumes v.
enum class Consumes { No, All, Some };

// Exit state when entering a region Reserved.
enum class Exit { Reserved, Consumed, Mixed };

struct Analysis {
  Value v;
  InFlightDiagnostic *diag = nullptr;
  bool failed = false;
};

Exit analyzeRegion(Region &region, Analysis &a);

Consumes consumeKind(Operation *op, Analysis &a) {
  if (isa<RingbufSubmitOp, RingbufDiscardOp>(op))
    return op->getOperand(0) == a.v ? Consumes::All : Consumes::No;
  if (op->getNumRegions() == 0)
    return Consumes::No;

  // Nested regions: All if every region consumes, Some if only some do.
  bool any = false, all = true, seen = false;
  for (Region &r : op->getRegions()) {
    if (r.empty())
      continue;
    seen = true;
    Exit e = analyzeRegion(r, a);
    if (e == Exit::Mixed) {
      a.failed = true;
      op->emitOpError()
          << "a ring buffer reservation is consumed on some paths but not "
             "others inside this operation";
      return Consumes::Some;
    }
    (e == Exit::Consumed ? any : all) = (e == Exit::Consumed);
    if (e == Exit::Consumed)
      any = true;
    else
      all = false;
  }
  if (!seen)
    return Consumes::No;
  if (all && any)
    return Consumes::All;
  if (any) {
    // Partial region consumption is path dependence; name it explicitly rather than returning an
    // unexplained nonzero status.
    a.failed = true;
    op->emitOpError()
        << "a ring buffer reservation is consumed in only some of this "
           "operation's regions, so whether it is consumed depends on the "
           "path taken at run time";
    return Consumes::Some;
  }
  return Consumes::No;
}

// Walk region CFG from Reserved entry and collect each exit state.
Exit analyzeRegion(Region &region, Analysis &a) {
  if (region.empty())
    return Exit::Reserved;

  DenseMap<Block *, bool> inState; // true means Consumed on arrival.
  SmallVector<Block *> worklist;
  inState[&region.front()] = false;
  worklist.push_back(&region.front());

  bool sawConsumedExit = false, sawReservedExit = false;
  DenseSet<Block *> visited;

  while (!worklist.empty()) {
    Block *b = worklist.pop_back_val();
    bool consumed = inState[b];
    if (!visited.insert(b).second && consumed == inState[b]) {
      // Stop revisiting the same state, ensuring loop convergence.
    }

    for (Operation &op : *b) {
      Consumes c = consumeKind(&op, a);
      if (c == Consumes::Some) {
        a.failed = true;
        return Exit::Mixed;
      }
      if (c != Consumes::All)
        continue;
      if (consumed) {
        a.failed = true;
        op.emitOpError() << "a ring buffer reservation is consumed twice on "
                            "this path";
        return Exit::Mixed;
      }
      consumed = true;
    }

    Operation *term = b->getTerminator();
    if (term->getNumSuccessors() == 0) {
      (consumed ? sawConsumedExit : sawReservedExit) = true;
      continue;
    }
    for (Block *succ : term->getSuccessors()) {
      auto it = inState.find(succ);
      if (it == inState.end()) {
        inState[succ] = consumed;
        worklist.push_back(succ);
      } else if (it->second != consumed) {
        // Different states at a merge mean only one branch consumed the reservation.
        a.failed = true;
        succ->getParentOp()->emitOpError()
            << "a ring buffer reservation is consumed on some paths but not "
               "others (the states disagree where control flow merges)";
        return Exit::Mixed;
      }
    }
  }

  if (sawConsumedExit && sawReservedExit)
    return Exit::Mixed;
  return sawConsumedExit ? Exit::Consumed : Exit::Reserved;
}

struct SpBPFVerifyOwnershipPass
    : public mlir::spbpf::impl::SpBPFVerifyOwnershipBase<
          SpBPFVerifyOwnershipPass> {
  void runOnOperation() override {
    ModuleOp module = getOperation();
    bool bad = false;

    // Successful reservations exist only as if_reserved present-region block arguments, so tracking
    // stays within that region. Explicit dialect nullability removes the need to trace the raw
    // reserve result.
    module.walk([&](ProgramOp prog) {
      prog.walk([&](RingbufIfReservedOp ifres) {
        Value v = ifres.getPresentRegion().front().getArgument(0);
        Analysis a{v};

        // Walk the present-region entry block from its beginning.
        Block *home = &ifres.getPresentRegion().front();
        bool consumed = false;
        for (Operation *op = &home->front(); op; op = op->getNextNode()) {
          Consumes c = consumeKind(op, a);
          if (c == Consumes::Some) {
            bad = true;
            return;
          }
          if (c != Consumes::All)
            continue;
          if (consumed) {
            bad = true;
            op->emitOpError() << "a ring buffer reservation is consumed twice "
                                 "on this path";
            return;
          }
          consumed = true;
        }

        Operation *term = home->getTerminator();
        if (term->getNumSuccessors() == 0) {
          if (!consumed) {
            bad = true;
            ifres.emitOpError()
                << "a ring buffer reservation is not consumed on this path";
          }
          return;
        }

        // Walk successor blocks.
        DenseMap<Block *, bool> inState;
        SmallVector<Block *> worklist;
        for (Block *succ : term->getSuccessors()) {
          inState[succ] = consumed;
          worklist.push_back(succ);
        }
        DenseSet<Block *> visited;
        bool sawConsumedExit = false, sawReservedExit = false;
        while (!worklist.empty()) {
          Block *b = worklist.pop_back_val();
          if (!visited.insert(b).second)
            continue;
          bool st = inState[b];
          for (Operation &op : *b) {
            Consumes c = consumeKind(&op, a);
            if (c == Consumes::Some) {
              bad = true;
              return;
            }
            if (c != Consumes::All)
              continue;
            if (st) {
              bad = true;
              op.emitOpError() << "a ring buffer reservation is consumed twice "
                                  "on this path";
              return;
            }
            st = true;
          }
          Operation *t = b->getTerminator();
          if (t->getNumSuccessors() == 0) {
            (st ? sawConsumedExit : sawReservedExit) = true;
            continue;
          }
          for (Block *succ : t->getSuccessors()) {
            auto it = inState.find(succ);
            if (it == inState.end()) {
              inState[succ] = st;
              worklist.push_back(succ);
            } else if (it->second != st) {
              bad = true;
              ifres.emitOpError()
                  << "a ring buffer reservation is consumed on some paths but "
                     "not others";
              return;
            }
          }
        }
        if (a.failed)
          bad = true;
        if (sawConsumedExit && sawReservedExit) {
          bad = true;
          ifres.emitOpError()
              << "a ring buffer reservation is consumed on some paths but not "
                 "others";
        } else if (sawReservedExit) {
          bad = true;
          ifres.emitOpError()
              << "a ring buffer reservation is not consumed on this path";
        }
      });
    });

    if (bad)
      signalPassFailure();
  }
};

} // namespace
