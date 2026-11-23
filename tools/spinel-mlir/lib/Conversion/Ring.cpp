// E029: group D's ring buffer — the RingBuf declaration, `R.output(S.new(…))`
// (reserve → if_reserved → store_record → submit) and how its result may be
// consumed (SB025). Go: ring.go, program.go:325-330/425-433/942-947,
// lower.go:678-744, schema.go:72/219/321, analyze.go:695-707.
#include "spinel/Conversion/Ring.h"
#include "spinel/Conversion/GroupGUprobe.h"
#include "spinel/Conversion/Argv.h"
#include "spinel/Conversion/KernelRecordAccess.h"
#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "mlir/Dialect/Arith/IR/Arith.h"

namespace spinel::consumer {
namespace {
constexpr const char *kOutputKind = "e029.ringout";
// E039: `R.output_str(…)` with a user string (`ctx.str_arg(n)`).
constexpr const char *kOutputStrKind = "e039.ringout-str";
constexpr const char *kOutputArgvKind = "e071.ringout-argv";
// E039: c.bindings key of an output_str result local (source: the write,
// analyzed: the `if r` right after it).
const std::string kOutputStrBinding = "ring.ostr:";

// E039: the user string read into the reservation (Go uprobe.go:306-427).
struct OutputStrValue : CheckedRecordValue {
  std::shared_ptr<const UserStringArg> user;
  std::shared_ptr<const UserBufferArg> buffer;
  Expr length;
  int64_t countOffset=0;
  std::string path;
  int64_t statusOffset = 0;
  // E045: output_str_or_discard — a negative read status discards the event
  // instead of submitting it (Go uprobe.go:336-375).
  bool discard = false;
  bool comm = false; // E066: current task, without a user-string operand.
};
struct OutputArgvValue : OutputStrValue {
  std::shared_ptr<const UserStringArg> array;
  int64_t indexOffset=0;
};
struct ArgvIndex { int64_t offset,slot; };
bool isOutputArgv(Operation *n) {return field(n,"strings","name")=="output_argv";}

// Which results the reservation's if_reserved yields.
enum class OutputResults { None, Bool, BoolStatus };

size_t findRing(const Consumer &c, StringRef constant) {
  for (size_t i = 0; i < c.rings.size(); ++i)
    if (c.rings[i].constant == constant)
      return i;
  return SIZE_MAX;
}

// `output_str` and its discarding variant (E045 — Go uprobe.go:120).
bool isOutputStr(Operation *n) {
  auto name = field(n, "strings", "name");
  return name == "output_str" || name == "output_str_or_discard" ||
         name == "output_comm" || name == "output_buf";
}

// The ring an `R.output` call names, or SIZE_MAX.
size_t outputRing(Consumer &c, Operation *n) {
  if (!n || text(n, "kind") != "CallNode" ||
      (field(n, "strings", "name") != "output" && !isOutputStr(n) && !isOutputArgv(n)))
    return SIZE_MAX;
  auto recv = c.ref(n, "receiver");
  if (!recv || text(recv, "kind") != "ConstantReadNode")
    return SIZE_MAX;
  return findRing(c, field(recv, "strings", "name"));
}

// Go's outputOfBadRing: the declaration was already rejected, so the use is
// not rejected again (reason priority 1).
bool outputOfBadRing(Consumer &c, Operation *n) {
  if (!n || text(n, "kind") != "CallNode")
    return false;
  if (field(n, "strings", "name") != "output" && !isOutputStr(n) && !isOutputArgv(n))
    return false;
  auto recv = c.ref(n, "receiver");
  return recv && text(recv, "kind") == "ConstantReadNode" &&
         c.badRings.count(field(recv, "strings", "name").str());
}

std::string droppedMessage(const RingDecl &r) {
  return "the result of " + r.constant +
         ".output (false when the ring is full) is dropped — use it as an "
         "`if` / `unless` condition (count drops in the false arm) or write "
         "`_ = " +
         r.constant +
         ".output(…)` to choose not to count them (P007 §2)";
}
std::string outputStrShape(const RingDecl &r, StringRef method = "output_str") {
  if (method == "output_comm")
    return "`r = " + r.constant + ".output_comm(" + r.layout->name +
        ".new(…), :<[:u8, 16] member>, :<i64 status member>)` then `if r` (read `r.status` inside), or `_ = " + r.constant + ".output_comm(…)` (E145)";
  return "`r = " + r.constant + ".output_str(" + r.layout->name +
      ".new(…), :<u8 array member>, ctx.str_arg(n), :<i64 status member>)` then `if r` (read `r.status` inside), or `_ = " + r.constant + ".output_str(…)` (P020)";
}

// Go's outputIsCondition: the call is an if / unless predicate itself, with
// at most one `!` in between.
bool outputIsCondition(Consumer &c, Operation *n) {
  Operation *p = c.parent(n);
  if (p && text(p, "kind") == "CallNode" && field(p, "strings", "name") == "!" &&
      c.ref(p, "receiver") == n) {
    n = p;
    p = c.parent(p);
  }
  if (!p)
    return false;
  auto kind = text(p, "kind");
  return (kind == "IfNode" || kind == "UnlessNode") &&
         c.ref(p, "predicate") == n;
}

// Go's ringDecl: `C = BPF::RingBuf.new("C", S.new(0, …), size)`.
Dispatch<bool> declareRing(Consumer &c, Operation *n) {
  auto call = c.ref(n, "value");
  auto constName = field(n, "strings", "name").str();
  c.badRings.insert(constName);
  bool mapNamed = llvm::any_of(
      c.maps, [&](const MapDecl &m) { return m.name == constName; });
  if (mapNamed || findRing(c, constName) != SIZE_MAX)
    return (void)c.diagnostic(n, "SB013", "MapDeclShape",
                              "constant " + constName + " is assigned twice"),
           Dispatch<bool>::error();
  auto as = c.args(call);
  if (as.size() == 3 && text(as[1], "kind") == "CallNode" &&
      recordDeclarationFailed(c, c.constant(c.ref(as[1], "receiver"))))
    return Dispatch<bool>::error(); // the record was already rejected
  std::string sampleShape = "the sample must be `S.new(0, …)` of a record S "
                            "declared with BPF.record (P007 §1)";
  if (as.size() == 3 && text(as[0], "kind") == "StringNode" &&
      text(as[2], "kind") == "IntegerNode" &&
      text(as[1], "kind") != "CallNode")
    return (void)c.diagnostic(as[1], "SB024", "RecordShape", sampleShape),
           Dispatch<bool>::error();
  if (as.size() != 3 || text(as[0], "kind") != "StringNode" ||
      text(as[1], "kind") != "CallNode" || text(as[2], "kind") != "IntegerNode")
    return (void)c.diagnostic(
               n, "SB013", "MapDeclShape",
               "a ring buffer is declared as `" + constName +
                   " = BPF::RingBuf.new(\"" + constName +
                   "\", S.new(0, …), size)` with literal arguments"),
           Dispatch<bool>::error();
  auto name = c.spelling(as[0], false).str();
  if (name != constName)
    return (void)c.diagnostic(as[0], "SB013", "MapDeclShape",
                              "the ring buffer name \"" + name +
                                  "\" differs from its constant " + constName),
           Dispatch<bool>::error();
  for (const auto &m : c.maps)
    if (m.name == name)
      return (void)c.diagnostic(n, "SB013", "MapDeclShape",
                                "a map and a ring buffer use the name \"" +
                                    name + "\""),
             Dispatch<bool>::error();
  for (const auto &r : c.rings)
    if (r.name == name)
      return (void)c.diagnostic(n, "SB013", "MapDeclShape",
                                "two ring buffer declarations use the name \"" +
                                    name + "\""),
             Dispatch<bool>::error();
  auto sample = as[1];
  auto sampleConst = c.constant(c.ref(sample, "receiver"));
  auto layout = lookupRecordLayout(c, sampleConst);
  if (field(sample, "strings", "name") != "new" || !layout)
    return (void)c.diagnostic(sample, "SB024", "RecordShape", sampleShape),
           Dispatch<bool>::error();
  auto sas = c.args(sample);
  if (sas.size() != layout->fields.size())
    return (void)c.diagnostic(sample, "SB024", "RecordShape",
                              "the sample must give all " +
                                  std::to_string(layout->fields.size()) +
                                  " members of " + sampleConst +
                                  " explicitly (upstream_suspects S5)"),
           Dispatch<bool>::error();
  if (failed(checkRecordSample(c, sas, *layout,
                               "the sample's members must be the literal 0 — "
                               "it is a sample of the type (P007 §1)",
                               SampleSite::RingEvent)))
    return Dispatch<bool>::error();
  auto size = c.integer(as[2]);
  if (failed(size))
    return Dispatch<bool>::error();
  uint64_t s = uint64_t(*size);
  if (*size < 4096 || s > (uint64_t(1) << 31) || (s & (s - 1)) != 0)
    return (void)c.diagnostic(
               as[2], "SB013", "MapDeclShape",
               "the ring buffer size must be a power of two of at least 4096 "
               "bytes (the x86_64 page) and at most 2^31, got " +
                   std::to_string(*size) + " (P007 §1)"),
           Dispatch<bool>::error();
  if (StringRef(name).starts_with("spinelbpf_"))
    return (void)c.diagnostic(n, "SB007", "ReservedName",
                              "ring buffer name \"" + name +
                                  "\" uses the reserved prefix spinelbpf_"),
           Dispatch<bool>::error();
  c.badRings.erase(constName);
  RingDecl r;
  r.constant = constName;
  r.name = name;
  r.layout = layout;
  r.size = s;
  r.node = n;
  c.rings.push_back(std::move(r));
  return Dispatch<bool>::handled(true);
}

static std::string outputBufForm(StringRef parameter) {
  return "`r = R.output_buf(S.new(…), :<u8 array member>, "+parameter.str()+".buf_arg(n), <length>, :<i64 status member>, :<i32 count member>)` then `if r`, or `_ = R.output_buf(…)`";
}
FailureOr<std::shared_ptr<const CheckedRecordValue>>
checkOutputBuf(Consumer &c,Operation *call,const RingDecl &r) {
  using R=FailureOr<std::shared_ptr<const CheckedRecordValue>>;
  auto bad=[&](Operation *at,StringRef code,const std::string &message)->R {
    (void)c.diagnostic(at,code,code=="SB028"?"TracingKind":code=="SB011"?"ShadowedName":"RecordShape",message,true);return failure();
  };
  if(c.activeKind!="uprobe")return bad(call,"SB028","`"+r.constant+".output_buf` reads a user buffer (`ctx.buf_arg(n)` of a :user_buf parameter in a uprobe program) — a "+c.activeKind+" program has none (E158)");
  CalleePolicy policy{"RingBuf#output_buf"};policy.requireCallee=false;
  if(failed(c.known(call,policy)))return failure();auto actual=text(c.evidence[c.id(call)].front(),"callee");
  if(actual!="RingBuf#output_buf")return bad(call,"SB011","`output_buf` resolves to "+actual.str()+", not BPF::RingBuf#output_buf");
  auto parameters=c.activeDef?c.array(c.ref(c.activeDef,"parameters"),"requireds"):SmallVector<Operation *>{};
  if(parameters.size()!=1)return (void)c.error(call,"output_buf requires the active context parameter"),failure();
  auto parameter=field(parameters[0],"strings","name").str();auto as=c.args(call);
  if(as.size()!=6)return bad(call,"SB024","output_buf takes six arguments — "+outputBufForm(parameter)+" (E158)");
  auto member=[&](Operation *n)->const record::FieldLayout*{if(text(n,"kind")!="SymbolNode")return nullptr;auto name=c.spelling(n,true);for(auto &f:r.layout->fields)if(f.name==name)return &f;return nullptr;};
  auto target=member(as[1]),status=member(as[4]),count=member(as[5]);
  if(!target||!target->count||target->bits!=8||target->isSigned)return bad(as[1],"SB024","the buffer member of output_buf must be a :u8 array member of "+r.layout->name+" (`data: [:u8, 64]` — bpf-mlir's user.read fills a 1-dimensional 8-bit array) (E158)");
  if(!status||status->count||status->bits!=64||!status->isSigned)return bad(as[4],"SB024","the status member of output_buf must be an :i64 member of "+r.layout->name+" (the raw status of probe_read_user — 0 or a negative errno) (E158)");
  if(!count||count->count||count->bits!=32||!count->isSigned)return bad(as[5],"SB024","the count member of output_buf must be an :i32 member of "+r.layout->name+" (the clamped length max(0, min(length, N)) — not the bytes read) (E158)");
  auto receiver=c.ref(as[2],"receiver");
  if(text(as[2],"kind")!="CallNode"||field(as[2],"strings","name")!="buf_arg"||text(receiver,"kind")!="LocalVariableReadNode"||field(receiver,"strings","name")!=parameter)
    return bad(as[2],"SB028","the third argument of output_buf is `"+parameter+".buf_arg(n)` itself (a user buffer is not a value on the eBPF side — not through a local) (E158)");
  auto buffer=checkedUserBuffer(c,as[2]);if(failed(buffer))return failure();
  auto length=c.scalar(as[3]);if(failed(length))return failure();
  auto make=as[0];
  if(text(make,"kind")=="CallNode"&&field(make,"strings","name")=="new"&&c.constant(c.ref(make,"receiver"))==r.layout->name) {
    auto values=c.args(make);size_t i=status-r.layout->fields.data();
    if(i<values.size()&&(text(values[i],"kind")!="IntegerNode"||text(values[i],"literal_decimal")!="0"))
      return bad(values[i],"SB024","the status member "+status->name+" is written by output_buf — give the literal 0 in "+r.layout->name+".new (P020)");
  }
  auto value=checkRecordMake(c,make,r.layout,RecordDestination{r.name,RecordDestination::Kind::Ring,""});if(failed(value))return failure();
  auto checked=std::make_shared<OutputStrValue>();static_cast<CheckedRecordValue&>(*checked)=**value;
  checked->buffer=*buffer;checked->length=*length;checked->path=target->name;checked->statusOffset=status->offset;checked->countOffset=count->offset;
  return std::shared_ptr<const CheckedRecordValue>(checked);
}

// E039: Go's outputStr (uprobe.go:129-198) — the checks the user and the
// kernel string share, in Go's order and words. A kernel string (`q.str(:m)`)
// then goes to group G's checkKernelRingString (E020) unchanged; a user string
// to E040's checkedUserString, then the status literal 0 and the event.
FailureOr<std::shared_ptr<const CheckedRecordValue>>
checkOutputStr(Consumer &c, Operation *call, const RingDecl &r) {
  using Result = FailureOr<std::shared_ptr<const CheckedRecordValue>>;
  auto reject = [&](Operation *at, StringRef code, StringRef label,
                    const std::string &message) -> Result {
    (void)c.diagnostic(at, code, label, message, true);
    return failure();
  };
  auto as = c.args(call);
  auto meth = field(call, "strings", "name").str();
  if(meth=="output_buf")return checkOutputBuf(c,call,r);
  bool comm = meth == "output_comm";
  bool kernelString = as.size() >= 3 && text(as[2], "kind") == "CallNode" &&
                      field(as[2], "strings", "name") == "str";
  if (!comm && c.activeKind != "uprobe" && c.activeKind != "tracepoint" &&
      c.activeKind != "ksyscall" && !kernelString)
    return reject(call, "SB028", "TracingKind",
                  "`" + r.constant + "." + meth +
                      "` reads a user string (`ctx.str_arg(n)` in a uprobe or ksyscall program, "
                      "`ctx.str_field(:f)` in a tracepoint program), or a kernel string (`q.str(:m)` — a "
                      ":strptr member of a present kernel pointer) (P020 / P026 / E142 / E143)");
  CalleePolicy policy;
  policy.expected = "RingBuf#" + meth;
  policy.requireCallee = false;
  if (failed(c.known(call, policy)))
    return failure();
  auto callee = text(c.evidence[c.id(call)].front(), "callee");
  if (callee != "RingBuf#" + meth)
    return reject(call, "SB011", "ShadowedName",
                  "`" + meth + "` resolves to " + callee.str() +
                      ", not BPF::RingBuf#" + meth);
  auto member = [&](Operation *x) -> const record::FieldLayout * {
    if (!x || text(x, "kind") != "SymbolNode")
      return nullptr;
    auto name = c.spelling(x, true);
    for (const auto &f : r.layout->fields)
      if (f.name == name)
        return &f;
    return nullptr;
  };
  if (comm) {
    if (as.size() == 2 || (as.size() == 3 && !member(as[2])))
      return reject(call, "SB024", "RecordShape",
                    "output_comm needs a status member: add `status: :i64` to BPF.record(" + r.layout->name +
                        ", …) and pass it as the third argument — the raw status of bpf_get_current_comm (E145) — " + outputStrShape(r, meth));
    if (as.size() != 3)
      return reject(call, "SB002", "UnsupportedCall", "output_comm takes three arguments — " + outputStrShape(r, meth));
    auto target = member(as[1]), status = member(as[2]);
    if (!target || target->padding || target->count != 16 || target->bits != 8 || target->isSigned)
      return reject(as[1], "SB024", "RecordShape", "the comm member of output_comm must be a [:u8, 16] member of " + r.layout->name + " (TASK_COMM_LEN — bpf_get_current_comm fills 16 bytes) (E145)");
    if (status->padding || status->count || status->bits != 64 || !status->isSigned)
      return reject(as[2], "SB024", "RecordShape", "the status member " + status->name + " of output_comm must be :i64 (the raw status of bpf_get_current_comm) (E145)");
    auto make = as[0];
    if (text(make, "kind") == "CallNode" && field(make, "strings", "name") == "new" && c.constant(c.ref(make, "receiver")) == r.layout->name) {
      auto values = c.args(make);
      size_t index = status - r.layout->fields.data();
      if (index < values.size() && (text(values[index], "kind") != "IntegerNode" || text(values[index], "literal_decimal") != "0"))
        return reject(values[index], "SB024", "RecordShape", "the status member " + status->name + " is written by output_comm — give the literal 0 in " + r.layout->name + ".new (P020)");
    }
    auto value = checkRecordMake(c, make, r.layout, RecordDestination{r.name, RecordDestination::Kind::Ring, ""});
    if (failed(value)) return failure();
    auto checked = std::make_shared<OutputStrValue>();
    static_cast<CheckedRecordValue &>(*checked) = **value;
    checked->comm = true;
    checked->path = target->name;
    checked->statusOffset = status->offset;
    return std::shared_ptr<const CheckedRecordValue>(checked);
  }
  if (as.size() == 3 || (as.size() == 4 && !member(as[3])))
    return reject(call, "SB024", "RecordShape",
                  meth + " needs a status member: add `status: :i64` to "
                         "BPF.record(" + r.layout->name +
                      ", …) and pass it as the fourth argument — a failed "
                      "read leaves the string member zeroed, the same bytes "
                      "as an empty string, so only the status tells them "
                      "apart (go-bpf-mlir E158) — " + outputStrShape(r));
  if (as.size() != 4)
    return reject(call, "SB002", "UnsupportedCall",
                  "output_str takes four arguments — " + outputStrShape(r));
  auto target = member(as[1]), status = member(as[3]);
  if (!target || target->padding || !target->count || target->bits != 8 ||
      target->isSigned)
    return reject(as[1], "SB024", "RecordShape",
                  "the string member of output_str must be a :u8 array "
                  "member of " + r.layout->name +
                      " (`name: [:u8, 32]` — bpf-mlir's user.read_str fills "
                      "a 1-dimensional 8-bit array) (P020)");
  if (status->padding || status->count || status->bits != 64 ||
      !status->isSigned)
    return reject(as[3], "SB024", "RecordShape",
                  "the status member " + status->name +
                      " of output_str must be :i64 (the raw status of "
                      "probe_read_user_str — length with NUL, or a negative "
                      "errno) (P020)");
  if (kernelString && meth != "output_str")
    return (void)c.error(call, "a kernel-string " + meth +
                                   " is not supported (E045)"),
           failure();
  if (kernelString)
    return checkKernelRingString(c, call, r);
  auto hooks = c.registry.uprobe;
  if (!hooks || !hooks->checkedUserString || !hooks->emitUserString)
    return (void)c.error(call, "a user string output_str requires the uprobe "
                               "hooks (E040)"),
           failure();
  auto user = checkedUserString(c, as[2]);
  if (failed(user))
    return failure();
  // Go's outputStrMake: the status member is written by the read.
  auto make = as[0];
  if (text(make, "kind") == "CallNode" &&
      field(make, "strings", "name") == "new" &&
      c.constant(c.ref(make, "receiver")) == r.layout->name) {
    auto values = c.args(make);
    size_t index = status - r.layout->fields.data();
    if (index < values.size() &&
        (text(values[index], "kind") != "IntegerNode" ||
         text(values[index], "literal_decimal") != "0"))
      return reject(values[index], "SB024", "RecordShape",
                    "the status member " + status->name +
                        " is written by output_str — give the literal 0 in " +
                        r.layout->name + ".new (P020)");
  }
  auto value = checkRecordMake(
      c, make, r.layout,
      RecordDestination{r.name, RecordDestination::Kind::Ring, ""});
  if (failed(value))
    return failure();
  auto checked = std::make_shared<OutputStrValue>();
  static_cast<CheckedRecordValue &>(*checked) = **value;
  checked->user = *user;
  checked->path = target->name;
  checked->statusOffset = status->offset;
  checked->discard = meth == "output_str_or_discard";
  return std::shared_ptr<const CheckedRecordValue>(checked);
}

FailureOr<std::shared_ptr<const CheckedRecordValue>>
checkOutputArgv(Consumer &c,Operation *call,const RingDecl &r) {
  using R=FailureOr<std::shared_ptr<const CheckedRecordValue>>;
  auto bad=[&](Operation *n,StringRef code,const std::string &m)->R {
    (void)c.diagnostic(n,code,code=="SB028"?"TracingKind":code=="SB011"?"ShadowedName":"RecordShape",m,true);return failure();
  };
  bool tp=c.activeKind=="tracepoint";
  if(!tp&&c.activeKind!="ksyscall")return bad(call,"SB028","`"+r.constant+".output_argv` reads an argv array (`ctx.argv_arg(n)` in a ksyscall program, `ctx.argv_field(:f)` in a tracepoint program) — a "+c.activeKind+" program has none (E151)");
  CalleePolicy policy{"RingBuf#output_argv"};policy.requireCallee=false;
  if(failed(c.known(call,policy)))return failure();
  auto callee=text(c.evidence[c.id(call)].front(),"callee");
  if(callee!="RingBuf#output_argv")return bad(call,"SB011","`output_argv` resolves to "+callee.str()+", not BPF::RingBuf#output_argv");
  auto as=c.args(call);auto src=tp?"ctx.argv_field(:f)":"ctx.argv_arg(n)";
  if(as.size()!=5)return bad(call,"SB024","output_argv takes five arguments — `_ = "+r.constant+".output_argv("+r.layout->name+".new(…), :<u8 array member>, "+src+", :<i64 status member>, :<u32 index member>)` (E151)");
  auto member=[&](Operation *n)->const record::FieldLayout * {
    if(text(n,"kind")!="SymbolNode")return nullptr;
    for(auto &f:r.layout->fields)if(f.name==c.spelling(n,true))return &f;return nullptr;
  };
  auto target=member(as[1]),status=member(as[3]),index=member(as[4]);
  if(!target||!target->count||target->bits!=8||target->isSigned)return bad(as[1],"SB024","the string member of output_argv must be a :u8 array member of "+r.layout->name+" (`arg: [:u8, 64]`) (E151)");
  if(!status||status->count||status->bits!=64||!status->isSigned)return bad(as[3],"SB024","the status member of output_argv must be an :i64 member of "+r.layout->name+" (the raw status of probe_read_user_str) (E151)");
  if(!index||index->count||index->bits!=32||index->isSigned)return bad(as[4],"SB024","the index member of output_argv must be a :u32 member of "+r.layout->name+" (the argv slot 0..19) (E151)");
  auto make=as[0];
  if(text(make,"kind")=="CallNode"&&field(make,"strings","name")=="new"&&c.constant(c.ref(make,"receiver"))==r.layout->name) {
    auto values=c.args(make);size_t i=status-r.layout->fields.data();
    if(i<values.size()&&(text(values[i],"kind")!="IntegerNode"||text(values[i],"literal_decimal")!="0"))
      return bad(values[i],"SB024","the status member "+status->name+" is written by output_argv — give the literal 0 in "+r.layout->name+".new (P020)");
  }
  auto made=checkRecordMake(c,make,r.layout,RecordDestination{r.name,RecordDestination::Kind::Ring,""});
  if(failed(made))return failure();
  auto array=checkedUserStringArray(c,as[2]);if(failed(array))return failure();
  auto p=std::make_shared<OutputArgvValue>();static_cast<CheckedRecordValue&>(*p)=**made;
  p->array=*array;p->path=target->name;p->statusOffset=status->offset;p->indexOffset=index->offset;
  return std::shared_ptr<const CheckedRecordValue>(p);
}

// Go's ringOutput (check side): the callee, the arity and the event value.
Dispatch<Expr> checkOutput(Consumer &c, Operation *n, size_t ri) {
  auto &r = c.rings[ri];
  if(isOutputArgv(n)) {
    auto p=checkOutputArgv(c,n,r);if(failed(p))return Dispatch<Expr>::error();
    r.used=true;auto e=std::make_shared<ScalarExpr>();e->node=n;e->map=ri;e->payload=*p;e->kind=kOutputArgvKind;
    return Dispatch<Expr>::handled(e);
  }
  if (isOutputStr(n)) {
    auto value = checkOutputStr(c, n, r);
    if (failed(value)) return Dispatch<Expr>::error();
    r.used = true;
    auto e = std::make_shared<ScalarExpr>();
    e->node = n; e->map = ri; e->payload = *value;
    // A kernel string always brings its read as a reservation write (E020);
    // a user string's payload is an OutputStrValue with none.
    e->kind = field(n, "strings", "name") == "output_comm" ||
                      (*value)->reservationWrites.empty()
                  ? kOutputStrKind : kOutputKind;
    for (const auto &m : (*value)->members)
      if (m) e->reads.insert(e->reads.end(), m->reads.begin(), m->reads.end());
    if(field(n,"strings","name")=="output_buf") {
      auto checked=std::static_pointer_cast<const OutputStrValue>(*value);
      e->reads.insert(e->reads.end(),checked->length->reads.begin(),checked->length->reads.end());
    }
    return Dispatch<Expr>::handled(e);
  }
  CalleePolicy policy;
  policy.expected = "RingBuf#output";
  policy.requireCallee = false;
  if (failed(c.known(n, policy)))
    return Dispatch<Expr>::error();
  auto callee = text(c.evidence[c.id(n)].front(), "callee");
  if (callee != "RingBuf#output")
    return (void)c.diagnostic(n, "SB011", "ShadowedName",
                              "`output` resolves to " + callee.str() +
                                  ", not BPF::RingBuf#output",
                              true),
           Dispatch<Expr>::error();
  auto as = c.args(n);
  if (as.size() != 1)
    return (void)c.diagnostic(n, "SB002", "UnsupportedCall",
                              "`" + r.constant + ".output` takes one event (`" +
                                  r.layout->name + ".new(…)`)",
                              true),
           Dispatch<Expr>::error();
  auto value = checkRecordMake(
      c, as[0], r.layout,
      RecordDestination{r.name, RecordDestination::Kind::Ring, ""});
  if (failed(value))
    return Dispatch<Expr>::error();
  r.used = true;
  auto e = std::make_shared<ScalarExpr>();
  e->node = n;
  e->kind = kOutputKind;
  e->map = ri;
  e->payload = *value;
  for (const auto &m : (*value)->members)
    if (m)
      e->reads.insert(e->reads.end(), m->reads.begin(), m->reads.end());
  e->range.isBool = true;
  return Dispatch<Expr>::handled(e);
}

// Go's lowerer.ringOutput: reserve → if_reserved { store_record → submit }.
// With a result, present yields true and absent false; `_ =` has none. Every
// op takes `loc`: the call's as a condition, the `_ =` statement's otherwise
// (Go's Stmt pos — stop A).
// E039: a user string's output_str first takes the string (uprobe.arg, before
// the reserve), then reads it into the stored event and writes the read's
// status to the status member; with BoolStatus present yields (true, status)
// and absent (false, 0) (Go uprobe.go:306-427).
FailureOr<Operation *> emitReservation(Consumer &c, const ScalarExpr &e,
                                       OutputResults results, Location loc,
                                       Value stringSSA={},std::optional<ArgvIndex> index=std::nullopt) {
  auto &r = c.rings[e.map];
  auto checked = std::static_pointer_cast<const CheckedRecordValue>(e.payload);
  auto &b = c.builder;
  auto *ctx = b.getContext();
  std::shared_ptr<const OutputStrValue> str;
  Value userString,bufferLength;
  if(e.kind==kOutputArgvKind) {
    if(!stringSSA||!isa<ebpf::UserStrType>(stringSSA.getType())||!index||index->slot<0||index->slot>19) {
      (void)c.error(e.node,"argv event requires its present string and fixed slot metadata");return failure();
    }
    str=std::static_pointer_cast<const OutputArgvValue>(e.payload);userString=stringSSA;
  }
  if (e.kind == kOutputStrKind) {
    str = std::static_pointer_cast<const OutputStrValue>(e.payload);
    if(str->buffer) {
      bufferLength=c.emitScalar(str->length);if(!bufferLength)return failure();
      auto buffer=emitUserBuffer(c,*str->buffer,loc);if(failed(buffer))return failure();userString=*buffer;
#ifdef SPINEL_E080_TEST_BUFFER_LEN_ZERO
      bufferLength=arith::ConstantOp::create(b,loc,b.getIntegerAttr(bufferLength.getType(),0));
#endif
    }
#ifndef SPINEL_E039_TEST_STR_IN_PRESENT
    if (!str->comm && !str->buffer) {
    auto s = emitUserString(c, *str->user, loc);
    if (failed(s))
      return failure();
    userString = *s;
    }
#endif
  }
  auto rec = ebpf::RecordType::get(ctx, r.layout->name, r.layout->size);
  auto reservation = ebpf::ReservationType::get(ctx, rec);
  auto maybe = ebpf::RingbufReserveOp::create(
      b, loc, ebpf::MaybeReservationType::get(ctx, rec), r.name);
  SmallVector<Type> types;
  if (results != OutputResults::None)
    types.push_back(b.getI1Type());
  bool discard = str && str->discard;
  if (results == OutputResults::BoolStatus)
    types.push_back(b.getI64Type());
  if (results == OutputResults::BoolStatus && discard)
    types.push_back(b.getI1Type()); // r.sent
  auto op = ebpf::RingbufIfReservedOp::create(b, loc, types, maybe);
  bool present = true, absent = false;
#ifdef SPINEL_E029_TEST_RING_POLARITY
  std::swap(present, absent); // E029 H6 M-ring-polarity (test build only)
#endif
  {
    OpBuilder::InsertionGuard guard(b);
    auto *yes = new Block();
    op.getPresentRegion().push_back(yes);
    // Go's block argument has no location (stop A).
    Value res = yes->addArgument(reservation, b.getUnknownLoc());
    b.setInsertionPointToStart(yes);
#ifdef SPINEL_E039_TEST_STR_IN_PRESENT
    if (e.kind==kOutputStrKind && str && !str->comm && !str->buffer) { // E039 H6 M-str-in-present (test build only)
      auto s = emitUserString(c, *str->user, loc);
      if (failed(s))
        return failure();
      userString = *s;
    }
#endif
    CheckedRecordValue value = *checked;
#ifdef SPINEL_E029_TEST_RING_FIELD_SWAP
    if (value.members.size() >= 2) // E029 H6 M-ring-field-swap (test only)
      std::swap(value.members[0], value.members[1]);
#endif
    auto made = emitRecordMake(c, value);
    if (failed(made))
      return failure();
    ebpf::RingbufStoreRecordOp::create(b, loc, res, *made);
    if(index) {
      int64_t k=index->slot;
#ifdef SPINEL_E071_TEST_ARGV_INDEX_SHIFT
      ++k;
#endif
      auto value=arith::ConstantIntOp::create(b,loc,k,32);
      ebpf::RingbufStoreFieldOp::create(b,loc,res,value,index->offset);
    }
    for (const auto &write : value.reservationWrites)
      if (failed(write(c, res, loc))) return failure();
    Value status;
    if (str) {
      if(str->buffer) {
        auto read=ebpf::UserReadOp::create(b,loc,b.getI64Type(),b.getI32Type(),res,str->path,userString,bufferLength);
        status=read.getStatus();ebpf::RingbufStoreFieldOp::create(b,loc,res,read.getCount(),str->countOffset);
      } else
      if (str->comm)
        status = ebpf::TaskCommOp::create(b, loc, b.getI64Type(), res, str->path);
      else
        status = ebpf::UserReadStrOp::create(b, loc, b.getI64Type(), res,
                                             str->path, userString);
      ebpf::RingbufStoreFieldOp::create(b, loc, res, status,
                                        str->statusOffset);
    }
    Value sent;
    if (discard) {
      // E045: discard on a negative read status, submit otherwise; with a
      // result, the arm yields whether it submitted (Go uprobe.go:336-375).
      auto zero = arith::ConstantIntOp::create(b, loc, 0, 64);
#ifdef SPINEL_E045_TEST_DISCARD_SGE
      auto predicate = arith::CmpIPredicate::sge; // E045 H6 (test build only)
#else
      auto predicate = arith::CmpIPredicate::slt;
#endif
      auto negative = arith::CmpIOp::create(b, loc, predicate, status, zero);
      bool withSent = results == OutputResults::BoolStatus;
      SmallVector<Type> sentTypes;
      if (withSent)
        sentTypes.push_back(b.getI1Type());
      auto branch = ebpf::IfOp::create(b, loc, sentTypes, negative);
      for (bool submitted : {false, true}) {
        OpBuilder::InsertionGuard arm(b);
        auto *block = new Block();
        branch->getRegion(submitted ? 1 : 0).push_back(block);
        b.setInsertionPointToStart(block);
        if (submitted)
          ebpf::RingbufSubmitOp::create(b, loc, res);
        else
          ebpf::RingbufDiscardOp::create(b, loc, res);
        SmallVector<Value> armYield;
        if (withSent)
          armYield.push_back(
              arith::ConstantIntOp::create(b, loc, submitted, 1));
        ebpf::IfYieldOp::create(b, loc, armYield);
      }
      if (withSent)
        sent = branch->getResult(0);
    } else
      ebpf::RingbufSubmitOp::create(b, loc, res);
    if (results == OutputResults::None)
      ebpf::YieldOp::create(b, loc, ValueRange{});
    else {
      SmallVector<Value> yields{
          arith::ConstantIntOp::create(b, loc, present, 1)};
      if (results == OutputResults::BoolStatus)
#ifdef SPINEL_E039_TEST_STATUS_ZERO
        // E039 H6 M-status-zero (test build only)
        yields.push_back(arith::ConstantIntOp::create(b, loc, 0, 64));
#else
        yields.push_back(status);
#endif
      if (sent)
        yields.push_back(sent);
      ebpf::YieldOp::create(b, loc, yields);
    }
    auto *no = new Block();
    op.getAbsentRegion().push_back(no);
    b.setInsertionPointToStart(no);
    if (results == OutputResults::None)
      ebpf::YieldOp::create(b, loc, ValueRange{});
    else {
      SmallVector<Value> yields{
          arith::ConstantIntOp::create(b, loc, absent, 1)};
      if (results == OutputResults::BoolStatus)
        yields.push_back(arith::ConstantIntOp::create(b, loc, 0, 64));
      if (results == OutputResults::BoolStatus && discard)
        yields.push_back(yields.front()); // nothing was submitted
      ebpf::YieldOp::create(b, loc, yields);
    }
  }
  return op.getOperation();
}

FailureOr<Value> emitOutput(Consumer &c, const ScalarExpr &e, bool withResult,
                            Location loc) {
  if(e.kind==kOutputArgvKind) {
    if(withResult){(void)c.error(e.node,"argv output does not produce a scalar result");return failure();}
    auto p=std::static_pointer_cast<const OutputArgvValue>(e.payload);
    auto result=emitArgvSlots(c,loc,[p](Consumer &c,Location l){return emitUserStringArray(c,*p->array,l);},
        [&](Consumer &c,Value s,int64_t k,Location l){return success(succeeded(emitReservation(c,e,OutputResults::None,l,s,ArgvIndex{p->indexOffset,k})));});
    return failed(result)?FailureOr<Value>(failure()):FailureOr<Value>(Value{});
  }
  auto op = emitReservation(
      c, e, withResult ? OutputResults::Bool : OutputResults::None, loc);
  if (failed(op))
    return failure();
  return withResult ? (*op)->getResult(0) : Value();
}

// An output read as a value: only an if / unless predicate (Go program.go
// 942-947); anything else is an operand, argument or value.
Dispatch<Expr> expressionOutput(Consumer &c, Operation *n) {
  if (outputOfBadRing(c, n))
    return Dispatch<Expr>::error(); // the declaration's rejection was printed
  auto ri = outputRing(c, n);
  if (ri == SIZE_MAX)
    return Dispatch<Expr>::declined();
  if(isOutputArgv(n))return (void)c.diagnostic(n,"SB025","DroppedEvent","the result of output_argv is not bound — it emits up to 20 events (one per present argv slot), so write `_ = "+c.rings[ri].constant+".output_argv(…)` (E151)",true),Dispatch<Expr>::error();
  if (isOutputStr(n))
    return (void)c.diagnostic(n, "SB025", "DroppedEvent",
        "the result of " + (field(n, "strings", "name") == "output_comm" ? std::string("output_comm") : std::string("output_str")) + " is accepted only as " + outputStrShape(c.rings[ri], field(n, "strings", "name")), true), Dispatch<Expr>::error();
  if (!outputIsCondition(c, n))
    return (void)c.diagnostic(n, "SB025", "DroppedEvent",
                              droppedMessage(c.rings[ri]) +
                                  " — not as an operand, argument or value",
                              true),
           Dispatch<Expr>::error();
  return checkOutput(c, n, ri);
}

Dispatch<Value> emitOutputValue(Consumer &c, const Expr &e) {
  auto v = emitOutput(c, *e, true, outputLoc(e->node));
  return failed(v) ? Dispatch<Value>::error() : Dispatch<Value>::handled(*v);
}

// `R.output(…)` as a statement drops the result (Go program.go:325-330).
Dispatch<StatementResult> statementOutput(Consumer &c,
                                          llvm::ArrayRef<Operation *> list,
                                          size_t i, unsigned) {
  auto n = list[i];
  if (outputOfBadRing(c, n))
    return Dispatch<StatementResult>::handled({1});
  auto ri = outputRing(c, n);
  if (ri == SIZE_MAX)
    return Dispatch<StatementResult>::declined();
  if (isOutputStr(n))
    return (void)c.diagnostic(n, "SB025", "DroppedEvent",
        "the result of " + field(n, "strings", "name").str() + " (nil when the ring is full) is dropped — use " +
        outputStrShape(c.rings[ri], field(n, "strings", "name")), true), Dispatch<StatementResult>::error();
  return (void)c.diagnostic(n, "SB025", "DroppedEvent",
                            droppedMessage(c.rings[ri]), true),
         Dispatch<StatementResult>::error();
}

std::string contextParameter(Consumer &c) {
  auto params = c.activeDef ? c.ref(c.activeDef, "parameters") : nullptr;
  if (!params)
    return {};
  auto requireds = c.array(params, "requireds");
  return requireds.size() == 1 ? field(requireds[0], "strings", "name").str()
                               : std::string();
}

// c.bindings outlives one program, so the key names the def (Go's ostrs is
// per progCtx).
std::string outputStrKey(Consumer &c, StringRef local) {
  return kOutputStrBinding +
         std::to_string(c.activeDef ? c.id(c.activeDef) : -1) + ":" +
         local.str();
}

// The analyzed `if r` of an output_str result local, or null.
Operation *outputStrIf(Consumer &c, StringRef local) {
  auto found = c.bindings.find(outputStrKey(c, local));
  return found == c.bindings.end() ? nullptr : found->second.analyzed;
}

// Go's ostrLive: inside the then statements of that `if r`, nested blocks
// included; not its else, not before or after it.
bool insideThen(Consumer &c, Operation *node, Operation *ifNode) {
  auto then = c.ref(ifNode, "statements");
  for (auto *p = c.parent(node); p && then; p = c.parent(p)) {
    if (p == then)
      return true;
    if (p == ifNode)
      return false;
  }
  return false;
}

// `r = R.output_str(…)` then `if r … [else …] end` (Go program.go:405-422,
// uprobe.go:227-277): the if_reserved results bind r (i1), r.status (i64) and
// r.sent (i1); the two statements are consumed together.
Dispatch<StatementResult> bindOutputStr(Consumer &c,
                                        llvm::ArrayRef<Operation *> list,
                                        size_t i, unsigned depth, size_t ri) {
  auto n = list[i];
  auto value = c.ref(n, "value");
  auto &r = c.rings[ri];
  auto method = field(value, "strings", "name") == "output_comm" ? "output_comm" : "output_str";
  auto local = field(n, "strings", "name").str();
  auto reject = [&](Operation *at, StringRef code, StringRef label,
                    const std::string &message) {
    (void)c.diagnostic(at, code, label, message, true);
    return Dispatch<StatementResult>::error();
  };
  Operation *next = i + 1 < list.size() ? list[i + 1] : nullptr;
  Operation *predicate = next && text(next, "kind") == "IfNode"
                             ? c.ref(next, "predicate")
                             : nullptr;
  if (!predicate || text(predicate, "kind") != "LocalVariableReadNode" ||
      field(predicate, "strings", "name") != local)
    return reject(n, "SB025", "DroppedEvent",
                  "`" + local + " = " + r.constant +
                      "." + method + "(…)` must be followed immediately by `if " +
                      local + "` — " + outputStrShape(r, method));
  if (c.locals.count(local) || c.borrows.count(local) ||
      local == contextParameter(c) || outputStrIf(c, local) ||
      c.bindings.count("packet:" + local) ||
      c.bindings.count("gkernel.ptr:" + local))
    return reject(n, "SB005", "RefCheckShape",
                  "`" + local +
                      "` is already bound — an output_str result needs a "
                      "fresh name");
  auto e = checkOutput(c, value, ri);
  if (e.state != Disposition::Handled)
    return e.state == Disposition::Error
               ? Dispatch<StatementResult>::error()
               : Dispatch<StatementResult>::declined();
  if ((*e.value)->kind != kOutputStrKind)
    return (void)c.error(value, "binding a kernel-string output_str result "
                                "is not supported (E039)"),
           Dispatch<StatementResult>::error();
  auto subsequent = c.ref(next, "subsequent");
  if (subsequent && text(subsequent, "kind") != "ElseNode")
    return reject(subsequent, "SB005", "RefCheckShape",
                  "`elsif` is not accepted after `if " + local + "` (P020)");
  // A probe checks only (E028). Probes run inside loop bodies, and Go rejects
  // a ring output there (SB030, not compared by E029): the check pass below
  // stops loudly instead of lowering it.
  if (c.probing)
    return Dispatch<StatementResult>::handled({2});
  if (!c.frames.empty())
    return (void)c.error(n, "an output_str result in a loop body is not "
                            "supported (E039)"),
           Dispatch<StatementResult>::error();
  c.bindings[outputStrKey(c, local)] = {n, next, {}};
  auto op = emitReservation(c, **e.value, OutputResults::BoolStatus,
                            outputLoc(value));
  if (failed(op))
    return Dispatch<StatementResult>::error();
  auto bind = [&](const std::string &name, Value v, bool isBool) {
    auto x = std::make_shared<ScalarExpr>();
    x->node = n;
    x->kind = "local";
    x->name = name;
    if (isBool)
      x->range.isBool = true;
    else
      x->range = {math::MathInterval(math::Interval::fullI64()), false, false,
                  range::Form::Local};
    c.locals[name] = {x, v};
  };
  bind(local, (*op)->getResult(0), true);
  bind(local + "#status", (*op)->getResult(1), false);
  // output_str submits whenever it reserves; the discarding variant yields
  // whether it submitted as a third result (E045).
  bind(local + "#sent", (*op)->getResult((*op)->getNumResults() == 3 ? 2 : 0),
       true);
  auto condition = c.scalar(predicate);
  if (failed(condition) ||
      failed(c.scalarBranch(next, (*op)->getResult(0), *condition,
                            std::nullopt, {}, depth)))
    return Dispatch<StatementResult>::error();
  for (auto name : {local, local + "#status", local + "#sent"})
    c.locals.erase(name);
  return Dispatch<StatementResult>::handled({2});
}

// Reading an output_str result local: only as its `if r` (Go program.go:763).
Dispatch<Expr> readOutputStr(Consumer &c, Operation *n) {
  auto local = field(n, "strings", "name");
  auto ifNode = outputStrIf(c, local);
  if (!ifNode || c.ref(ifNode, "predicate") == n)
    return Dispatch<Expr>::declined();
  return (void)c.diagnostic(n, "SB005", "RefCheckShape",
                            "`" + local.str() +
                                "` (an output_str result) may be read only "
                                "as `if " + local.str() + "` and as `" +
                                local.str() + ".status` inside it",
                            true),
         Dispatch<Expr>::error();
}

// `r.status` / `r.sent` inside the then of `if r` (Go ostrStatus,
// uprobe.go:279-300).
Dispatch<Expr> statusOutputStr(Consumer &c, Operation *n) {
  auto m = field(n, "strings", "name").str();
  auto recv = c.ref(n, "receiver");
  if ((m != "status" && m != "sent") || !recv ||
      text(recv, "kind") != "LocalVariableReadNode")
    return Dispatch<Expr>::declined();
  auto local = field(recv, "strings", "name").str();
  auto ifNode = outputStrIf(c, local);
  if (!ifNode)
    return Dispatch<Expr>::declined();
  auto reject = [&](const std::string &code, const std::string &label,
                    const std::string &message) {
    (void)c.diagnostic(n, code, label, message, true);
    return Dispatch<Expr>::error();
  };
  if (!insideThen(c, n, ifNode))
    return reject("SB005", "RefCheckShape",
                  "`" + local + "." + m + "` is read only inside `if " +
                      local + "` right after `" + local +
                      " = R.output_str(…)` (P020)");
  CalleePolicy policy;
  policy.expected = "OutputStr#" + m;
  policy.requireCallee = false;
  if (failed(c.known(n, policy)))
    return Dispatch<Expr>::error();
  auto callee = text(c.evidence[c.id(n)].front(), "callee");
  if (callee != "OutputStr#" + m)
    return reject("SB011", "ShadowedName",
                  "`" + m + "` resolves to " + callee.str() +
                      ", not BPF::OutputStr#" + m);
  if (!c.args(n).empty())
    return reject("SB002", "UnsupportedCall",
                  "`" + local + "." + m + "` takes no arguments");
  auto found = c.locals.find(local + "#" + m);
  if (found == c.locals.end())
    return (void)c.error(n, "output_str result " + local + " has no " + m),
           Dispatch<Expr>::error();
  auto e = std::make_shared<ScalarExpr>(*found->second.expr);
  e->node = n;
  e->range = range::asLocal(found->second.expr->range);
  return Dispatch<Expr>::handled(e);
}

// `_ = R.output(…)` chooses not to count drops; any other local is SB025
// (Go program.go:425-433).
Dispatch<StatementResult> statementWrite(Consumer &c,
                                         llvm::ArrayRef<Operation *> list,
                                         size_t i, unsigned depth) {
  auto n = list[i];
  auto value = c.ref(n, "value");
  if (outputOfBadRing(c, value))
    return Dispatch<StatementResult>::declined();
  auto ri = outputRing(c, value);
  if (ri == SIZE_MAX && text(value, "kind") == "CallNode" &&
      field(value, "strings", "name") == "output_comm")
    return (void)c.diagnostic(value, "SB002", "UnsupportedCall",
        "call `output_comm` is not accepted on the eBPF side", true),
        Dispatch<StatementResult>::error();
  if (ri == SIZE_MAX)
    return Dispatch<StatementResult>::declined();
  auto local = field(n, "strings", "name").str();
  if (local != "_" && isOutputStr(value))
    return bindOutputStr(c, list, i, depth, ri);
  if(local!="_"&&isOutputArgv(value))return (void)c.diagnostic(n,"SB025","DroppedEvent","the result of output_argv is not bound — it emits up to 20 events (one per present argv slot), so write `_ = "+c.rings[ri].constant+".output_argv(…)` (E151)",true),Dispatch<StatementResult>::error();
  if (local != "_")
    return (void)c.diagnostic(
               n, "SB025", "DroppedEvent",
               "`" + local + " = " + c.rings[ri].constant +
                   ".output(…)` — the result is accepted only as an `if` / "
                   "`unless` condition or `_ = …` (a bool local can carry it "
                   "to a path that drops it) (P007 §2)",
               true),
           Dispatch<StatementResult>::error();
  auto e = checkOutput(c, value, ri);
  if (e.state != Disposition::Handled)
    return e.state == Disposition::Error
               ? Dispatch<StatementResult>::error()
               : Dispatch<StatementResult>::declined();
  // A probe checks only (E028).
  auto loc = (isOutputStr(value)||isOutputArgv(value))
                 ? outputLoc(value) : outputLoc(n);
  if (!c.probing && failed(emitOutput(c, **e.value, false, loc)))
    return Dispatch<StatementResult>::error();
  return Dispatch<StatementResult>::handled({1});
}

// schema.go:219 / 321 — the ring's own fields; the shared json places rings
// after every map.
Dispatch<ExportFields> exportRing(Consumer &c, size_t ri, bool schema) {
  auto &r = c.rings[ri];
  ExportFields f;
  if (schema) {
    f.emplace_back("symbol", r.name);
    f.emplace_back("kind", "ringbuf");
    f.emplace_back("max_entries", int64_t(r.size));
    f.emplace_back("flags", int64_t(0));
    f.emplace_back("record", r.layout->name);
    f.emplace_back("note", "Ruby constant " + r.constant);
  } else {
    f.emplace_back("name", r.name);
    f.emplace_back("kind", "ringbuf");
    f.emplace_back("key", "-");
    f.emplace_back("value", "record:" + r.layout->name);
    f.emplace_back("max_entries", int64_t(r.size));
  }
  return Dispatch<ExportFields>::handled(std::move(f));
}
} // namespace

void registerGroupRing(Registry &r) {
  r.addDeclaration({"BPF::RingBuf", "new"}, declareRing);
  r.addExpression("CallNode", expressionOutput);
  r.addExpression("CallNode", statusOutputStr);
  r.addExpression("LocalVariableReadNode", readOutputStr);
  r.addEmitter(kOutputKind, emitOutputValue);
  r.addStatement("CallNode", statementOutput);
  r.addStatement("LocalVariableWriteNode", statementWrite);
  r.addRingExporter(exportRing);
}
} // namespace spinel::consumer
