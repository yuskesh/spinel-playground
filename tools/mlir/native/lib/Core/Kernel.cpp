//===- Kernel.cpp - a checked scalar CORE kernel from a contract ----------===//
#include "spinel-mlir/Core/Kernel.h"

#include "spinel-mlir/Core/Eligibility.h"
#include "spinel-mlir/Core/LoopBounds.h"
#include "spinel-mlir/Scalar/HostEmit.h"
#include "spinel-mlir/Scalar/Importer.h"

#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Dialect/ControlFlow/IR/ControlFlowOps.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/Dialect/LLVMIR/LLVMDialect.h"
#include "mlir/IR/BuiltinOps.h"
#include "mlir/IR/MLIRContext.h"
#include "mlir/IR/SymbolTable.h"
#include "mlir/IR/Verifier.h"
#include "llvm/ADT/Twine.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/Path.h"
#include "llvm/Support/raw_ostream.h"

#include <algorithm>
#include <cstdlib>
#include <limits>
#include <vector>

using namespace spinel_mlir;

namespace spinel_mlir::core {
namespace {

std::string line(llvm::StringRef category, const llvm::Twine &detail) {
  return ("spinel-core-kernel: " + category + ": " + detail).str();
}

llvm::StringRef elementName(ElementType e) {
  switch (e) {
  case ElementType::U8: return "u8";
  case ElementType::I32: return "i32";
  case ElementType::U32: return "u32";
  case ElementType::I64: return "i64";
  case ElementType::I8: return "i8";
  case ElementType::U16: return "u16";
  case ElementType::I16: return "i16";
  }
  return "";
}

unsigned elementBytes(ElementType e) {
  switch (e) {
  case ElementType::U8:
  case ElementType::I8: return 1;
  case ElementType::U16:
  case ElementType::I16: return 2;
  case ElementType::I32:
  case ElementType::U32: return 4;
  case ElementType::I64: return 8;
  }
  return 0;
}

llvm::StringRef domainName(ScalarDomain d) {
  switch (d) {
  case ScalarDomain::I32: return "i32";
  case ScalarDomain::U32: return "u32";
  case ScalarDomain::I64: return "i64";
  case ScalarDomain::U64: return "u64";
  }
  return "";
}

} // namespace

EntryFacts entryFactsFor(const BoundaryContract &c) {
  // Each scalar domain is a Ruby Integer at this level; the width is the C
  // boundary's and the wrapper's parameter types enforce it.
  EntryFacts facts;
  facts.entry = c.entry;
  for (const Param &o : c.order) {
    if (o.kind == Param::Kind::Scalar) {
      facts.parameters.push_back(c.scalars[o.index].name);
      continue;
    }
    const BufferParam &b = c.buffers[o.index];
    facts.parameters.push_back(b.name);
    EntryBufferFact f;
    f.name = b.name;
    f.element = elementName(b.element).str();
    f.readOnly = b.mode == AccessMode::In;
    f.countName = b.countParam;
    f.constCount = b.constCount;
    f.cross = b.cross;
    facts.buffers.push_back(f);
  }
  // Decision 0014: an application entry's context and externs, as facts. The
  // guards are run-time checks the lowering emits; only the statics reach
  // admission, where they are decided per call site.
  facts.context = c.context;
  facts.scratchBytes = c.scratchBytes;
  for (const ExternDecl &e : c.externs) {
    ExternFact x;
    x.module = e.module;
    x.fn = e.fn;
    x.returns = e.returns.has_value();
    x.isrOk = e.isrOk;
    for (const ExternArg &a : e.args) {
      ExternArgFact af;
      af.name = a.name;
      af.isBuffer = a.kind == Param::Kind::Buffer;
      af.domain = af.isBuffer ? elementName(a.element).str() : domainName(a.scalar).str();
      af.readOnly = a.mode == AccessMode::In;
      x.args.push_back(af);
    }
    for (const StaticRequirement &s : e.statics)
      x.statics.push_back({s.lhs, s.op, s.rhs, s.diagnostic});
    facts.externs.push_back(x);
  }
  return facts;
}

std::optional<EligibilityReport> admitCoreKernel(const PreparedBoundary &prepared,
                                                 CoreDiagnosticFn diag) {
  const BoundaryContract &c = prepared.contract;
  // Admission, in the mode that matches the machine this lowers to. The same
  // checker the unchecked core slice runs, told which boundary is asking --
  // not a second opinion, and not a relaxed copy. The declaration's facts, in
  // the order the contract declares them.
  const EntryFacts facts = entryFactsFor(c);
  EligibilityReport report = checkEligibility(
      *prepared.module, c.entry, EligibilityMode::CheckedScalar, &facts, prepared.integerBits);
  if (!report.checked()) {
    for (const Diagnostic &d : report.diagnostics)
      diag(llvm::Twine("spinel-core-kernel: not-eligible: " + d.reason + ": " +
                       d.detail + " (" + d.location + ")")
               .str());
    if (report.diagnostics.empty())
      diag(line("not-eligible", "'" + c.entry + "' names no method here"));
    return std::nullopt;
  }
  // DECISION 0014 §6: an application entry's work is bounded, so a loop
  // without a derived bound refuses it, in either context. The same loop in a
  // version 1 entry is still only reported, under hosted-stage2.
  if (c.isApplication()) {
    const LoopBoundResult loops = deriveLoopBounds(*prepared.module, report, facts);
    bool unbounded = false;
    for (const LoopFinding &l : loops.loops)
      if (!l.pass) {
        unbounded = true;
        diag(llvm::Twine("spinel-core-kernel: not-eligible: loop-unbounded: the loop " +
                         l.id + " (" + l.header + ") has no derived bound: " + l.reason +
                         (l.detail.empty() ? "" : ", " + l.detail) + " (" + c.rootPath + ":" +
                         std::to_string(l.line) + ":" + std::to_string(l.column) + ")")
                 .str());
      }
    if (unbounded) return std::nullopt;
  }
  return report;
}

CoreEmitStatus emitCoreKernel(const PreparedBoundary &prepared,
                              const CoreKernelRequest &request,
                              RunToolFn runTool, TempPathFn tempPath,
                              CoreDiagnosticFn diag) {
  const BoundaryContract &c = prepared.contract;
  if (request.outputPath.empty())
    return diag(line("bad-request", "no output path")), CoreEmitStatus::BadRequest;

  const bool application = c.isApplication();
  if (!application && !c.result) {
    // The ABI is a status plus a written result. A contract with no result has
    // nothing for the pointer to point at, and a kernel that only reported
    // success or failure would be a different boundary, not this one with a
    // field left out.
    diag(line("unsupported-boundary",
              "the contract declares no `result`; this boundary returns a "
              "status and writes a result, and has no form without one"));
    return CoreEmitStatus::InputRejected;
  }
  if (!application && *c.result == ScalarDomain::U64) {
    diag(line("unsupported-boundary",
              "`u64` is an element count type at this boundary, not a result "
              "domain"));
    return CoreEmitStatus::InputRejected;
  }
  for (const ScalarParam &p : c.scalars) {
    if (p.domain == ScalarDomain::U64 && p.countsFor.empty()) {
      // The contract already refuses an unbound u64; this is the same rule
      // restated where the signature is built, because a u64 that counts
      // nothing would arrive here as an ordinary scalar.
      diag(line("unsupported-boundary",
                "parameter " + p.name + " is u64 but counts no buffer"));
      return CoreEmitStatus::InputRejected;
    }
  }

  // 2. Admission, in the mode that matches the machine this lowers to.
  const EntryFacts facts = entryFactsFor(c);
  std::optional<EligibilityReport> admitted = admitCoreKernel(prepared, diag);
  if (!admitted) return CoreEmitStatus::InputRejected;
  EligibilityReport &report = *admitted;

  // DECISION 0014 §5: a cross element is accessed by one instruction of its
  // own width. A 32-bit target has no such instruction for 64 bits -- the
  // backend would call a library routine, which is neither atomic by itself
  // nor a symbol the contract declares -- so the shape is refused here, by
  // name, rather than lowered as something it is not.
  if (application && request.pointerBits < 64)
    for (const BufferParam &b : c.buffers)
      if (b.cross && b.element == ElementType::I64) {
        diag(line("not-lowerable",
                  "cross-i64: buffer " + b.name + " is a cross i64 buffer, and a " +
                      std::to_string(request.pointerBits) +
                      "-bit target has no single-instruction 64-bit atomic access"));
        return CoreEmitStatus::InputRejected;
      }

  // 3. Selection and import, through the importer every other lane uses.
  bool selectionFailed = false;
  auto scalarDiag = [&](llvm::StringRef m) {
    selectionFailed = true;
    diag(("spinel-core-kernel: not-lowerable: " + m).str());
  };
  // The SAME options object reaches the selector and the importer. The
  // selector's admitted operator set widens for this boundary too, and giving
  // it a different view would mean one of the two deciding a question the
  // other thought it had answered.
  scalar::ScalarImportOptions options;
  options.status.entry = c.entry;
  // An application entry (0014) computes no result: the body's slot is an
  // i64 the wrapper allocates and discards, and the C signature has none.
  options.status.resultDomain = application ? "i64" : domainName(*c.result).str();
  options.application = application;
  options.integerBits = prepared.integerBits;
  options.pointerBits = request.pointerBits;
  options.recordCross = application && request.recordCross;
  for (const EntryBufferFact &f : facts.buffers) {
    scalar::ScalarStatusBuffer b;
    b.name = f.name;
    b.element = f.element;
    b.readOnly = f.readOnly;
    b.countName = f.countName;
    b.constCount = f.constCount;
    b.cross = f.cross;
    options.status.buffers.push_back(b);
  }
  // Decision 0041 stage 2: the data stack, and who makes or reaches arrays.
  options.status.scratchBytes = c.scratchBytes.value_or(0);
  options.status.scratchMethods = report.scratchMethods;
  for (const auto &a : report.arrayMakes) options.status.arrayMakers.insert(a.method);
  // Decision 0014: the externs, for the importer to lower `Module.fn(...)`
  // with the guards the contract declares.
  for (const ExternDecl &e : c.externs) {
    scalar::ScalarAppExtern x;
    x.module = e.module;
    x.fn = e.fn;
    x.symbol = e.symbol;
    for (const ExternArg &a : e.args) {
      scalar::ScalarAppExternArg af;
      af.name = a.name;
      af.isBuffer = a.kind == Param::Kind::Buffer;
      af.domain = af.isBuffer ? elementName(a.element).str() : domainName(a.scalar).str();
      af.readOnly = a.mode == AccessMode::In;
      x.args.push_back(af);
    }
    if (e.returns) x.returns = domainName(*e.returns).str();
    for (const Guard &g : e.guards) x.guards.push_back({g.lhs, g.op, g.rhs, g.onFalse});
    options.appExterns.push_back(x);
  }
  // The selector refuses a node the producer typed `unknown`. For a source
  // nothing calls, that is every node -- so it reads the SAME derivation the
  // checker just did rather than deriving a second one.
  options.derivedTypes = report.derivedTypes;
  // Decision 0026 step 4: the calls the checker resolved, so the selector and
  // the lowering read its edges rather than resolving call names again.
  options.callEdges.emplace();
  for (const CallEdge &e : report.callEdges) (*options.callEdges)[e.nodeId] = e.callee;
  options.derivedSignatures = report.derivedSignatures;
  // Decision 0008 task 3: the borrows the checker derived, flattened for the
  // scalar layer, which does not include the Core headers.
  for (const auto &method : report.borrows.parameters)
    for (const auto &slot : method.second) {
      if (!slot.second.isBuffer()) continue;
      scalar::ScalarBorrowedParam b;
      b.method = method.first;
      b.index = slot.first;
      b.element = slot.second.element;
      b.readOnly = slot.second.readOnly;
      b.cross = slot.second.cross;
      b.origin = slot.second.origin;
      options.borrows.push_back(b);
    }

  // Failure sites (a debugging aid): only when asked for, so the object is
  // otherwise exactly what it was.
  const std::string siteSymbol = "spinel_core_" + c.entry + "_failure_site";
  std::vector<scalar::ScalarFailureSite> sites;
  const bool failureSites = !request.failureSitesPath.empty();
  if (failureSites) {
    options.failureSiteSymbol = siteSymbol;
    options.failureSites = &sites;
  }

  auto program = scalar::selectScalarProgram(*prepared.module, report.methods,
                                             scalarDiag, options);
  if (!program || selectionFailed)
    return CoreEmitStatus::InputRejected;

  mlir::MLIRContext context;
  context.loadDialect<mlir::func::FuncDialect, mlir::arith::ArithDialect,
                      mlir::cf::ControlFlowDialect, mlir::LLVM::LLVMDialect>();
  auto imported = scalar::importScalarProgram(
      *prepared.module, *program, context, scalar::OverflowMode::Status,
      scalarDiag, /*emitCheckedArithmetic=*/false, /*trapHook=*/"", options);
  if (!imported || selectionFailed)
    return CoreEmitStatus::InputRejected;
  mlir::ModuleOp mod = *imported;

  // 4. The exported wrapper.
  //
  //    The imported entry takes every parameter as an i64, because that is the
  //    width the body computes in. The header declares the contract's own
  //    widths. Those are two different signatures, and a C caller linking
  //    against the header would pass an `int32_t` where an `i64` was expected
  //    with nothing to notice it -- a symbol name carries no types.
  //
  //    So the exported symbol is a WRAPPER with the header's signature. It
  //    widens each parameter in its declared signedness, checks what an entry
  //    can check about its result pointer, and calls the body. The body keeps
  //    its internal name and internal linkage.
  mlir::SymbolTable symbols(mod);
  const std::string internal = "sp_" + c.entry;
  auto body = symbols.lookup<mlir::func::FuncOp>(internal);
  if (!body) {
    std::string have;
    mod.walk([&](mlir::func::FuncOp f) {
      if (!have.empty()) have += ", ";
      have += f.getSymName().str();
    });
    diag(line("internal", "the lowered closure has no function '" + internal +
                              "'; it defines: " + (have.empty() ? "nothing" : have)));
    return CoreEmitStatus::BadRequest;
  }

  const std::string exported = "spinel_core_" + c.entry;
  if (symbols.lookup(exported)) {
    diag(line("bad-request",
              "the closure already defines '" + exported + "'"));
    return CoreEmitStatus::BadRequest;
  }

  mlir::OpBuilder builder(&context);
  builder.setInsertionPointToEnd(mod.getBody());
  // A body with no failing path stores nothing and declared no global; the
  // wrapper zeroes it either way, so it exists whenever sites are asked for.
  if (failureSites && !symbols.lookup(siteSymbol))
    mlir::LLVM::GlobalOp::create(builder, body.getLoc(), builder.getI32Type(), /*isConstant=*/false,
                                 mlir::LLVM::Linkage::External, siteSymbol, builder.getI32IntegerAttr(0));
  const mlir::Location loc = body.getLoc();
  const mlir::Type i32 = builder.getI32Type();
  const mlir::Type i64 = builder.getI64Type();
  const mlir::Type ptr = mlir::LLVM::LLVMPointerType::get(&context);

  llvm::SmallVector<mlir::Type> inputs;
  for (const Param &o : c.order) {
    if (o.kind == Param::Kind::Scalar) {
      const ScalarParam &p = c.scalars[o.index];
      // A `u64` count is 64 bits at the C boundary whatever it counts; the
      // other domains are their own widths.
      inputs.push_back(p.domain == ScalarDomain::I64 ||
                               p.domain == ScalarDomain::U64
                           ? i64
                           : i32);
    } else {
      inputs.push_back(ptr);
    }
  }
  // DECISION 0014: an application entry's C signature is its state buffers
  // and nothing else -- `int32_t <entry>(<elem> *p1, ...)`: no counts, which
  // are the contract's constants, and no result pointer. The body still has
  // its result slot; the wrapper gives it a private one and discards it.
  // DECISION 0041 STAGE 2: the context's data stack, after the buffers.
  if (c.scratchBytes) inputs.push_back(ptr);
  if (!application) inputs.push_back(ptr);
  auto wrapper = mlir::func::FuncOp::create(
      builder, loc, exported, builder.getFunctionType(inputs, i32));
  mlir::Block *entry = wrapper.addEntryBlock();
  builder.setInsertionPointToEnd(entry);
  // Failure sites: 0 until this call fails somewhere that records one, so a
  // site read after a failed call is this call's, never an earlier one's; a
  // refusal of the wrapper's own leaves it 0.
  if (failureSites) {
    mlir::Value addr = mlir::LLVM::AddressOfOp::create(builder, loc, ptr, siteSymbol);
    mlir::Value zero = mlir::arith::ConstantOp::create(builder, loc, i32, builder.getI32IntegerAttr(0));
    mlir::LLVM::StoreOp::create(builder, loc, zero, addr);
  }

  mlir::Value resultPtr;
  if (application) {
    mlir::Value one = mlir::arith::ConstantOp::create(builder, loc, i64,
                                                      builder.getI64IntegerAttr(1));
    resultPtr = mlir::LLVM::AllocaOp::create(builder, loc, ptr, i64, one, /*alignment=*/8);
  } else {
    resultPtr = entry->getArgument(entry->getNumArguments() - 1);
  }

  // ---- descriptor validation ---------------------------------------------
  //
  // ALL of it before any kernel write. Decision 0007: an entry-validation
  // failure leaves buffers and result untouched, so every one of these has to
  // be decided before control reaches the body.
  //
  // One shared cold arm returning ARGUMENT: these are all defects in what the
  // CALLER supplied, and distinguishing them from each other in the status
  // would be inventing categories the ABI does not have.
  mlir::Block *badArgument = builder.createBlock(&wrapper.getBody());
  {
    mlir::OpBuilder cold(&context);
    cold.setInsertionPointToEnd(badArgument);
    mlir::Value argument = mlir::arith::ConstantOp::create(
        cold, loc, i32,
        cold.getI32IntegerAttr(
            static_cast<int32_t>(scalar::CoreStatus::Argument)));
    mlir::func::ReturnOp::create(cold, loc, argument);
  }

  mlir::Block *cur = entry;
  auto at = [&](mlir::Block *b) { builder.setInsertionPointToEnd(b); };
  auto konst = [&](int64_t v) {
    at(cur);
    return mlir::Value(mlir::arith::ConstantOp::create(
        builder, loc, i64, builder.getI64IntegerAttr(v)));
  };
  auto cmp = [&](mlir::arith::CmpIPredicate p, mlir::Value a, mlir::Value b) {
    at(cur);
    return mlir::Value(mlir::arith::CmpIOp::create(builder, loc, p, a, b));
  };
  auto orOf = [&](mlir::Value a, mlir::Value b) {
    at(cur);
    return mlir::Value(mlir::arith::OrIOp::create(builder, loc, a, b));
  };
  auto andOf = [&](mlir::Value a, mlir::Value b) {
    at(cur);
    return mlir::Value(mlir::arith::AndIOp::create(builder, loc, a, b));
  };
  auto address = [&](mlir::Value p) {
    at(cur);
    return mlir::Value(mlir::LLVM::PtrToIntOp::create(builder, loc, i64, p));
  };
  // DECISION 0022 §3: with 32-bit pointers the address, range and overlap
  // comparisons are made in 32 bits, once every value compared is shown to be
  // representable there. Every other target keeps the i64 lowering below.
  const bool narrow = request.pointerBits == 32;
  auto konst32 = [&](uint32_t v) {
    at(cur);
    return mlir::Value(mlir::arith::ConstantOp::create(
        builder, loc, i32, builder.getI32IntegerAttr(static_cast<int32_t>(v))));
  };
  auto address32 = [&](mlir::Value p) {
    at(cur);
    return mlir::Value(mlir::LLVM::PtrToIntOp::create(builder, loc, i32, p));
  };
  // `refuse when` -- the whole of descriptor validation is a chain of these.
  auto refuseWhen = [&](mlir::Value cond) {
    at(cur);
    mlir::Block *next = builder.createBlock(&wrapper.getBody());
    at(cur);
    mlir::cf::CondBranchOp::create(builder, loc, cond, badArgument,
                                   mlir::ValueRange{}, next, mlir::ValueRange{});
    cur = next;
  };

  const int64_t kMaxIndex = prepared.integerBits == 32 ? INT32_MAX : INT64_MAX;
  const std::vector<std::string> &readCounts = report.readParameters;

  // The result pointer, first: it is the one descriptor every entry has. An
  // application entry's is the wrapper's own slot, and needs no check.
  if (!application) {
    const int64_t align = *c.result == ScalarDomain::I64 ? 8 : 4;
    mlir::Value a = address(resultPtr);
    mlir::Value isNull = cmp(mlir::arith::CmpIPredicate::eq, a, konst(0));
    mlir::Value low = andOf(a, konst(align - 1));
    mlir::Value unaligned = cmp(mlir::arith::CmpIPredicate::ne, low, konst(0));
    refuseWhen(orOf(isNull, unaligned));
  }

  if (prepared.integerBits == 32) {
    for (size_t i = 0; i < c.order.size(); ++i) {
      const Param &p = c.order[i];
      if (p.kind != Param::Kind::Scalar || c.scalars[p.index].domain != ScalarDomain::U32 ||
          !c.scalars[p.index].countsFor.empty())
        continue;
      at(cur);
      mlir::Value wide = mlir::arith::ExtUIOp::create(builder, loc, i64, entry->getArgument(i));
      refuseWhen(cmp(mlir::arith::CmpIPredicate::ugt, wide, konst(INT32_MAX)));
    }
  }

  // Each buffer's own descriptor. Zero length permits NULL; a nonzero length
  // requires a non-NULL, aligned pointer whose byte range neither overflows
  // nor leaves the address space.
  struct Range { mlir::Value begin, end, live; bool readOnly; };
  std::vector<Range> ranges;
  {
    size_t index = 0;
    for (const Param &o : c.order) {
      const size_t slot = index++;
      if (o.kind != Param::Kind::Buffer) continue;
      const BufferParam &b = c.buffers[o.index];
      const int64_t bytes = elementBytes(b.element);
      mlir::Value pointer = entry->getArgument(slot);
      mlir::Value count;
      if (b.constCount) {
        // Decision 0014: the count is the contract's constant. The same
        // descriptor rules apply to the pointer -- the glue owns the storage,
        // and a wrong pointer is a wrong pointer -- and the constant count
        // makes the size arithmetic fold.
        count = konst(static_cast<int64_t>(*b.constCount));
      } else {
        // The count's slot, found by NAME rather than by position: the
        // contract binds them by name and this side must not reintroduce a
        // positional rule.
        size_t countSlot = 0;
        bool found = false;
        size_t k = 0;
        for (const Param &q : c.order) {
          if (q.kind == Param::Kind::Scalar &&
              c.scalars[q.index].name == b.countParam) {
            countSlot = k;
            found = true;
          }
          ++k;
        }
        if (!found) {
          diag(line("internal", "no count parameter for buffer " + b.name));
          return CoreEmitStatus::BadRequest;
        }
        count = entry->getArgument(countSlot);
      }

      // The count's domain here is the WHOLE of u64, which is what the
      // contract says it is. An earlier version refused anything above
      // INT64_MAX and called it a descriptor rule; it was not. The two
      // questions are separate:
      //
      //   the DESCRIPTOR asks whether count*element-size and base+size stay
      //   inside the target address width, both in unsigned 64-bit;
      //
      //   the count's RUBY VALUE only exists if it fits i64, and that is an
      //   entry-scalar question, asked below and only of a count the body
      //   actually reads.
      //
      // The bounds check inside the kernel depends on neither: it is a signed
      // test for a negative index and an unsigned one against the count.
      const bool readCount =
          !b.constCount && std::find(readCounts.begin(), readCounts.end(), b.countParam) !=
                               readCounts.end();
      if (narrow) {
        // Decision 0022 §3, in its order, accepting exactly what the i64
        // lowering below accepts with 32-bit pointers:
        //
        // 1. A count whose upper word is not zero. The i64 lowering refuses
        //    every such count too: it is nonzero, so its range is live, and
        //    count * size >= 2^32 either passes the address width or wraps u64.
        //    Written as `count > UINT32_MAX` on the i64 itself, not as a test
        //    of `count >> 32`: from this compare LLVM gives the count the body
        //    receives the range [0, 2^32) and so proves the body's checked
        //    arithmetic on it in range. Measured on DOOM's step entry: with
        //    the shift form the body's i64 parameters with a range fell from
        //    2355 to 330 and its overflow checks rose from 411 to 1028.
        refuseWhen(cmp(mlir::arith::CmpIPredicate::ugt, count, konst(UINT32_MAX)));
        at(cur);
        mlir::Value count32 = mlir::arith::TruncIOp::create(builder, loc, i32, count);
        // 2. count * size in i64, where a count below 2^32 times at most 8
        //    cannot overflow, against UINTPTR_MAX - base, which cannot wrap.
        //    A zero count has size 0 and always passes, so this needs no `live`.
        mlir::Value base = address32(pointer);
        at(cur);
        mlir::Value size = mlir::arith::MulIOp::create(
            builder, loc, mlir::arith::ExtUIOp::create(builder, loc, i64, count32), konst(bytes));
        at(cur);
        mlir::Value room = mlir::arith::ExtUIOp::create(
            builder, loc, i64,
            mlir::arith::SubIOp::create(builder, loc, konst32(UINT32_MAX), base));
        refuseWhen(cmp(mlir::arith::CmpIPredicate::ugt, size, room));
        // 3. Narrowed. The exclusive end is at most UINTPTR_MAX, so it and the
        //    base are both representable in 32 bits.
        at(cur);
        mlir::Value limit = mlir::arith::AddIOp::create(
            builder, loc, base, mlir::arith::TruncIOp::create(builder, loc, i32, size));
        mlir::Value live = cmp(mlir::arith::CmpIPredicate::ne, count32, konst32(0));
        refuseWhen(andOf(live, cmp(mlir::arith::CmpIPredicate::eq, base, konst32(0))));
        if (bytes > 1)
          refuseWhen(andOf(live, cmp(mlir::arith::CmpIPredicate::ne,
                                     andOf(base, konst32(static_cast<uint32_t>(bytes - 1))),
                                     konst32(0))));
        // A read count as a Ruby value. After step 1 every count is below
        // 2^32, so only a 32-bit body's INT32_MAX can still refuse one.
        if (readCount && kMaxIndex == INT32_MAX)
          refuseWhen(cmp(mlir::arith::CmpIPredicate::ugt, count32, konst32(INT32_MAX)));
        ranges.push_back({base, limit, live, b.mode == AccessMode::In});
        continue;
      }
      if (bytes > 1)
        refuseWhen(cmp(mlir::arith::CmpIPredicate::ugt, count,
                       konst(static_cast<int64_t>(~0ULL / bytes))));

      at(cur);
      mlir::Value base = address(pointer);
      mlir::Value size = mlir::arith::MulIOp::create(builder, loc, count,
                                                     konst(bytes));
      mlir::Value limit = mlir::arith::AddIOp::create(builder, loc, base, size);
      mlir::Value live = cmp(mlir::arith::CmpIPredicate::ne, count, konst(0));

      // Separate guards rather than one disjunction. Every one of them is
      // ARGUMENT, so which fires first is an implementation detail and not
      // part of the ABI -- a caller cannot tell them apart and nothing should
      // let it. What separating them buys is a readable implementation; that a
      // test shape exercises the rule it names is established by the test,
      // which measures that the shape violates no OTHER rule.
      refuseWhen(andOf(live, cmp(mlir::arith::CmpIPredicate::eq, base, konst(0))));
      if (bytes > 1)
        refuseWhen(andOf(live, cmp(mlir::arith::CmpIPredicate::ne,
                                   andOf(base, konst(bytes - 1)), konst(0))));
      refuseWhen(andOf(live, cmp(mlir::arith::CmpIPredicate::ult, limit, base)));
      // On a 32-bit target the sum above cannot wrap in i64, so "inside the
      // address width" is a second question: the limit must not pass the
      // width. Otherwise a count that fits i64 but not the address space is
      // accepted, and an index below the count reaches an address the element
      // arithmetic, done in the pointer's width, has wrapped.
      if (request.pointerBits < 64)
        refuseWhen(andOf(live, cmp(mlir::arith::CmpIPredicate::ugt, limit,
                                   konst(static_cast<int64_t>(
                                       (1ULL << request.pointerBits) - 1)))));

      // The count as a Ruby VALUE. Only for a count the closure reads: one it
      // never reads needs no value, and refusing it would narrow the
      // descriptor's domain for the body's convenience. Decision 0007 calls an
      // invalid entry scalar ARGUMENT, and a u64 above INT64_MAX has no i64
      // value for the body to compute with.
      if (readCount)
        refuseWhen(cmp(mlir::arith::CmpIPredicate::ugt, count, konst(kMaxIndex)));

      ranges.push_back({base, limit, live, b.mode == AccessMode::In});
    }
  }

  // The result must be disjoint from every buffer range.
  //
  // After every per-buffer check. Not an ABI promise about which failure a
  // caller sees -- all of these are ARGUMENT and are indistinguishable from
  // outside -- but it keeps the two kinds of question apart in the source.
  // Measured: with this inside the loop, the `addr-overflow` shape was being
  // refused here, because a range spanning half the address space contains the
  // result, and the wrap it meant to test was never reached. The test now
  // measures a shape's isolation rather than relying on any order.
  for (const Range &rg : ranges) {
    if (application) break;  // the slot is the wrapper's own, disjoint by construction
    if (narrow) {
      // Decision 0022 §3: r + 4 or r + 8 may be 2^32, which 32 bits would
      // read as 0 and so miss an overlap at the top of the address space.
      // The test uses the result's LAST byte instead, rg.begin <= r + (w - 1)
      // for rg.begin < r + w: the check above made r non-null and aligned to
      // w, so r <= 2^32 - w and the last byte cannot carry.
      const uint32_t w = *c.result == ScalarDomain::I64 ? 8 : 4;
      mlir::Value r = address32(resultPtr);
      at(cur);
      mlir::Value rLast = mlir::arith::AddIOp::create(builder, loc, r, konst32(w - 1));
      refuseWhen(andOf(rg.live,
                       andOf(cmp(mlir::arith::CmpIPredicate::ult, r, rg.end),
                             cmp(mlir::arith::CmpIPredicate::ule, rg.begin, rLast))));
      continue;
    }
    mlir::Value r = address(resultPtr);
    mlir::Value rEnd = mlir::arith::AddIOp::create(
        builder, loc, r, konst(*c.result == ScalarDomain::I64 ? 8 : 4));
    refuseWhen(andOf(rg.live,
                     andOf(cmp(mlir::arith::CmpIPredicate::ult, r, rg.end),
                           cmp(mlir::arith::CmpIPredicate::ult, rg.begin, rEnd))));
  }

  // Any overlap involving an `inout` buffer, including two names for the same
  // storage. Two read-only buffers MAY overlap and are not compared.
  //
  // With 32-bit pointers the pairs are compared by a loop over a table rather
  // than unrolled. Measured on the FRDM-IMXRT1186 (2026-10-21): DOOM's step
  // and render entries compare 18639 and 15714 pairs, 18 instructions each,
  // 1.08 MB and 0.91 MB of straight-line code run once per call from the
  // QSPI XIP, which cost 16.6 and 14.1 ms of a 143 ms tic. The table holds
  // each range's begin and end, the `inout` ranges first; a range whose count
  // is 0 is entered as [0, 0), which intersects nothing (`b < 0` is never
  // true unsigned), so the loop needs no live flag. Each `inout` range is
  // compared with every range after it: the same pairs, the same predicate
  // and the same ARGUMENT as the unrolled form. The table is a fixed-size
  // alloca at the top of the entry block, so it is part of the wrapper's
  // static frame and counted wherever that frame is.
  if (narrow) {
    std::vector<size_t> order;
    for (size_t i = 0; i < ranges.size(); ++i)
      if (!ranges[i].readOnly) order.push_back(i);
    const size_t inouts = order.size();
    for (size_t i = 0; i < ranges.size(); ++i)
      if (ranges[i].readOnly) order.push_back(i);
    const size_t n = order.size();
    if (inouts > 0 && n > 1) {
      mlir::OpBuilder top(&context);
      top.setInsertionPointToStart(entry);
      mlir::Value cells = mlir::arith::ConstantOp::create(
          top, loc, i32, top.getI32IntegerAttr(static_cast<int32_t>(2 * n)));
      mlir::Value table = mlir::LLVM::AllocaOp::create(top, loc, ptr, i32, cells, /*alignment=*/4);
      auto slot = [&](mlir::Value index) {
        return mlir::Value(mlir::LLVM::GEPOp::create(builder, loc, ptr, i32, table, mlir::ValueRange{index}));
      };
      for (size_t k = 0; k < n; ++k) {
        const Range &rg = ranges[order[k]];
        mlir::Value zero = konst32(0);
        at(cur);
        mlir::Value b = mlir::arith::SelectOp::create(builder, loc, rg.live, rg.begin, zero);
        mlir::Value e = mlir::arith::SelectOp::create(builder, loc, rg.live, rg.end, zero);
        mlir::LLVM::StoreOp::create(builder, loc, b, slot(konst32(static_cast<uint32_t>(2 * k))));
        at(cur);
        mlir::LLVM::StoreOp::create(builder, loc, e, slot(konst32(static_cast<uint32_t>(2 * k + 1))));
      }
      mlir::Region &body = wrapper.getBody();
      mlir::Block *outerHead = builder.createBlock(&body);
      mlir::Value i = outerHead->addArgument(i32, loc);
      mlir::Block *outerBody = builder.createBlock(&body);
      mlir::Block *innerHead = builder.createBlock(&body);
      mlir::Value j = innerHead->addArgument(i32, loc);
      mlir::Block *innerBody = builder.createBlock(&body);
      mlir::Block *outerLatch = builder.createBlock(&body);
      mlir::Block *done = builder.createBlock(&body);
      at(cur);
      mlir::cf::BranchOp::create(builder, loc, outerHead, mlir::ValueRange{konst32(0)});
      // for i in [0, inouts)
      cur = outerHead;
      mlir::Value more = cmp(mlir::arith::CmpIPredicate::ult, i, konst32(static_cast<uint32_t>(inouts)));
      at(cur);
      mlir::cf::CondBranchOp::create(builder, loc, more, outerBody, mlir::ValueRange{}, done, mlir::ValueRange{});
      cur = outerBody;
      mlir::Value i2 = mlir::arith::ShLIOp::create(builder, loc, i, konst32(1));
      at(cur);
      mlir::Value bi = mlir::LLVM::LoadOp::create(builder, loc, i32, slot(i2));
      at(cur);
      mlir::Value ei = mlir::LLVM::LoadOp::create(
          builder, loc, i32, slot(mlir::arith::AddIOp::create(builder, loc, i2, konst32(1))));
      at(cur);
      mlir::Value next = mlir::arith::AddIOp::create(builder, loc, i, konst32(1));
      mlir::cf::BranchOp::create(builder, loc, innerHead, mlir::ValueRange{next});
      //   for j in (i, n)
      cur = innerHead;
      mlir::Value inner = cmp(mlir::arith::CmpIPredicate::ult, j, konst32(static_cast<uint32_t>(n)));
      at(cur);
      mlir::cf::CondBranchOp::create(builder, loc, inner, innerBody, mlir::ValueRange{}, outerLatch, mlir::ValueRange{});
      cur = innerBody;
      mlir::Value j2 = mlir::arith::ShLIOp::create(builder, loc, j, konst32(1));
      at(cur);
      mlir::Value bj = mlir::LLVM::LoadOp::create(builder, loc, i32, slot(j2));
      at(cur);
      mlir::Value ej = mlir::LLVM::LoadOp::create(
          builder, loc, i32, slot(mlir::arith::AddIOp::create(builder, loc, j2, konst32(1))));
      mlir::Value hits = andOf(cmp(mlir::arith::CmpIPredicate::ult, bi, ej),
                               cmp(mlir::arith::CmpIPredicate::ult, bj, ei));
      at(cur);
      mlir::Value after = mlir::arith::AddIOp::create(builder, loc, j, konst32(1));
      mlir::cf::CondBranchOp::create(builder, loc, hits, badArgument, mlir::ValueRange{}, innerHead,
                                     mlir::ValueRange{after});
      cur = outerLatch;
      at(cur);
      mlir::Value onward = mlir::arith::AddIOp::create(builder, loc, i, konst32(1));
      mlir::cf::BranchOp::create(builder, loc, outerHead, mlir::ValueRange{onward});
      cur = done;
    }
  } else
  for (size_t i = 0; i < ranges.size(); ++i)
    for (size_t j = i + 1; j < ranges.size(); ++j) {
      if (ranges[i].readOnly && ranges[j].readOnly) continue;
      mlir::Value hits =
          andOf(cmp(mlir::arith::CmpIPredicate::ult, ranges[i].begin, ranges[j].end),
                cmp(mlir::arith::CmpIPredicate::ult, ranges[j].begin, ranges[i].end));
      refuseWhen(andOf(andOf(ranges[i].live, ranges[j].live), hits));
    }

  // ---- the call ----------------------------------------------------------
  {
    at(cur);
    llvm::SmallVector<mlir::Value> args;
    size_t index = 0;
    for (const Param &o : c.order) {
      mlir::Value v = entry->getArgument(index++);
      if (o.kind == Param::Kind::Buffer) {
        args.push_back(v);
        continue;
      }
      const ScalarParam &p = c.scalars[o.index];
      // The widening carries the DECLARED signedness. `u32` is not `i32` with
      // a different name: 4294967295 arrives as the same 32 bits either way
      // and means 4294967295 in one domain and -1 in the other. A `u64` count
      // needs no widening and is known to fit i64 by the check above.
      if (p.domain == ScalarDomain::I32)
        v = mlir::arith::ExtSIOp::create(builder, loc, i64, v);
      else if (p.domain == ScalarDomain::U32)
        v = mlir::arith::ExtUIOp::create(builder, loc, i64, v);
      if (prepared.integerBits == 32 && p.countsFor.empty())
        v = mlir::arith::TruncIOp::create(builder, loc, i32, v);
      args.push_back(v);
    }
    // DECISION 0041 STAGE 2: a null region is the caller's defect, refused
    // before the body runs; a body that makes no array is not passed it.
    if (c.scratchBytes) {
      mlir::Value region = entry->getArgument(c.order.size());
      mlir::Value null = mlir::LLVM::ZeroOp::create(builder, loc, ptr);
      refuseWhen(mlir::LLVM::ICmpOp::create(builder, loc, mlir::LLVM::ICmpPredicate::eq, region, null));
      at(cur);
      if (options.status.scratchMethods.count(c.entry)) args.push_back(region);
    }
    args.push_back(resultPtr);
    auto call = mlir::func::CallOp::create(builder, loc, body, args);
    mlir::func::ReturnOp::create(builder, loc, call.getResult(0));
  }

  // 5. Linkage. The wrapper is the object's only exported symbol.
  mod.walk([&](mlir::func::FuncOp fn) {
    if (fn.getSymName() == exported) return;
    fn.setPrivate();
    // `private` visibility alone does not stop the conversion to LLVM from
    // giving a defined function external linkage; say so explicitly, as the
    // unchecked core lane already has to.
    fn->setAttr("llvm.linkage", mlir::LLVM::LinkageAttr::get(
                                    &context, mlir::LLVM::Linkage::Internal));
  });

  if (mlir::failed(mlir::verify(mod))) {
    diag(line("internal", "the lowered kernel does not verify"));
    return CoreEmitStatus::Infrastructure;
  }

  if (!request.emitMlirPath.empty()) {
    scalar::HostEmitRequest mreq;
    mreq.kind = scalar::HostEmitRequest::Kind::Mlir;
    mreq.outputPath = request.emitMlirPath;
    if (!scalar::emitHostModule(mod, mreq, runTool, tempPath, diag))
      return CoreEmitStatus::Infrastructure;
  }
  scalar::HostEmitRequest req;
  req.kind = scalar::HostEmitRequest::Kind::Obj;
  req.outputPath = request.outputPath;
  req.clangPath = request.clangPath;
  // Decision 0007 keeps version 1's undefined set empty, and a loop the
  // optimiser recognises as a memset or a memcpy breaks that. Measured:
  // clear_u8's `while` became an undefined `memset` at the shared emitter's
  // -O2, and neither `-fno-builtin` nor `-ffreestanding` stopped it -- those
  // are frontend flags and the input here is already IR. A `no-builtins`
  // passthrough attribute on the `func.func` did not survive the conversion to
  // LLVM either. This option does, and it fails LOUDLY if a future LLVM drops
  // it, because clang refuses an unknown -mllvm option rather than ignoring it.
  //
  // It goes FIRST, so a caller's own flags follow it and this is not something
  // the caller silently omits. The decision is explicit that an option alone is
  // not proof: the object's undefined set is inspected by tests/core-boundary/
  // buffers.sh at this same optimisation level.
  // Nothing here can unwind, and the object must say so itself: on ARM EABI a
  // function without `nounwind` references __aeabi_unwind_cpp_pr0, and the
  // optimiser only infers the attribute at -Os, not at -O0 (0014 Task 2).
  req.noUnwind = true;
  req.clangArgs.push_back("-mllvm");
  req.clangArgs.push_back("-disable-loop-idiom-all");
  for (const std::string &a : request.clangArgs) {
    req.clangArgs.push_back(a);
    // Compiling with the sanitiser and not marking the functions leaves an
    // object that carries ASan's module constructor and instruments nothing.
    // The flag and the attribute go together or the flag does nothing.
    llvm::StringRef flag(a);
    if (flag.consume_front("-fsanitize=")) {
      llvm::SmallVector<llvm::StringRef, 4> parts;
      flag.split(parts, ',');
      for (llvm::StringRef part : parts)
        if (part.trim() == "address") req.sanitizeAddress = true;
    }
  }
  req.optimisedIrPath = request.optimisedIrPath;
  if (!scalar::emitHostModule(mod, req, runTool, tempPath, diag))
    return CoreEmitStatus::Infrastructure;
  if (failureSites) {
    std::error_code ec;
    llvm::raw_fd_ostream os(request.failureSitesPath, ec, llvm::sys::fs::OF_Text);
    if (ec) {
      diag(line("bad-request", "cannot write " + request.failureSitesPath + ": " + ec.message()));
      return CoreEmitStatus::BadRequest;
    }
    static const char *const kStatus[] = {"OK", "ARGUMENT", "ARITHMETIC", "BOUNDS", "CAPACITY"};
    os << "# spinel-core-kernel failure sites: the id a failing path stores in the global\n"
       << "# entry\t" << c.entry << "\n# global\t" << siteSymbol << "\n"
       << "site\tfile\tline\tcolumn\tstatus\twhat\n";
    // The importer saw the snapshot of the root; the table names the root.
    for (const scalar::ScalarFailureSite &s : sites)
      os << s.id << "\t"
         << (llvm::sys::path::filename(s.file) == llvm::sys::path::filename(c.rootResolved) ? c.rootResolved : s.file)
         << "\t" << s.line << "\t" << s.column << "\t"
         << kStatus[static_cast<int32_t>(s.status)] << "\t" << s.what << "\n";
  }
  if (request.admitted) *request.admitted = report;
  return CoreEmitStatus::Ok;
}

} // namespace spinel_mlir::core
