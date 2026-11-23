// Emit BPF ELF with BTF.
#include "spinel-mlir/Target/SpBPF/ObjectEmitter.h"

#include "mlir/Target/LLVMIR/Dialect/All.h"
#include "mlir/Target/LLVMIR/Export.h"

#include "llvm/IR/DIBuilder.h"
#include "llvm/IR/DebugInfoMetadata.h"
#include "llvm/IR/GlobalVariable.h"
#include "llvm/IR/LLVMContext.h"
#include "llvm/IR/LegacyPassManager.h"
#include "llvm/IR/Module.h"
#include "llvm/MC/TargetRegistry.h"
#include "llvm/Support/CodeGen.h"
#include "llvm/Support/TargetSelect.h"
#include "llvm/Target/TargetMachine.h"
#include "llvm/Target/TargetOptions.h"

#include <map>

using namespace llvm;

namespace spbpf {
namespace {

// Linux bpf_map_type numeric ids live only here, as helper ids live only in the lowering target
// profile.
unsigned mapTypeNumber(MapKind k) {
  switch (k) {
  case MapKind::Hash:
    return 1; // BPF_MAP_TYPE_HASH
  case MapKind::Array:
    return 2; // BPF_MAP_TYPE_ARRAY
  case MapKind::RingBuf:
    return 27; // BPF_MAP_TYPE_RINGBUF
  case MapKind::PerCpuArray:
    return 6; // BPF_MAP_TYPE_PERCPU_ARRAY
  }
  return 0;
}

struct Emitter {
  Module &m;
  const Schema &schema;
  Diagnostics &diags;
  DIBuilder db;
  DIFile *file;
  DICompileUnit *cu;
  DIBasicType *intTy; // Plain int inside __uint(...).
  std::map<std::string, DIType *> recordTypes;

  Emitter(Module &mod, const Schema &s, Diagnostics &d)
      : m(mod), schema(s), diags(d), db(mod) {
    file = db.createFile("spbpf-schema", ".");
    cu = db.createCompileUnit(dwarf::DW_LANG_C99, file, "spbpf",
                              /*isOptimized=*/true, "", 0);
    intTy = db.createBasicType("int", 32, dwarf::DW_ATE_signed);
  }

  // Qualify Type: the unqualified name in this namespace means spbpf::Type.
  llvm::Type *ptrTy() { return PointerType::get(m.getContext(), 0); }

  // Schema to DWARF types, carrying signedness into BTF even though earlier type matching checked
  // width only.
  DIType *diTypeOf(const spbpf::Type &t) {
    if (const auto *i = std::get_if<IntType>(&t.v)) {
      // BTF cannot represent endianness here. bpfel validation enforces little endian; emitObject
      // refuses other declarations.
      std::string name = (i->isSigned ? "s" : "u") + std::to_string(i->bits);
      return db.createBasicType(name, i->bits,
                                i->isSigned ? dwarf::DW_ATE_signed
                                            : dwarf::DW_ATE_unsigned);
    }
    if (const auto *a = std::get_if<ArrayType>(&t.v)) {
      DIType *elem = diTypeOf(*a->element);
      auto sz = schema.sizeOf(t);
      uint64_t bits = sz ? *sz * 8 : 0;
      if (!sz)
        consumeError(sz.takeError());
      SmallVector<Metadata *, 1> subs{db.getOrCreateSubrange(0, a->count)};
      return db.createArrayType(bits, /*align=*/0, elem,
                                db.getOrCreateArray(subs));
    }
    const auto &r = std::get<RecordRefType>(t.v);
    auto it = recordTypes.find(r.symbol);
    if (it != recordTypes.end())
      return it->second;
    diags.error("record_ref \"" + r.symbol + "\" has no DWARF type");
    return intTy;
  }

  // Build records as DWARF structs in two passes to resolve references.
  void buildRecordTypes() {
    // First pass installs forward declarations for record_ref resolution.
    for (const Record &r : schema.records())
      recordTypes[r.symbol] = db.createReplaceableCompositeType(
          dwarf::DW_TAG_structure_type, r.symbol, cu, file, 0);
    // Second pass: definitions.
    for (const Record &r : schema.records()) {
      SmallVector<Metadata *, 8> members;
      for (const Field &f : r.fields) {
        DIType *ft = diTypeOf(f.type);
        auto sz = schema.sizeOf(f.type);
        uint64_t bits = sz ? *sz * 8 : 0;
        if (!sz)
          consumeError(sz.takeError());
        members.push_back(db.createMemberType(
            cu, f.name, file, 0, bits, /*align=*/0, f.offset * 8,
            DINode::FlagZero, ft));
      }
      auto *body = db.createStructType(cu, r.symbol, file, 0, r.size * 8,
                                       r.alignment * 8, DINode::FlagZero,
                                       nullptr, db.getOrCreateArray(members));
      auto *fwd = cast<DICompositeType>(recordTypes[r.symbol]);
      db.replaceTemporary(TempDIType(fwd), body);
      recordTypes[r.symbol] = body;
    }
  }

  // __uint(name,N) spelling: int (*name)[N].
  DIType *uintMember(StringRef name, uint64_t value, unsigned offsetBits) {
    SmallVector<Metadata *, 1> subs{
        db.getOrCreateSubrange(0, static_cast<int64_t>(value ? value : 1))};
    DIType *arr = db.createArrayType(32 * (value ? value : 1), 0, intTy,
                                     db.getOrCreateArray(subs));
    DIType *p = db.createPointerType(arr, 64);
    return db.createMemberType(cu, name, file, 0, 64, 0, offsetBits,
                               DINode::FlagZero, p);
  }

  // __type(name,T) spelling: T *name.
  DIType *typeMember(StringRef name, const spbpf::Type &t,
                     unsigned offsetBits) {
    DIType *p = db.createPointerType(diTypeOf(t), 64);
    return db.createMemberType(cu, name, file, 0, 64, 0, offsetBits,
                               DINode::FlagZero, p);
  }

  // Replace lowering placeholders with actual BTF-backed definitions.
  void emitMaps() {
    for (const Map &mp : schema.maps()) {
      GlobalVariable *old = m.getGlobalVariable(mp.symbol, true);
      if (!old)
        continue; // Omit maps unused by this program.

      SmallVector<Metadata *, 4> members;
      members.push_back(uintMember("type", mapTypeNumber(mp.kind), 0));
      members.push_back(uintMember("max_entries", mp.maxEntries, 64));
      unsigned n = 2;
      if (mp.key) {
        members.push_back(typeMember("key", *mp.key, 128));
        ++n;
      }
      if (mp.value) {
        members.push_back(typeMember("value", *mp.value, 192));
        ++n;
      }
      auto *ty = db.createStructType(cu, "", file, 0, n * 64, 64,
                                     DINode::FlagZero, nullptr,
                                     db.getOrCreateArray(members));

      SmallVector<llvm::Type *, 4> fields(n, ptrTy());
      auto *st = StructType::get(m.getContext(), fields);
      auto *g = new GlobalVariable(m, st, /*isConstant=*/false,
                                   GlobalValue::ExternalLinkage,
                                   ConstantAggregateZero::get(st),
                                   mp.symbol + ".spbpf");
      g->setSection(kMapsSection);
      g->setAlignment(Align(8));
      g->setDSOLocal(true);

      auto *gv = db.createGlobalVariableExpression(
          cu, mp.symbol, mp.symbol, file, 0, ty, /*IsLocalToUnit=*/false);
      g->addDebugInfo(gv);

      old->replaceAllUsesWith(ConstantExpr::getBitCast(g, old->getType()));
      old->eraseFromParent();
      g->setName(mp.symbol); // Stable symbol: use the schema symbol directly.
    }
  }

  // Retain record types in BTF with const struct X *__spbpf_record_X witnesses in a dedicated
  // section. Do not modify .text/program instructions.
  void emitRecordWitnesses() {
    for (const Record &r : schema.records()) {
      DIType *rec = recordTypes[r.symbol];
      DIType *constRec = db.createQualifiedType(dwarf::DW_TAG_const_type, rec);
      DIType *p = db.createPointerType(constRec, 64);

      std::string name = ("__spbpf_record_" + r.symbol);
      auto *g = new GlobalVariable(
          m, ptrTy(), /*isConstant=*/true, GlobalValue::ExternalLinkage,
          ConstantPointerNull::get(cast<PointerType>(ptrTy())), Twine(name));
      g->setSection(kRecordsSection);
      g->setAlignment(Align(8));
      g->setDSOLocal(true);
      auto *gv = db.createGlobalVariableExpression(cu, name, name, file, 0, p,
                                                   false);
      g->addDebugInfo(gv);
    }
  }

  void emitLicense(StringRef license) {
    auto *data = ConstantDataArray::getString(m.getContext(), license, true);
    auto *g = new GlobalVariable(m, data->getType(), false,
                                 GlobalValue::ExternalLinkage, data,
                                 "_license");
    g->setSection(kLicenseSection);
    g->setAlignment(Align(1));
    g->setDSOLocal(true);
    SmallVector<Metadata *, 1> subs{
        db.getOrCreateSubrange(0, (int64_t)license.size() + 1)};
    DIType *charTy =
        db.createBasicType("char", 8, dwarf::DW_ATE_signed_char);
    DIType *arr = db.createArrayType((license.size() + 1) * 8, 0, charTy,
                                     db.getOrCreateArray(subs));
    g->addDebugInfo(
        db.createGlobalVariableExpression(cu, "_license", "_license", file, 0,
                                          arr, false));
  }

  // Attach DISubprogram to program functions, producing BTF FUNC records.
  void annotatePrograms() {
    for (Function &f : m) {
      if (f.isDeclaration())
        continue;
      SmallVector<Metadata *, 2> tys{nullptr, nullptr};
      tys[0] = intTy;
      tys[1] = db.createPointerType(
          db.createBasicType("void", 0, dwarf::DW_ATE_unsigned), 64);
      auto *ft = db.createSubroutineType(db.getOrCreateTypeArray(tys));
      auto *sp = db.createFunction(
          cu, f.getName(), f.getName(), file, 0, ft, 0, DINode::FlagPrototyped,
          DISubprogram::SPFlagDefinition);
      // BTF FUNC arguments need names: unnamed arguments in global FUNC_PROTO caused kernel Invalid
      // arg#1 and BTF rejection. DILocalVariable lets the backend retain their names.
      db.createParameterVariable(sp, "ctx", 1, file, 0,
                                 cast<DIType>(tys[1]),
                                 /*AlwaysPreserve=*/true);
      f.setSubprogram(sp);
    }
  }
};

} // namespace

mlir::LogicalResult emitObject(mlir::ModuleOp module, const Schema &schema,
                               raw_pwrite_stream &os, Diagnostics &diags,
                               StringRef license) {
  // Refuse big-endian declarations before emitting bpfel; their meanings conflict.
  auto checkLittle = [&](const spbpf::Type &t, StringRef where) {
    if (const auto *i = std::get_if<IntType>(&t.v))
      if (i->endianness != Endianness::Little)
        diags.error(where + ": the schema declares big-endian but the target "
                            "is bpfel (little endian)");
  };
  for (const Record &r : schema.records())
    for (const Field &f : r.fields)
      checkLittle(f.type, "record \"" + r.symbol + "\" field \"" + f.name +
                              "\"");
  for (const Map &mp : schema.maps()) {
    if (mp.key)
      checkLittle(*mp.key, "map \"" + mp.symbol + "\" key");
    if (mp.value)
      checkLittle(*mp.value, "map \"" + mp.symbol + "\" value");
  }
  if (diags.failed)
    return mlir::failure();

  LLVMContext ctx;
  mlir::DialectRegistry registry;
  mlir::registerAllToLLVMIRTranslations(registry);
  module->getContext()->appendDialectRegistry(registry);
  auto llvmModule = mlir::translateModuleToLLVMIR(module, ctx, "spbpf");
  if (!llvmModule) {
    diags.error("could not translate the module to LLVM IR");
    return mlir::failure();
  }

  LLVMInitializeBPFTargetInfo();
  LLVMInitializeBPFTarget();
  LLVMInitializeBPFTargetMC();
  LLVMInitializeBPFAsmPrinter();

  Triple triple("bpfel-unknown-none");
  std::string err;
  const Target *target = TargetRegistry::lookupTarget(triple, err);
  if (!target) {
    diags.error("no bpfel target: " + err);
    return mlir::failure();
  }
  TargetOptions opts;
  std::unique_ptr<TargetMachine> tm(target->createTargetMachine(
      triple, "v1", "", opts, std::optional<Reloc::Model>()));
  if (!tm) {
    diags.error("could not create the bpfel target machine");
    return mlir::failure();
  }
  llvmModule->setTargetTriple(triple);
  llvmModule->setDataLayout(tm->createDataLayout());

  {
    Emitter e(*llvmModule, schema, diags);
    e.buildRecordTypes();
    e.emitMaps();
    e.emitRecordWitnesses();
    e.emitLicense(license);
    e.annotatePrograms();
    e.db.finalize();
  }
  // Set the debug-info version or DWARF, and thus BTF, is dropped.
  llvmModule->addModuleFlag(Module::Warning, "Debug Info Version",
                            DEBUG_METADATA_VERSION);
  llvmModule->addModuleFlag(Module::Error, "Dwarf Version", 4);
  if (diags.failed)
    return mlir::failure();

  legacy::PassManager pm;
  if (tm->addPassesToEmitFile(pm, os, nullptr, CodeGenFileType::ObjectFile)) {
    diags.error("the bpfel target machine cannot emit an object file");
    return mlir::failure();
  }
  pm.run(*llvmModule);
  return mlir::success();
}

} // namespace spbpf
