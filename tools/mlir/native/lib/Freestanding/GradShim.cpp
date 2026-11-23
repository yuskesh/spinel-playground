// Generate the frozen emit_shim functions, argument order and calls directly in IR; emit no C
// source.
#include "spinel-mlir/Freestanding/GradShim.h"

#include "llvm/IR/Constants.h"
#include "llvm/IR/DerivedTypes.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/GlobalVariable.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/Type.h"

using namespace llvm;

namespace spinel_mlir::freestanding {
namespace {

// Boundary type to LLVM type, one-to-one with frozen ctype(): :len is int32_t, buffers pointers,
// scalars width-specific integers/floats.
Type *boundaryType(LLVMContext &ctx, const FsParam &p) {
  switch (p.kind) {
  case FsParam::Kind::Len:
    return Type::getInt32Ty(ctx);
  case FsParam::Kind::Buffer:
    return PointerType::get(ctx, 0);
  case FsParam::Kind::Scalar:
    break;
  }
  StringRef t(p.type);
  if (t == "f32")
    return Type::getFloatTy(ctx);
  if (t == "f64")
    return Type::getDoubleTy(ctx);
  if (t == "i8" || t == "u8")
    return Type::getInt8Ty(ctx);
  if (t == "i16" || t == "u16")
    return Type::getInt16Ty(ctx);
  if (t == "i32" || t == "u32")
    return Type::getInt32Ty(ctx);
  if (t == "i64" || t == "u64")
    return Type::getInt64Ty(ctx);
  return nullptr;
}

// Boundary symbol: export: or default spinel_<name>, matching frozen FsDecl.sym.
std::string boundarySymbol(const FsDecl &d) {
  return d.exportSymbol.empty() ? ("spinel_" + d.name) : d.exportSymbol;
}

bool isUnsigned(const FsParam &p) {
  return p.kind == FsParam::Kind::Scalar && !p.type.empty() && p.type[0] == 'u';
}

// Apply C variadic promotions explicitly: float to double, char/short to int. Frozen C compilation
// performed these automatically; direct IR must do so to preserve the call.
Value *promoteForVarargs(IRBuilder<> &b, Value *v, const FsParam &p) {
  Type *ty = v->getType();
  if (ty->isFloatTy())
    return b.CreateFPExt(v, Type::getDoubleTy(ty->getContext()));
  if (ty->isIntegerTy() && ty->getIntegerBitWidth() < 32)
    return isUnsigned(p) ? b.CreateZExt(v, Type::getInt32Ty(ty->getContext()))
                         : b.CreateSExt(v, Type::getInt32Ty(ty->getContext()));
  return v;
}

/// `for (int32_t i = 0; i < n; i++) base[i] = 0.0;`
void zeroLoop(IRBuilder<> &b, Function *f, Value *base, Value *n,
              const Twine &tag) {
  LLVMContext &ctx = f->getContext();
  Type *i32 = Type::getInt32Ty(ctx);
  Type *dbl = Type::getDoubleTy(ctx);
  BasicBlock *cond = BasicBlock::Create(ctx, tag + ".cond", f);
  BasicBlock *body = BasicBlock::Create(ctx, tag + ".body", f);
  BasicBlock *done = BasicBlock::Create(ctx, tag + ".done", f);
  BasicBlock *entry = b.GetInsertBlock();
  b.CreateBr(cond);
  b.SetInsertPoint(cond);
  PHINode *i = b.CreatePHI(i32, 2, tag + ".i");
  i->addIncoming(ConstantInt::get(i32, 0), entry);
  b.CreateCondBr(b.CreateICmpSLT(i, n), body, done);
  b.SetInsertPoint(body);
  b.CreateStore(ConstantFP::get(dbl, 0.0), b.CreateGEP(dbl, base, {i}));
  Value *next = b.CreateAdd(i, ConstantInt::get(i32, 1));
  i->addIncoming(next, body);
  b.CreateBr(cond);
  b.SetInsertPoint(done);
}

// Generated functions cannot throw. Without nounwind, personality/unwind symbols enter the object
// and libc:none profiles refuse them at G, as previously observed.
void markShim(Function *f, const ShimCodegenAttrs &attrs) {
  f->addFnAttr(Attribute::NoUnwind);
  // no-builtins is essential: later profile-optimization codegen can turn shadow zero loops into
  // memset and __aeabi_memclr8, refused by libc:none. Frozen -ffreestanding -fno-builtin produced
  // this attribute; direct IR must set it (observed DENY without it on Cortex-M33).
  f->addFnAttr("no-builtins");
  if (attrs.minSize)
    f->addFnAttr(Attribute::MinSize);
  if (attrs.optSize || attrs.minSize)
    f->addFnAttr(Attribute::OptimizeForSize);
  if (!attrs.cpu.empty())
    f->addFnAttr("target-cpu", attrs.cpu);
  if (!attrs.features.empty())
    f->addFnAttr("target-features", attrs.features);
  f->setDSOLocal(false);
}

} // namespace

int lenGoverning(ArrayRef<FsParam> params, size_t idx) {
  for (size_t j = idx; j < params.size(); ++j) {
    if (params[j].kind == FsParam::Kind::Len)
      return static_cast<int>(j);
    if (params[j].kind != FsParam::Kind::Buffer)
      return -1;
  }
  return -1;
}

ShimCodegenAttrs shimAttrsFromCflags(ArrayRef<std::string> cflags) {
  ShimCodegenAttrs a;
  for (const std::string &f : cflags) {
    StringRef s(f);
    if (s == "-Os")
      a.optSize = true;
    else if (s == "-Oz")
      a.minSize = true;
    else if (s.consume_front("-mcpu="))
      // In -mcpu=cortex-m33+nodsp, +nodsp is a feature; target-cpu remains cortex-m33, as clang
      // separates it.
      a.cpu = s.take_until([](char c) { return c == '+' || c == '-'; }).str();
    else if (s.consume_front("-march=") && a.cpu.empty())
      a.cpu = s.take_until([](char c) { return c == '+' || c == '-'; }).str();
  }
  return a;
}

bool buildEnzymeShim(Module &m, ArrayRef<GradTarget> targets,
                     const ShimCodegenAttrs &attrs, std::string &error) {
  LLVMContext &ctx = m.getContext();
  Type *i32 = Type::getInt32Ty(ctx);
  Type *dbl = Type::getDoubleTy(ctx);
  Type *ptr = PointerType::get(ctx, 0);

  bool anyHvp = false;
  for (const GradTarget &t : targets)
    anyHvp |= t.grad->hvp;

  // `extern double __enzyme_autodiff(void *, ...);`
  FunctionType *adTy = FunctionType::get(dbl, {ptr}, /*isVarArg=*/true);
  FunctionCallee autodiff = m.getOrInsertFunction("__enzyme_autodiff", adTy);
  FunctionCallee fwddiff;
  if (anyHvp)
    fwddiff = m.getOrInsertFunction("__enzyme_fwddiff", adTy);
  // `extern int enzyme_const; extern int enzyme_dup;`
  auto extInt = [&](StringRef name) -> GlobalVariable * {
    if (auto *g = m.getGlobalVariable(name))
      return g;
    return new GlobalVariable(m, i32, /*isConstant=*/false,
                              GlobalValue::ExternalLinkage, nullptr, name);
  };
  GlobalVariable *enzymeConst = extInt("enzyme_const");
  GlobalVariable *enzymeDup = extInt("enzyme_dup");

  for (const GradTarget &t : targets) {
    const FsGradDecl &g = *t.grad;
    const FsDecl &fs = *t.fs;
    // Original function declaration.
    std::vector<Type *> primTypes;
    for (const FsParam &p : fs.params) {
      Type *ty = boundaryType(ctx, p);
      if (!ty) {
        error = "internal: unknown boundary type :" + p.type + " of " + g.name;
        return false;
      }
      primTypes.push_back(ty);
    }
    FunctionType *primTy = FunctionType::get(dbl, primTypes, false);
    FunctionCallee prim = m.getOrInsertFunction(boundarySymbol(fs), primTy);

    // Gradient function preserves boundary order, inserting one shadow immediately after each
    // active buffer.
    std::vector<Type *> gradTypes;
    std::vector<std::string> gradNames;
    for (size_t i = 0; i < fs.params.size(); ++i) {
      gradTypes.push_back(primTypes[i]);
      gradNames.push_back(t.pnames[i]);
      if (llvm::is_contained(g.wrt, t.pnames[i])) {
        gradTypes.push_back(ptr);
        gradNames.push_back("d_" + t.pnames[i]);
      }
    }
    FunctionType *gradTy = FunctionType::get(dbl, gradTypes, false);
    Function *gradFn = Function::Create(gradTy, GlobalValue::ExternalLinkage,
                                        g.sym(), &m);
    markShim(gradFn, attrs);
    for (size_t i = 0; i < gradNames.size(); ++i)
      gradFn->getArg(i)->setName(gradNames[i]);
    auto argOf = [&](StringRef name) -> Argument * {
      for (Argument &a : gradFn->args())
        if (a.getName() == name)
          return &a;
      return nullptr;
    };

    IRBuilder<> b(BasicBlock::Create(ctx, "entry", gradFn));
    // Zero the shadow under the ASSIGN contract.
    for (const std::string &w : g.wrt) {
      auto it = llvm::find(t.pnames, w);
      size_t idx = std::distance(t.pnames.begin(), it);
      int li = lenGoverning(fs.params, idx);
      if (li < 0) {
        error = "internal: no :len governs buffer " + w + " of " + g.name;
        return false;
      }
      zeroLoop(b, gradFn, argOf("d_" + w), argOf(t.pnames[li]), "zero." + w);
    }
    // `double _v = prim(...);`
    std::vector<Value *> callArgs;
    for (const std::string &n : t.pnames)
      callArgs.push_back(argOf(n));
    Value *v = b.CreateCall(prim, callArgs, "_v");
    cast<CallInst>(v)->setDoesNotThrow();
    // `__enzyme_autodiff((void *)prim, …);`
    std::vector<Value *> adArgs{prim.getCallee()};
    for (size_t i = 0; i < fs.params.size(); ++i) {
      const std::string &n = t.pnames[i];
      bool active = llvm::is_contained(g.wrt, n);
      adArgs.push_back(b.CreateLoad(i32, active ? enzymeDup : enzymeConst));
      adArgs.push_back(promoteForVarargs(b, argOf(n), fs.params[i]));
      if (active)
        adArgs.push_back(argOf("d_" + n));
    }
    cast<CallInst>(b.CreateCall(autodiff, adArgs))->setDoesNotThrow();
    b.CreateRet(v);

    if (!g.hvp)
      continue;

    // Hessian-vector product: forward-over-reverse.
    const std::string &w = g.wrt.front();
    std::vector<Type *> hvpTypes;
    std::vector<std::string> hvpNames;
    for (size_t i = 0; i < fs.params.size(); ++i) {
      hvpTypes.push_back(primTypes[i]);
      hvpNames.push_back(t.pnames[i]);
      if (t.pnames[i] == w) {
        for (const char *pfx : {"dir_", "g_", "hv_"}) {
          hvpTypes.push_back(ptr);
          hvpNames.push_back(pfx + w);
        }
      }
    }
    FunctionType *hvpTy = FunctionType::get(dbl, hvpTypes, false);
    Function *hvpFn = Function::Create(hvpTy, GlobalValue::ExternalLinkage,
                                       g.hvpSym(), &m);
    markShim(hvpFn, attrs);
    for (size_t i = 0; i < hvpNames.size(); ++i)
      hvpFn->getArg(i)->setName(hvpNames[i]);
    auto hArg = [&](StringRef name) -> Argument * {
      for (Argument &a : hvpFn->args())
        if (a.getName() == name)
          return &a;
      return nullptr;
    };
    IRBuilder<> hb(BasicBlock::Create(ctx, "entry", hvpFn));
    auto wIt = llvm::find(t.pnames, w);
    size_t wIdx = std::distance(t.pnames.begin(), wIt);
    int wLen = lenGoverning(fs.params, wIdx);
    Value *wn = hArg(t.pnames[wLen]);
    zeroLoop(hb, hvpFn, hArg("g_" + w), wn, "zero.g");
    zeroLoop(hb, hvpFn, hArg("hv_" + w), wn, "zero.hv");
    // Pass inactive buffers as enzyme_dup with zero shadows. The C path used variable-length
    // arrays; IR uses dynamic alloca.
    std::vector<std::pair<std::string, Value *>> zeros;
    for (size_t i = 0; i < fs.params.size(); ++i) {
      if (fs.params[i].kind != FsParam::Kind::Buffer || t.pnames[i] == w)
        continue;
      int li = lenGoverning(fs.params, i);
      if (li < 0) {
        error = "internal: no :len governs buffer " + t.pnames[i] + " of " +
                g.name;
        return false;
      }
      Value *n = hArg(t.pnames[li]);
      // `double z_n[n > 0 ? n : 1];`
      Value *sz = hb.CreateSelect(
          hb.CreateICmpSGT(n, ConstantInt::get(i32, 0)), n,
          ConstantInt::get(i32, 1));
      Value *z = hb.CreateAlloca(dbl, sz, "z_" + t.pnames[i]);
      zeroLoop(hb, hvpFn, z, n, "zero.z." + t.pnames[i]);
      zeros.emplace_back(t.pnames[i], z);
    }
    std::vector<Value *> fwArgs{gradFn};
    for (size_t i = 0; i < fs.params.size(); ++i) {
      const std::string &n = t.pnames[i];
      if (n == w) {
        fwArgs.push_back(hb.CreateLoad(i32, enzymeDup));
        fwArgs.push_back(hArg(n));
        fwArgs.push_back(hArg("dir_" + n));
        fwArgs.push_back(hb.CreateLoad(i32, enzymeDup));
        fwArgs.push_back(hArg("g_" + n));
        fwArgs.push_back(hArg("hv_" + n));
        continue;
      }
      if (fs.params[i].kind == FsParam::Kind::Buffer) {
        Value *z = nullptr;
        for (auto &kv : zeros)
          if (kv.first == n)
            z = kv.second;
        fwArgs.push_back(hb.CreateLoad(i32, enzymeDup));
        fwArgs.push_back(hArg(n));
        fwArgs.push_back(z);
        continue;
      }
      fwArgs.push_back(hb.CreateLoad(i32, enzymeConst));
      fwArgs.push_back(promoteForVarargs(hb, hArg(n), fs.params[i]));
    }
    Value *hv = hb.CreateCall(fwddiff, fwArgs);
    cast<CallInst>(hv)->setDoesNotThrow();
    hb.CreateRet(hv);
  }
  return true;
}

} // namespace spinel_mlir::freestanding
