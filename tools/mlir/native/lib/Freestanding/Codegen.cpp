//===- Codegen.cpp - in-process optimisation and object emission ---------===//
//
// What `clang -c kern.ll` did, without clang. Every effect a profile flag had
// on that compile is stated in kFlags below, and every triple a profile names
// in kTriples; clang's driver derived the same values for an IR input (read
// from `clang -###` for each profile under LLVM 23.1.1).
//===----------------------------------------------------------------------===//
#include "spinel-mlir/Freestanding/Codegen.h"

#include "llvm/ADT/STLExtras.h"
#include "llvm/ADT/StringExtras.h"
#include "llvm/ADT/StringMap.h"
#include "llvm/Analysis/CGSCCPassManager.h"
#include "llvm/Analysis/LoopAnalysisManager.h"
#include "llvm/Analysis/TargetLibraryInfo.h"
#include "llvm/Analysis/TargetTransformInfo.h"
#include "llvm/IR/LegacyPassManager.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/PassManager.h"
#include "llvm/MC/TargetRegistry.h"
#include "llvm/Passes/PassBuilder.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/Target/TargetMachine.h"
#include "llvm/Target/TargetOptions.h"
#include "llvm/TargetParser/ARMTargetParser.h"
#include "llvm/TargetParser/RISCVISAInfo.h"
#include "llvm/TargetParser/Triple.h"

#include <mutex>
#include <vector>

extern "C" {
void LLVMInitializeARMTargetInfo();
void LLVMInitializeARMTarget();
void LLVMInitializeARMTargetMC();
void LLVMInitializeARMAsmPrinter();
void LLVMInitializeRISCVTargetInfo();
void LLVMInitializeRISCVTarget();
void LLVMInitializeRISCVTargetMC();
void LLVMInitializeRISCVAsmPrinter();
void LLVMInitializeWebAssemblyTargetInfo();
void LLVMInitializeWebAssemblyTarget();
void LLVMInitializeWebAssemblyTargetMC();
void LLVMInitializeWebAssemblyAsmPrinter();
void LLVMInitializeX86TargetInfo();
void LLVMInitializeX86Target();
void LLVMInitializeX86TargetMC();
void LLVMInitializeX86AsmPrinter();
void LLVMInitializeAArch64TargetInfo();
void LLVMInitializeAArch64Target();
void LLVMInitializeAArch64TargetMC();
void LLVMInitializeAArch64AsmPrinter();
}

using namespace llvm;

namespace spinel_mlir::freestanding {

namespace {

// ---- what each flag means ---------------------------------------------------
//
// The complete set the profiles use (tools/freestanding/profiles,
// tests/freestanding; tools/platform/menus.yaml has no cflags), plus the
// -O2 -ffreestanding -fno-builtin the emitter has always put in front of them.

enum class FlagEffect {
  OptLevel,   ///< the last -O wins, as in clang: `-O2 ... -Os` compiles -Os
              ///< (the O2 pipeline over optsize functions; see below)
  Cpu,        ///< -mcpu=<cpu>[+ext...]; ARM only
  FloatAbi,   ///< -mfloat-abi=soft; ARM only
  Arch,       ///< -march=<isa>; RISC-V only
  Abi,        ///< -mabi=<name>; RISC-V only
  NoBuiltins, ///< TargetLibraryInfo with every library function unavailable
  NoIrEffect, ///< accepted, and changes nothing for an IR input
};

struct FlagRule {
  StringRef spelling; ///< exact flag, or the prefix up to and including '='
  FlagEffect effect;
};

// -fshort-enums is a frontend option. It sizes C enums, and clang's ARM code
// generation states it to the backend as the "min_enum_size" module flag, from
// which the ARM AsmPrinter writes Tag_ABI_enum_size. Neither happens for an IR
// input: under LLVM 23.1.1, `clang -c` of an IR file gives a byte-identical
// object with and without -fshort-enums, with no Tag_ABI_enum_size at all.
//
// -Os is the O2 pipeline over functions marked optsize. LLVM 23's
// OptimizationLevel has no Os: optimising for size is the optsize function
// attribute, which clang's frontend adds to every C function at -Os. An IR
// input does not get it, so clang 23 compiled an IR input at -Os exactly as at
// -O2 (the same bytes for ARM, RISC-V and x86_64). Here, when the last -O is
// -Os, every function defined in the module is marked optsize before the
// pipeline runs, as clang marks C functions. One marked optnone or minsize
// already is left as it is. -Oz (minsize) is not in the table and stays
// refused.
const FlagRule kFlags[] = {
    {"-O2", FlagEffect::OptLevel},
    {"-Os", FlagEffect::OptLevel},
    {"-mcpu=", FlagEffect::Cpu},
    {"-mfloat-abi=", FlagEffect::FloatAbi},
    {"-march=", FlagEffect::Arch},
    {"-mabi=", FlagEffect::Abi},
    {"-ffreestanding", FlagEffect::NoBuiltins},
    {"-fno-builtin", FlagEffect::NoBuiltins},
    {"-fshort-enums", FlagEffect::NoIrEffect},
};

// ---- what each triple implies ------------------------------------------------
//
// What clang adds for the triple when no flag says otherwise. Its -tune-cpu,
// -mframe-pointer and -debugger-tuning go to function attributes or debug info
// that an IR input does not get, so they are not here.
//
// The features are clang's whole feature map, which is what its backend got:
// the driver's -target-feature list, completed by the frontend's target
// (initFeatureMap) and sorted. A feature the CPU implies changes nothing on its
// own, but a function attribute can name another CPU -- the grad shim names the
// -march string -- and then only this list says, for one, that RV32 is 32-bit.
// The lists are what clang 23.1.1 writes as "target-features" on a C function
// for the default CPU, and for ARM and RISC-V the part the flags do not derive.

struct TripleRule {
  Triple::ArchType arch;
  Triple::OSType os;     ///< UnknownOS matches any
  StringRef cpu;         ///< used unless -mcpu names one
  StringRef features;    ///< added to what the flags derive
  StringRef abiName;     ///< used unless -mabi names one
  Reloc::Model reloc;
  bool addrsig;          ///< clang passes -faddrsig
};

const TripleRule kTriples[] = {
    // The CPU's architecture (+armv8-m.main for cortex-m33) is added from -mcpu.
    {Triple::thumb, Triple::UnknownOS, "", "+thumb-mode", "aapcs",
     Reloc::Static, true},
    // +relax is the driver's default -mrelax.
    {Triple::riscv32, Triple::UnknownOS, "generic-rv32", "+32bit,+relax", "",
     Reloc::Static, true},
    {Triple::wasm32, Triple::UnknownOS, "generic",
     "+bulk-memory,+bulk-memory-opt,+call-indirect-overlong,+multivalue,"
     "+mutable-globals,+nontrapping-fptoint,+reference-types,+sign-ext",
     "", Reloc::Static, false},
    {Triple::x86_64, Triple::Linux, "x86-64",
     "+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87", "", Reloc::PIC_, true},
    {Triple::aarch64, Triple::MacOSX, "apple-m1",
     "+aes,+altnzcv,+ccdp,+ccidx,+ccpp,+complxnum,+crc,+dit,+dotprod,+flagm,"
     "+fp-armv8,+fp16fml,+fptoint,+fullfp16,+jsconv,+lse,+neon,+pauth,"
     "+perfmon,+predres,+ras,+rcpc,+rdm,+sb,+sha2,+sha3,+specrestrict,+ssbs,"
     "+v8.1a,+v8.2a,+v8.3a,+v8.4a,+v8a",
     "darwinpcs", Reloc::PIC_, false},
};

const FlagRule *findFlag(StringRef flag) {
  for (const FlagRule &r : kFlags)
    if (r.spelling.ends_with("=") ? flag.starts_with(r.spelling)
                                  : flag == r.spelling)
      return &r;
  return nullptr;
}

const TripleRule *findTriple(const Triple &t) {
  for (const TripleRule &r : kTriples)
    if (t.getArch() == r.arch && (r.os == Triple::UnknownOS || t.getOS() == r.os))
      return &r;
  return nullptr;
}

/// clang keeps the last occurrence of each feature and sorts the result; so
/// does this.
std::string unifyFeatures(ArrayRef<std::string> features) {
  StringMap<size_t> last;
  for (size_t i = 0; i < features.size(); ++i)
    last[StringRef(features[i]).drop_front()] = i;
  std::vector<std::string> kept;
  for (size_t i = 0; i < features.size(); ++i)
    if (last[StringRef(features[i]).drop_front()] == i)
      kept.push_back(features[i]);
  llvm::sort(kept);
  return join(kept, ",");
}

/// The ARM features clang derives from -mcpu=<cpu>[+ext...] and
/// -mfloat-abi=soft: the CPU's extensions, the requested ones, its default
/// FPU, and then every hardware floating-point feature turned off.
bool armFeatures(StringRef cpuFlag, bool softFloat, std::string &cpu,
                 std::vector<std::string> &out, std::string &error) {
  SmallVector<StringRef, 4> parts;
  cpuFlag.split(parts, '+');
  cpu = parts.front().str();
  ARM::ArchKind ak = ARM::parseCPUArch(cpu);
  if (ak == ARM::ArchKind::INVALID) {
    error = "unknown ARM CPU '" + cpu + "' in -mcpu=" + cpuFlag.str();
    return false;
  }
  std::vector<StringRef> f;
  std::string archFeature = ("+" + ARM::getArchName(ak)).str();
  f.push_back(archFeature);
  // clang also says +soft-float-abi, and its ARM target removes it again before
  // the backend sees the list: it is a frontend option, which the backend
  // reports as an unrecognised feature.
  if (softFloat)
    f.push_back("+soft-float");
  ARM::getExtensionFeatures(ARM::getDefaultExtensions(cpu, ak), f);
  ARM::FPUKind fpu = ARM::getDefaultFPU(cpu, ak);
  for (StringRef ext : ArrayRef(parts).drop_front())
    if (!ARM::appendArchExtFeatures(cpu, ak, ext, f, fpu)) {
      error = "unknown ARM extension '+" + ext.str() + "' in -mcpu=" +
              cpuFlag.str();
      return false;
    }
  ARM::getFPUFeatures(fpu, f);
  if (softFloat) {
    ARM::getFPUFeatures(ARM::FK_NONE, f);
    for (StringRef s : {"-dotprod", "-fp16fml", "-bf16", "-mve", "-mve.fp",
                        "-fpregs", "-crypto", "-sha2", "-aes"})
      f.push_back(s);
  }
  for (StringRef s : f)
    out.push_back(s.str());
  return true;
}

void initializeTargets() {
  static std::once_flag once;
  std::call_once(once, [] {
    LLVMInitializeARMTargetInfo();
    LLVMInitializeARMTarget();
    LLVMInitializeARMTargetMC();
    LLVMInitializeARMAsmPrinter();
    LLVMInitializeRISCVTargetInfo();
    LLVMInitializeRISCVTarget();
    LLVMInitializeRISCVTargetMC();
    LLVMInitializeRISCVAsmPrinter();
    LLVMInitializeWebAssemblyTargetInfo();
    LLVMInitializeWebAssemblyTarget();
    LLVMInitializeWebAssemblyTargetMC();
    LLVMInitializeWebAssemblyAsmPrinter();
    LLVMInitializeX86TargetInfo();
    LLVMInitializeX86Target();
    LLVMInitializeX86TargetMC();
    LLVMInitializeX86AsmPrinter();
    LLVMInitializeAArch64TargetInfo();
    LLVMInitializeAArch64Target();
    LLVMInitializeAArch64TargetMC();
    LLVMInitializeAArch64AsmPrinter();
  });
}

} // namespace

std::optional<CodegenConfig>
codegenConfigFromFlags(StringRef tripleName, ArrayRef<std::string> flags,
                       std::string &error) {
  Triple triple(Triple::normalize(tripleName));
  const TripleRule *tr = findTriple(triple);
  if (!tr) {
    error = "no codegen rule for the triple '" + tripleName.str() + "'";
    return std::nullopt;
  }
  CodegenConfig c;
  c.triple = triple.str();
  c.cpu = tr->cpu.str();
  c.abiName = tr->abiName.str();
  c.reloc = tr->reloc;
  c.emitAddrsig = tr->addrsig;

  const bool arm = triple.isARM() || triple.isThumb();
  const bool riscv = triple.isRISCV();
  std::string cpuFlag, march;
  for (const std::string &flag : flags) {
    const FlagRule *rule = findFlag(flag);
    if (!rule) {
      error = "unsupported cflag '" + flag + "'";
      return std::nullopt;
    }
    StringRef value = StringRef(flag).drop_front(rule->spelling.size());
    auto notFor = [&] {
      error = "cflag '" + flag + "' does not apply to " + tripleName.str();
      return std::nullopt;
    };
    switch (rule->effect) {
    case FlagEffect::OptLevel:
      c.optLevel = OptimizationLevel::O2;
      c.optSize = flag == "-Os";
      break;
    case FlagEffect::Cpu:
      if (!arm)
        return notFor();
      cpuFlag = value.str();
      break;
    case FlagEffect::FloatAbi:
      if (!arm)
        return notFor();
      if (value != "soft") {
        error = "unsupported cflag '" + flag + "' (only -mfloat-abi=soft)";
        return std::nullopt;
      }
      c.softFloat = true;
      break;
    case FlagEffect::Arch:
      if (!riscv)
        return notFor();
      march = value.str();
      break;
    case FlagEffect::Abi:
      if (!riscv)
        return notFor();
      c.abiName = value.str();
      break;
    case FlagEffect::NoBuiltins:
      c.noBuiltins = true;
      break;
    case FlagEffect::NoIrEffect:
      break;
    }
  }

  std::vector<std::string> features;
  SmallVector<StringRef, 40> base;
  tr->features.split(base, ',', -1, /*KeepEmpty=*/false);
  for (StringRef s : base)
    features.push_back(s.str());
  if (arm) {
    if (cpuFlag.empty() || !c.softFloat) {
      error = "an ARM profile must state -mcpu= and -mfloat-abi=soft";
      return std::nullopt;
    }
    std::vector<std::string> armF;
    if (!armFeatures(cpuFlag, c.softFloat, c.cpu, armF, error))
      return std::nullopt;
    features.insert(features.end(), armF.begin(), armF.end());
  }
  if (riscv) {
    if (march.empty()) {
      error = "a RISC-V profile must state -march=";
      return std::nullopt;
    }
    auto isa = RISCVISAInfo::parseArchString(march,
                                             /*EnableExperimentalExtension=*/true);
    if (!isa) {
      error = "-march=" + march + ": " + toString(isa.takeError());
      return std::nullopt;
    }
    std::vector<std::string> isaF =
        (*isa)->toFeatures(/*AddAllExtensions=*/true, /*IgnoreUnknown=*/false);
    features.insert(features.end(), isaF.begin(), isaF.end());
  }
  c.features = unifyFeatures(features);
  return c;
}

std::unique_ptr<TargetMachine>
createCodegenTargetMachine(const CodegenConfig &c, std::string &error) {
  initializeTargets();
  Triple triple(c.triple);
  const Target *target = TargetRegistry::lookupTarget(triple, error);
  if (!target)
    return nullptr;
  TargetOptions options;
  options.FloatABIType = c.softFloat ? FloatABI::Soft : FloatABI::Default;
  options.MCOptions.ABIName = c.abiName;
  options.UseInitArray = true;
  options.EmitAddrsig = c.emitAddrsig;
  CodeGenOptLevel level = c.optLevel == OptimizationLevel::O0
                              ? CodeGenOptLevel::None
                              : CodeGenOptLevel::Default;
  std::unique_ptr<TargetMachine> tm(target->createTargetMachine(
      triple, c.cpu, c.features, options, c.reloc, std::nullopt, level));
  if (!tm)
    error = "cannot create a target machine for " + c.triple;
  return tm;
}

std::optional<std::string> codegenDataLayout(const CodegenConfig &c,
                                             std::string &error) {
  auto tm = createCodegenTargetMachine(c, error);
  if (!tm)
    return std::nullopt;
  return tm->createDataLayout().getStringRepresentation();
}

bool optimizeAndEmitObject(Module &module, const CodegenConfig &c,
                           StringRef objPath, std::string &error) {
  auto tm = createCodegenTargetMachine(c, error);
  if (!tm)
    return false;
  const std::string expected = tm->createDataLayout().getStringRepresentation();
  if (module.getDataLayoutStr() != expected) {
    error = "data-layout-mismatch: module says \"" + module.getDataLayoutStr() +
            "\" but the target machine assumes \"" + expected + "\"";
    return false;
  }
  module.setTargetTriple(tm->getTargetTriple());

  // The optimiser's library info. -fno-builtin makes every library function
  // unavailable to it, so no pass turns a loop into memset or memcpy. (An IR
  // input to clang 23 did not get this: the frontend states -fno-builtin as a
  // function attribute, which only C sources receive.) Code generation keeps
  // the target's own library info, as clang's did, for the calls the backend
  // itself must make.
  TargetLibraryInfoImpl optTLI(tm->getTargetTriple());
  if (c.noBuiltins)
    optTLI.disableAllFunctions();

  if (c.optSize)
    for (Function &fn : module.functions())
      if (!fn.isDeclaration() && !fn.hasFnAttribute(Attribute::OptimizeNone) &&
          !fn.hasFnAttribute(Attribute::MinSize))
        fn.addFnAttr(Attribute::OptimizeForSize);

  LoopAnalysisManager lam;
  FunctionAnalysisManager fam;
  CGSCCAnalysisManager cgam;
  ModuleAnalysisManager mam;
  // clang's -O2 and -Os both unroll and vectorise (-vectorize-loops,
  // -vectorize-slp); -O0 does neither.
  PipelineTuningOptions pto;
  const bool optimizing = c.optLevel != OptimizationLevel::O0;
  pto.LoopUnrolling = optimizing;
  pto.LoopInterleaving = optimizing;
  pto.LoopVectorization = optimizing;
  pto.SLPVectorization = optimizing;
  PassBuilder pb(tm.get(), pto);
  fam.registerPass([&] { return TargetLibraryAnalysis(optTLI); });
  pb.registerModuleAnalyses(mam);
  pb.registerCGSCCAnalyses(cgam);
  pb.registerFunctionAnalyses(fam);
  pb.registerLoopAnalyses(lam);
  pb.crossRegisterProxies(lam, fam, cgam, mam);
  ModulePassManager mpm = optimizing
                              ? pb.buildPerModuleDefaultPipeline(c.optLevel)
                              : pb.buildO0DefaultPipeline(c.optLevel);
  mpm.run(module, mam);

  std::error_code ec;
  raw_fd_ostream os(objPath, ec);
  if (ec) {
    error = "cannot write " + objPath.str() + ": " + ec.message();
    return false;
  }
  TargetLibraryInfoImpl cgTLI(tm->getTargetTriple());
  legacy::PassManager cg;
  cg.add(new TargetLibraryInfoWrapperPass(cgTLI));
  if (tm->addPassesToEmitFile(cg, os, nullptr, CodeGenFileType::ObjectFile)) {
    error = "the target machine for " + c.triple + " cannot emit an object";
    return false;
  }
  cg.run(module);
  os.close();
  if (os.has_error()) {
    error = "cannot write " + objPath.str() + ": " + os.error().message();
    os.clear_error();
    return false;
  }
  return true;
}

} // namespace spinel_mlir::freestanding
