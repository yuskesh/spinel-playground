#include "spinel/Conversion/InspectionOutput.h"
#include "spinel/Conversion/LowerToEBPF.h"
#include "spinel/Conversion/BuildRevision.h"
#include "spinel/Import/Import.h"
#include "spinel/Dialect/SpinelFacts/IR/SpinelFactsDialect.h"
#include "mlir/IR/Verifier.h"
#include "mlir/Parser/Parser.h"
#include "mlir/Pass/PassManager.h"
#include "mlir/Pass/Pass.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/JSON.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/Path.h"
#include "llvm/Support/SHA256.h"
#include "llvm/Support/SourceMgr.h"
#include "llvm/Support/FormatVariadic.h"
#include <tuple>
#include "llvm/ADT/StringExtras.h"
#include <map>
using namespace mlir;
namespace spinel {
namespace {
std::string sha(llvm::StringRef bytes) {
  auto digest = llvm::SHA256::hash(llvm::ArrayRef<uint8_t>(
    reinterpret_cast<const uint8_t *>(bytes.data()),bytes.size()));
  return llvm::toHex(digest,true);
}
std::string absolute(llvm::StringRef input) {
  llvm::SmallString<256> path(input);
  if (llvm::sys::fs::make_absolute(path)) return {};
  llvm::sys::path::remove_dots(path,true);
  return path.str().str();
}
std::string fileIn(llvm::StringRef dir, llvm::StringRef name) {
  llvm::SmallString<256> path(dir); llvm::sys::path::append(path,name);
  return path.str().str();
}
bool ancestor(llvm::StringRef a, llvm::StringRef b) {
  return a == b || (b.starts_with(a) && b.size() > a.size() && b[a.size()] == '/');
}
bool write(llvm::StringRef path, llvm::StringRef bytes) {
  std::error_code ec;
  llvm::raw_fd_ostream out(path,ec);
  if (ec) { llvm::errs()<<"spinel-mlir: inspection write "<<path<<": "<<ec.message()<<"\n"; return false; }
  out<<bytes; out.close();
  if (out.has_error()) {
    llvm::errs()<<"spinel-mlir: inspection write "<<path<<": "<<out.error().message()<<"\n";
    out.clear_error(); return false;
  }
  return true;
}
std::string json(const llvm::json::Value &value) {
  std::string out; llvm::raw_string_ostream stream(out);
  stream<<llvm::formatv("{0:2}",value)<<"\n"; return out;
}
std::string targets(const std::vector<UprobeTarget> &values) {
  llvm::json::Array rows;
  for (const auto &p : values)
    rows.push_back(llvm::json::Object{{"name",p.name},{"kind",p.kind},
      {"binary_path",p.binaryPath},{"decl",llvm::json::Object{
        {"file",p.declFile},{"line",p.declLine},{"col",p.declCol}}}});
  return json(llvm::json::Object{{"version",1},{"programs",std::move(rows)}});
}
struct Directory {
  std::string final;
  llvm::SmallString<256> temp;
  ~Directory() { if (!temp.empty()) (void)llvm::sys::fs::remove_directories(temp); }
  bool prepare() {
    if (llvm::sys::fs::exists(final)) {
      llvm::errs()<<"spinel-mlir: inspection output directory already exists: "<<final<<"\n";
      return false;
    }
    auto ec=llvm::sys::fs::createUniqueDirectory(final+".tmp",temp);
    if (ec) { llvm::errs()<<"spinel-mlir: inspection create temp: "<<ec.message()<<"\n"; return false; }
    return true;
  }
  bool publish() {
    auto ec=llvm::sys::fs::rename(temp,final);
    if (ec) { llvm::errs()<<"spinel-mlir: inspection publish "<<final<<": "<<ec.message()<<"\n";return false; }
    temp.clear(); return true;
  }
};
}
int printBuildInfo() {
  llvm::outs()<<json(llvm::json::Object{{"version",1},{"pins",llvm::json::Object{
    {"consumer",llvm::json::Object{{"commit",SPINEL_CONSUMER_COMMIT},{"dirty",SPINEL_CONSUMER_DIRTY}}},
    {"bpf_mlir",llvm::json::Object{{"commit",SPINEL_BPF_MLIR_COMMIT}}}}}});
  return 0;
}
int runInspectionCLI(int argc, char **argv) {

  std::string emit,inspect,input;
  auto usage=[]() {
    llvm::errs()<<"usage: spinel-mlir [--emit-dir E] --inspect-dir I INPUT.mlir\n";
    return 2;
  };
  for (int i=1;i<argc;++i) {
    llvm::StringRef arg(argv[i]);
    if (arg=="--emit-dir" || arg=="--inspect-dir") {
      auto &dest=arg=="--emit-dir" ? emit : inspect;
      if (!dest.empty() || ++i==argc || llvm::StringRef(argv[i]).starts_with("--")) return usage();
      dest=absolute(argv[i]); if (dest.empty()) return usage();
    } else {
      if (arg.starts_with("--") || !input.empty()) return usage();
      input=absolute(arg); if (input.empty()) return usage();
    }
  }
  if (input.empty() || inspect.empty() || (!emit.empty() &&
       (ancestor(emit,inspect)||ancestor(inspect,emit)))) return usage();
  DialectRegistry registry; registry.insert<ir::SpinelFactsDialect>();
  MLIRContext context(registry);
  auto buffer=llvm::MemoryBuffer::getFile(input);
  if (!buffer) { llvm::errs()<<"spinel-mlir: cannot read inspection facts: "<<buffer.getError().message()<<"\n";return 1; }
  auto factsSHA=sha((*buffer)->getBuffer());
  llvm::SourceMgr sourceMgr; sourceMgr.AddNewSourceBuffer(std::move(*buffer),llvm::SMLoc());
  auto module=parseSourceFile<ModuleOp>(sourceMgr,&context);
  if (!module || failed(verify(*module)) || failed(verifyImport(*module))) return 1;
  std::string sourcePath,sourceText,revision;
  unsigned sources=0;
  for (auto source:module->getOps<ir::SourceOp>())
    if (source->getAttrOfType<IntegerAttr>("file_id").getInt()==0) {
      ++sources;
      sourcePath=source->getAttrOfType<StringAttr>("path").getValue().str();
      sourceText=source->getAttrOfType<StringAttr>("text").getValue().str();
    }
  revision=(*module)->getAttrOfType<StringAttr>("spinel_facts.producer_revision").getValue().str();
  auto spinelCommit=llvm::StringRef(revision).split('+').first;
  auto stem=llvm::sys::path::filename(sourcePath).str();
  if (sources!=1 || !llvm::StringRef(stem).ends_with(".rb") || stem.size()==3 ||
      spinelCommit.size()!=40 || spinelCommit.find_first_not_of("0123456789abcdef")!=llvm::StringRef::npos) {
    llvm::errs()<<"spinel-mlir: inspection requires one .rb entry source and the real producer commit\n";
    return 1;
  }
  stem.resize(stem.size()-3);
  Artifacts artifacts; Inspection inspection;
  PassManager manager(&context);manager.addPass(createLowerToEBPFPass(artifacts,&inspection));
  int result=failed(manager.run(*module)) ? 1 : 0;
  if (!inspection.domainProduced) return result;
  Directory report{inspect,{}};
  if (!report.prepare()) return 3;
  llvm::json::Object files;
  auto record=[&](llvm::StringRef key,llvm::StringRef directory,llvm::StringRef suffix,
                  llvm::StringRef bytes,llvm::StringRef staged)->bool {
    auto name=stem+suffix.str();
    if (!write(fileIn(staged,name),bytes)) return false;
    files[key.str()]=llvm::json::Object{{"path",fileIn(directory,name)},{"sha256",sha(bytes)}};
    return true;
  };
  if (!record("domain",inspect,".domain.json",inspection.domain,report.temp)) return 3;
  // The domain bytes are prepared first, just as Generate precedes emission.
  // Only publish the complete report after its referenced output files exist.
  bool emitIOFailure = false;
  if (result==0 && !emit.empty()) {
    auto emitArtifacts = [&]() -> bool {
    Directory output{emit,{}};
    if (!output.prepare()) return false;
    std::string ir; llvm::raw_string_ostream stream(ir);
    OpPrintingFlags flags;flags.enableDebugInfo(true,false);module->print(stream,flags);stream<<"\n";
    for (const auto &f : std::vector<std::tuple<std::string,std::string,std::string>>{
        {"mlir",".mlir",ir},{"schema",".schema.json",artifacts.schema},
        {"maps",".maps.json",artifacts.maps},{"records",".records.txt",artifacts.records},
        {"uprobe_targets",".uprobe_targets.json",targets(artifacts.uprobeTargets)}})
      if (!record(std::get<0>(f),emit,std::get<1>(f),std::get<2>(f),output.temp)) return false;
    return output.publish();
    };
    if (!emitArtifacts()) {
      result = 1; emitIOFailure = true;
      for (const auto *key : {"mlir","schema","maps","records","uprobe_targets"}) files.erase(key);
    }
  }
  llvm::json::Object manifest{{"version",1},
    {"source",llvm::json::Object{{"path",sourcePath},{"sha256",sha(sourceText)}}},
    {"facts",llvm::json::Object{{"path",input},{"sha256",factsSHA}}},
    {"execution","consumer"},
    {"pins",llvm::json::Object{
      {"spinel",llvm::json::Object{{"commit",spinelCommit},{"producer_revision",revision},{"producer_source","facts"}}},
      {"consumer",llvm::json::Object{{"commit",SPINEL_CONSUMER_COMMIT},{"dirty",SPINEL_CONSUMER_DIRTY}}},
      {"bpf_mlir",llvm::json::Object{{"commit",SPINEL_BPF_MLIR_COMMIT}}}}},
    {"result",llvm::json::Object{{"rc",result},{"domain_produced",true}}},
    {"outputs",std::move(files)}};
  if (emitIOFailure) {
    auto *status = manifest.getObject("result");
    (*status)["failure_stage"] = "emit_io";
  }
  if (!write(fileIn(report.temp,stem+".inspect-manifest.json"),json(std::move(manifest))) ||
      !report.publish()) return 3;
  return result;
}
} // namespace spinel
