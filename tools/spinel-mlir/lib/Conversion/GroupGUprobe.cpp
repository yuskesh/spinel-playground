#include "spinel/Conversion/GroupGUprobe.h"
#include "spinel/Conversion/Consumer.h"
#include "spinel/Analysis/KernelTypes.h"
#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "llvm/ADT/StringExtras.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/Path.h"
#include "llvm/Support/SHA256.h"
#include <set>

namespace spinel::consumer {
namespace {
using namespace mlir;
using DE = Dispatch<Expr>;
struct Int { unsigned bits; bool sign; };
static std::optional<Int> integerType(StringRef name) {
  if (name.size()<2 || (name.front()!='i' && name.front()!='u')) return {};
  unsigned bits;
  if (name.drop_front().getAsInteger(10,bits) ||
      (bits!=8 && bits!=16 && bits!=32 && bits!=64)) return {};
  return Int{bits,name.front()=='i'};
}
struct Declaration : Payload {
  std::string kind,target,binarySHA,param,ret;
  std::vector<std::pair<int64_t,std::string>> params;
  Operation *def=nullptr;
};
struct Read : Payload { int64_t n=0; Int type{0,false}; };
static LogicalResult diagnostic(Consumer &c,Operation *n,StringRef code,
    StringRef label,const std::string &message,bool path=true) {
  return c.diagnostic(n,code,label,message,path);
}
static std::string quote(StringRef s) {
  std::string value;llvm::raw_string_ostream os(value);
  os<<llvm::json::Value(s);return value;
}
// POSIX filepath.Clean semantics needed by Go's uprobe declaration gate.
static std::string cleanTargetPath(StringRef path) {
  llvm::SmallString<256> dots(path);llvm::sys::path::remove_dots(dots,true);
  std::string clean;for(char ch:dots)if(ch!='/'||clean.empty()||clean.back()!='/')clean+=ch;
  while(clean.size()>1&&clean.back()=='/')clean.pop_back();return clean.empty()?".":clean;
}
struct Uprobe {
  std::shared_ptr<const Declaration> current;
  bool context(Consumer &c,Operation *node) const {
    return current && c.activeKind==current->kind && c.activeDef==current->def &&
      text(node,"kind")=="LocalVariableReadNode" &&
      field(node,"strings","name")==current->param;
  }
  Dispatch<ProgramDecl> root(Consumer &c,Operation *node) {
    auto d=std::make_shared<Declaration>();d->kind=field(node,"strings","name").str();
    bool ret=d->kind=="uretprobe";
    if (!ret && d->kind!="uprobe") return Dispatch<ProgramDecl>::declined();
    const std::string shape=ret
      ? "`BPF.uretprobe :name, \"target/binary\", \"symbol\", ret: :i64`"
      : "`BPF.uprobe :name, \"target/binary\", \"symbol\", params: {1 => :user_str, 2 => :i32}`";
    auto bad=[&](const std::string &message) {
      (void)diagnostic(c,node,"SB008","ProgramShape",message,false);
      return Dispatch<ProgramDecl>::error();
    };
    auto args=c.args(node);
    if (args.size()!=4 || text(args[0],"kind")!="SymbolNode" ||
        text(args[1],"kind")!="StringNode" || text(args[2],"kind")!="StringNode" ||
        text(args[3],"kind")!="KeywordHashNode" ||
        c.spelling(args[1],false).empty() || c.spelling(args[2],false).empty())
      return bad("a "+d->kind+" program is declared as "+shape+
        " — a Symbol, the target binary's path and symbol as non-empty String literals, and `"+
        (ret ? "ret:" : "params:")+"` ("+(ret ? "P026" : "P020")+")");
    auto path=c.spelling(args[1],false);auto relative=cleanTargetPath(path);
    bool absolute=llvm::sys::path::is_absolute(path);
    if(absolute&&relative!=path)
      return bad("the uprobe target "+quote(path)+" must be a clean absolute path (no `.`, `..` or repeated `/`) or a path relative to the source's directory — the build reads it and puts only its SHA-256 in the schema (P020, E156)");
    if(!absolute&&(relative==".."||StringRef(relative).starts_with("../")))
      return bad("the uprobe target "+quote(path)+" must be a path relative to the source's directory that stays inside it (no `..` out of it) or a clean absolute path — the build reads it and puts only its SHA-256 in the schema (P020, E156)");
    llvm::SmallString<256> full;
    if(absolute)full=path;
    else {
      for (auto source:c.input.getOps<ir::SourceOp>())
        if (source->getAttr("file_id")==node->getAttr("file_id")) {full=text(source,"path");break;}
      if (full.empty()) { (void)c.error(node,"uprobe source path is unavailable");return Dispatch<ProgramDecl>::error(); }
      llvm::sys::path::remove_filename(full);llvm::sys::path::append(full,relative);
    }
    if (!llvm::sys::fs::is_regular_file(full))
      return bad("the uprobe target "+quote(path)+" is not a readable regular file — the build needs it to compute binary_sha256 (P020)");
    auto bytes=llvm::MemoryBuffer::getFile(full);
    if (!bytes) return bad("the uprobe target "+quote(path)+" cannot be read: "+bytes.getError().message()+" (P020)");
    auto buffer=(*bytes)->getBuffer();
    auto hash=llvm::SHA256::hash(llvm::ArrayRef<uint8_t>(reinterpret_cast<const uint8_t*>(buffer.data()),buffer.size()));
    d->binarySHA=llvm::toHex(hash,true);d->target=c.spelling(args[2],false).str();
    Operation *option=nullptr;
    for (auto item:c.array(args[3],"elements")) {
      auto key=c.ref(item,"key");
      if (text(item,"kind")!="AssocNode" || text(key,"kind")!="SymbolNode" ||
          c.spelling(key,true)!=(ret ? "ret" : "params") || option)
        return bad("the options of "+shape+" are exactly `"+(ret ? "ret:" : "params:")+"` ("+(ret ? "P026" : "P020")+")");
      option=c.ref(item,"value");
    }
    if (ret) {
      if (!option || text(option,"kind")!="SymbolNode")
        return bad(shape+" needs `ret:` (a Symbol :i8 … :u64 — the kernel does not check it; the value is the return register cut to this width) (P026)");
      d->ret=c.spelling(option,true).str();
      if (!integerType(d->ret)) return bad("`ret:` of "+shape+" is one of :i8 … :i64 / :u8 … :u64 (P026)");
    } else {
      if (!option || text(option,"kind")!="HashNode")
        return bad(shape+" needs `params:` with a Hash literal of argument number (1..6) => type (P020)");
      std::set<int64_t> seen;
      for (auto item:c.array(option,"elements")) {
        auto key=c.ref(item,"key"),value=c.ref(item,"value");
        if (text(item,"kind")!="AssocNode" || text(key,"kind")!="IntegerNode")
          return bad("each uprobe parameter is `n => :type` with n an Integer literal 1..6 (P020)");
        auto literal=math::Integer::parse(text(key,"literal_text").str());
        if (!literal) {llvm::consumeError(literal.takeError());return bad("a uprobe parameter number is 1..6 (the x86_64 argument registers, 1-origin like the schema's n) and appears once (P020)");}
        int64_t n=0;
        for (int64_t i=1;i<=6;++i) if (*literal==math::Integer::from(i))n=i;
        if (!n || !seen.insert(n).second)
          return bad("a uprobe parameter number is 1..6 (the x86_64 argument registers, 1-origin like the schema's n) and appears once (P020)");
        std::string type=text(value,"kind")=="SymbolNode" ? c.spelling(value,true).str() : "";
        if (!integerType(type) && type!="user_str" && type!="ptr" && type!="user_buf")
          return bad("a uprobe parameter type is one of :i8 … :i64 / :u8 … :u64, :user_str (a `const char *` — read with ctx.str_arg(n)), :ptr (a pointer's raw value as i64 — read with ctx.arg(n)) or :user_buf (a buffer — read with ctx.buf_arg(n) in R.output_buf) (P020, E157, E158)");
        d->params.emplace_back(n,type);
      }
    }
    if (failed(c.known(node,CalleePolicy{"BPF."+d->kind}))) return Dispatch<ProgramDecl>::error();
    auto name=c.spelling(args[0],true);
    for (auto f:c.selectedTop) if (text(f,"kind")=="DefNode" && field(f,"strings","name")==name)d->def=f;
    if (!d->def) return bad("root target must be a declared method");
    auto parameters=c.array(c.ref(d->def,"parameters"),"requireds");
    if (parameters.size()!=1) return bad("a probe program requires one context parameter");
    d->param=field(parameters[0],"strings","name").str();current=d;
    ProgramDecl p;p.kind=d->kind;p.attachTarget=d->target;p.arch="x86_64";
    p.binaryPath=full.str().str();
    p.contextType=ebpf::ContextType::get(c.ctx,d->kind);
    p.analysisContext=ret ? "obj_BPF::UretprobeCtx" : "obj_BPF::UprobeCtx";p.payload=d;
    p.finalizeBody=[d](Consumer &c) {
      auto block=c.builder.getInsertionBlock();
      if (!block || (!block->empty() && block->back().hasTrait<OpTrait::IsTerminator>()))
        return c.error(d->def,"uprobe finalizer requires an unterminated program block");
      ebpf::VerdictOp::create(c.builder,outputLoc(d->def),"done");return success();
    };
    return Dispatch<ProgramDecl>::handled(std::move(p));
  }
  FailureOr<std::pair<int64_t,std::string>> parameter(Consumer &c,Operation *call) {
    auto args=c.args(call);auto name=field(call,"strings","name").str();
    auto bad=[&](Operation *at,const std::string &message) {return diagnostic(c,at,"SB028","TracingKind",message);};
    if (args.size()!=1 || text(args[0],"kind")!="IntegerNode") {
      (void)bad(call,"`"+current->param+"."+name+"(n)` takes one Integer literal n — a declared parameter number (P020)");return failure();
    }
    if (failed(c.known(args[0]))) return failure();
    auto n=math::Integer::parse(text(args[0],"literal_text").str());
    if (!n) { (void)c.rangeFailure(n.takeError(),args[0]);return failure(); }
    for (auto &p:current->params) if (*n==math::Integer::from(p.first)) return p;
    (void)bad(args[0],"`"+current->param+"."+name+"("+n->str()+")`: "+n->str()+" is not a parameter number declared in `BPF.uprobe … params:` (1..6, 1-origin like the schema's n) (P020)");
    return failure();
  }
  FailureOr<std::shared_ptr<const UserStringArg>> userString(Consumer &c,Operation *call) {
    if (!current || current->kind!="uprobe" || !context(c,c.ref(call,"receiver")) ||
        text(call,"kind")!="CallNode" || field(call,"strings","name")!="str_arg") {
      std::string param=current ? current->param : "ctx";
      (void)diagnostic(c,call,"SB028","TracingKind","the third argument of output_str is `"+param+".str_arg(n)` itself (a user string is not a value on the eBPF side — not through a local) (P020)");return failure();
    }
    CalleePolicy policy{"UprobeCtx#str_arg"};policy.requireCallee=false;
    if (failed(c.known(call,policy))) return failure();
    auto actual=text(c.evidence[c.id(call)].front(),"callee");
    if (actual!="UprobeCtx#str_arg") {
      (void)diagnostic(c,call,"SB011","ShadowedName","`str_arg` resolves to "+actual.str()+", not BPF::UprobeCtx#str_arg");return failure();
    }
    auto p=parameter(c,call);if (failed(p))return failure();
    if (p->second!="user_str") {
      auto n=std::to_string(p->first);
      (void)diagnostic(c,call,"SB028","TracingKind","`"+current->param+".str_arg("+n+")`: parameter "+n+" is declared :"+p->second+" — read it with `"+current->param+".arg("+n+")` (P020)");return failure();
    }
    UserStringArg metadata{p->first,call}; metadata.def=current->def;
    return std::shared_ptr<const UserStringArg>(std::make_shared<UserStringArg>(std::move(metadata)));
  }
  FailureOr<std::shared_ptr<const UserBufferArg>> userBuffer(Consumer &c,Operation *call) {
    if(!current||current->kind!="uprobe"||!context(c,c.ref(call,"receiver"))||text(call,"kind")!="CallNode"||field(call,"strings","name")!="buf_arg") {
      (void)c.error(call,"user buffer requires a direct buf_arg of the active uprobe context");return failure();
    }
    CalleePolicy policy{"UprobeCtx#buf_arg"};policy.requireCallee=false;
    if(failed(c.known(call,policy)))return failure();auto actual=text(c.evidence[c.id(call)].front(),"callee");
    if(actual!="UprobeCtx#buf_arg") {
      (void)diagnostic(c,call,"SB011","ShadowedName","`buf_arg` resolves to "+actual.str()+", not BPF::UprobeCtx#buf_arg");return failure();
    }
    auto p=parameter(c,call);if(failed(p))return failure();
    if(p->second!="user_buf") {
      auto n=std::to_string(p->first);(void)diagnostic(c,call,"SB028","TracingKind","`"+current->param+".buf_arg("+n+")`: parameter "+n+" is declared :"+p->second+", not :user_buf (E158)");return failure();
    }
    return std::shared_ptr<const UserBufferArg>(std::make_shared<UserBufferArg>(UserBufferArg{p->first,call,current->def}));
  }
  DE expression(Consumer &c,Operation *node) {
    if (!context(c,c.ref(node,"receiver"))) return DE::declined();
    auto name=field(node,"strings","name").str();
    auto bad=[&](const std::string &message) { (void)diagnostic(c,node,"SB028","TracingKind",message);return DE::error(); };
    CalleePolicy policy{""};policy.requireCallee=false;
    if (failed(c.known(node,policy)))return DE::error();
    if (current->kind=="uprobe" && name=="str_arg")
      return bad("`"+current->param+".str_arg(n)` is accepted only as the third argument of `R.output_str(S.new(…), :field, "+current->param+".str_arg(n), :status)` — a user string is not a value on the eBPF side (P020)");
    if(current->kind=="uprobe"&&name=="buf_arg")
      return bad("`"+current->param+".buf_arg(n)` is accepted only as the third argument of `r = R.output_buf(S.new(…), :<u8 array member>, "+current->param+".buf_arg(n), <length>, :<i64 status member>, :<i32 count member>)` then `if r`, or `_ = R.output_buf(…)` — a user buffer is not a value on the eBPF side (E158)");
    bool ret=current->kind=="uretprobe";
    if (name!=(ret ? "ret" : "arg"))
      return bad("the "+current->kind+" context has no `"+name+"` — it reads "+(ret
        ? std::string("`ctx.ret` (the declared return type — the return register; arguments are not readable on return)")
        : std::string("`ctx.arg(n)` (an integer parameter) and `ctx.str_arg(n)` (a :user_str parameter — only as the third argument of `R.output_str`) with n a declared parameter number (1..6)"))+" (P013)");
    auto actual=text(c.evidence[c.id(node)].front(),"callee");
    auto expected=ret ? "UretprobeCtx#ret" : "UprobeCtx#arg";
    if (actual!=expected) {
      (void)diagnostic(c,node,"SB011","ShadowedName","`"+current->param+"."+name+"` resolves to "+quote(actual)+", not BPF::"+expected);return DE::error();
    }
    auto read=std::make_shared<Read>();std::string type=current->ret;
    if (ret) { if (!c.args(node).empty())return bad("probe return read requires no arguments"); }
    else {
      auto param=parameter(c,node);if (failed(param))return DE::error();
      read->n=param->first;type=param->second;
      if (type=="user_str") {auto n=std::to_string(read->n);return bad("`"+current->param+".arg("+n+")`: parameter "+n+" is declared :user_str — read it with `"+current->param+".str_arg("+n+")` as the third argument of `R.output_str` (P020)");}
    }
    if(type=="user_buf") {
      auto n=std::to_string(read->n);return bad("`"+current->param+".arg("+n+")`: parameter "+n+" is declared :user_buf — read it with `"+current->param+".buf_arg("+n+")` as the third argument of `R.output_buf` (E158)");
    }
    if(type=="ptr")type="i64";
    read->type=*integerType(type);auto e=std::make_shared<ScalarExpr>();
    e->kind=ret ? "uprobe.ret" : "uprobe.arg";e->node=node;e->payload=read;
    auto range=tracing::integerRange(read->type.bits,read->type.sign,ret ? tracing::IntegerSource::KprobeReturn : tracing::IntegerSource::Argument);
    if (!range) { (void)c.rangeFailure(range.takeError(),node);return DE::error(); }
    e->range=*range;return DE::handled(e);
  }
};
static Value makeRead(Consumer &c,StringRef name,Type result,int64_t n,Location loc) {
  OperationState state(loc,name);state.addOperands(c.contextValue);state.addTypes(result);
  if (name=="ebpf.uprobe.arg")state.addAttribute("n",c.builder.getI64IntegerAttr(n));
  return c.builder.create(state)->getResult(0);
}
static Dispatch<Value> emit(Consumer &c,const Expr &e) {
  auto p=std::static_pointer_cast<const Read>(e->payload);
  if (!p || !c.contextValue) { (void)c.error(e->node,"uprobe checked metadata/context missing");return Dispatch<Value>::error(); }
  auto loc=outputLoc(e->node);auto raw=makeRead(c,e->kind=="uprobe.ret" ? "ebpf.probe.retval" : "ebpf.uprobe.arg",c.builder.getIntegerType(p->type.bits),p->n,loc);
  if (p->type.bits==64)return Dispatch<Value>::handled(raw);
  bool sign=p->type.sign;
#ifdef SPINEL_E040_TEST_SIGNED_U32
  if (e->kind=="uprobe.arg" && p->n==2 && p->type.bits==32 && !sign)sign=true;
#endif
  return Dispatch<Value>::handled(sign ? arith::ExtSIOp::create(c.builder,loc,c.builder.getI64Type(),raw).getResult() : arith::ExtUIOp::create(c.builder,loc,c.builder.getI64Type(),raw).getResult());
}
static Dispatch<ExportFields> exportProgram(Consumer &c,size_t index,bool) {
  if (index>=c.programs.size())return Dispatch<ExportFields>::error();
  auto &p=c.programs[index];auto d=std::static_pointer_cast<const Declaration>(p.payload);
  if (!d)return Dispatch<ExportFields>::error();
  ExportFields fields;fields.emplace_back("name",p.name);fields.emplace_back("kind",p.kind);fields.emplace_back("attach_target",p.attachTarget);
  std::vector<std::string> maps;for (auto i:p.maps)maps.push_back(c.maps[i].name);
  fields.emplace_back("maps",ExportValue::write([maps](auto &out){out.array([&]{for (auto &m:maps)out.value(m);});}));
  fields.emplace_back("arch",p.arch);
  if (!d->params.empty())fields.emplace_back("params",ExportValue::write([params=d->params](auto &out){out.array([&]{for (auto &p:params)out.object([&]{
    out.attribute("n",p.first);out.attributeBegin("type");out.object([&]{
      if (p.second=="user_str"||p.second=="ptr"||p.second=="user_buf")out.attribute("kind",p.second);
      else {auto t=*integerType(p.second);out.attribute("kind","int");out.attribute("bits",t.bits);out.attribute("signed",t.sign);out.attribute("endianness","little");out.attribute("alignment",t.bits/8);}
    });out.attributeEnd();
  });});}));
  fields.emplace_back("binary_sha256",d->binarySHA);fields.emplace_back("note","Ruby def "+p.name);
  return Dispatch<ExportFields>::handled(std::move(fields));
}
} // namespace
FailureOr<std::shared_ptr<const UserStringArg>> checkedUserString(Consumer &c,Operation *node) {
  if (!c.registry.uprobe || !c.registry.uprobe->checkedUserString) {
    (void)c.error(node,"uprobe user-string check hook is unavailable");return failure();
  }
  return c.registry.uprobe->checkedUserString(c,node);
}
FailureOr<Value> emitUserString(Consumer &c,const UserStringArg &arg,Location loc) {
  if(arg.valueKind!=UserStringValueKind::String) {
    (void)c.error(arg.node,"scalar user-string emission rejects array metadata");return failure();
  }
  if (!c.registry.uprobe || !c.registry.uprobe->emitUserString) {
    (void)c.error(arg.node,"uprobe user-string emit hook is unavailable");return failure();
  }
  return c.registry.uprobe->emitUserString(c,arg,loc);
}
FailureOr<std::shared_ptr<const UserStringArg>> checkedUserStringArray(Consumer &c,Operation *node) {
  if(!c.registry.uprobe||!c.registry.uprobe->checkedUserStringArray||!c.registry.uprobe->emitUserStringArray) {
    (void)c.error(node,"argv check/emit hooks are unavailable or incomplete");return failure();
  }
  return c.registry.uprobe->checkedUserStringArray(c,node);
}
FailureOr<Value> emitUserStringArray(Consumer &c,const UserStringArg &arg,Location loc) {
  if(!c.registry.uprobe||!c.registry.uprobe->checkedUserStringArray||!c.registry.uprobe->emitUserStringArray||arg.valueKind!=UserStringValueKind::Array) {
    (void)c.error(arg.node,"argv emission requires complete hooks and checked array metadata");return failure();
  }
  return c.registry.uprobe->emitUserStringArray(c,arg,loc);
}
FailureOr<std::shared_ptr<const UserBufferArg>> checkedUserBuffer(Consumer &c,Operation *node) {
  if(!c.registry.uprobe||!c.registry.uprobe->checkedUserBuffer||!c.registry.uprobe->emitUserBuffer) {
    (void)c.error(node,"user-buffer check/emit hooks are unavailable or incomplete");return failure();
  }
  return c.registry.uprobe->checkedUserBuffer(c,node);
}
FailureOr<Value> emitUserBuffer(Consumer &c,const UserBufferArg &arg,Location loc) {
  if(!c.registry.uprobe||!c.registry.uprobe->checkedUserBuffer||!c.registry.uprobe->emitUserBuffer) {
    (void)c.error(arg.node,"user-buffer check/emit hooks are unavailable or incomplete");return failure();
  }
  return c.registry.uprobe->emitUserBuffer(c,arg,loc);
}
void registerGroupGUprobe(Registry &registry) {
  auto state=std::make_shared<Uprobe>();registry.uprobe=std::make_shared<UprobeHooks>();
  registry.uprobe->checkedUserBuffer=[state](Consumer &c,Operation *node){return state->userBuffer(c,node);};
  registry.uprobe->emitUserBuffer=[state](Consumer &c,const UserBufferArg &arg,Location loc)->FailureOr<Value>{
    if(c.probing||!state->current||state->current->kind!="uprobe"||c.activeKind!="uprobe"||!c.contextValue||c.contextValue.getType()!=ebpf::ContextType::get(c.ctx,"uprobe")||
       !arg.node||arg.n<1||arg.n>6||arg.def!=state->current->def||c.activeDef!=arg.def||
       !state->context(c,c.ref(arg.node,"receiver"))||field(arg.node,"strings","name")!="buf_arg") {
      (void)c.error(arg.node,"user-buffer emission requires matching checked uprobe metadata and a non-Probe context");return failure();
    }
    auto as=c.args(arg.node);auto number=as.size()==1?c.integer(as[0]):FailureOr<int64_t>(failure());
    if(failed(number)||*number!=arg.n||!llvm::any_of(state->current->params,[&](const auto &p){return p.first==arg.n&&p.second=="user_buf";})) {
      (void)c.error(arg.node,"user-buffer emission parameter does not match the checked declaration");return failure();
    }
    return makeRead(c,"ebpf.uprobe.arg",ebpf::UserBufType::get(c.ctx),arg.n,loc);
  };
  registry.uprobe->checkedUserString=[state](Consumer &c,Operation *node){return state->userString(c,node);};
  registry.uprobe->emitUserString=[state](Consumer &c,const UserStringArg &arg,Location loc)->FailureOr<Value>{
    if (c.probing || c.activeKind!="uprobe" || arg.source!=UserStringSource::Uprobe || arg.valueKind!=UserStringValueKind::String ||
        !c.contextValue || !arg.node || arg.n<1 || arg.n>6 || !state->current ||
        arg.def!=state->current->def || c.activeDef!=state->current->def ||
        !state->context(c,c.ref(arg.node,"receiver")) ||
        !llvm::any_of(state->current->params,[&](const auto &p){return p.first==arg.n && p.second=="user_str";})) {
      (void)c.error(arg.node,"uprobe user-string emission requires checked metadata and active context");return failure();
    }
    return makeRead(c,"ebpf.uprobe.arg",ebpf::UserStrType::get(c.ctx),arg.n,loc);
  };
  for (auto kind:{"uprobe","uretprobe"})registry.addRoot(kind,[state](Consumer &c,Operation *n){return state->root(c,n);});
  registry.addExpression("CallNode",[state](Consumer &c,Operation *n){return state->expression(c,n);});
  for (auto kind:{"uprobe.arg","uprobe.ret"})registry.addEmitter(kind,emit);
  for (auto kind:{"uprobe","uretprobe"})registry.addProgramExporter(kind,exportProgram);
}
} // namespace spinel::consumer
