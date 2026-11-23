#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "spinel/Analysis/KernelTypes.h"
#include "spinel/Conversion/Consumer.h"
#include "spinel/Conversion/KernelRecordAccess.h"
#include "spinel/Conversion/PacketDiagnostics.h"
#include "spinel/Conversion/FmodRet.h"
#include "llvm/ADT/StringExtras.h"
namespace spinel::consumer {
namespace {
struct IntegerType {unsigned bits;bool sign;};
std::optional<IntegerType> integerType(StringRef name) {
  if(name.size()<2||(name.front()!='i'&&name.front()!='u'))return {};
  unsigned bits;if(name.drop_front().getAsInteger(10,bits)||(bits!=8&&bits!=16&&bits!=32&&bits!=64))return {};
  return IntegerType{bits,name.front()=='i'};
}
struct KernelProgram : Payload {
  std::string kind,target,param,ret;
  int64_t nargs=0;
  std::map<int64_t,std::string> args;
  std::map<int64_t,std::string> structs;
  std::set<int64_t> nullable;
  Operation *def=nullptr;
};
struct KernelRead : Payload {IntegerType type;int64_t index;};
struct FieldDecl {std::string name,kind,type,target;int64_t count=0;};
struct TypeDecl {std::string constant,name;std::vector<FieldDecl> fields;Operation *node=nullptr;};
struct FieldRead : Payload {IntegerType type;std::string variable,field;};
void writeInteger(llvm::json::OStream &,IntegerType);
struct Kernel {
  std::shared_ptr<const KernelProgram> current;
  std::map<std::string,TypeDecl> types;
  std::vector<std::string> order;
  std::map<std::string,std::string> handles;
  std::set<std::string> checked;
std::set<std::string> failedEmbeds;
std::map<std::string, std::vector<std::string>> embedGraph(Consumer &c) const {
  std::map<std::string, std::vector<std::string>> graph;
  for(auto n:c.selectedTop) {
    if(text(n,"kind")!="CallNode"||c.constant(c.ref(n,"receiver"))!="BPF"||field(n,"strings","name")!="kernel_type")continue;
    auto args=c.args(n);if(args.size()!=3||text(args[0],"kind")!="ConstantReadNode")continue;
    auto key=c.constant(args[0]);graph[key];
    for(auto pair:c.array(args[2],"elements")){auto v=c.ref(pair,"value");if(text(v,"kind")!="ArrayNode")continue;auto a=c.array(v,"elements");if(a.size()==2&&text(a[0],"kind")=="SymbolNode"&&c.spelling(a[0],true)=="struct"&&text(a[1],"kind")=="ConstantReadNode")graph[key].push_back(c.constant(a[1]));}
  }
  return graph;
}
bool embedSample(Consumer &c,Operation *sample,const std::string &target,std::set<std::string> seen={}) const {
  auto d=types.find(target);if(d==types.end()||!seen.insert(target).second)return false;
  if(text(sample,"kind")!="CallNode"||field(sample,"strings","name")!="new"||c.constant(c.ref(sample,"receiver"))!=target)return false;
  auto values=c.args(sample);if(values.size()!=d->second.fields.size())return false;
  for(size_t i=0;i<values.size();++i){auto x=values[i];auto &f=d->second.fields[i];
    if(f.kind=="struct"){if(!embedSample(c,x,f.target,seen))return false;}
    else if(f.kind=="strptr"){if(text(x,"kind")!="StringNode"||!c.spelling(x,false).empty())return false;}
    else if(f.kind=="array"){auto as=c.args(x);if(text(x,"kind")!="CallNode"||field(x,"strings","name")!="new"||c.constant(c.ref(x,"receiver"))!="Array"||as.size()!=2||text(as[0],"kind")!="IntegerNode"||text(as[1],"kind")!="IntegerNode")return false;auto n=c.integer(as[0]),z=c.integer(as[1]);if(failed(n)||failed(z)||*n!=f.count||*z)return false;}
    else {if(text(x,"kind")!="IntegerNode")return false;auto z=c.integer(x);if(failed(z)||*z)return false;}
  }
  return true;
}
bool memberLike(StringRef name) const {
  static const std::set<std::string> objects={"dup","clone","freeze","frozen?","to_a","to_h","deconstruct","members","values","each","hash","eql?","equal?","inspect","to_s","size","length","tap","then"};
  return !name.empty()&&((name.front()>='a'&&name.front()<='z')||name.front()=='_')&&llvm::all_of(name,[](char x){return llvm::isAlnum(x)||x=='_';})&&!objects.count(name.str());
}
Dispatch<Expr> pathRead(Consumer &c,Operation *n) {
  std::vector<Operation*> segments;auto cur=n;
  while(text(cur,"kind")=="CallNode"&&field(cur,"strings","name")!="load"){
    if(!memberLike(field(cur,"strings","name")))return Dispatch<Expr>::declined();
    segments.insert(segments.begin(),cur);cur=c.ref(cur,"receiver");
  }
  if(text(cur,"kind")!="CallNode"||field(cur,"strings","name")!="load"||segments.size()<2)return Dispatch<Expr>::declined();
  auto variable=c.ref(cur,"receiver");if(text(variable,"kind")!="LocalVariableReadNode")return Dispatch<Expr>::declined();
  auto name=field(variable,"strings","name").str();auto binding=c.bindings.find("gkernel.ptr:"+name);if(binding==c.bindings.end())return Dispatch<Expr>::declined();
  auto &evidence=c.evidence[c.id(cur)];
  if(evidence.size()!=1||text(evidence.front(),"callee").empty()){
    (void)c.unknownDiagnostic(cur,"SB004","UnknownEdge","Spinel placed no single call for `load` ("+std::to_string(evidence.size())+" codegen records) — the target cannot be resolved statically",true);return Dispatch<Expr>::error();
  }
  if(text(evidence.front(),"callee")!="KPtr#load")return exprError(c,cur,"`load` resolves to "+text(evidence.front(),"callee").str()+", not BPF::KPtr#load","SB011","ShadowedName");
  CalleePolicy policy;policy.expected="KPtr#load";if(failed(c.known(cur,policy)))return Dispatch<Expr>::error();
  if(segments.size()>3)return exprError(c,n,"`"+name+".load` reads at most 3 members deep (a.b.c — bpf-mlir's kfield paths), got "+std::to_string(segments.size())+" (E154)","SB033","KernelTypeShape");
  auto type=dyn_cast<ebpf::KPtrType>(binding->second.value.getType());const TypeDecl *d=nullptr;
  if(type)for(auto &item:types)if(item.second.name==type.getStructName())d=&item.second;
  if(!d)return exprError(c,n,"kernel pointer has no checked declaration","SB033","KernelTypeShape");
  std::vector<std::string> names;
  for(size_t i=0;i<segments.size();++i){auto at=segments[i];auto member=field(at,"strings","name").str();if(!c.args(at).empty())return exprError(c,at,"a member read takes no arguments","SB002","UnsupportedCall");
    auto f=llvm::find_if(d->fields,[&](const FieldDecl &f){return f.name==member;});
    if(f==d->fields.end())return exprError(c,at,d->constant+" ("+d->name+") declares no member `"+member+"` — declare the members it reads in BPF.kernel_type (E154)","SB033","KernelTypeShape");
    names.push_back(member);
    if(i+1<segments.size()){
      if(f->kind!="struct")return exprError(c,at,"member "+member+" of "+d->constant+" is not an embedded struct ([:struct, S]) — a member path goes only through embedded structs (E154)","SB033","KernelTypeShape");
      auto next=types.find(f->target);if(next==types.end())return exprError(c,at,"embedded kernel struct has no checked declaration","SB033","KernelTypeShape");d=&next->second;continue;
    }
    if(f->kind!="int")return exprError(c,at,"`"+name+".load."+llvm::join(names,".")+"` reads an integer member only — "+member+" is a "+f->kind+" member (pointers, byte arrays and strings through a member path are not written yet — E154)","SB033","KernelTypeShape");
    auto numeric=*integerType(f->type);auto range=tracing::integerRange(numeric.bits,numeric.sign,tracing::IntegerSource::KernelField);if(!range){(void)c.rangeFailure(range.takeError(),at);return Dispatch<Expr>::error();}
    auto p=std::make_shared<FieldRead>();p->type=numeric;p->variable=name;p->field=llvm::join(names,".");auto e=std::make_shared<ScalarExpr>();e->node=n;e->kind="gkernel.field";e->range=*range;e->payload=p;return Dispatch<Expr>::handled(e);
  }
  return Dispatch<Expr>::declined();
}
  Dispatch<Expr> recordAccess(Consumer &c,Operation *n) {
    auto method=field(n,"strings","name");
    if(text(n,"kind")!="CallNode"||(method!="copy"&&method!="str"))return Dispatch<Expr>::declined();
    auto recv=c.ref(n,"receiver");
    if(text(recv,"kind")!="LocalVariableReadNode")return Dispatch<Expr>::declined();
    auto variable=field(recv,"strings","name").str();
    auto binding=c.bindings.find("gkernel.ptr:"+variable);
    if(binding==c.bindings.end())return Dispatch<Expr>::declined();
    auto type=dyn_cast<ebpf::KPtrType>(binding->second.value.getType());
    if(!type)return exprError(c,n,"kernel pointer requires its present check","SB033","KernelTypeShape");
    const TypeDecl *d=nullptr;for(const auto &p:types)if(p.second.name==type.getStructName())d=&p.second;
    if(!d)return exprError(c,n,"kernel pointer has no checked declaration","SB033","KernelTypeShape");
    CalleePolicy policy;policy.expected="KPtr#"+method.str();
    if(failed(c.known(n,policy)))return Dispatch<Expr>::error();
    auto as=c.args(n);bool string=method=="str";
    if(as.size()!=1||text(as[0],"kind")!="SymbolNode")
      return exprError(c,n,string?"`"+variable+".str(:m)` takes one Symbol literal — a :strptr member of "+d->constant+" (P026)":"`"+variable+".copy(:m)` takes one member Symbol (P021)","SB033","KernelTypeShape");
    auto member=c.spelling(as[0],true).str();
    auto f=llvm::find_if(d->fields,[&](const FieldDecl &f){return f.name==member;});
    if(string&&(f==d->fields.end()||f->kind!="strptr"))return exprError(c,as[0],"`"+variable+".str(:"+member+")`: "+member+" is not a :strptr member of "+d->constant+" (declare `"+member+": :strptr` in BPF.kernel_type — a char * member) (P026)","SB033","KernelTypeShape");
    if(!string&&f==d->fields.end())return exprError(c,as[0],d->constant+" ("+d->name+") declares no member `"+member+"` (P021)","SB033","KernelTypeShape");
    if(!string&&f->kind!="array")return exprError(c,as[0],"member "+member+" is not a byte array (`[:u8, N]`) — read it with `"+variable+".load."+member+"` (P021)","SB033","KernelTypeShape");
    auto payload=std::make_shared<KernelRecordAccess>();
    payload->variable=variable;payload->structure=d->name;payload->typeConstant=d->constant;payload->field=member;payload->count=f->count;payload->string=string;
    auto e=std::make_shared<ScalarExpr>();e->node=n;e->kind=string?"gkernel.record-str":"gkernel.record-copy";e->payload=payload;
    return Dispatch<Expr>::handled(e);
  }
  Dispatch<bool> declaration(Consumer &c,Operation *n) {
    auto reject=[&](Operation *at,const std::string &m){(void)c.diagnostic(at,"SB033","KernelTypeShape",m);return Dispatch<bool>::error();};
    if(field(n,"strings","name")=="kernel_type") {
      auto as=c.args(n);
      if(as.size()!=3||text(as[0],"kind")!="ConstantReadNode"||text(as[1],"kind")!="StringNode"||c.spelling(as[1],false).empty()||text(as[2],"kind")!="KeywordHashNode")return reject(n,"a kernel struct is declared as `BPF.kernel_type(S, \"kernel_name\", member: :i32, …)` — a Struct constant, the kernel struct's name and the members read (P021)");
      auto constant=c.constant(as[0]);
      Operation *structure=nullptr;
      for(auto &p:c.nodes)if(text(p.second,"kind")=="ConstantWriteNode"&&field(p.second,"strings","name")==constant&&p.second->getAttr("file_id")==n->getAttr("file_id"))structure=p.second;
      auto call=c.ref(structure,"value");
      if(!structure||c.constant(c.ref(call,"receiver"))!="Struct"||field(call,"strings","name")!="new")return reject(as[0],constant+" is not a top-level `"+constant+" = Struct.new(:m, …)` (P021)");
      if(types.count(constant))return reject(n,"kernel struct "+constant+" is declared twice");
      std::vector<std::string> members;
      for(auto m:c.args(call)){if(text(m,"kind")!="SymbolNode")return reject(m,"Struct members must be Symbol literals");members.push_back(c.spelling(m,true).str());}
      TypeDecl d;d.constant=constant;d.name=c.spelling(as[1],false).str();d.node=n;
      for(auto e:c.array(as[2],"elements")) {
        auto k=c.ref(e,"key"),v=c.ref(e,"value");
        if(text(e,"kind")!="AssocNode"||text(k,"kind")!="SymbolNode"||!v)return reject(e,"each member is `name: :i32`, `name: [:kptr, S]` or `name: [:u8, N]` (P021)");
        FieldDecl f;f.name=c.spelling(k,true).str();
        const std::set<std::string> keywords={"alias","and","begin","break","case","class","def","defined?","do","else","elsif","end","ensure","false","for","if","in","module","next","nil","not","or","redo","rescue","retry","return","self","super","then","true","undef","unless","until","when","while","yield"};
        bool ident=!f.name.empty()&&((f.name[0]>='a'&&f.name[0]<='z')||f.name[0]=='_')&&llvm::all_of(StringRef(f.name).drop_front(),[](char x){return llvm::isAlnum(x)||x=='_';});
        if(!ident||keywords.count(f.name))return reject(k,"member "+f.name+": the kernel member's name must be a lowercase Ruby identifier that is not a keyword (it becomes the Struct's accessor) — read another field, or ask bpf-mlir for an alias (P021)");
        if(text(v,"kind")=="SymbolNode") {
          f.type=c.spelling(v,true).str();f.kind=f.type=="strptr"?"strptr":"int";
          if(f.kind=="int"&&!integerType(f.type))return reject(v,"member "+f.name+": the type must be :i8 … :i64 / :u8 … :u64, `[:kptr, S]` or `[:u8, N]`, got :"+f.type+" (P021)");
        } else if(text(v,"kind")=="ArrayNode") {
          auto a=c.array(v,"elements");
          if(a.size()!=2||text(a[0],"kind")!="SymbolNode")return reject(v,"member "+f.name+": `[:kptr, S]` or `[:u8, N]` (P021)");
          auto label=c.spelling(a[0],true);
          if((label=="kptr"||label=="struct")&&text(a[1],"kind")=="ConstantReadNode"){f.kind=label.str();f.target=c.constant(a[1]);}
          else if((label=="u8"||label=="i8")&&text(a[1],"kind")=="IntegerNode") {
            auto count=c.integer(a[1]);if(failed(count))return Dispatch<bool>::error();
            if(*count<1||*count>64)return reject(a[1],"member "+f.name+": the array length must be a literal 1..64 (bpf-mlir's kernel byte arrays — kfield.copy) (P021)");
            f.kind="array";f.type=label.str();f.count=*count;
          }else return reject(v,"member "+f.name+": `[:kptr, S]` (S a kernel struct), `[:struct, S]` (an embedded kernel struct — E154) or `[:u8, N]` / `[:i8, N]` (P021)");
        }else return reject(v,"member "+f.name+": the type is a Symbol literal or `[:kptr, S]` / `[:u8, N]` (P021)");
        d.fields.push_back(f);
      }
      if(d.fields.empty())return reject(n,"kernel struct "+constant+" reads no member (P021)");
      std::vector<std::string> got;for(auto &f:d.fields)got.push_back(f.name);
      if(got!=members)return reject(n,"the members of BPF.kernel_type("+constant+", …) ("+llvm::join(got,", ")+") must be the Struct's members in the same order ("+llvm::join(members,", ")+") (P021)");
      for(const auto &f:d.fields)if(f.kind=="kptr") {
        bool declared=false;
        for(const auto &p:c.nodes) {
          auto candidate=p.second;
          if(text(candidate,"kind")!="CallNode"||field(candidate,"strings","name")!="kernel_type"||c.constant(c.ref(candidate,"receiver"))!="BPF"||candidate->getAttr("file_id")!=n->getAttr("file_id"))continue;
          auto args=c.args(candidate);
          if(!args.empty()&&c.constant(args[0])==f.target){declared=true;break;}
        }
        if(!declared)return reject(n,"member "+f.name+" of "+constant+" points to "+f.target+", which is not declared with BPF.kernel_type (P021)");
      }
auto graph=embedGraph(c);
for(auto &f:d.fields)if(f.kind=="struct"&&!graph.count(f.target))return reject(n,"member "+f.name+" of "+constant+" embeds "+f.target+", which is not declared with BPF.kernel_type (E154)");
std::set<std::string> seen;std::vector<std::string> path{constant};std::string cycle;
std::function<bool(const std::string&)> walk=[&](const std::string &key){if(failedEmbeds.count(key)||!seen.insert(key).second)return false;for(auto &next:graph[key]){path.push_back(next);if(next==constant){cycle=llvm::join(path," -> ");return true;}if(walk(next))return true;path.pop_back();}seen.erase(key);return false;};
if(walk(constant)){failedEmbeds.insert(constant);return reject(n,"kernel struct "+constant+" embeds itself by value ("+cycle+") — an embedded struct ([:struct, S]) cannot contain its container; use [:kptr, S] for a pointer (E154)");}
types.emplace(constant,std::move(d));order.push_back(constant);return Dispatch<bool>::handled(true);

    }
    auto name=field(n,"strings","name").str();auto call=c.ref(n,"value");auto as=c.args(call);
    if(as.size()!=1||text(as[0],"kind")!="CallNode"||field(as[0],"strings","name")!="new")return reject(n,"a kernel struct's typing sample is `"+name+" = BPF::KernelType.new(S.new(0, …))` (P021)");
    auto constant=c.constant(c.ref(as[0],"receiver"));auto found=types.find(constant);
    if(found==types.end())return reject(as[0],constant+" is not declared with BPF.kernel_type (P021)");
    auto sample=c.args(as[0]);auto &fields=found->second.fields;
    if(sample.size()!=fields.size())return reject(as[0],"the sample must give all "+std::to_string(fields.size())+" members of "+constant+" (P021)");
    for(size_t i=0;i<sample.size();++i) {
      auto &f=fields[i];auto x=sample[i];
      if(f.kind=="struct") {if(!embedSample(c,x,f.target))return reject(x,"the sample of the embedded struct member "+f.name+" is `"+f.target+".new(0, …)` with every member's sample (E154)");}
      else if(f.kind=="strptr") {if(text(x,"kind")!="StringNode"||!c.spelling(x,false).empty())return reject(x,"the sample of the :strptr member "+f.name+" is the empty String literal \"\" (P026)");}
      else if(f.kind=="array") {
        auto args=c.args(x);
        bool shape=text(x,"kind")=="CallNode"&&field(x,"strings","name")=="new"&&c.constant(c.ref(x,"receiver"))=="Array"&&args.size()==2;
        if(!shape)return reject(x,"the sample of the array member "+f.name+" is `Array.new("+std::to_string(f.count)+", 0)` (P021)");
        auto count=c.integer(args[0]),zero=c.integer(args[1]);
        if(failed(count)||failed(zero))return Dispatch<bool>::error();
        if(*count!=f.count||*zero!=0)return reject(x,"the sample of the array member "+f.name+" is `Array.new("+std::to_string(f.count)+", 0)` (P021)");
      } else {
        if(text(x,"kind")!="IntegerNode")return reject(x,"the sample's members are the literal 0 — it is a sample of the type for Spinel's inference (P021)");
        auto zero=c.integer(x);if(failed(zero))return Dispatch<bool>::error();
        if(*zero)return reject(x,"the sample's members are the literal 0 — it is a sample of the type for Spinel's inference (P021)");
      }
    }
    handles[name]=constant;return Dispatch<bool>::handled(true);
  }
  LogicalResult checkVerdicts(Consumer &c,Operation *def,StringRef name,StringRef kind) {
    Operation *wrongVerdict=nullptr;std::string verdictName;
    Operation *wrongReturn=nullptr;
    llvm::DenseSet<Operation*> seen;
    std::function<void(Operation*)> scan=[&](Operation *x) {
      if(!x||!seen.insert(x).second)return;
      if(text(x,"kind")=="CallNode"&&field(x,"strings","name")=="fmod_return"&&c.constant(c.ref(x,"receiver"))=="BPF"&&(!wrongReturn||c.id(x)<c.id(wrongReturn)))wrongReturn=x;
      auto cn=c.constant(x);
      const std::set<std::string> verdicts={"BPF::XDP_ABORTED","BPF::XDP_DROP","BPF::XDP_PASS","BPF::XDP_TX","BPF::TC_PASS","BPF::TC_DROP","BPF::CG_ALLOW","BPF::CG_DENY","BPF::SF_KEEP","BPF::SF_DROP","BPF::NF_ACCEPT","BPF::NF_DROP","BPF::FLOW_OK","BPF::FLOW_DROP","BPF::FLOW_CONTINUE","BPF::SK_PASS","BPF::SK_DROP"};
      if(verdicts.count(cn)&&!(kind=="netfilter"&&(cn=="BPF::NF_ACCEPT"||cn=="BPF::NF_DROP"))&&(!wrongVerdict||c.id(x)<c.id(wrongVerdict))){wrongVerdict=x;verdictName=cn;}
      if(auto refs=x->getAttrOfType<DictionaryAttr>("refs"))for(auto item:refs)scan(c.nodes.lookup(cast<IntegerAttr>(item.getValue()).getInt()));
      if(auto arrays=x->getAttrOfType<DictionaryAttr>("arrays"))for(auto item:arrays)for(auto id:cast<ArrayAttr>(item.getValue()))scan(c.nodes.lookup(cast<IntegerAttr>(id).getInt()));
    };scan(def);
    if(wrongReturn) {
      auto saved=c.programName;c.programName=name.str();
      (void)c.diagnostic(wrongReturn,"SB028","TracingKind","`BPF.fmod_return` ends only a fmod_ret program — a "+kind.str()+" program returns nothing (its last value is dropped) (E144)",true);
      c.programName=saved;return failure();
    }
    if(wrongVerdict) {
      auto v=StringRef(verdictName);std::string label=v.starts_with("BPF::XDP_")?"an XDP":v.starts_with("BPF::TC_")?"a sched_cls (tcx)":v.starts_with("BPF::CG_")?"a cgroup_skb":v.starts_with("BPF::SF_")?"a socket_filter":v.starts_with("BPF::NF_")?"a netfilter":v.starts_with("BPF::SK_")?"an sk_lookup":"a flow_dissector";
      auto saved=c.programName;c.programName=name.str();
      std::string suffix=(v.starts_with("BPF::CG_")||v.starts_with("BPF::NF_")||v.starts_with("BPF::SF_")||v.starts_with("BPF::FLOW_")||kind=="netfilter")?"P026":v.starts_with("BPF::TC_")?"P019":"P013";
      std::string want=kind=="netfilter"?"BPF::NF_ACCEPT or BPF::NF_DROP":"nothing (its last value is dropped)";
      (void)c.diagnostic(wrongVerdict,"SB028","TracingKind",verdictName+" is "+label+" verdict — a "+kind.str()+" program returns "+want+" ("+suffix+")",true);
      c.programName=saved;return failure();
    }
    return success();
  }
  Dispatch<ProgramDecl> root(Consumer &c,Operation *n) {
    auto kind=field(n,"strings","name").str();
    if(kind=="netfilter")return netfilterRoot(c,n);
    bool entry=kind!="fexit";
    bool tp=kind=="tp_btf";
    const std::string shape=tp?"`BPF.tp_btf :name, \"tracepoint\", args: {0 => TaskT, 2 => :u32}`":entry?"`BPF.fentry :name, \"kernel_function\", args: {0 => [:or_null, TaskT]}`":"`BPF.fexit :name, \"kernel_function\", nargs: N, ret: :i32`";
    auto bad=[&](const std::string &message){(void)c.diagnostic(n,"SB008","ProgramShape",message);return Dispatch<ProgramDecl>::error();};
    auto as=c.args(n);
    const std::string targetShape=entry&&!tp?"`BPF.fentry :name, \"kernel_function\"`":shape;
    if(as.size()<2||text(as[0],"kind")!="SymbolNode"||text(as[1],"kind")!="StringNode"||c.spelling(as[1],false).empty())return bad("a "+kind+" program is declared as "+targetShape+" with a Symbol and a non-empty String literal (P013)");
    if((entry&&!tp?(as.size()!=2&&as.size()!=3):as.size()!=3)||(as.size()==3&&text(as[2],"kind")!="KeywordHashNode"))return bad("a "+kind+" program is declared as "+shape+" (P013)");
    std::map<std::string,Operation*> opts;
    if(as.size()==3)for(auto element:c.array(as[2],"elements")) {
      auto key=c.ref(element,"key"),value=c.ref(element,"value");
      if(text(element,"kind")!="AssocNode"||text(key,"kind")!="SymbolNode"||!value)return bad("the options of "+shape+" are `key: literal` pairs (P013)");
      opts[c.spelling(key,true).str()]=value;
    }
    auto d=std::make_shared<KernelProgram>();d->kind=kind;d->target=c.spelling(as[1],false).str();
    if(entry) {
      if(as.size()==3) {
        auto hv=opts.count("args")?opts["args"]:nullptr;
        auto rejectArgs=[&](const std::string &message){(void)c.diagnostic(n,"SB033","KernelTypeShape",message);return Dispatch<ProgramDecl>::error();};
        if(opts.size()!=1||text(hv,"kind")!="HashNode")return rejectArgs(shape+" needs `args:` with a Hash literal of argument index (0..11) => a kernel struct's sample handle or an integer type (P021)");
        for(auto e:c.array(hv,"elements")) {
          auto k=c.ref(e,"key"),v=c.ref(e,"value");
          if(text(e,"kind")!="AssocNode"||text(k,"kind")!="IntegerNode")return rejectArgs("each fentry argument is `i => TaskT` or `i => :u32` with i an Integer literal 0..11 (P021)");
          auto index=c.integer(k);if(failed(index))return Dispatch<ProgramDecl>::error();
          if(*index<0||*index>11||d->args.count(*index)||d->structs.count(*index))return rejectArgs("a "+kind+" argument index is 0..11 (the u64 context slots) and appears once (P021)");
          auto handle=v;bool nullable=false;
          if(text(v,"kind")=="ArrayNode") {
            auto values=c.array(v,"elements");
            if(values.size()!=2||text(values[0],"kind")!="SymbolNode"||c.spelling(values[0],true)!="or_null"||text(values[1],"kind")!="ConstantReadNode"||!handles.count(c.constant(values[1])))return rejectArgs("argument "+std::to_string(*index)+": a nullable struct argument is `[:or_null, T]` with T a kernel struct's sample handle (P021)");
            handle=values[1];nullable=true;
          }
          if(text(handle,"kind")=="ConstantReadNode") {
            auto h=c.constant(handle);
            if(!tp&&!nullable)return rejectArgs("argument "+std::to_string(*index)+": a fentry struct argument is always nullable — declare it `"+std::to_string(*index)+" => [:or_null, T]` and read it with `q = ctx.kptr_or_null("+std::to_string(*index)+", T)` and `if q` (an integer argument is `"+std::to_string(*index)+" => :u32` etc., read with `ctx.arg("+std::to_string(*index)+")`) (P021)");
            if(!handles.count(h))return rejectArgs("argument "+std::to_string(*index)+": "+h+" is not a kernel struct's sample handle (`"+h+" = BPF::KernelType.new(S.new(0, …))`) (P021)");
            d->structs[*index]=types.at(handles[h]).name;if(nullable)d->nullable.insert(*index);continue;
          }
          if(text(v,"kind")!="SymbolNode")return rejectArgs("argument "+std::to_string(*index)+": a kernel struct's sample handle or an integer type Symbol (P021)");
          auto type=c.spelling(v,true).str();if(!integerType(type))return rejectArgs("argument "+std::to_string(*index)+": an integer argument's type is one of :i8 … :i64 / :u8 … :u64 (P021)");
          d->args[*index]=type;
        }
      }
    } else {
    auto nv=opts.count("nargs")?opts["nargs"]:nullptr;
    auto rv=opts.count("ret")?opts["ret"]:nullptr;
    if(opts.size()!=2||!rv||text(nv,"kind")!="IntegerNode")return bad(shape+" needs exactly `nargs:` (an Integer literal 0..12) and `ret:` (a Symbol :i8 … :u64) (P013)");
    auto count=c.integer(nv);if(failed(count))return Dispatch<ProgramDecl>::error();
    if(*count<0||*count>12)return bad("`nargs:` of "+shape+" is the target function's argument count, 0..12 (P013)");
    auto ret=c.spelling(rv,true).str();
    if(text(rv,"kind")!="SymbolNode"||!integerType(ret))return bad("`ret:` of "+shape+" is one of :i8 … :i64 / :u8 … :u64 (P013)");
    d->ret=ret;d->nargs=*count;
    }
    CalleePolicy policy;policy.expected="BPF."+kind;if(failed(c.known(n,policy)))return Dispatch<ProgramDecl>::error();
    auto name=c.spelling(as[0],true);
    for(auto node:c.selectedTop)if(text(node,"kind")=="DefNode"&&field(node,"strings","name")==name)d->def=node;
    if(!d->def){(void)c.error(n,"root target must be a declared method");return Dispatch<ProgramDecl>::error();}
    auto params=c.array(c.ref(d->def,"parameters"),"requireds");
    if(params.size()!=1){(void)c.error(d->def,"root requires one context parameter");return Dispatch<ProgramDecl>::error();}
    if(failed(checkVerdicts(c,d->def,name,kind)))return Dispatch<ProgramDecl>::error();
    for(auto &item:types)for(auto &f:item.second.fields)if(f.kind=="kptr"&&!types.count(f.target)){(void)c.diagnostic(item.second.node,"SB033","KernelTypeShape","member "+f.name+" of "+item.first+" points to "+f.target+", which is not declared with BPF.kernel_type (P021)");return Dispatch<ProgramDecl>::error();}
    d->param=field(params[0],"strings","name").str();current=d;checked.clear();
    for(auto i=c.bindings.begin();i!=c.bindings.end();)if(StringRef(i->first).starts_with("gkernel.ptr:"))i=c.bindings.erase(i);else ++i;
    ProgramDecl p;p.kind=kind;p.attachTarget=d->target;p.analysisContext=tp?"obj_BPF::TpBtfCtx":entry?"obj_BPF::FentryCtx":"obj_BPF::FexitCtx";p.payload=d;
    p.finalizeBody=[](Consumer &running) {
      auto *block=running.builder.getInsertionBlock();
      if(block->empty()||!block->back().hasTrait<OpTrait::IsTerminator>())ebpf::VerdictOp::create(running.builder,outputLoc(running.activeDef),"done");
      return success();
    };
    return Dispatch<ProgramDecl>::handled(std::move(p));
  }
  Dispatch<ProgramDecl> netfilterRoot(Consumer &c,Operation *n) {
    auto as=c.args(n);
    if(as.size()!=1||text(as[0],"kind")!="SymbolNode") {
      (void)c.diagnostic(n,"SB008","ProgramShape","`BPF.netfilter` takes exactly one Symbol literal (`BPF.netfilter :name` — the hook is chosen in user space with `obj.attach_netfilter(name, pf, hooknum, priority)`) (E128)");
      return Dispatch<ProgramDecl>::error();
    }
    CalleePolicy policy;policy.expected="BPF.netfilter";
    if(failed(c.known(n,policy)))return Dispatch<ProgramDecl>::error();
    auto d=std::make_shared<KernelProgram>();d->kind="netfilter";
    for(auto node:c.selectedTop)if(text(node,"kind")=="DefNode"&&field(node,"strings","name")==c.spelling(as[0],true))d->def=node;
    if(!d->def){(void)c.error(n,"root target must be a declared method");return Dispatch<ProgramDecl>::error();}
    auto ps=c.array(c.ref(d->def,"parameters"),"requireds");
    if(ps.size()!=1){(void)c.error(d->def,"root requires one context parameter");return Dispatch<ProgramDecl>::error();}
    if(failed(checkVerdicts(c,d->def,c.spelling(as[0],true),"netfilter")))return Dispatch<ProgramDecl>::error();
    d->param=field(ps[0],"strings","name").str();current=d;checked.clear();
    for(auto i=c.bindings.begin();i!=c.bindings.end();)if(StringRef(i->first).starts_with("gkernel.ptr:"))i=c.bindings.erase(i);else ++i;
    ProgramDecl p;p.kind="netfilter";p.analysisContext="obj_BPF::NfCtx";p.payload=d;
    p.finalizeBody=packetFinalizeBody;
    return Dispatch<ProgramDecl>::handled(std::move(p));
  }
  Dispatch<Expr> expression(Consumer &c,Operation *n) {
    if(text(n,"kind")=="ConstantReadNode"&&c.constant(n)=="Thread"&&c.activeDef) {
      (void)c.diagnostic(n,"SB027","ThreadInBPFSide","`Thread` inside a function reached from an eBPF program — threads do not exist on the eBPF side");
      return Dispatch<Expr>::error();
    }
// A nullable name survives its check, but its present binding exists only
// in the then arm. Inspect that lexical binding before consuming callees.
auto nullable=[&](Operation *x)->Dispatch<Expr> {
  if(current&&current->def==c.activeDef&&text(x,"kind")=="LocalVariableReadNode") {
    auto name=field(x,"strings","name").str();
    if(checked.count(name)&&!c.bindings.count("gkernel.ptr:"+name))
      return exprError(c,x,"`"+name+"` (a nullable kernel pointer) may be read only as `if "+name+"` and as `"+name+".load.m` / `"+name+".ptr(…)` inside it (P021)","SB005","RefCheckShape");
  }
  return Dispatch<Expr>::declined();
};
auto variable=n;
if(text(n,"kind")=="CallNode") {
  variable=c.ref(n,"receiver");
  if(text(variable,"kind")=="CallNode"&&field(variable,"strings","name")=="load")variable=c.ref(variable,"receiver");
}
auto absent=nullable(variable);if(absent.state==Disposition::Error)return absent;
if(text(n,"kind")=="LocalVariableReadNode") {
      auto name=field(n,"strings","name").str();
      if(c.bindings.count("gkernel.ptr:"+name))return exprError(c,n,"the kernel pointer `"+name+"` is not a value — read its members as `"+name+".load.m` (P021)","SB033","KernelTypeShape");
    }
    auto path=pathRead(c,n);if(path.state!=Disposition::Declined)return path;
    auto recv=c.ref(n,"receiver");
    if(text(recv,"kind")=="CallNode"&&field(recv,"strings","name")=="load") {
      auto variable=c.ref(recv,"receiver");auto name=field(variable,"strings","name").str();
      auto binding=c.bindings.find("gkernel.ptr:"+name);
      if(binding!=c.bindings.end()) {
        auto type=dyn_cast<ebpf::KPtrType>(binding->second.value.getType());
        if(!type)return exprError(c,n,"kernel pointer requires its present check","SB033","KernelTypeShape");
        const TypeDecl *decl=nullptr;for(auto &p:types)if(p.second.name==type.getStructName())decl=&p.second;
        if(!decl)return exprError(c,n,"kernel pointer has no checked declaration","SB033","KernelTypeShape");
        auto member=field(n,"strings","name").str();
        auto f=llvm::find_if(decl->fields,[&](const FieldDecl &f){return f.name==member;});
        if(f==decl->fields.end())return exprError(c,n,decl->constant+" ("+decl->name+") declares no member `"+member+"` — declare the members it reads in BPF.kernel_type (P021)","SB033","KernelTypeShape");
        if(failed(c.typed(recv)))return Dispatch<Expr>::error();
        CalleePolicy policy;policy.expected="KPtr#load";if(failed(c.known(recv,policy)))return Dispatch<Expr>::error();
if(f->kind=="struct")return exprError(c,n,"member "+member+" is an embedded struct — read its integer members as `"+name+".load."+member+".m` (E154)","SB033","KernelTypeShape");
if(f->kind=="kptr")return exprError(c,n,"member "+member+" is a kernel pointer — follow it with `rp = "+name+".ptr(:"+member+", T)` and `if rp` (P021)","SB033","KernelTypeShape");
if(f->kind=="strptr")return exprError(c,n,"member "+member+" is a :strptr (char *) — read the string it points to with `R.output_str(…, "+name+".str(:"+member+"), …)`, not its address (P026)","SB033","KernelTypeShape");
if(f->kind!="int")return exprError(c,n,"kernel non-integer member requires its dedicated operation","SB033","KernelTypeShape");
        auto numeric=*integerType(f->type);auto range=tracing::integerRange(numeric.bits,numeric.sign,tracing::IntegerSource::KernelField);
        if(!range){(void)c.rangeFailure(range.takeError(),n);return Dispatch<Expr>::error();}
        auto payload=std::make_shared<FieldRead>();payload->type=numeric;payload->variable=name;payload->field=member;
        auto e=std::make_shared<ScalarExpr>();e->node=n;e->kind="gkernel.field";e->range=*range;e->payload=payload;return Dispatch<Expr>::handled(e);
      }
    }
if(text(n,"kind")=="CallNode"&&text(recv,"kind")=="LocalVariableReadNode") {
  auto variable=field(recv,"strings","name").str();auto method=field(n,"strings","name");
  if(c.bindings.count("gkernel.ptr:"+variable)) {
if(method=="addr") {
  auto &evidence=c.evidence[c.id(n)];
  if(evidence.size()==1&&text(evidence.front(),"callee")!="KPtr#addr")return exprError(c,n,"`addr` resolves to "+text(evidence.front(),"callee").str()+", not BPF::KPtr#addr","SB011","ShadowedName");
  CalleePolicy policy;policy.expected="KPtr#addr";if(failed(c.known(n,policy)))return Dispatch<Expr>::error();
  if(!c.args(n).empty())return exprError(c,n,"`"+variable+".addr` takes no arguments — it is the address of the checked kernel pointer (E155)","SB033","KernelTypeShape");
  auto range=tracing::integerRange(64,true,tracing::IntegerSource::Argument);if(!range){(void)c.rangeFailure(range.takeError(),n);return Dispatch<Expr>::error();}
  auto p=std::make_shared<FieldRead>();p->variable=variable;p->type={64,true};auto e=std::make_shared<ScalarExpr>();e->node=n;e->kind="gkernel.addr";e->range=*range;e->range.form=range::Form::Computed;e->payload=p;return Dispatch<Expr>::handled(e);
}
    if(method=="str")return exprError(c,n,"the kernel pointer `"+variable+"` is not a value — read its members as `"+variable+".load.m` (P021)","SB033","KernelTypeShape");
    if(method=="copy")return exprError(c,n,"`"+variable+".copy(:m)` (a byte-array field) is not a value — it is accepted only as `r.load.<member> = "+variable+".copy(:m)` inside `if r` of a record map's lookup (P021)","SB033","KernelTypeShape");
    if(method=="load")return exprError(c,n,"`"+variable+".load` is not a value — read an integer member `"+variable+".load.m` (P021)","SB033","KernelTypeShape");
  }
}
    if(!current||current->def!=c.activeDef||text(recv,"kind")!="LocalVariableReadNode"||field(recv,"strings","name")!=current->param)return Dispatch<Expr>::declined();
    auto name=field(n,"strings","name");
    if((current->kind=="fentry"||current->kind=="tp_btf")&&name=="arg") {
      auto as=c.args(n);
      if(as.size()!=1||text(as[0],"kind")!="IntegerNode")return exprError(c,n,"`"+current->param+".arg(i)` takes one Integer literal i — an argument index declared in `BPF.fentry … args:` (P021)","SB033","KernelTypeShape");
      auto index=c.integer(as[0]);if(failed(index))return Dispatch<Expr>::error();
if(auto structure=current->structs.find(*index);structure!=current->structs.end()) {
  for(const auto &p:types)if(p.second.name==structure->second)
    return exprError(c,n,"argument "+std::to_string(*index)+" is declared as the kernel struct "+p.second.constant+" — bind it with `t = "+current->param+".kptr("+std::to_string(*index)+", "+p.second.constant+"T)` (P021)","SB033","KernelTypeShape");
}
      auto found=current->args.find(*index);
      if(found==current->args.end())return exprError(c,as[0],"argument "+std::to_string(*index)+" is not declared in `BPF.fentry … args:` (P021)","SB033","KernelTypeShape");
      CalleePolicy policy;policy.expected=current->kind=="fentry"?"FentryCtx#arg":"TpBtfCtx#arg";if(failed(c.known(n,policy)))return Dispatch<Expr>::error();
      auto type=*integerType(found->second);auto range=tracing::integerRange(type.bits,type.sign,tracing::IntegerSource::Argument);
      if(!range){(void)c.rangeFailure(range.takeError(),n);return Dispatch<Expr>::error();}
      auto payload=std::make_shared<KernelRead>();payload->type=type;payload->index=*index;
      auto e=std::make_shared<ScalarExpr>();e->node=n;e->kind="gkernel.arg";e->range=*range;e->payload=payload;return Dispatch<Expr>::handled(e);
    }
    if(current->kind=="netfilter")return exprError(c,n,"the netfilter context has no `"+name.str()+"` — it reads `st = ctx.state(T)` (nf_hook_state) and `sk = ctx.skb(T)` (sk_buff) — then `st.load.hook` etc. (a netfilter program has no packet window) (E128) (P013)","SB028","TracingKind");
    if(current->kind=="fentry")return exprError(c,n,"the fentry context has no `"+name.str()+"` — it reads `ctx.arg(i)` (an integer argument declared in `BPF.fentry … args:`) and `q = ctx.kptr_or_null(i, T)` (a struct argument) (P013)","SB028","TracingKind");
    if(name!="ret") {
      (void)c.diagnostic(n,"SB028","TracingKind","the fexit context has no `"+name.str()+"` — it reads `ctx.ret` (the declared return type) (P013)",true);
      return Dispatch<Expr>::error();
    }
    CalleePolicy policy;policy.expected="FexitCtx#ret";policy.requireCallee=false;
    if(failed(c.known(n,policy)))return Dispatch<Expr>::error();
    auto callee=text(c.evidence[c.id(n)].front(),"callee");
    auto as=c.args(n);
    if(callee!="FexitCtx#ret"||!as.empty()) {
      (void)c.diagnostic(n,"SB011","ShadowedName","`"+current->param+".ret` resolves to "+callee.str()+" (with "+std::to_string(as.size())+" arguments), not BPF::FexitCtx#ret",true);
      return Dispatch<Expr>::error();
    }
    auto type=*integerType(current->ret);
    auto range=tracing::integerRange(type.bits,type.sign,tracing::IntegerSource::FexitReturn);
    if(!range){(void)c.rangeFailure(range.takeError(),n);return Dispatch<Expr>::error();}
    auto payload=std::make_shared<KernelRead>();payload->type=type;payload->index=current->nargs;
    auto e=std::make_shared<ScalarExpr>();e->node=n;e->kind="gkernel.retval";e->range=*range;e->payload=payload;
    return Dispatch<Expr>::handled(std::move(e));
  }
  static Dispatch<Expr> exprError(Consumer &c,Operation *n,const std::string &message,StringRef code,StringRef label) {
    (void)c.diagnostic(n,code,label,message,true);return Dispatch<Expr>::error();
  }
  Dispatch<StatementResult> statement(Consumer &c,ArrayRef<Operation*> list,size_t index,unsigned depth) {
    auto n=list[index],call=c.ref(n,"value"),recv=c.ref(call,"receiver");
    if(!current||current->def!=c.activeDef||text(n,"kind")!="LocalVariableWriteNode"||text(call,"kind")!="CallNode"||text(recv,"kind")!="LocalVariableReadNode")return Dispatch<StatementResult>::declined();
    auto method=field(call,"strings","name");
    if(current->kind=="netfilter"&&field(recv,"strings","name")==current->param&&(method=="state"||method=="skb")) {
      auto name=field(n,"strings","name").str();auto as=c.args(call);
      auto bad=[&](Operation *at,const std::string &message){(void)c.diagnostic(at,"SB033","KernelTypeShape",message,true);return Dispatch<StatementResult>::error();};
      if(depth)return bad(n,"`"+name+" = "+current->param+".kptr(…)` is accepted only as a statement directly in the program's body (not inside an arm or a loop) — bind the kernel pointer first (P021)");
      if(c.locals.count(name)||c.borrows.count(name)||c.bindings.count("gkernel.ptr:"+name)||name==current->param)return bad(n,"`"+name+"` is already bound — a kernel pointer is bound once to a fresh name (P021)");
      if(as.size()!=1||text(as[0],"kind")!="ConstantReadNode")return bad(call,"a netfilter context pointer takes a kernel struct's sample handle (E128)");
      auto h=c.constant(as[0]);
      if(!handles.count(h))return bad(as[0],h+" is not a kernel struct's sample handle (E128)");
      auto target=types.at(handles[h]).name;auto expected=method=="state"?"nf_hook_state":"sk_buff";
      if(target!=expected)return bad(as[0],"`"+current->param+"."+method.str()+"` points to the kernel struct "+expected+" — "+h+" is "+target+" (E128)");
      CalleePolicy policy;policy.expected="NfCtx#"+method.str();if(failed(c.known(call,policy)))return Dispatch<StatementResult>::error();
      auto value=ebpf::CtxFieldOp::create(c.builder,outputLoc(n),ebpf::KPtrType::get(c.ctx,target),c.contextValue,method,IntegerAttr{});
      c.bindings["gkernel.ptr:"+name]={n,nullptr,value};
      return Dispatch<StatementResult>::handled({1});
    }
    if((field(recv,"strings","name")==current->param&&method=="kptr_or_null")||(method=="ptr"&&c.bindings.count("gkernel.ptr:"+field(recv,"strings","name").str())))return nullableBind(c,list,index,depth);
    if(field(recv,"strings","name")!=current->param||method!="kptr")return Dispatch<StatementResult>::declined();
    auto name=field(n,"strings","name").str();
    auto bad=[&](Operation *at,const std::string &m){(void)c.diagnostic(at,"SB033","KernelTypeShape",m,true);return Dispatch<StatementResult>::error();};
    if(depth)return bad(n,"`"+name+" = "+current->param+".kptr(…)` is accepted only as a statement directly in the program's body (not inside an arm or a loop) — bind the kernel pointer first (P021)");
    if(current->kind=="fentry")return bad(call,"a fentry program reads its struct arguments only as `q = ctx.kptr_or_null(i, T)` and `if q` (fentry pointers may always be NULL — declare `i => [:or_null, T]`) (P021)");
    if(c.locals.count(name)||c.borrows.count(name)||c.bindings.count("gkernel.ptr:"+name)||name==current->param)return bad(n,"`"+name+"` is already bound — a kernel pointer is bound once to a fresh name (P021)");
    CalleePolicy policy;policy.expected="TpBtfCtx#kptr";if(failed(c.known(call,policy)))return Dispatch<StatementResult>::error();
    auto as=c.args(call);
    if(as.size()!=2||text(as[0],"kind")!="IntegerNode"||text(as[1],"kind")!="ConstantReadNode")return bad(call,"`"+current->param+".kptr(i, T)` takes an Integer literal index and a kernel struct's sample handle (P021)");
    auto i=c.integer(as[0]);if(failed(i))return Dispatch<StatementResult>::error();
    auto declared=current->structs.find(*i);
    if(declared==current->structs.end()) {
      auto integer=current->args.find(*i);
      if(integer!=current->args.end())return bad(call,"argument "+std::to_string(*i)+" is declared as the integer :"+integer->second+" — read it with `"+current->param+".arg("+std::to_string(*i)+")` (P021)");
      return bad(as[0],"argument "+std::to_string(*i)+" is not declared in `BPF.tp_btf … args:` (P021)");
    }
    auto h=c.constant(as[1]);
    if(!handles.count(h)||types.at(handles[h]).name!=declared->second)return bad(as[1],"kernel argument's handle differs from its checked declaration");
    if(current->nullable.count(*i))return bad(call,"argument "+std::to_string(*i)+" is declared nullable (`[:or_null, T]`) — read it with `q = "+current->param+".kptr_or_null("+std::to_string(*i)+", T)` and `if q` (P021)");
    auto type=ebpf::KPtrType::get(c.ctx,declared->second);
    OperationState state(outputLoc(n),"ebpf.ctx.arg");state.addOperands(c.contextValue);state.addTypes(type);state.addAttribute("index",c.builder.getI64IntegerAttr(*i));
    auto value=c.builder.create(state)->getResult(0);c.bindings["gkernel.ptr:"+name]={n,nullptr,value};
    return Dispatch<StatementResult>::handled({1});
  }
  Dispatch<StatementResult> nullableBind(Consumer &c,ArrayRef<Operation*> list,size_t index,unsigned depth) {
    auto n=list[index],call=c.ref(n,"value"),recv=c.ref(call,"receiver");auto name=field(n,"strings","name").str();auto method=field(call,"strings","name");
    auto bad=[&](Operation *at,const std::string &m,StringRef code="SB033",StringRef label="KernelTypeShape"){(void)c.diagnostic(at,code,label,m,true);return Dispatch<StatementResult>::error();};
    if(c.locals.count(name)||c.borrows.count(name)||c.bindings.count("gkernel.ptr:"+name)||checked.count(name)||name==current->param)return bad(n,"`"+name+"` is already bound — a kernel pointer is bound once to a fresh name (P021)");
    if(index+1>=list.size())return bad(n,"`"+name+" = "+method.str()+"(…)` (a nullable kernel pointer) must be followed immediately by `if "+name+"` (P021)","SB005","RefCheckShape");
    auto check=list[index+1],pred=c.ref(check,"predicate");
    if(text(check,"kind")!="IfNode"||text(pred,"kind")!="LocalVariableReadNode"||field(pred,"strings","name")!=name)return bad(n,"`"+name+" = "+method.str()+"(…)` (a nullable kernel pointer) must be followed immediately by `if "+name+"` (P021)","SB005","RefCheckShape");
    auto sub=c.ref(check,"subsequent");
    if(sub&&text(sub,"kind")!="ElseNode")return bad(sub,"`elsif` is not accepted after `if "+name+"` (P021)","SB005","RefCheckShape");
    auto as=c.args(call);std::string target;Value pointer;
    if(method=="kptr_or_null") {
      CalleePolicy policy;policy.expected=current->kind=="fentry"?"FentryCtx#kptr_or_null":"TpBtfCtx#kptr_or_null";
      if(failed(c.known(call,policy)))return Dispatch<StatementResult>::error();
      if(depth)return bad(n,"`"+name+" = "+current->param+".kptr_or_null(…)` is accepted only as a statement directly in the program's body (P021)");
      if(as.size()!=2||text(as[0],"kind")!="IntegerNode"||text(as[1],"kind")!="ConstantReadNode")return bad(call,"`"+current->param+".kptr_or_null(i, T)` takes an Integer literal index and a kernel struct's sample handle (P021)");
      auto i=c.integer(as[0]);if(failed(i))return Dispatch<StatementResult>::error();auto arg=current->structs.find(*i);
      if(arg==current->structs.end())return bad(as[0],"argument "+std::to_string(*i)+" is not declared in `BPF."+current->kind+" … args:` (P021)");
      if(!current->nullable.count(*i))return bad(call,"argument "+std::to_string(*i)+" is declared non-null — read it with `t = "+current->param+".kptr("+std::to_string(*i)+", T)` (declare `"+std::to_string(*i)+" => [:or_null, T]` if the tracepoint passes NULL) (P021)");
      auto h=c.constant(as[1]);if(!handles.count(h)||types.at(handles[h]).name!=arg->second)return bad(as[1],"kernel argument's handle differs from its checked declaration");
      target=arg->second;
      OperationState state(outputLoc(n),"ebpf.ctx.arg");state.addOperands(c.contextValue);state.addTypes(ebpf::KPtrOrNullType::get(c.ctx,target));state.addAttribute("index",c.builder.getI64IntegerAttr(*i));pointer=c.builder.create(state)->getResult(0);
    } else {
      auto variable=field(recv,"strings","name").str();auto base=c.bindings.at("gkernel.ptr:"+variable).value;
      auto type=dyn_cast<ebpf::KPtrType>(base.getType());if(!type)return bad(call,"kernel pointer requires its present check");
      CalleePolicy policy;policy.expected="KPtr#ptr";if(failed(c.known(call,policy)))return Dispatch<StatementResult>::error();
      if(as.size()!=2||text(as[0],"kind")!="SymbolNode"||text(as[1],"kind")!="ConstantReadNode")return bad(call,"`"+variable+".ptr(:m, T)` takes a member Symbol and the pointee's sample handle (P021)");
      const TypeDecl *d=nullptr;for(auto &item:types)if(item.second.name==type.getStructName())d=&item.second;
      if(!d)return bad(call,"kernel pointer has no checked declaration");
      auto member=c.spelling(as[0],true).str();auto field=llvm::find_if(d->fields,[&](const FieldDecl &f){return f.name==member;});
      if(field==d->fields.end())return bad(as[0],d->constant+" ("+d->name+") declares no member `"+member+"` (P021)");
      if(field->kind!="kptr")return bad(as[0],"member "+member+" is not a kernel pointer (`[:kptr, S]`) — read it with `"+variable+".load."+member+"` (P021)");
      auto h=c.constant(as[1]);if(!handles.count(h)||handles[h]!=field->target)return bad(as[1],"member "+member+" points to "+field->target+", not the struct of "+h+" (P021)");
      target=types.at(field->target).name;
      OperationState state(outputLoc(n),"ebpf.kfield.ptr");state.addOperands(base);state.addTypes(ebpf::KPtrOrNullType::get(c.ctx,target));state.addAttribute("field",c.builder.getStringAttr(member));pointer=c.builder.create(state)->getResult(0);
    }
    checked.insert(name);
    auto pre=c.locals;auto oldBindings=c.bindings;auto oldBorrows=c.borrows;
    auto yes=std::make_unique<Block>(),no=std::make_unique<Block>();Locals thenEnv,elseEnv;
    {
      OpBuilder::InsertionGuard insertion(c.builder);
      c.builder.setInsertionPointToStart(yes.get());
      auto present=yes->addArgument(ebpf::KPtrType::get(c.ctx,target),c.builder.getUnknownLoc());
      c.bindings["gkernel.ptr:"+name]={n,nullptr,present};
      if(failed(c.scalarBody(c.ref(check,"statements"),depth+1)))return Dispatch<StatementResult>::error();
      thenEnv=c.locals;c.locals=pre;c.bindings=oldBindings;c.borrows=oldBorrows;
      c.builder.setInsertionPointToStart(no.get());
      if(failed(c.scalarBody(c.ref(sub,"statements"),depth+1)))return Dispatch<StatementResult>::error();
      elseEnv=c.locals;c.locals=pre;c.bindings=oldBindings;c.borrows=oldBorrows;
    }
    range::Environment aRange,bRange;for(auto &p:thenEnv)aRange[p.first]=p.second.expr->range;for(auto &p:elseEnv)bRange[p.first]=p.second.expr->range;
    auto joined=range::joinEnvironment(aRange,bRange);if(!joined){(void)c.rangeFailure(joined.takeError(),check);return Dispatch<StatementResult>::error();}
    std::vector<std::string> names;SmallVector<Type> resultTypes;SmallVector<Value> a,b;
    for(auto &p:thenEnv) {
      auto other=elseEnv.find(p.first);if(other==elseEnv.end()||!joined->count(p.first))continue;
      auto before=pre.find(p.first);if(before!=pre.end()&&before->second.value==p.second.value&&before->second.value==other->second.value)continue;
      names.push_back(p.first);resultTypes.push_back(p.second.value.getType());a.push_back(p.second.value);b.push_back(other->second.value);
    }
    auto op=ebpf::KPtrCheckOp::create(c.builder,outputLoc(n),resultTypes,pointer);
    op->getRegion(0).push_back(yes.release());op->getRegion(1).push_back(no.release());
    {
      OpBuilder::InsertionGuard insertion(c.builder);c.builder.setInsertionPointToEnd(&op->getRegion(0).front());ebpf::YieldOp::create(c.builder,outputLoc(check),a);
      c.builder.setInsertionPointToEnd(&op->getRegion(1).front());ebpf::YieldOp::create(c.builder,outputLoc(check),b);
    }
    for(size_t i=0;i<names.size();++i){auto e=std::make_shared<ScalarExpr>(*thenEnv.at(names[i]).expr);e->range=joined->at(names[i]);e->range.form=range::Form::Local;auto &reads=elseEnv.at(names[i]).expr->reads;e->reads.insert(e->reads.end(),reads.begin(),reads.end());c.locals[names[i]]={e,op->getResult(i)};}
    return Dispatch<StatementResult>::handled({2});
  }
  Dispatch<ExportValue> coreExport(Consumer &,bool schema) {
    if(!schema||order.empty())return Dispatch<ExportValue>::declined();
    std::vector<TypeDecl> declarations;std::map<std::string,std::string> names;
    for(auto &key:order){auto d=types.at(key);d.node=nullptr;declarations.push_back(d);names[key]=d.name;}
    return Dispatch<ExportValue>::handled(ExportValue::write([declarations,names](auto &out){
      out.array([&]{for(auto &d:declarations)out.object([&]{out.attribute("name",d.name);out.attribute("note","Ruby Struct "+d.constant);out.attributeArray("fields",[&]{for(auto &f:d.fields)out.object([&]{out.attribute("name",f.name);out.attributeBegin("type");if(f.kind=="int")writeInteger(out,*integerType(f.type));else if(f.kind=="kptr"||f.kind=="struct")out.object([&]{out.attribute("kind",f.kind);out.attribute("struct",names.at(f.target));});else if(f.kind=="array")out.object([&]{out.attribute("kind","array");out.attribute("count",f.count);out.attributeBegin("element");writeInteger(out,*integerType(f.type));out.attributeEnd();});else out.object([&]{out.attribute("kind","strptr");});out.attributeEnd();});});});});
    }));
  }
};
void writeInteger(llvm::json::OStream &out,IntegerType type) {
  out.object([&]{out.attribute("kind","int");out.attribute("bits",type.bits);out.attribute("signed",type.sign);out.attribute("endianness","little");out.attribute("alignment",type.bits/8);});
}
Dispatch<ExportFields> exportProgram(Consumer &c,size_t index,bool schema) {
  if(!schema)return Dispatch<ExportFields>::declined();
  if(index>=c.programs.size())return Dispatch<ExportFields>::error();
  auto &p=c.programs[index];auto d=std::static_pointer_cast<const KernelProgram>(p.payload);if(!d)return Dispatch<ExportFields>::error();
  ExportFields fields;fields.emplace_back("name",p.name);fields.emplace_back("kind",p.kind);fields.emplace_back("attach_target",p.attachTarget);
  if(d->kind=="fexit") {
    fields.emplace_back("nargs",d->nargs);
    fields.emplace_back("ret",ExportValue::write([type=*integerType(d->ret)](auto &out){writeInteger(out,type);}));
  }
  std::vector<std::string> maps;for(auto i:p.maps)maps.push_back(c.maps[i].name);
  fields.emplace_back("maps",ExportValue::write([maps](auto &out){out.array([&]{for(auto &name:maps)out.value(name);});}));
  if(!d->args.empty()||!d->structs.empty())fields.emplace_back("args",ExportValue::write([args=d->args,structs=d->structs,nullable=d->nullable](auto &out){
    int64_t last=std::max(args.empty()?-1:args.rbegin()->first,structs.empty()?-1:structs.rbegin()->first);
    out.array([&]{for(int64_t i=0;i<=last;++i){auto f=args.find(i),s=structs.find(i);if(f!=args.end())writeInteger(out,*integerType(f->second));else if(s!=structs.end()){if(nullable.count(i))out.object([&]{out.attribute("kind","struct");out.attribute("name",s->second);out.attribute("nullable",true);});else out.value(s->second);}else out.value(nullptr);}});
  }));
  fields.emplace_back("note","Ruby def "+p.name);
  return Dispatch<ExportFields>::handled(std::move(fields));
}
Dispatch<Value> emitRead(Consumer &c,const Expr &e) {
  if(e->kind=="gkernel.addr") {
    auto p=std::static_pointer_cast<const FieldRead>(e->payload);auto at=c.bindings.find("gkernel.ptr:"+p->variable);
    if(at==c.bindings.end()||!at->second.value||!isa<ebpf::KPtrType>(at->second.value.getType()))return (void)c.error(e->node,"checked addr lost its present kernel pointer"),Dispatch<Value>::error();
#ifdef SPINEL_E079_TEST_ADDR_ZERO
    return Dispatch<Value>::handled(arith::ConstantIntOp::create(c.builder,outputLoc(e->node),0,64).getResult());
#else
    return Dispatch<Value>::handled(ebpf::KPtrAddrOp::create(c.builder,outputLoc(e->node),c.builder.getI64Type(),at->second.value).getResult());
#endif
  }
  if(e->kind=="gkernel.field") {
    auto p=std::static_pointer_cast<const FieldRead>(e->payload);auto at=c.bindings.find("gkernel.ptr:"+p->variable);
    if(at==c.bindings.end())return Dispatch<Value>::error();
    auto loc=outputLoc(e->node);OperationState state(loc,"ebpf.kfield.load");state.addOperands(at->second.value);state.addTypes(c.builder.getIntegerType(p->type.bits));state.addAttribute("field",c.builder.getStringAttr(p->field));
#ifdef SPINEL_E079_TEST_PATH_LEAF_SWAP
    if(p->field=="__sk_common.skc_daddr")state.attributes.set("field",c.builder.getStringAttr("__sk_common.skc_rcv_saddr"));
#endif
    Value value=c.builder.create(state)->getResult(0);
    if(p->type.bits<64)value=p->type.sign?arith::ExtSIOp::create(c.builder,loc,c.builder.getI64Type(),value).getResult():arith::ExtUIOp::create(c.builder,loc,c.builder.getI64Type(),value).getResult();
    return Dispatch<Value>::handled(value);
  }
  auto p=std::static_pointer_cast<const KernelRead>(e->payload);auto loc=outputLoc(e->node);
  bool argument=e->kind=="gkernel.arg";
  OperationState state(loc,argument?"ebpf.ctx.arg":"ebpf.ctx.retval");state.addOperands(c.contextValue);state.addTypes(c.builder.getIntegerType(p->type.bits));state.addAttribute(argument?"index":"nargs",c.builder.getI64IntegerAttr(p->index));
  Value value=c.builder.create(state)->getResult(0);
  if(p->type.bits<64)value=p->type.sign?arith::ExtSIOp::create(c.builder,loc,c.builder.getI64Type(),value).getResult():arith::ExtUIOp::create(c.builder,loc,c.builder.getI64Type(),value).getResult();
  return Dispatch<Value>::handled(value);
}
} // namespace
void registerGroupGKernel(Registry &r) {
  registerFmodRet(r);
  auto kernel=std::make_shared<Kernel>();
  r.addExpression("KernelRecordAccess",[kernel](Consumer &c,Operation *n){return kernel->recordAccess(c,n);});
  r.addRoot("fexit",[kernel](Consumer &c,Operation *n){return kernel->root(c,n);});
  r.addRoot("fentry",[kernel](Consumer &c,Operation *n){return kernel->root(c,n);});
  r.addRoot("tp_btf",[kernel](Consumer &c,Operation *n){return kernel->root(c,n);});
  r.addRoot("netfilter",[kernel](Consumer &c,Operation *n){return kernel->root(c,n);});
  r.addDeclaration({"BPF","kernel_type"},[kernel](Consumer &c,Operation *n){return kernel->declaration(c,n);});
  r.addDeclaration({"BPF::KernelType","new"},[kernel](Consumer &c,Operation *n){return kernel->declaration(c,n);});
  r.addStatement("LocalVariableWriteNode",[kernel](Consumer &c,ArrayRef<Operation*> list,size_t i,unsigned depth){return kernel->statement(c,list,i,depth);});
  r.addExpression("CallNode",[kernel](Consumer &c,Operation *n){return kernel->expression(c,n);});
  for(auto kind:{"ConstantReadNode","LocalVariableReadNode"})r.addExpression(kind,[kernel](Consumer &c,Operation *n){return kernel->expression(c,n);});
  r.addEmitter("gkernel.retval",emitRead);r.addProgramExporter("fexit",exportProgram);
  r.addEmitter("gkernel.arg",emitRead);r.addProgramExporter("fentry",exportProgram);
  r.addEmitter("gkernel.addr",emitRead);r.addEmitter("gkernel.field",emitRead);r.addProgramExporter("tp_btf",exportProgram);
  r.addCoreExporter("kernel_types",[kernel](Consumer &c,bool schema){return kernel->coreExport(c,schema);});
}
Dispatch<Expr> checkKernelRecordCopy(Consumer &c, Operation *node,
                                     const record::Layout &layout,
                                     const record::FieldLayout &field,
                                     bool ring, Operation *destination) {
  if (text(node,"kind")!="CallNode" ||
      spinel::consumer::field(node,"strings","name")!="copy")
    return Dispatch<Expr>::declined();
  auto result=c.dispatchExpression("KernelRecordAccess",node);
  if(result.state!=Disposition::Handled)return result;
  auto e=*result.value;
  if(e->kind!="gkernel.record-copy")return (void)c.error(node,"kernel copy check returned another kind"),Dispatch<Expr>::error();
  auto p=std::static_pointer_cast<const KernelRecordAccess>(e->payload);
  auto reject=[&](const std::string &message){(void)c.diagnostic(destination?destination:node,"SB033","KernelTypeShape",message,true);return Dispatch<Expr>::error();};
  auto count=field.count.value_or(0);
  if(ring&&(field.bits!=8||count!=p->count))
    return reject("event member "+field.name+" of "+layout.name+" has "+std::to_string(count)+" elements but "+p->typeConstant+"."+p->field+" has "+std::to_string(p->count)+" — the copy is a fixed N bytes into a `[:u8, N]` member, declare the same N (P026)");
  if(!ring&&(field.bits!=8||!count))return reject("record member "+field.name+" of "+layout.name+" is not an 8-bit array — `"+p->variable+".copy(:"+p->field+")` copies "+std::to_string(p->count)+" bytes into a `[:u8, "+std::to_string(p->count)+"]` member (P021)");
  if(count!=p->count)return reject("record member "+field.name+" has "+std::to_string(count)+" elements but "+p->typeConstant+"."+p->field+" has "+std::to_string(p->count)+" — the copy is a fixed N bytes, declare the same N (P021)");
  return result;
}
LogicalResult emitKernelRecordCopy(Consumer &c,const Expr &expr,Value destination,
                                    StringRef field,Location loc) {
  auto p=std::static_pointer_cast<const KernelRecordAccess>(expr->payload);
  auto binding=c.bindings.find("gkernel.ptr:"+p->variable);
  if(binding==c.bindings.end()||!binding->second.value||
      binding->second.value.getType()!=ebpf::KPtrType::get(c.ctx,p->structure))
    return c.error(expr->node,"checked kernel copy lost its present pointer");
  ebpf::KFieldCopyOp::create(c.builder,loc,binding->second.value,p->field,destination,field);
  return success();
}
FailureOr<std::shared_ptr<const CheckedRecordValue>>
checkKernelRingString(Consumer &c,Operation *call,const RingDecl &ring) {
  auto as=c.args(call);
  auto reject=[&](Operation *at,StringRef code,StringRef label,const std::string &m)
      ->FailureOr<std::shared_ptr<const CheckedRecordValue>> {
    (void)c.diagnostic(at,code,label,m,true);return failure();
  };
  if(c.activeKind!="fentry"&&c.activeKind!="tp_btf"&&c.activeKind!="netfilter")
    return reject(as.size()>2?as[2]:call,"SB028","TracingKind","`….str(:m)` reads a kernel string through a kernel pointer — a "+c.activeKind+" program has none (fentry / tp_btf arguments and netfilter's state / skb do) (P026)");
  CalleePolicy policy;policy.expected="RingBuf#output_str";
  if(failed(c.known(call,policy)))return failure();
  auto member=[&](Operation *n)->const record::FieldLayout * {
    if(text(n,"kind")!="SymbolNode")return nullptr;
    auto name=c.spelling(n,true);
    for(const auto &f:ring.layout->fields)if(f.name==name)return &f;
    return nullptr;
  };
  if(as.size()!=4)return reject(call,"SB002","UnsupportedCall","output_str takes four arguments with a string and status member");
  auto target=member(as[1]),status=member(as[3]);
  if(!target||target->padding||!target->count||target->bits!=8||target->isSigned)
    return reject(as[1],"SB024","RecordShape","the string member of output_str must be a :u8 array member of "+ring.layout->name+" (`name: [:u8, 32]` — bpf-mlir's user.read_str fills a 1-dimensional 8-bit array) (P020)");
  if(!status||status->padding||status->count||status->bits!=64||!status->isSigned)
    return reject(as[3],"SB024","RecordShape","output_str requires an :i64 status member");
  auto string=c.dispatchExpression("KernelRecordAccess",as[2]);
  if(string.state==Disposition::Error)return failure();
  if(string.state!=Disposition::Handled||(*string.value)->kind!="gkernel.record-str")
    return reject(as[2],"SB033","KernelTypeShape","kernel output_str requires a :strptr member of a present kernel pointer");
  auto values=c.args(as[0]);
  size_t statusIndex=status-ring.layout->fields.data();
  if(statusIndex<values.size()) {
    auto n=values[statusIndex];
    if(text(n,"kind")!="IntegerNode"||text(n,"literal_decimal")!="0")
      return reject(n,"SB024","RecordShape","the status member "+status->name+" is written by output_str — give the literal 0 in "+ring.layout->name+".new (P020)");
  }
  auto value=checkRecordMake(c,as[0],ring.layout,
      RecordDestination{ring.name,RecordDestination::Kind::Ring,""});
  if(failed(value))return failure();
  auto checked=std::make_shared<CheckedRecordValue>(**value);
  auto expr=*string.value;
  checked->reservationWrites.push_back(
      [expr,path=target->name,offset=status->offset](Consumer &c,Value res,Location loc) {
        auto p=std::static_pointer_cast<const KernelRecordAccess>(expr->payload);
        auto binding=c.bindings.find("gkernel.ptr:"+p->variable);
        if(binding==c.bindings.end()||!binding->second.value||
            binding->second.value.getType()!=ebpf::KPtrType::get(c.ctx,p->structure))
          return c.error(expr->node,"checked kernel string lost its present pointer");
        Value status=ebpf::KernelReadStrOp::create(c.builder,loc,
            c.builder.getI64Type(),res,path,binding->second.value,p->field);
        ebpf::RingbufStoreFieldOp::create(c.builder,loc,res,status,offset);
        return success();
      });
  return std::shared_ptr<const CheckedRecordValue>(checked);
}
} // namespace spinel::consumer
