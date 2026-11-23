// Freestanding object generation.
#include "spinel-mlir/Freestanding/Emit.h"
#include "spinel-mlir/Support/Int64Allow.h"
#include "spinel-mlir/Support/IntegerWidth.h"

#include "spinel-mlir/Freestanding/PlatformLedger.h"
#include "spinel-mlir/Freestanding/UndefGate.h"


#include "mlir/Dialect/Arith/IR/Arith.h"
#include "mlir/Dialect/ControlFlow/IR/ControlFlowOps.h"
#include "mlir/Dialect/Func/IR/FuncOps.h"
#include "mlir/Dialect/LLVMIR/LLVMDialect.h"
#include "spinel-mlir/Contract/Reader.h"
#include "spinel-mlir/Core/Prelude.h"
#include "spinel-mlir/Conversion/SpinelToLLVM/Passes.h"
#include "spinel-mlir/Scalar/HostEmit.h"
#include "spinel-mlir/Scalar/Importer.h"

#include "../Frontend/Scalar/ScalarAst.h"

#include "mlir/Conversion/ArithToLLVM/ArithToLLVM.h"
#include "mlir/Conversion/ControlFlowToLLVM/ControlFlowToLLVM.h"
#include "mlir/Conversion/FuncToLLVM/ConvertFuncToLLVMPass.h"
#include "mlir/Conversion/ReconcileUnrealizedCasts/ReconcileUnrealizedCasts.h"
#include "mlir/IR/Verifier.h"
#include "mlir/Pass/Pass.h"
#include "mlir/Pass/PassManager.h"
#include "mlir/Target/LLVMIR/Dialect/Builtin/BuiltinToLLVMIRTranslation.h"
#include "mlir/Target/LLVMIR/Dialect/LLVMIR/LLVMToLLVMIRTranslation.h"
#include "mlir/Target/LLVMIR/Export.h"

#include "llvm/IR/Module.h"
#include <cstring>
#include <map>
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/LineIterator.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/Path.h"
#include "mlir/IR/Builders.h"
#include "mlir/IR/BuiltinAttributes.h"

#include "llvm/ADT/StringSet.h"
#include "mlir/IR/SymbolTable.h"
#include "llvm/ADT/StringSwitch.h"

// Opening both namespaces makes Type/StringSwitch ambiguous. Open only MLIR and qualify LLVM ADTs.
using namespace mlir;

namespace spinel_mlir::freestanding {
namespace {

// Internal body name built by the scalar importer; keep its rule in one place shared with
// Importer.cpp.
std::string bodyName(llvm::StringRef declName) { return ("sp_" + declName).str(); }

// Boundary integer width; floats/buffers are separate (the initial slice was integer-only).
unsigned boundaryWidth(llvm::StringRef t) {
  return llvm::StringSwitch<unsigned>(t)
      .Case("i8", 8).Case("u8", 8)
      .Case("i16", 16).Case("u16", 16)
      .Case("i32", 32).Case("u32", 32)
      .Case("i64", 64)
      .Default(0);
}

bool boundarySigned(llvm::StringRef t) { return t.starts_with("i"); }

// Boundary float width, or 0 for nonfloat. Separate from integers because AAPCS signext/zeroext
// does not apply to floats.
unsigned boundaryFloatWidth(llvm::StringRef t) {
  return t == "f32" ? 32 : t == "f64" ? 64 : 0;
}

// AAPCS (Arm procedure-call standard) requires signext/zeroext on arguments/results narrower than
// 32 bits. Missing attributes cause generated header/object ABI mismatch, as observed. Do not
// attach them at 32 bits or wider.
Attribute extensionAttr(Builder &b, llvm::StringRef type, unsigned width) {
  if (width >= 32)
    return {};
  return b.getUnitAttr();
}
llvm::StringRef extensionName(llvm::StringRef type) {
  return boundarySigned(type) ? LLVM::LLVMDialect::getSExtAttrName()
                              : LLVM::LLVMDialect::getZExtAttrName();
}

} // namespace

bool checkExportSymbols(ModuleOp module, const FreestandingProfile &profile,
                        llvm::ArrayRef<FsDecl> decls, FsDiagnosticFn diag) {
  // Inspect every existing module symbol, not just declaration-derived sp_<name>. Otherwise
  // reachable helpers such as sp_helper are missed, leading to unstructured verifier redefinition
  // errors without naming the bad export.
  llvm::StringSet<> taken;
  module.walk([&](mlir::SymbolOpInterface op) {
    taken.insert(op.getName());
  });
  // Also reserve future names, including the trap hook that wrappers reference.
  taken.insert(profile.trapHook());

  llvm::StringSet<> seen;
  for (const FsDecl &d : decls) {
    if (taken.contains(d.exportSymbol)) {
      diag({Stage::D1, Category::BadExportSymbol, d.name, 0,
            "export: '" + d.exportSymbol +
                "' collides with a symbol the compiler already builds"
                " (an internal body, a call-closure helper, or the trap hook)"});
      return false;
    }
    if (!seen.insert(d.exportSymbol).second) {
      diag({Stage::D1, Category::BadExportSymbol, d.name, 0,
            "export: '" + d.exportSymbol + "' is declared twice"});
      return false;
    }
    // Check boundary C spellings before probe. Previously the header writer checked after opening
    // output, allowing successful probes to fail only after creating a file.
    if (cScalarType(d.returns).empty()) {
      diag({Stage::D1, Category::BadBoundaryType, d.name, 0,
            "returns :" + d.returns + " has no C spelling"});
      return false;
    }
    for (const FsParam &p : d.params) {
      if (p.kind == FsParam::Kind::Len)
        continue;
      if (cScalarType(p.type).empty()) {
        diag({Stage::D1, Category::BadBoundaryType, d.name, 0,
              "parameter :" + p.type + " has no C spelling"});
        return false;
      }
    }
  }
  return true;
}

namespace {
// Trap-detail .rodata names use string FNV-1a, not potentially execution-seeded hash_value,
// preserving byte identity. Identical strings share a global; different strings receive different
// symbols.
uint64_t fsFnv1a64(llvm::StringRef s) {
  uint64_t h = 0xcbf29ce484222325ULL;
  for (unsigned char c : s) { h ^= c; h *= 0x100000001b3ULL; }
  return h;
}

Value trapDetailPtr(OpBuilder &b, ModuleOp module, Location loc,
                    llvm::StringRef text) {
  MLIRContext *ctx = b.getContext();
  std::string symbol = ("sp_cstr_trap_" + llvm::Twine(fsFnv1a64(text))).str();
  if (!module.lookupSymbol<LLVM::GlobalOp>(symbol)) {
    OpBuilder::InsertionGuard g(b);
    b.setInsertionPointToStart(module.getBody());
    std::string bytes = (text + llvm::Twine('\0')).str();
    auto ty = LLVM::LLVMArrayType::get(b.getI8Type(), bytes.size());
    auto global = LLVM::GlobalOp::create(b, module.getLoc(), ty,
                                         /*isConstant=*/true,
                                         LLVM::Linkage::Private, symbol,
                                         b.getStringAttr(bytes));
    global->setAttr("addr_space", b.getI32IntegerAttr(0));
  }
  return LLVM::AddressOfOp::create(b, loc, LLVM::LLVMPointerType::get(ctx),
                                   symbol);
}
} // namespace

bool addBoundaryWrappers(ModuleOp module, const FreestandingProfile &profile,
                         llvm::ArrayRef<FsDecl> decls, llvm::StringRef dataLayout,
                         FsDiagnosticFn diag) {
  MLIRContext *ctx = module.getContext();
  OpBuilder b(ctx);
  Type i64 = b.getIntegerType(64);
  Type i32 = b.getIntegerType(32);

  module->setAttr("llvm.target_triple", b.getStringAttr(profile.triple()));
  module->setAttr("llvm.data_layout", b.getStringAttr(dataLayout));

  // Internalize every importer-generated function, including reachable helpers such as sp_sumsq,
  // which otherwise remained external in the observed k4 case. Only later wrapper exports should
  // remain visible.
  for (auto fn : module.getOps<func::FuncOp>()) {
    if (fn.isDeclaration())
      continue;
    fn.setPrivate();
    fn->setAttr("llvm.linkage",
                LLVM::LinkageAttr::get(ctx, LLVM::Linkage::Internal));
    // Apply nounwind to every body/helper, not only roots/wrappers. Helpers previously attracted
    // exception tables and __aeabi_unwind_cpp_pr0, refused by the gate. Freestanding forbids unwind
    // regardless of profile.
    fn->setAttr("passthrough", b.getArrayAttr({b.getStringAttr("nounwind")}));
  }

  // Declare the trap hook once, and only for policies that call it, avoiding unused undefined
  // symbols.
  func::FuncOp hook;
  auto ensureHook = [&]() -> func::FuncOp {
    if (hook)
      return hook;
    // The importer may already declare the hook for bounds checks. Look it up to preserve one hook
    // per module and avoid verifier redefinition errors.
    if ((hook = module.lookupSymbol<func::FuncOp>(profile.trapHook())))
      return hook;
    b.setInsertionPointToEnd(module.getBody());
    auto ty = b.getFunctionType({i32, i64, i64, LLVM::LLVMPointerType::get(ctx)},
                                {});
    hook = func::FuncOp::create(b, module.getLoc(), profile.trapHook(), ty);
    hook.setPrivate();
    return hook;
  };

  for (const FsDecl &d : decls) {
    auto body = module.lookupSymbol<func::FuncOp>(bodyName(d.name));
    if (!body) {
      diag({Stage::D1, Category::BadExportSymbol, d.name, 0,
            "the importer did not build " + bodyName(d.name)});
      return false;
    }
    // Bodies were already internalized above; only attributes remain here.
    body->setAttr("passthrough", b.getArrayAttr({b.getStringAttr("nounwind")}));

    unsigned rw = boundaryWidth(d.returns);
    unsigned rf = boundaryFloatWidth(d.returns);
    if (rw == 0 && rf == 0) {
      diag({Stage::D1, Category::BadBoundaryType, d.name, 0,
            "returns :" + d.returns + " is not a boundary scalar type"});
      return false;
    }
    llvm::SmallVector<Type> argTys;
    llvm::SmallVector<Attribute> argAttrs;
    for (const FsParam &p : d.params) {
      NamedAttrList a;
      // Pass buffers as pointers, represented by C T*/const T*. No width/sign extension is needed;
      // indexing owns element width.
      if (p.kind == FsParam::Kind::Buffer) {
        // Float buffers (:f32_buf/:f64_buf) also cross the boundary as pointers; indexing and
        // load/store own element widths.
        if (boundaryWidth(p.type) == 0 && boundaryFloatWidth(p.type) == 0) {
          diag({Stage::D1, Category::BadBoundaryType, d.name, 0,
                "buffer element :" + p.type + " is not a boundary element type"});
          return false;
        }
        argTys.push_back(LLVM::LLVMPointerType::get(ctx));
        argAttrs.push_back(a.getDictionary(ctx));
        continue;
      }
      llvm::StringRef t = p.kind == FsParam::Kind::Len ? llvm::StringRef("i32")
                                                 : llvm::StringRef(p.type);
      unsigned w = p.kind == FsParam::Kind::Len ? 32 : boundaryWidth(p.type);
      unsigned f = p.kind == FsParam::Kind::Len ? 0 : boundaryFloatWidth(p.type);
      if (w == 0 && f == 0) {
        diag({Stage::D1, Category::BadBoundaryType, d.name, 0,
              "parameter :" + p.type + " is not a boundary scalar type"});
        return false;
      }
      if (f) {
        // Never attach signext/zeroext to floats: AAPCS integer extension rules would give LLVM the
        // wrong floating signature.
        argTys.push_back(f == 32 ? Type(b.getF32Type()) : Type(b.getF64Type()));
        argAttrs.push_back(a.getDictionary(ctx));
        continue;
      }
      argTys.push_back(b.getIntegerType(w));
      if (Attribute e = extensionAttr(b, t, w))
        a.set(extensionName(t), e);
      argAttrs.push_back(a.getDictionary(ctx));
    }
    Type retTy = rf ? (rf == 32 ? Type(b.getF32Type()) : Type(b.getF64Type()))
                    : Type(b.getIntegerType(rw));

    b.setInsertionPointToEnd(module.getBody());
    auto wrapTy = b.getFunctionType(argTys, {retTy});
    auto wrap = func::FuncOp::create(b, body.getLoc(), d.exportSymbol, wrapTy);
    wrap.setPublic();
    wrap->setAttr("passthrough", b.getArrayAttr({b.getStringAttr("nounwind")}));
    wrap.setAllArgAttrs(argAttrs);
    if (Attribute e = rf ? Attribute() : extensionAttr(b, d.returns, rw)) {
      NamedAttrList r;
      r.set(extensionName(d.returns), e);
      wrap.setAllResultAttrs(llvm::ArrayRef<Attribute>{r.getDictionary(ctx)});
    }

    Block *entry = wrap.addEntryBlock();
    b.setInsertionPointToStart(entry);
    Location loc = wrap.getLoc();
    llvm::SmallVector<Value> callArgs;
    for (auto [i, p] : llvm::enumerate(d.params)) {
      Value a = entry->getArgument(i);

      // Pass buffer pointers unchanged; convert floats to internal f64.
      if (p.kind == FsParam::Kind::Buffer) {
        callArgs.push_back(a);
        continue;
      }
      if (unsigned f = p.kind == FsParam::Kind::Len ? 0
                                                    : boundaryFloatWidth(p.type)) {
        callArgs.push_back(f == 64 ? a
                                   : Value(arith::ExtFOp::create(
                                         b, loc, b.getF64Type(), a)));
        continue;
      }
      unsigned w = p.kind == FsParam::Kind::Len ? 32 : boundaryWidth(p.type);
      // Do not extend when boundary width equals internal width: i64-to-i64 extsi fails
      // verification. Earlier cases covered i32 and narrow i8/i16, leaving this width untested.
      const unsigned bodyWidth = llvm::cast<IntegerType>(body.getFunctionType().getInput(i)).getWidth();
      if (w == bodyWidth) {
        callArgs.push_back(a);
        continue;
      }
      bool sgn = p.kind == FsParam::Kind::Len || boundarySigned(p.type);
      Type bodyType = b.getIntegerType(bodyWidth);
      callArgs.push_back(sgn ? Value(arith::ExtSIOp::create(b, loc, bodyType, a))
                             : Value(arith::ExtUIOp::create(b, loc, bodyType, a)));
    }
    // Check call contracts before invoking the body (codes 5/6). Preserve frozen order: length
    // first, so len=-1 plus NULL returns code 6. Detail names the export symbol.
    {
      auto trapHere = [&](Value cond, int32_t codeNo, Value a,
                          llvm::StringRef text) {
        // ensureHook moves insertion to the module body. Save the current block first; asking
        // afterward makes cf.cond_br target another region and fails verification.
        Block *cur = b.getInsertionBlock();
        func::FuncOp h = ensureHook();
        Block *ok = wrap.addBlock();
        Block *bad = wrap.addBlock();
        b.setInsertionPointToEnd(cur);
        cf::CondBranchOp::create(b, loc, cond, bad, ValueRange{}, ok,
                                 ValueRange{});
        b.setInsertionPointToStart(bad);
        Value codeV = arith::ConstantOp::create(b, loc,
                                                b.getIntegerAttr(i32, codeNo));
        Value zeroV = arith::ConstantOp::create(b, loc, b.getIntegerAttr(i64, 0));
        Value detail = trapDetailPtr(b, module, loc, text);
        func::CallOp::create(b, loc, h, ValueRange{codeV, a, zeroV, detail});
        LLVM::UnreachableOp::create(b, loc);
        b.setInsertionPointToStart(ok);
      };
      for (auto [i, p] : llvm::enumerate(d.params)) {
        if (p.kind != FsParam::Kind::Scalar || p.type != "u32" ||
            !body.getFunctionType().getInput(i).isInteger(32) || d.overflow != "trap")
          continue;
        Value value = arith::ExtUIOp::create(b, loc, i64, entry->getArgument(i));
        Value limit = arith::ConstantOp::create(b, loc, b.getIntegerAttr(i64, INT32_MAX));
        Value tooBig = arith::CmpIOp::create(b, loc, arith::CmpIPredicate::ugt, value, limit);
        trapHere(tooBig, 3, value, d.exportSymbol + ": argument does not fit target Integer");
      }
      // (1) Negative :len.
      for (auto [i, p] : llvm::enumerate(d.params)) {
        if (p.kind != FsParam::Kind::Len)
          continue;
        Value len = entry->getArgument(i);
        Value len64 = arith::ExtSIOp::create(b, loc, i64, len);
        Value z = arith::ConstantOp::create(b, loc, b.getIntegerAttr(i64, 0));
        Value neg = arith::CmpIOp::create(b, loc, arith::CmpIPredicate::slt,
                                          len64, z);
        trapHere(neg, 6, len64,
                 d.exportSymbol + ": negative length for the buffer before it");
      }
      // (2) NULL buffer with len > 0. The declaration places :len immediately after the buffer, reflected by detail "the buffer before it".
      for (auto [i, p] : llvm::enumerate(d.params)) {
        if (p.kind != FsParam::Kind::Buffer)
          continue;
        if (i + 1 >= d.params.size() ||
            d.params[i + 1].kind != FsParam::Kind::Len)
          continue;
        Value buf = entry->getArgument(i);
        Value len = entry->getArgument(i + 1);
        Value len64 = arith::ExtSIOp::create(b, loc, i64, len);
        Value z = arith::ConstantOp::create(b, loc, b.getIntegerAttr(i64, 0));
        Value nullp =
            LLVM::ZeroOp::create(b, loc, LLVM::LLVMPointerType::get(ctx));
        Value isNull = LLVM::ICmpOp::create(b, loc, LLVM::ICmpPredicate::eq,
                                            buf, nullp);
        Value pos = arith::CmpIOp::create(b, loc, arith::CmpIPredicate::sgt,
                                          len64, z);
        Value bad = arith::AndIOp::create(b, loc, isNull, pos);
        trapHere(bad, 5, len64,
                 d.exportSymbol + ": NULL buffer with a non-zero length");
      }
    }
    Value r = func::CallOp::create(b, loc, body, callArgs).getResult(0);

    // Float boundaries only adjust width. Overflow policy is for integers, so insert no hook: code
    // 3 denotes integer narrowing overflow.
    if (rf) {
      func::ReturnOp::create(
          b, loc,
          rf == 64 ? r : Value(arith::TruncFOp::create(b, loc, retTy, r)));
      continue;
    }
    if (r.getType().isInteger(32))
      r = arith::ExtSIOp::create(b, loc, i64, r);
    if (rw == 64) {
      func::ReturnOp::create(b, loc, r);
      continue;
    }
    Value narrow = arith::TruncIOp::create(b, loc, retTy, r);
    if (d.overflow != "trap") {
      // overflow: :wrap truncates directly to boundary width without a hook.
      func::ReturnOp::create(b, loc, narrow);
      continue;
    }
    // overflow: trap calls the hook if the result cannot fit the declared width (code 3), making
    // the hook an undefined symbol.
    bool sgn = boundarySigned(d.returns);
    Value back = sgn ? Value(arith::ExtSIOp::create(b, loc, i64, narrow))
                     : Value(arith::ExtUIOp::create(b, loc, i64, narrow));
    Value fits = arith::CmpIOp::create(b, loc, arith::CmpIPredicate::eq, back, r);
    // Call ensureHook before constructing blocks: it moves insertion to the module, potentially
    // leaving newly created blocks empty. Save the current block before that call and append there,
    // not invariably at entry. Codes 5/6 may already terminate entry with cf.cond_br; adding after
    // it violates terminator placement.
    Block *cur = b.getInsertionBlock();
    func::FuncOp h = ensureHook();
    Block *ok = wrap.addBlock();
    Block *bad = wrap.addBlock();
    b.setInsertionPointToEnd(cur);
    cf::CondBranchOp::create(b, loc, fits, ok, ValueRange{}, bad, ValueRange{});
    b.setInsertionPointToStart(bad);
    Value code = arith::ConstantOp::create(b, loc, b.getIntegerAttr(i32, 3));
    Value zero = arith::ConstantOp::create(b, loc, b.getIntegerAttr(i64, 0));
    // Preserve full frozen detail: boundary codes 3/5/6 name the export, while arithmetic codes 1/2
    // name the Ruby method, as observed.
    Value detail = trapDetailPtr(b, module, loc,
                                 d.exportSymbol + ": return value does not fit " +
                                     d.returns);
    func::CallOp::create(b, loc, h, ValueRange{code, r, zero, detail});
    LLVM::UnreachableOp::create(b, loc);
    b.setInsertionPointToStart(ok);
    func::ReturnOp::create(b, loc, narrow);
  }
  return true;
}

bool writeBoundaryHeader(llvm::raw_ostream &os, llvm::StringRef sourceName,
                         llvm::StringRef profileName, const FreestandingProfile &profile,
                         llvm::ArrayRef<FsDecl> decls, FsDiagnosticFn diag) {
  os << "/* Generated by spinel-fs-emit from " << sourceName
     << " -- do not edit.  Profile: " << profileName << " */\n"
     << "#ifndef SPINEL_FREESTANDING_H\n#define SPINEL_FREESTANDING_H\n"
     << "#include <stdint.h>\n\n"
     << "void " << profile.trapHook()
     << "(int32_t code, int64_t a, int64_t b, const char *detail);\n\n";
  for (const FsDecl &d : decls) {
    llvm::StringRef ret = cScalarType(d.returns);
    if (ret.empty()) {
      diag({Stage::D1, Category::BadBoundaryType, d.name, 0,
            "returns :" + d.returns + " has no C spelling"});
      return false;
    }
    os << ret << " " << d.exportSymbol << "(";
    bool first = true;
    for (const FsParam &p : d.params) {
      if (!first)
        os << ", ";
      first = false;
      if (p.kind == FsParam::Kind::Len) {
        os << "int32_t";
        continue;
      }
      llvm::StringRef c = cScalarType(p.type);
      if (c.empty()) {
        diag({Stage::D1, Category::BadBoundaryType, d.name, 0,
              "parameter :" + p.type + " has no C spelling"});
        return false;
      }
      if (p.kind == FsParam::Kind::Buffer) {
        if (p.direction == "in")
          os << "const ";
        os << c << " *";
      } else {
        os << c;
      }
    }
    if (first)
      os << "void";
    os << ");\n";
  }
  // Emit profile platform-extern prototypes so the C compiler independently checks platform
  // wrappers against generated declarations (run_extern_check.sh expects conflicting types on
  // mismatch). Use the shared boundary C spellings, const T*/T* buffers and int32_t :len.
  if (!profile.externs().empty()) {
    os << "\n";
    for (const FsExtern &e : profile.externs()) {
      llvm::StringRef ret = cScalarType(e.returns);
      if (ret.empty()) {
        diag({Stage::P2, Category::BadExternType, e.name, 0,
              "platform extern returns :" + e.returns + " has no C spelling"});
        return false;
      }
      os << ret << " " << e.symbol << "(";
      bool first = true;
      for (const FsParam &p : e.params) {
        if (!first)
          os << ", ";
        first = false;
        if (p.kind == FsParam::Kind::Len) {
          os << "int32_t";
          continue;
        }
        llvm::StringRef c = cScalarType(p.type);
        if (c.empty()) {
          diag({Stage::P2, Category::BadExternType, e.name, 0,
                "platform extern parameter :" + p.type + " has no C spelling"});
          return false;
        }
        if (p.kind == FsParam::Kind::Buffer) {
          if (p.direction == "in")
            os << "const ";
          os << c << " *";
        } else {
          os << c;
        }
      }
      if (first)
        os << "void";
      os << ");\n";
    }
  }
  os << "\n#endif\n";
  return true;
}


// compileFreestanding: stage 1 through object generation.
namespace {

// Synthetic second-stage driver, ported from frozen fs_driver. The initial integer slice deferred
// float/buffer/extern stubs to the later port rather than inventing new rules. Kernel files have no
// top-level calls, so write declaration facts as driver calls to constrain inference: floats use
// ARGV.size+0.5, buffers use [n] or [n+0.5]. This yields int_array/float_array and types indexed
// elements; no pointer facts remain in the module. Append rather than insert, preserving original
// line numbers.
bool writeSyntheticDriver(llvm::raw_ostream &os, llvm::StringRef original,
                          llvm::ArrayRef<FsDecl> decls,
                          llvm::ArrayRef<FsExtern> externs, FsDiagnosticFn diag) {
  auto isFloatType = [](llvm::StringRef t) { return t == "f32" || t == "f64"; };
  bool needFloat = false, needIntBuf = false, needFloatBuf = false;
  for (const FsDecl &d : decls)
    for (const FsParam &p : d.params) {
      if (p.kind == FsParam::Kind::Buffer)
        (isFloatType(p.type) ? needFloatBuf : needIntBuf) = true;
      else if (p.kind == FsParam::Kind::Scalar && isFloatType(p.type))
        needFloat = true;
      else if (p.kind == FsParam::Kind::Scalar && boundaryWidth(p.type) == 0) {
        diag({Stage::D1, Category::BadBoundaryType, d.name, 0,
              "boundary type the synthesized driver cannot handle (:" + p.type + ")"});
        return false;
      }
    }
  os << original << "\n_sp_fs_n = ARGV.size\n";
  // One stub def per callable platform extern gives whole-program inference the declared result
  // kind via a literal body. Like driver calls, stubs express declaration facts only; externCall
  // intercepts before top-level lookup, leaving none of the stub in generated output.
  for (const FsExtern &e : externs) {
    os << "def " << e.name;
    if (!e.params.empty()) {
      os << "(";
      for (size_t i = 0; i < e.params.size(); ++i)
        os << (i ? ", " : "") << "_e" << i;
      os << ")";
    }
    const bool f = e.returns == "f32" || e.returns == "f64";
    os << "; " << (f ? "0.0" : "0") << "; end\n";
  }
  if (needFloat)
    os << "_sp_fs_n_f = _sp_fs_n + 0.5\n";
  if (needIntBuf)
    os << "_sp_fs_n_ib = [_sp_fs_n]\n";
  if (needFloatBuf)
    os << "_sp_fs_n_fb = [_sp_fs_n + 0.5]\n";
  for (const FsDecl &d : decls) {
    os << "puts " << d.name;
    if (d.params.empty()) {
      os << "\n";
      continue;
    }
    os << "(";
    for (size_t i = 0; i < d.params.size(); ++i) {
      const FsParam &p = d.params[i];
      os << (i ? ", " : "");
      if (p.kind == FsParam::Kind::Buffer)
        os << (isFloatType(p.type) ? "_sp_fs_n_fb" : "_sp_fs_n_ib");
      else if (p.kind == FsParam::Kind::Scalar && isFloatType(p.type))
        os << "_sp_fs_n_f";
      else
        os << "_sp_fs_n";
    }
    os << ")\n";
  }
  return true;
}

} // namespace

namespace {
// Merge policy-group modules, skipping existing symbols. Only trap-hook declarations may overlap,
// preserving the one-hook invariant shared with ensureHook. Duplicate root/helper bodies would
// already have caused policy-conflict refusal.
void mergeModules(ModuleOp into, ModuleOp from) {
  llvm::SmallVector<Operation *> moving;
  for (Operation &op : from.getBody()->getOperations())
    moving.push_back(&op);
  for (Operation *op : moving) {
    if (auto sym = llvm::dyn_cast<mlir::SymbolOpInterface>(op))
      if (into.lookupSymbol(sym.getName())) {
        op->erase();
        continue;
      }
    op->remove();
    into.getBody()->push_back(op);
  }
}
} // namespace

namespace ast = ::spinel_mlir::scalar::ast;

// Core sweep checks even unreachable top-level defs: # spinel-tier: core claims every def is core.
// Use the same eighteen-kind supportedNodeKinds table and freestandingTypes flags as the real
// importer; a narrower sweep would reject importer-admitted bodies. Frozen fs_subset_check names
// allocating syntax differently, recorded as divergent wording, but verdicts must agree.
static bool sweepCoreDefs(const contract::ContractModule &m,
                          llvm::ArrayRef<FsDecl> decls,
                          llvm::raw_ostream &note) {
  auto node = [&](int64_t id) -> const contract::Node * {
    for (const contract::Node &n : m.nodes())
      if (n.id == id)
        return &n;
    return nullptr;
  };
  llvm::StringSet<> supported;
  scalar::ScalarImportOptions sweepOptions;
  sweepOptions.freestandingTypes = true;
  for (llvm::StringRef k : scalar::supportedNodeKinds(sweepOptions))
    supported.insert(k);

  const contract::Node *root = node(m.root());
  if (!root)
    return true;
  int64_t stmtsId = -1;
  ast::getReference(*root, "statements", stmtsId);
  const contract::Node *stmts = node(stmtsId);
  if (!stmts)
    return true;
  std::vector<int64_t> body;
  ast::getArray(*stmts, "body", body);

  for (int64_t id : body) {
    const contract::Node *n = node(id);
    std::string name;
    if (!n || n->kind != "DefNode" || !ast::getString(*n, "name", name))
      continue;
    bool declared = false;
    for (const FsDecl &d : decls)
      if (d.name == name)
        declared = true;
    if (declared)
      continue;

    // Walk every body node and refuse any kind outside the closed set. Fix traversal by id for
    // deterministic wording when several causes exist.
    int64_t defBody = -1;
    ast::getReference(*n, "body", defBody);
    std::vector<int64_t> stack{defBody};
    std::vector<std::pair<int64_t, std::string>> bad;
    while (!stack.empty()) {
      int64_t cur = stack.back();
      stack.pop_back();
      const contract::Node *c = node(cur);
      if (!c)
        continue;
      if (!supported.contains(c->kind))
        bad.emplace_back(c->id, c->kind);
      for (const contract::AstField &f : c->fields) {
        if (f.kind == contract::AstField::Kind::Reference) {
          int64_t ref = std::get<int64_t>(f.value);
          if (ref >= 0)
            stack.push_back(ref);
        } else if (f.kind == contract::AstField::Kind::Array) {
          for (int64_t ch : std::get<std::vector<int64_t>>(f.value))
            stack.push_back(ch);
        }
      }
    }
    if (bad.empty())
      continue;
    std::sort(bad.begin(), bad.end());
    note << "spinel-fs-emit: unsupported: " << name << ": " << bad.front().second
         << " is not in the freestanding subset -- '" << name
         << "' is not reachable from any freestanding_def, but this file "
            "declares itself core, so every def in it is checked "
            "(P008 kentouten C, E141)\n";
    return false;
  }
  return true;
}

// Tier declaration window: comment lines in the first two physical lines only. A shebang occupies a
// slot, permitting a declaration on line 2; later lookalikes are not declarations. Match frozen
// spinel_platform.read_spinel_tier.
std::optional<std::string> readDeclaredTier(llvm::StringRef sourceText,
                                            int *line) {
  llvm::SmallVector<llvm::StringRef, 4> lines;
  sourceText.split(lines, '\n', /*MaxSplit=*/3);
  for (size_t i = 0; i < lines.size() && i < 2; ++i) {
    llvm::StringRef raw = lines[i].rtrim("\r");
    // End the window at the first noncomment (break, not continue), and require # at line start.
    // Frozen read_entry_tier did this; native previously read line 2 after require_relative,
    // rejecting a bogus tier that frozen Python ignored and compiled. A stricter native refusal was
    // still a parity defect.
    if (!raw.starts_with("#"))
      break;
    llvm::StringRef rest = raw.drop_front(1).ltrim();
    if (!rest.consume_front("spinel-tier:"))
      continue;
    llvm::StringRef v = rest.trim();
    // Require exactly one token: never silently reduce core extra to core. Match frozen
    // ^#\s*spinel-tier:\s*(\S+)\s*$.
    if (v.empty() || v.contains(' ') || v.contains('\t'))
      return std::string();
    if (line) *line = static_cast<int>(i) + 1;
    return v.str();
  }
  return std::nullopt;
}

namespace {

// Shared core for compileFreestanding/emitFreestandingModule. Nonnull capture returns the Module
// immediately after translation with Emitted, without object/.ll output. Keep admission and
// pipelines in one implementation.
EmitStatus compileCore(const EmitRequest &req, RunToolFn runTool,
                       TempPathFn tempPath, FsDiagnosticFn diagOut,
                       llvm::raw_ostream &noteOut,
                       llvm::LLVMContext *externalContext,
                       std::unique_ptr<llvm::Module> *capture) {
  // Buffer diagnostics until finish determines the final result. Historically probe/admit rc 3
  // routed to frozen Python silently, but infrastructure rc 1 still reported. Centralizing
  // suppression prevents new diagnostics from violating silence: adding admit once leaked
  // not-default-eligible because a branch checked only probe.
  std::vector<Rejection> pending;
  auto collect = [&](const Rejection &r) { pending.push_back(r); };
  FsDiagnosticFn diag = collect;
  std::string noteBuf;
  llvm::raw_string_ostream note(noteBuf);
  // Routing rc 3 leaves no artifacts. Probe stops after admission, while admit may write then fail
  // at object gate G. Do not make probe pay full generation cost: clean up admit instead. Delete
  // only paths this run wrote; guessing req.objPath could erase an existing caller file on an
  // earlier refusal.
  std::vector<std::string> written;
  auto wrote = [&](llvm::StringRef p) {
    if (!p.empty())
      written.emplace_back(p);
  };
  auto finish = [&](EmitStatus st) {
    if ((req.probe || req.admit) && st == EmitStatus::InputRejected) {
      // Remove artifacts: a routing-rejected run leaves no files.
      for (const std::string &p : written)
        llvm::sys::fs::remove(p);
      // Keep diagnostics: historically rc 3 routing was silent, but freestanding InputRejected
      // later became rc 1 even in routing mode. Verdict parity had been checked, with the
      // duplicate-key profile as a declared inverse divergence. Silent rc 1 violates the stopping
      // contract; print the same diagnostic in routing too.
    }
    note.flush();
    for (const Rejection &r : pending)
      diagOut(r);
    noteOut << noteBuf;
    return st;
  };

  auto readFile = [&](llvm::StringRef path,
                      std::unique_ptr<llvm::MemoryBuffer> &out) {
    auto buf = llvm::MemoryBuffer::getFile(path);
    if (!buf) {
      note << "spinel-fs-emit: unreadable: " << path << ": "
           << buf.getError().message() << "\n";
      return false;
    }
    out = std::move(*buf);
    return true;
  };

  std::unique_ptr<llvm::MemoryBuffer> yaml;
  if (!readFile(req.profilePath, yaml))
    return finish(EmitStatus::Infrastructure);
  // Resolve platform-first profiles with the ledger; legacy profiles follow readFreestandingProfile
  // with identical order/wording. Broken/unreadable ledger or base is Infrastructure, not
  // InputRejected, or routing could silently fall back on repository defects.
  std::string ledgerInfra;
  auto profile = resolveFreestandingProfile(req.profilePath, yaml->getBuffer(),
                                            req.menusPath, diag, &ledgerInfra);
  if (!ledgerInfra.empty()) {
    note << "spinel-fs-emit: ledger: " << ledgerInfra << "\n";
    return finish(EmitStatus::Infrastructure);
  }
  if (!profile)
    return finish(EmitStatus::InputRejected);

  // After reading a legacy profile, emit exactly one frozen deprecation line using wrapper name
  // spinel-mlirgen, matching the fuse diagnostic convention. Native originally omitted it, so g13
  // passed only on Python. Do not emit it for probe: it accompanies generation, not acceptance, and
  // would violate zero-stderr probing.
  if (!profile->platformFirst() && !req.probe)
    note << "spinel-mlirgen: note: profile " << req.profilePath
         << " uses the pre-T5 format (deprecated; P008 Phase 2 canonicalizes "
            "the platform-first form); accepted unchanged\n";

  std::unique_ptr<llvm::MemoryBuffer> widthSource;
  if (!readFile(req.sourcePath, widthSource))
    return finish(EmitStatus::Infrastructure);
  const unsigned targetBits = targetIntegerPointerBits(profile->triple());
  const unsigned profileBits = profileIntegerBits(profile->intWidth());
  const bool declaredInt64 = declaresInt64(widthSource->getBuffer());
  // Decision 0019, revised 2026-10-21: a 32-bit target has no 64-bit body
  // unless tools/core/int64-allow.tsv lists the source.
  if (targetBits == 32 && declaredInt64) {
    const Int64Allow allow = int64Allowed(widthSource->getBuffer(), req.int64AllowPath);
    if (!allow.error.empty()) {
      note << "spinel-fs-emit: int64-allow-table: " << allow.error << "\n";
      return finish(EmitStatus::InputRejected);
    }
    if (!allow.listed) {
      note << "spinel-fs-emit: int-width-int64-refused: " << req.sourcePath
           << ":1: `# spinel: int64` declares a 64-bit body, " << profile->triple()
           << " has 32-bit pointers, and " << allow.table
           << " does not list this source; remove the declaration and compute at "
              "32 bits, or build for a 64-bit target\n";
      return finish(EmitStatus::InputRejected);
    }
  }
  if (!targetBits || !profileBits || (targetBits != profileBits && !declaredInt64)) {
    note << "spinel-fs-emit: int-width-mismatch: abi.int_width "
         << profile->intWidth() << " disagrees with target " << profile->triple()
         << "; use " << (targetBits == 32 ? "i32-internal" : "i64-internal") << "\n";
    return finish(EmitStatus::InputRejected);
  }
  const unsigned integerBits = declaredInt64 ? 64 : profileBits;
  const std::string widthArg = "--int-width=" + std::to_string(integerBits);

  // Spinel's analysis can append nodes the parse never had: it writes
  // `Integer.prepend(M)` out as a `class Integer` holding M's methods. The
  // contract reader refuses a nodes-face row past the parse (a dangling
  // reference), so the program never reaches the declaration stage that
  // names a changed builtin class. For that one message only, the faces are
  // read once more without the appended rows, and a reopened-builtin refusal
  // from the declaration stage is reported. Nothing is accepted this way:
  // the caller still refuses the program on the first read's failure.
  bool reopenedRefused = false;
  auto reopenedBehindAppended = [&](const contract::ContractInputs &in) {
    int64_t astCount = 0;
    llvm::SmallVector<llvm::StringRef> astLines;
    in.ast.split(astLines, '\n');
    for (llvm::StringRef l : astLines) {
      int64_t id = -1;
      if (l.consume_front("N ") && !l.split(' ').first.getAsInteger(10, id))
        astCount = std::max(astCount, id + 1);
    }
    // The nodes face without the rows past the parse; a scope only those
    // rows use (the copied method's) leaves the locals and methods faces too.
    llvm::StringSet<> keptScopes, droppedScopes;
    std::string nodes;
    llvm::SmallVector<llvm::StringRef> rows;
    in.nodes.split(rows, '\n');
    for (size_t i = 0; i < rows.size(); ++i) {
      llvm::SmallVector<llvm::StringRef> f;
      rows[i].split(f, '\t');
      int64_t id = -1;
      bool past = i > 0 && !f[0].getAsInteger(10, id) && id >= astCount;
      if (i > 0 && f.size() > 3)
        (past ? droppedScopes : keptScopes).insert(f[3]);
      if (past)
        continue;
      nodes += rows[i].str();
      if (i + 1 < rows.size())
        nodes += "\n";
    }
    if (droppedScopes.empty())
      return;
    auto withoutScopes = [&](llvm::StringRef face) {
      std::string out;
      llvm::SmallVector<llvm::StringRef> ls;
      face.split(ls, '\n');
      for (size_t i = 0; i < ls.size(); ++i) {
        llvm::StringRef scope = ls[i].split('\t').first;
        if (i > 0 && droppedScopes.count(scope) && !keptScopes.count(scope))
          continue;
        out += ls[i].str();
        if (i + 1 < ls.size())
          out += "\n";
      }
      return out;
    };
    std::string locals = withoutScopes(in.locals), methods = withoutScopes(in.methods);
    contract::ContractInputs trimmed{in.ast, nodes, locals, methods};
    auto quiet = [](llvm::StringRef) {};
    auto module = contract::readContract(trimmed, quiet);
    if (!module)
      return;
    auto onlyReopened = [&](const Rejection &r) {
      if (r.category != Category::ReopenedBuiltin)
        return;
      reopenedRefused = true;
      diag(r);
    };
    (void)readFreestandingDeclarations(*module, *profile, onlyReopened);
  };

  // Collect the four faces twice: stage 1 structural contract, stage 2 body kind.
  static const llvm::StringRef kFaces[4] = {"ast", "nodes", "locals", "methods"};
  auto faces = [&](llvm::StringRef src, llvm::StringRef tag,
                   std::unique_ptr<contract::ContractModule> &out,
                   const spinel_mlir::core::PreludeCopy &prelude = {}) {
    std::unique_ptr<llvm::MemoryBuffer> b[4];
    for (int f = 0; f < 4; ++f) {
      std::string o = tempPath((tag + "." + kFaces[f] + ".txt").str());
      std::string e = tempPath((tag + "." + kFaces[f] + ".err").str());
      llvm::StringRef argv[] = {req.typedumpPath, src, widthArg, kFaces[f]};
      if (runTool(req.typedumpPath, argv, o, e) != 0) {
        note << "spinel-fs-emit: typedump-failed: " << tag << " " << kFaces[f]
             << "\n";
        if (auto eb = llvm::MemoryBuffer::getFile(e))
          note << spinel_mlir::core::sourceLines((*eb)->getBuffer(), src, prelude);
        return false;
      }
      if (!readFile(o, b[f]))
        return false;
    }
    contract::ContractInputs in{b[0]->getBuffer(), b[1]->getBuffer(),
                                b[2]->getBuffer(), b[3]->getBuffer()};
    in.preludeLine = prelude.preludeLine;
    in.preludeLines = prelude.preludeLines;
    in.preludeColumns = prelude.firstColumns;
    bool bad = false;
    auto d = [&](llvm::StringRef line) {
      if (bad) return;
      bad = true;
      note << "spinel-fs-emit: contract-rejected: " << line << "\n";
    };
    out = contract::readContract(in, d);
    if (!out && tag == "stage1")
      reopenedBehindAppended(in);
    return static_cast<bool>(out);
  };

// Ruby parses each required file on its own; Spinel splices them into one
// buffer first, so a definition opened in one file and closed by an `end`
// in another reaches stage 1 as one method. Each required file is parsed
// alone here, and one that does not parse is refused, naming the file and
// the parser's first error. A file that parses but does not analyse alone
// is not refused: only the parse is Ruby's rule. Returns true when it
// refused `path`.
auto refusedAlone = [&](const std::string &path, unsigned n) -> bool {
  std::string o = tempPath("alone." + std::to_string(n) + ".txt");
  std::string e = tempPath("alone." + std::to_string(n) + ".err");
  llvm::StringRef argv[] = {req.typedumpPath, path, widthArg, "ast", "--ast-only"};
  if (runTool(req.typedumpPath, argv, o, e) == 0)
    return false;
  std::unique_ptr<llvm::MemoryBuffer> eb;
  if (!readFile(e, eb) || !eb->getBuffer().contains("Parse errors in"))
    return false;
  llvm::SmallVector<llvm::StringRef> lines;
  eb->getBuffer().split(lines, '\n');
  std::string first;
  for (llvm::StringRef l : lines)
    if (l.starts_with("  ")) {
      first = l.trim().str();
      break;
    }
  Rejection r;
  r.stage = Stage::D1;
  r.category = Category::SplitAcrossFiles;
  r.subject = path;
  r.detail = path + " does not parse on its own (" + first +
             "). Ruby parses each required file separately, so a "
             "definition, block or `end` cannot cross into the file that "
             "requires it; Spinel's splice of the two would hide that. Close "
             "each construct in the file that opens it.";
  diag(r);
  return true;
};

  std::unique_ptr<contract::ContractModule> stage1;
  if (!faces(req.sourcePath, "stage1", stage1)) {
    if (reopenedRefused)
      return finish(EmitStatus::InputRejected);
    // Spinel now parses the entry on its own before it splices a required
    // file in, so a construct split across files can stop stage 1 at the
    // entry's parse, before the sources list below exists. The required
    // files are then read from the entry's own `require_relative "..."`
    // lines (a literal name, resolved beside the entry; a nested require is
    // not followed) and parsed alone the same way, so the refusal still
    // names the file that leaves the construct open or closes it. Without
    // such a file the failure stays what it was.
    std::unique_ptr<llvm::MemoryBuffer> entry;
    if (readFile(req.sourcePath, entry)) {
      llvm::StringRef dir = llvm::sys::path::parent_path(req.sourcePath);
      unsigned n = 0;
      for (llvm::line_iterator it(*entry, /*SkipBlanks=*/true); !it.is_at_end(); ++it) {
        llvm::StringRef l = it->trim();
        if (!l.consume_front("require_relative"))
          continue;
        l = l.ltrim();
        if (!l.consume_front("\"") || !l.consume_back("\"") || l.contains('"'))
          continue;
        llvm::SmallString<256> p(dir);
        llvm::sys::path::append(p, l.str() + ".rb");
        if (refusedAlone(std::string(p), ++n))
          return finish(EmitStatus::InputRejected);
      }
    }
    return finish(EmitStatus::Infrastructure);
  }
for (const contract::Source &s : stage1->sources()) {
  if (s.id == stage1->sources().front().id)
    continue;
  if (refusedAlone(s.path, static_cast<unsigned>(s.id) + 1000))
    return finish(EmitStatus::InputRejected);
}
  // Tier values are core|arena|full; refuse unknowns. core claims every def, so inspect unreachable
  // top-level defs too. arena/full/no declaration need no extra check because proving core
  // satisfies these higher tiers.
  bool tierCore = false;
  int tierLine = 0;
  {
    std::unique_ptr<llvm::MemoryBuffer> tierBuf;
    if (!readFile(req.sourcePath, tierBuf))
      return finish(EmitStatus::Infrastructure);
    if (auto tier = readDeclaredTier(tierBuf->getBuffer(), &tierLine)) {
      static const llvm::StringRef kTiers[] = {"core", "arena", "full"};
      if (!llvm::is_contained(kTiers, *tier)) {
        note << "spinel-fs-emit: REJECT tier-unknown: '" << *tier
             << "' is not a spinel tier (core|arena|full) -- the entry "
             << llvm::sys::path::filename(req.sourcePath)
             << " declares it in the first two lines\n";
        return finish(EmitStatus::InputRejected);
      }
      tierCore = *tier == "core";
    }
  }

  // Tier context note: refusal of a # spinel-tier: core file contradicts its source claim; name
  // that discrepancy. Preserve frozen DIE_CONTEXT wording.
  std::string tierNote;
  if (tierCore)
    tierNote = " [the entry declares \"# spinel-tier: core\" (line " +
               std::to_string(tierLine) +
               "); a refusal here is the declaration contradicting the subset "
               "proof, T-2]";
  FsDiagnosticFn tierDiag = diag;
  auto annotated = [&](const Rejection &r) {
    Rejection copy = r;
    copy.detail += tierNote;
    diag(copy);
  };
  if (!tierNote.empty())
    tierDiag = annotated;

  auto decls = readFreestandingDeclarations(*stage1, *profile, tierDiag);
  if (!decls)
    return finish(EmitStatus::InputRejected);
  if (!checkFreestandingBodies(*stage1, *profile, *decls, tierDiag, integerBits))
    return finish(EmitStatus::InputRejected);
  if (decls->empty()) {
    note << "spinel-fs-emit: no-declarations: the source declares no boundary\n";
    return finish(EmitStatus::InputRejected);
  }

  // --method/-m selects declarations only, not a different closure algorithm, matching frozen keep=set(args.method). Sort unknown names into one diagnostic line.
  if (!req.methods.empty()) {
    std::vector<std::string> missing;
    for (const std::string &m : req.methods) {
      bool found = false;
      for (const FsDecl &d : *decls)
        if (d.name == m)
          found = true;
      if (!found && !llvm::is_contained(missing, m))
        missing.push_back(m);
    }
    if (!missing.empty()) {
      std::sort(missing.begin(), missing.end());
      note << "spinel-fs-emit: no freestanding_def for "
           << llvm::join(missing, ", ") << "\n";
      return finish(EmitStatus::InputRejected);
    }
    std::vector<FsDecl> kept;
    for (const FsDecl &d : *decls)
      if (llvm::is_contained(req.methods, d.name))
        kept.push_back(d);
    *decls = std::move(kept);
  }

  // Core sweep uses the shared scalar supportedNodeKinds table for undeclared top-level defs; the
  // historical comment counted fifteen kinds. Never duplicate the predicate.
  if (tierCore && !sweepCoreDefs(*stage1, *decls, note))
    return finish(EmitStatus::InputRejected);

  // Policy belongs to root plus call closure, not the file. Remove the former one-file-one-policy
  // restriction: independent trap/wrap declarations coexist in frozen Python. Only a helper reached
  // under incompatible policies conflicts, reported below as D2/overflow-policy-conflict.

  // Determine data layout before constructing the module. Without a pin, ask spinel-fs-codegen what
  // that profile target assumes. Codegen.h owns machine-code generation; this library stops at LLVM
  // IR, links no backend, and passes the profile path read by this run.
  auto codegenArgv = [&](std::vector<std::string> tail) {
    std::vector<std::string> v = {req.codegenPath, "--profile", req.profilePath};
    if (!req.menusPath.empty()) {
      v.push_back("--menus");
      v.push_back(req.menusPath);
    }
    v.insert(v.end(), tail.begin(), tail.end());
    return v;
  };
  auto runCodegen = [&](const std::vector<std::string> &owned,
                        llvm::StringRef out, llvm::StringRef err) {
    std::vector<llvm::StringRef> argv(owned.begin(), owned.end());
    return runTool(req.codegenPath, argv, out, err);
  };
  auto askLayout = [&](llvm::StringRef tag) -> std::optional<std::string> {
    std::string out = tempPath((tag + ".txt").str());
    std::string err = tempPath((tag + ".err").str());
    if (runCodegen(codegenArgv({"--print-data-layout"}), out, err) != 0) {
      note << "spinel-fs-emit: data-layout-probe-failed\n";
      if (auto eb = llvm::MemoryBuffer::getFile(err)) note << (*eb)->getBuffer();
      return std::nullopt;
    }
    auto buf = llvm::MemoryBuffer::getFile(out);
    if (!buf) return std::nullopt;
    return (*buf)->getBuffer().trim().str();
  };
  std::string dataLayout = profile->dataLayout().str();
  bool pinned = !dataLayout.empty();
  if (!pinned) {
    auto asked = askLayout("dl0");
    if (!asked) return finish(EmitStatus::Infrastructure);
    dataLayout = *asked;
  }

  mlir::MLIRContext context;
  context.loadDialect<mlir::func::FuncDialect, mlir::arith::ArithDialect,
                      mlir::cf::ControlFlowDialect, mlir::LLVM::LLVMDialect>();
  mlir::OwningOpRef<mlir::ModuleOp> imported;

  // Historically route per root: float/buffer/platform extern declarations used the limited
  // prototype importer, others the two-stage scalar path, avoiding whole-file rejection of mixed
  // roots. The later typed scalar importer supports float/buffer/view/extern throughout, retiring
  // PocMlirGen and rootNeedsPoc into one route.
  if (integerBits == 32) {
    for (const FsDecl &d : *decls) {
      bool wideBoundary = d.returns == "i64";
      for (const FsParam &p : d.params)
        if (p.kind == FsParam::Kind::Scalar && p.type == "i64") wideBoundary = true;
      if (wideBoundary) {
        note << "spinel-fs-emit: int-width-boundary: " << d.name
             << " has an i64 boundary, which a 32-bit Integer refuses; use i32\n";
        return finish(EmitStatus::InputRejected);
      }
    }
  }
  llvm::SmallVector<FsDecl> scalarDecls(decls->begin(), decls->end());


  if (!scalarDecls.empty()) {
  // Stage-2 synthetic source: copy the shim beside it for require_relative resolution.
  std::unique_ptr<llvm::MemoryBuffer> srcBuf;
  if (!readFile(req.sourcePath, srcBuf))
    return finish(EmitStatus::Infrastructure);
  // Each file copied into the temp dir, and the file it is a copy of: the
  // second stage's file table names the copies, and its nodes are located
  // in the originals.
  std::map<std::string, std::string> copiedFrom;
  auto normal = [](llvm::StringRef p) {
    llvm::SmallString<128> s(p);
    llvm::sys::path::remove_dots(s, /*remove_dot_dot=*/true);
    return std::string(s);
  };
  {
    llvm::SmallString<128> shim(llvm::sys::path::parent_path(req.sourcePath));
    llvm::sys::path::append(shim, "spinel");
    if (llvm::sys::fs::is_directory(shim)) {
      std::string dst = tempPath("spinel");
      llvm::sys::fs::create_directory(dst);
      std::error_code ec;
      for (llvm::sys::fs::directory_iterator it(shim, ec), end; it != end && !ec;
           it.increment(ec)) {
        llvm::SmallString<128> t(dst);
        llvm::sys::path::append(t, llvm::sys::path::filename(it->path()));
        if (!llvm::sys::fs::copy_file(it->path(), t))
          copiedFrom[normal(t)] = it->path();
      }
    }
  }
  // Make require_relative resolvable in the temporary directory. Copying only a neighboring spinel/
  // missed deeper paths such as ../../../../../tools/freestanding/spinel/freestanding in
  // subjects/fs_kern.rb; frozen Python passed the original file, but native failed stage2 ast. Copy
  // each actual resolved target into the temp directory and rewrite to its basename. Replace quoted
  // text within one line only: scalar diagnostics use synthetic-file line numbers, so preserve line
  // count/positions.
  std::string rewrittenSource;
  {
    const std::string tempDir =
        std::string(llvm::sys::path::parent_path(tempPath("stage2.rb")));
    llvm::StringRef srcDir = llvm::sys::path::parent_path(req.sourcePath);
    llvm::SmallVector<llvm::StringRef> lines;
    srcBuf->getBuffer().split(lines, '\n');
    llvm::raw_string_ostream rs(rewrittenSource);
    for (size_t i = 0; i < lines.size(); ++i) {
      if (i)
        rs << "\n";
      llvm::StringRef line = lines[i];
      const size_t kw = line.find("require_relative");
      if (kw == llvm::StringRef::npos) {
        rs << line;
        continue;
      }
      llvm::StringRef after = line.substr(kw + strlen("require_relative"));
      const size_t q = after.find_first_of("\"'");
      if (q == llvm::StringRef::npos) {
        rs << line;
        continue;
      }
      const char quote = after[q];
      const size_t end = after.find(quote, q + 1);
      if (end == llvm::StringRef::npos) {
        rs << line;
        continue;
      }
      llvm::StringRef spelling = after.substr(q + 1, end - q - 1);
      // Leave paths already resolvable from the temporary directory unchanged, including the copied
      // neighboring spinel/ case.
      llvm::SmallString<128> inTemp(tempDir);
      llvm::sys::path::append(inTemp, spelling + ".rb");
      // Resolve relative to the original source directory.
      llvm::SmallString<128> resolved(srcDir);
      llvm::sys::path::append(resolved, spelling + ".rb");
      if (llvm::sys::fs::exists(inTemp) || !llvm::sys::fs::exists(resolved)) {
        rs << line;
        continue;
      }
      llvm::StringRef base = llvm::sys::path::stem(resolved);
      llvm::SmallString<128> dst(tempDir);
      llvm::sys::path::append(dst, base + ".rb");
      if (llvm::sys::fs::copy_file(resolved, dst)) {
        // If copying fails, retain the spelling: the original failure has clearer attribution than
        // a rewritten path to a file never copied.
        rs << line;
        continue;
      }
      copiedFrom[normal(dst)] = std::string(resolved);
      rs << line.substr(0, kw + strlen("require_relative"))
         << after.substr(0, q + 1) << base << after.substr(end);
    }
  }

  std::string synthetic = tempPath("stage2.rb");
  spinel_mlir::core::PreludeCopy prelude;
  {
    std::error_code ec;
    llvm::raw_fd_ostream file(synthetic, ec);
    if (ec) {
      note << "spinel-fs-emit: synthetic-write-failed: " << ec.message() << "\n";
      return finish(EmitStatus::Infrastructure);
    }
    // Decision 0042 stage 4: before the program (after its leading comment
    // lines), the prelude's definitions of the intrinsics the source names,
    // so that a call to one has a type in this analysis and every intrinsic
    // is defined before a call to it runs. readContract drops them again and
    // moves the program's lines back (preludeLine, preludeLines).
    std::string text;
    llvm::raw_string_ostream os(text);
    // Historically the synthetic driver called only scalar-path roots; including prototype
    // float/buffer/extern roots hit the driver integer-only restriction and rejected mixed files
    // (observed mixed_int_float f64 bad-boundary-type).
    if (!writeSyntheticDriver(os, rewrittenSource, scalarDecls,
                              profile->externs(), diag))
      return finish(EmitStatus::InputRejected);
    os.flush();
    // The names are picked from every file stage 1 read, not the root's
    // bytes alone: this analysis reads the required files too, and a call
    // to an intrinsic in one of them needs the prelude's definition as much
    // as a call in the root does.
    std::string spelled = srcBuf->getBuffer().str();
    for (const contract::Source &s : stage1->sources()) {
      if (s.id == stage1->sources().front().id)
        continue;
      // A relative FILE path is the reader's, beside the root.
      llvm::SmallString<256> beside;
      if (!llvm::sys::path::is_absolute(s.path)) {
        beside = llvm::sys::path::parent_path(req.sourcePath);
        llvm::sys::path::append(beside, s.path);
      }
      auto fb = llvm::MemoryBuffer::getFile(s.path);
      if (!fb && !beside.empty())
        fb = llvm::MemoryBuffer::getFile(beside);
      if (!fb) {
        note << "spinel-fs-emit: cannot read " << s.path
             << ", which stage 1 read, to pick the intrinsics' prelude: "
             << fb.getError().message() << "\n";
        return finish(EmitStatus::Infrastructure);
      }
      spelled += "\n";
      spelled += (*fb)->getBuffer().str();
    }
    prelude = spinel_mlir::core::insertPrelude(text, spinel_mlir::core::preludeFor(spelled));
    file << prelude.text;
  }
  std::unique_ptr<contract::ContractModule> stage2;
  if (!faces(synthetic, "stage2", stage2, prelude))
    return finish(EmitStatus::Infrastructure);
  // Normalize synthetic identity to original source. ScalarProgram retains it for FileLineColLoc;
  // otherwise diagnostics/locations leak temporary paths after removal.
  stage2->setSourceFile(req.sourcePath);
  copiedFrom[normal(synthetic)] = req.sourcePath;
  stage2->renameSources([&](llvm::StringRef p) {
    auto found = copiedFrom.find(normal(p));
    return found == copiedFrom.end() ? p.str() : found->second;
  });

  // Parallel assignment and op= entered scalar product defaults; only typed values (f64/buffer
  // pointers/FloatNode) remain a freestanding-only opt-in.
  scalar::ScalarImportOptions kFsOptions;
  kFsOptions.freestandingTypes = true;
  kFsOptions.integerBits = integerBits;
  kFsOptions.pointerBits = targetBits;
  for (const FsDecl &d : scalarDecls) {
    scalar::ScalarRootDesc rd;
    rd.name = d.name;
    rd.returns = d.returns;
    rd.boundsChecked = d.bounds != "unchecked";
    for (const FsParam &p : d.params) {
      scalar::ScalarParamDesc pd;
      switch (p.kind) {
      case FsParam::Kind::Buffer:
        pd.kind = scalar::ScalarParamDesc::Kind::Buffer;
        pd.elem = p.type;
        pd.dir = p.direction;
        pd.lenIndex = p.lenIndex;
        break;
      case FsParam::Kind::Len:
        pd.kind = scalar::ScalarParamDesc::Kind::Len;
        break;
      case FsParam::Kind::Scalar:
        pd.kind = (p.type == "f32" || p.type == "f64")
                      ? scalar::ScalarParamDesc::Kind::Float
                      : scalar::ScalarParamDesc::Kind::Int;
        break;
      }
      rd.params.push_back(std::move(pd));
    }
    kFsOptions.roots.push_back(std::move(rd));
  }
  // Copy profile-declared platform externs.
  for (const FsExtern &e : profile->externs()) {
    scalar::ScalarExternDesc ed;
    ed.name = e.name;
    ed.symbol = e.symbol;
    ed.returns = e.returns;
    for (const FsParam &p : e.params) {
      scalar::ScalarExternDesc::Param pd;
      switch (p.kind) {
      case FsParam::Kind::Buffer:
        pd.kind = scalar::ScalarExternDesc::Param::Kind::Buffer;
        pd.elem = p.type;
        pd.dir = p.direction;
        pd.lenIndex = p.lenIndex;
        break;
      case FsParam::Kind::Len:
        pd.kind = scalar::ScalarExternDesc::Param::Kind::Len;
        break;
      case FsParam::Kind::Scalar:
        pd.kind = scalar::ScalarExternDesc::Param::Kind::Scalar;
        pd.elem = p.type;
        break;
      }
      ed.params.push_back(std::move(pd));
    }
    kFsOptions.externs.push_back(std::move(ed));
  }

  // D2 compares declared returns: width with inferred result kind. A declared f32 with inferred
  // int, the reverse, or poly contradicts the body and is refused with frozen wording. Only stage 2
  // can check: stage 1 has no driver, so every uncalled kernel result is unknown and would fail.
  auto checkReturnKind = [&](const contract::ContractModule &m) {
    for (const FsDecl &d : scalarDecls) {
      const contract::Method *cm = nullptr;
      for (const contract::Method &cand : m.methods())
        if (cand.name == d.name)
          cm = &cand;
      if (!cm || cm->returnType == "unknown")
        continue;
      const bool declFloat = d.returns == "f32" || d.returns == "f64";
      const bool ok = declFloat ? cm->returnType == "float"
                                : cm->returnType == "int";
      if (ok)
        continue;
      diag({Stage::D2, Category::AbiWidthMismatch, d.name, 0,
            ("freestanding_def :" + d.name + " (line " + Twine(d.line) +
             "): `returns: :" + d.returns +
             "` but whole-program inference says `" + d.name + "` returns `" +
             cm->returnType +
             "`. The declaration fixes the boundary WIDTH; it does not change "
             "what the body computes (E077)").str()});
      return false;
    }
    return true;
  };

  bool scalarBad = false;
  if (!checkReturnKind(*stage2))
    return finish(EmitStatus::InputRejected);
  auto scalarDiag = [&](llvm::StringRef line) {
    if (scalarBad) return;
    scalarBad = true;
    // Append tier notes for scalar refusals too, matching frozen DIE_CONTEXT regardless of die
    // wording. Remove native-only scalar:<line>: <category>: prefixes only on freestanding output.
    // Leave ModuleGen::reject unchanged to preserve hosted diagnostics.
    llvm::StringRef body = line;
    llvm::StringRef suffix;
    if (body.consume_front("scalar:")) {
      body = body.drop_until([](char ch) { return ch == ':'; });
      if (body.consume_front(": ")) {
        // Strip exactly one <category>: prefix, retaining colons in detail. duplicate-method detail
        // is only a name, so move that category after it; preserve the generator prefix.
        const size_t sep = body.find(": ");
        if (sep != llvm::StringRef::npos &&
            body.take_front(sep).find(' ') == llvm::StringRef::npos) {
          if (body.take_front(sep) == "duplicate-method")
            suffix = " (duplicate-method: defined more than once at the top level)";
          body = body.drop_front(sep + 2);
        }
      }
    } else {
      body = line;
    }
    note << "spinel-mlirgen: unsupported: " << body << suffix << tierNote << "\n";
  };

  // Compare closures root by root in declaration order, remembering each helper first reaching root
  // policy. Refuse when a differently configured root reaches the same helper. This also fixes
  // diagnostic a/b ordering to root declaration order, matching recorded frozen behavior.
  {
    llvm::StringMap<std::pair<std::string, std::string>> owner; // helper -> (policy, root)
    for (const FsDecl &d : scalarDecls) {
      std::vector<std::string> one{d.name};
      auto reach = scalar::selectScalarProgram(*stage2, one, scalarDiag, kFsOptions);
      if (!reach)
        return finish(EmitStatus::InputRejected);
      for (const scalar::ScalarMethod &m : reach->methods()) {
        auto it = owner.find(m.name());
        if (it == owner.end()) {
          owner[m.name()] = {d.overflow, d.name};
          continue;
        }
        if (it->second.first == d.overflow)
          continue;
        // Use frozen Generator.want wording verbatim.
        diag({Stage::D2, Category::OverflowPolicyConflict, m.name().str(), 0,
              ("method '" + m.name() + "' is reachable from both an "
               "--int-overflow=" + it->second.first + " and an --int-overflow=" +
               d.overflow + " boundary; one function cannot have two overflow "
               "policies. Split them into separate modules, or give both "
               "declarations the same `overflow:`.").str()});
        return finish(EmitStatus::InputRejected);
      }
    }
  }

  // Import once per policy group. Keep scalar public API unchanged: it takes one policy per call,
  // so split invocation units instead.
  llvm::SmallVector<std::string> policies;
  for (const FsDecl &d : scalarDecls)
    if (!llvm::is_contained(policies, d.overflow))
      policies.push_back(d.overflow);

  for (llvm::StringRef policy : policies) {
    std::vector<std::string> entries;
    for (const FsDecl &d : scalarDecls)
      if (d.overflow == policy)
        entries.push_back(d.name);
    auto program = scalar::selectScalarProgram(*stage2, entries, scalarDiag, kFsOptions);
    if (!program)
      return finish(EmitStatus::InputRejected);

    // trap uses checked operations to call the hook. wrap keeps plain arithmetic but still guards
    // zero divisors whenever a hook exists, since divGuard branches on hook presence first.
    const bool isTrap = policy == "trap";
    auto mode = isTrap  ? scalar::OverflowMode::Trap
                : policy == "wrap" ? scalar::OverflowMode::Wrap
                                   : scalar::OverflowMode::None;
    auto part = scalar::importScalarProgram(*stage2, *program, context, mode,
                                            scalarDiag, /*emitChecked=*/isTrap,
                                            profile->trapHook(), kFsOptions);
    if (!part)
      return finish(EmitStatus::InputRejected);
    if (!imported)
      imported = std::move(part);
    else
      mergeModules(*imported, *part);
  }
  }

  if (mlir::failed(mlir::verify(*imported))) {
    note << "spinel-fs-emit: internal-verify-failure: imported module\n";
    return finish(EmitStatus::Infrastructure);
  }
  // Validate export names before wrappers: otherwise LLVM/MLIR may silently rename or issue
  // unstructured redefinition errors.
  if (!checkExportSymbols(*imported, *profile, *decls, diag))
    return finish(EmitStatus::InputRejected);
  if (!addBoundaryWrappers(*imported, *profile, *decls, dataLayout, diag))
    return finish(EmitStatus::InputRejected);
  if (mlir::failed(mlir::verify(*imported))) {
    note << "spinel-fs-emit: internal-verify-failure: wrapped module\n";
    return finish(EmitStatus::Infrastructure);
  }

  // Remove the old default-route eligibility rules: once admission covered freestanding, no
  // separate predicate was needed for wrapper defaults. Acceptance alone decides. No InputRejected
  // occurs beyond this point because checkExportSymbols owns C-spelling checks, closing
  // successful-probe/later-refusal gaps.
  if (req.probe)
    return finish(EmitStatus::Probed);

  // Write headers for every artifact kind when requested, matching frozen if args.emit_header.
  auto writeHeader = [&]() -> std::optional<EmitStatus> {
    // Do not write a header without --emit-header. An empty path means no output; guard it here
    // rather than trying to open an empty filename in CWD.
    if (req.headerPath.empty())
      return std::nullopt;
    std::error_code ec;
    llvm::raw_fd_ostream os(req.headerPath, ec);
    if (ec) {
      note << "spinel-fs-emit: header-write-failed\n";
      return EmitStatus::Infrastructure;
    }
    wrote(req.headerPath);
    if (!writeBoundaryHeader(os, llvm::sys::path::filename(req.sourcePath),
                             llvm::sys::path::filename(req.profilePath),
                             *profile, *decls, diag))
      return EmitStatus::InputRejected;
    return std::nullopt;
  };

  // Write debug-location MLIR only when requested. Locations come from module source identity,
  // making this its observation surface.
  if (!req.mlirPath.empty()) {
    std::error_code ec;
    llvm::raw_fd_ostream os(req.mlirPath, ec);
    if (ec) {
      note << "spinel-fs-emit: mlir-write-failed: " << ec.message() << "\n";
      return finish(EmitStatus::Infrastructure);
    }
    wrote(req.mlirPath);
    imported->print(os, mlir::OpPrintingFlags().enableDebugInfo());
    os << "\n";
  }

  // The library defines pass pipelines, not CLI mlir-opt command reconstruction.
  mlir::PassManager pm(&context);
  // Expand spinel.checked_* into profile-hook calls before standard lowering. Only
  // freestanding-hook applies, with the profile owning its name; modules without trap match no
  // patterns. Share buildLoweringPipeline with hosted, differing only in target/hook. For .mlir,
  // expand checks then print before the four func/arith/cf-to-LLVM passes, matching the frozen
  // output stage.
  if (req.emitKind == EmitRequest::EmitKind::Mlir)
    scalar::buildCheckedArithStage(
        pm, mlir::spinel::CheckedArithmeticTarget::FreestandingHook,
        profile->trapHook());
  else
    scalar::buildLoweringPipeline(
        pm, mlir::spinel::CheckedArithmeticTarget::FreestandingHook,
        profile->trapHook());
  if (mlir::failed(pm.run(*imported))) {
    note << "spinel-fs-emit: lowering-failed\n";
    return finish(EmitStatus::Infrastructure);
  }

  // For product -o .mlir, write and return without clang or undefined-symbol checking. Omit debug
  // locations; separate --emit-mlir writes pre-lowering locations for identity inspection. Output
  // moved after checked-op expansion because the earlier raw module retained spinel.checked_*
  // (sixty-four ops in three compared modules). It must remain before the four passes, not
  // immediately before LLVM translation, so func/cf survive as in frozen .mlir.
  if (req.emitKind == EmitRequest::EmitKind::Mlir) {
    std::error_code ec;
    llvm::raw_fd_ostream os(req.objPath, ec);
    if (ec) {
      note << "spinel-fs-emit: mlir-write-failed: " << ec.message() << "\n";
      return finish(EmitStatus::Infrastructure);
    }
    wrote(req.objPath);
    imported->print(os, mlir::OpPrintingFlags());
    os << "\n";
    os.close();
    if (auto bad = writeHeader())
      return finish(*bad);
    return finish(EmitStatus::Emitted);
  }
  mlir::registerBuiltinDialectTranslation(context);
  mlir::registerLLVMDialectTranslation(context);
  llvm::LLVMContext ownContext;
  llvm::LLVMContext &llvmContext =
      externalContext ? *externalContext : ownContext;
  auto llvmModule = mlir::translateModuleToLLVMIR(*imported, llvmContext);
  if (!llvmModule) {
    note << "spinel-fs-emit: translate-failed\n";
    return finish(EmitStatus::Infrastructure);
  }
  llvmModule->setTargetTriple(llvm::Triple(profile->triple()));
  llvmModule->setDataLayout(dataLayout);
  // Every definition is nounwind in the LLVM IR itself. The `passthrough`
  // attribute set on each func.func above does not survive translation under
  // LLVM 23, so nothing stated it; LLVM 22 hid that by inferring the attribute.
  // Without it an ARM EABI object references __aeabi_unwind_cpp_pr0 and the
  // undef gate refuses it. Same repair as the CORE kernel's noUnwind (0014).
  for (llvm::Function &fn : llvmModule->functions())
    if (!fn.isDeclaration())
      fn.addFnAttr(llvm::Attribute::NoUnwind);
  // Return here for captured Modules. Grad owns subsequent .ll/object/header/gate steps and their
  // wording.
  if (capture) {
    *capture = std::move(llvmModule);
    return finish(EmitStatus::Emitted);
  }
  // For Ll, -o is the actual IR destination; direct invocation separately accepts --emit-llvm and
  // retains llPath.
  const std::string llTarget =
      req.emitKind == EmitRequest::EmitKind::Ll ? req.objPath : req.llPath;
  {
    std::error_code ec;
    llvm::raw_fd_ostream os(llTarget, ec);
    if (ec) { note << "spinel-fs-emit: ll-write-failed\n"; return finish(EmitStatus::Infrastructure); }
    wrote(llTarget);
    llvmModule->print(os, nullptr);
  }
  if (req.emitKind == EmitRequest::EmitKind::Ll) {
    if (auto bad = writeHeader())
      return finish(*bad);
    return finish(EmitStatus::Emitted);
  }
  if (auto bad = writeHeader())
    return finish(*bad);

  // The object, from the .ll just written, by spinel-fs-codegen: the flags
  // clang was given (-O2 -ffreestanding -fno-builtin, then the profile's
  // cflags, so the last -O wins) mean what its table says.
  std::string ccErr = tempPath("codegen.err");
  if (runCodegen(codegenArgv({req.llPath, "-o", req.objPath}), "", ccErr) != 0) {
    note << "spinel-fs-emit: compile-failed\n";
    if (auto eb = llvm::MemoryBuffer::getFile(ccErr)) note << (*eb)->getBuffer();
    return finish(EmitStatus::Infrastructure);
  }
  wrote(req.objPath);
  // Independently query again after generation to check the two managed copies agree.
  auto again = askLayout("dl1");
  if (!again) return finish(EmitStatus::Infrastructure);
  if (*again != dataLayout) {
    note << "spinel-fs-emit: data-layout-mismatch: module says \"" << dataLayout
         << "\" but spinel-fs-codegen assumes \"" << *again << "\"\n";
    return finish(EmitStatus::Infrastructure);
  }

  // Stage G inspects the completed object for symbols outside profile policy, reading in process
  // without Python or subprocesses.
  if (!req.noUndefCheck) {
    std::vector<UndefRow> rows;
    std::string gateInfra;
    const bool clean = runUndefGate(req.objPath, *profile, rows, &gateInfra);
    if (!gateInfra.empty()) {
      note << "spinel-fs-emit: undef-gate: " << gateInfra << "\n";
      return finish(EmitStatus::Infrastructure);
    }
    if (!clean) {
      // Report every DENY row, as frozen Python prints the entire table before dying. Use note
      // rather than first-error diag: the object symbol list itself explains the failure, rather
      // than attributing it to one point.
      for (const UndefRow &r : rows) {
        if (r.verdict != "DENY")
          continue;
        Rejection rej;
        rej.stage = Stage::G;
        rej.category = Category::UndefAllowlistViolation;
        rej.subject = r.symbol;
        rej.detail = r.reason;
        // Keep stage-G formatter spelling here. The diagnostic alignment changed declaration/scalar
        // rejection tables only; spinel-fs:G: undef-allowlist-violation: is a separately pinned
        // observation surface and retains the shared formatter.
        note << formatRejection(rej) << "\n";
      }
      // Do not write TSV on DENY: frozen gate failure precedes TSV output. Preserve the object, as
      // frozen Python does.
      return finish(EmitStatus::InputRejected);
    }
    if (!req.undefTsvPath.empty()) {
      std::error_code ec;
      llvm::raw_fd_ostream os(req.undefTsvPath, ec);
      if (ec) {
        note << "spinel-fs-emit: undef-tsv-write-failed: " << ec.message() << "\n";
        return finish(EmitStatus::Infrastructure);
      }
      wrote(req.undefTsvPath);
      os << formatUndefTsv(rows);
    }
  }
  return finish(EmitStatus::Emitted);
}

} // namespace

EmitStatus compileFreestanding(const EmitRequest &req, RunToolFn runTool,
                               TempPathFn tempPath, FsDiagnosticFn diagOut,
                               llvm::raw_ostream &noteOut) {
  return compileCore(req, runTool, tempPath, diagOut, noteOut, nullptr,
                     nullptr);
}

std::unique_ptr<llvm::Module>
emitFreestandingModule(const EmitRequest &req, llvm::LLVMContext &context,
                       RunToolFn runTool, TempPathFn tempPath,
                       FsDiagnosticFn diag, llvm::raw_ostream &note,
                       EmitStatus &status) {
  std::unique_ptr<llvm::Module> module;
  status = compileCore(req, runTool, tempPath, diag, note, &context, &module);
  if (status != EmitStatus::Emitted)
    return nullptr;
  return module;
}

} // namespace spinel_mlir::freestanding
