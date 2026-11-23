#include "spinel/Conversion/ConsumerTypingProbe.h"
#include "spinel/Conversion/Consumer.h"
#include "spinel/Conversion/TypingProbeComparison.h"
#include "llvm/ADT/StringExtras.h"
#include "llvm/Support/Path.h"
#include "llvm/Support/SHA256.h"
namespace spinel::consumer {
LogicalResult checkTypingProbe(Consumer &c) {
  Operation *embedded=nullptr;
  for(auto n:c.selectedTop) {
    if(text(n,"kind")!="CallNode"||c.constant(c.ref(n,"receiver"))!="BPF"||field(n,"strings","name")!="kernel_type")continue;
    auto args=c.args(n);if(args.size()!=3)continue;
    for(auto pair:c.array(args[2],"elements")) {
      auto value=c.ref(pair,"value");if(text(value,"kind")!="ArrayNode")continue;
      auto items=c.array(value,"elements");
      if(items.size()==2&&text(items[0],"kind")=="SymbolNode"&&c.spelling(items[0],true)=="struct")embedded=n;
    }
  }
  auto metadata=c.input->getAttrOfType<DictionaryAttr>("spinel_facts.typing_probe");
  if(!metadata) {
    if(embedded)return c.error(embedded,"embedded kernel members require spinel_facts.typing_probe (M4) for Go's typing comparison");
    return success();
  }
  auto bad=[&](StringRef message){return c.error(embedded,"typing_probe: "+message.str());};
  if(c.probing)return bad("comparison is not a Probe action");
  const std::set<std::string> keys={"version","complete","producer_patch","source_file_id","source_sha256","analysis_roots","before_json","after_json","before_stderr"};
  if(metadata.size()!=keys.size()||llvm::any_of(metadata,[&](auto a){return !keys.count(a.getName().str());}))return bad("invalid metadata keys");
  auto version=metadata.getAs<IntegerAttr>("version"),fid=metadata.getAs<IntegerAttr>("source_file_id");
  auto complete=metadata.getAs<BoolAttr>("complete");auto patch=metadata.getAs<StringAttr>("producer_patch");
  auto hash=metadata.getAs<StringAttr>("source_sha256"),before=metadata.getAs<StringAttr>("before_json"),after=metadata.getAs<StringAttr>("after_json");
  if(!version||version.getInt()!=1||!fid||!complete||!complete.getValue()||!patch||patch.getValue()!="M4"||!hash||!before||!after||!metadata.getAs<StringAttr>("before_stderr"))return bad("incomplete M4 observations");
  auto roots=metadata.getAs<ArrayAttr>("analysis_roots"),declared=c.input->getAttrOfType<ArrayAttr>("spinel_facts.analysis_roots");
  if(!roots||!declared||roots.size()!=declared.size()||roots.empty())return bad("analysis roots mismatch");
  for(size_t i=0;i<roots.size();++i){auto a=dyn_cast<DictionaryAttr>(roots[i]),b=dyn_cast<DictionaryAttr>(declared[i]);if(!a||!b||a.get("method")!=b.get("method")||a.get("requested_arg_types")!=b.get("requested_arg_types"))return bad("analysis roots mismatch");}
  std::map<int64_t,std::string> paths;std::string source,path;
  for(auto s:c.input.getOps<ir::SourceOp>()) {
    auto id=s->getAttrOfType<IntegerAttr>("file_id").getInt();paths[id]=text(s,"path").str();
    if(id==fid.getInt()){source=text(s,"text").str();path=paths[id];}
  }
  if(path.empty())return bad("missing observed source");
  auto digest=llvm::SHA256::hash(llvm::ArrayRef<uint8_t>(reinterpret_cast<const uint8_t*>(source.data()),source.size()));
  if(llvm::toHex(digest,true)!=hash.getValue())return bad("source sha256 mismatch");
  std::map<int64_t,ProbeNode> nodes;std::map<std::string,int64_t> defs;std::set<std::string> names;
  for(auto &entry:c.nodes) {
    auto n=entry.second;ProbeNode p;p.name=field(n,"strings","name").str();p.span.kind=text(n,"kind").str();
    auto id=n->getAttrOfType<IntegerAttr>("file_id").getInt();if(id>=0){auto f=paths.find(id);if(f==paths.end())return bad("node source missing");p.span.file=f->second;}
    auto span=n->getAttrOfType<ArrayAttr>("span");
    if(!span||(span.empty()&&id>=0)||(!span.empty()&&span.size()!=4))return bad("node span missing");
    if(!span.empty()){int64_t values[4];for(unsigned i=0;i<4;++i){auto a=dyn_cast<IntegerAttr>(span[i]);if(!a)return bad("node span is not integer");values[i]=a.getInt();}p.span.line=values[0];p.span.col=values[1];p.span.endLine=values[2];p.span.endCol=values[3];}
    for(auto r:n->getAttrOfType<DictionaryAttr>("refs"))p.refs[r.getName().str()]=cast<IntegerAttr>(r.getValue()).getInt();
    for(auto a:n->getAttrOfType<DictionaryAttr>("arrays"))for(auto x:cast<ArrayAttr>(a.getValue()))p.arrays[a.getName().str()].push_back(cast<IntegerAttr>(x).getInt());
    nodes[entry.first]=std::move(p);
  }
  for(auto n:c.selectedTop)if(text(n,"kind")=="DefNode"&&!c.ref(n,"receiver")&&n->getAttrOfType<IntegerAttr>("file_id").getInt()==fid.getInt())defs[field(n,"strings","name").str()]=c.id(n);
  for(auto n:c.rootEntries){auto args=c.args(n);if(!args.empty())names.insert(c.spelling(args[0],true).str());}
  auto dependencies=typingProbeDependencies(nodes,defs,names);if(!dependencies)return bad(llvm::toString(dependencies.takeError()));
  int64_t lines=std::count(source.begin(),source.end(),'\n');if(!source.empty()&&source.back()!='\n')++lines;
  std::set<std::string> sourcePaths;for(const auto &entry:paths)sourcePaths.insert(entry.second);
  auto differences=compareTypingProbe(before.str(),after.str(),path,lines,names,*dependencies,sourcePaths);
  if(!differences)return bad(llvm::toString(differences.takeError()));
  for(auto &d:*differences) {
    inspection::Diagnostic diagnostic;diagnostic.verdict="rejected";diagnostic.code="SB010";diagnostic.name="TypingProbe";diagnostic.message=d.message;
    diagnostic.pos={llvm::sys::path::filename(d.span.file).str(),static_cast<unsigned>(d.span.line),static_cast<unsigned>(d.span.col+1)};
    (void)c.recordLocatedDiagnostic(diagnostic);
  }
  return differences->empty()?success():failure();
}
}
