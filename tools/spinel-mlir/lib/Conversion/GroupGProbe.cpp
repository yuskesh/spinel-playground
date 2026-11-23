#include "spinel/Conversion/GroupGProbe.h"
#include "spinel/Conversion/GroupGUprobe.h"
#include "spinel/Conversion/TracepointRecordAccess.h"
#include "spinel/Conversion/Consumer.h"
#include "spinel/Analysis/KernelTypes.h"
#include "bpf-mlir/Dialect/EBPF/IR/EBPFDialect.h"
#include "mlir/Dialect/Arith/IR/Arith.h"
#include "llvm/ADT/StringExtras.h"
#include "llvm/ADT/ScopeExit.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/Path.h"
#include <set>

// Adapted from the Go frontend's analyze.go probe declarations, kread.go,
// tracepoint.go, program.go tracingRead, lower.go and schema.go. E020 owns the
// consolidated provenance/notice entry. Source facts remain non-owning views.
namespace spinel::consumer {
namespace {
using namespace mlir;
using DE = Dispatch<Expr>;
using DS = Dispatch<StatementResult>;
struct IntType {
  unsigned bits = 0;
  bool sign = false;
};
static std::optional<IntType> integerType(StringRef name) {
  if (name.size() < 2 || (name.front() != 'i' && name.front() != 'u'))
    return std::nullopt;
  unsigned bits;
  if (name.drop_front().getAsInteger(10, bits) ||
      (bits != 8 && bits != 16 && bits != 32 && bits != 64))
    return std::nullopt;
  return IntType{bits, name.front() == 'i'};
}
struct Field {
  std::string name, type;
  int64_t offset = 0;
  int64_t count = 0; // E153: fixed byte array, zero preserves scalar/string fields.
};
struct ProbeDecl : Payload {
  std::string kind, target, ret, param, klass;
  std::vector<std::pair<int64_t, std::string>> params;
  std::vector<Field> fields;
  Operation *def = nullptr;
};
struct ProbeRead : Payload {
  IntType type;
  int64_t index = 0;
  std::string field;
};
static LogicalResult issue(Consumer &c, Operation *n, StringRef code,
                           StringRef label, const std::string &message,
                           bool path = true) {
  return c.diagnostic(n, code, label, message, path);
}
static bool ident(StringRef s) {
  if (s.empty() || !(llvm::isAlpha(s.front()) || s.front() == '_'))
    return false;
  return llvm::all_of(s.drop_front(), [](char x) {
    return llvm::isAlnum(x) || x == '_';
  });
}
static std::string quote(StringRef s) {
  std::string out;
  llvm::raw_string_ostream os(out);
  os << llvm::json::Value(s);
  return out;
}
static Value extend(Consumer &c, Value value, IntType t, Location loc) {
  if (t.bits == 64)
    return value;
  return t.sign ? arith::ExtSIOp::create(c.builder, loc,
                     c.builder.getI64Type(), value).getResult()
                : arith::ExtUIOp::create(c.builder, loc,
                     c.builder.getI64Type(), value).getResult();
}
static Value operation(Consumer &c, StringRef name, Type type, Value ctx,
                       ArrayRef<NamedAttribute> attrs, Location loc) {
  OperationState state(loc, name);
  state.addTypes(type);
  state.addOperands(ctx);
  state.addAttributes(attrs);
  return c.builder.create(state)->getResult(0);
}
struct Probe {
  std::shared_ptr<const ProbeDecl> current;
  bool context(Consumer &c, Operation *receiver) const {
    return current && c.activeKind == current->kind &&
           c.activeDef == current->def &&
           text(receiver, "kind") == "LocalVariableReadNode" &&
           field(receiver, "strings", "name") == current->param;
  }
  Dispatch<ProgramDecl> root(Consumer &c, Operation *n) {
    auto d = std::make_shared<ProbeDecl>();
    d->kind = field(n, "strings", "name").str();
    auto as = c.args(n);
    auto bad = [&](const std::string &message) {
      (void)issue(c, n, "SB008", "ProgramShape", message, false);
      return Dispatch<ProgramDecl>::error();
    };
    static const std::map<std::string, std::string> klass = {
        {"kprobe", "KprobeCtx"}, {"kretprobe", "KretprobeCtx"},
        {"ksyscall", "KsyscallCtx"}, {"raw_tp", "RawTpCtx"},
        {"tracepoint", "TracepointCtx"}};
    auto k = klass.find(d->kind);
    if (k == klass.end())
      return Dispatch<ProgramDecl>::declined();
    d->klass = k->second;
    const std::string tpShape = "`BPF.tracepoint :name, \"category/event\", fields: {name => [offset, :type], …}`";
    std::string shape = "`BPF." + d->kind + " :name, \"" +
        (d->kind == "raw_tp" ? "tracepoint" : d->kind == "ksyscall" ? "syscall" : "kernel_function") + "\"";
    if (d->kind == "kprobe" || d->kind == "ksyscall")
      shape += ", params: {n => :u64, …}";
    if (d->kind == "kretprobe") shape += ", ret: :i32";
    shape += "`";
    if (d->kind == "tracepoint") shape = tpShape;
    if (d->kind == "tracepoint") {
      if (as.size() != 3 || text(as[0], "kind") != "SymbolNode" ||
          text(as[1], "kind") != "StringNode" || text(as[2], "kind") != "KeywordHashNode")
        return bad("a tracepoint program is declared as " + shape +
                   " — the event's fields it reads, with the offset and type from the tracefs format (P026)");
    } else {
      if (as.size() < 2 || text(as[0], "kind") != "SymbolNode" ||
          text(as[1], "kind") != "StringNode" || c.spelling(as[1], false).empty())
        return bad("a " + d->kind + " program is declared as " + shape +
                   " with a Symbol and a non-empty String literal (P013)");
      size_t expected = d->kind == "raw_tp" ? 2 : 3;
      if (as.size() != expected || (expected == 3 && text(as[2], "kind") != "KeywordHashNode"))
        return bad("a " + d->kind + " program is declared as " + shape + " (P013)");
    }
    d->target = c.spelling(as[1], false).str();
    std::map<std::string, Operation *> opts;
    if (as.size() == 3)
      for (auto e : c.array(as[2], "elements")) {
        auto key = c.ref(e, "key");
        if (text(e, "kind") != "AssocNode" || text(key, "kind") != "SymbolNode")
          return bad("the options of " + shape + " are `key: literal` pairs (P013)");
        auto name = c.spelling(key, true).str();
        if (!opts.emplace(name, c.ref(e, "value")).second)
          return bad("duplicate option in " + shape);
      }
    if (d->kind == "kretprobe") {
      if (opts.size() != 1 || !opts.count("ret"))
        return bad(shape + " needs exactly `ret:` (a Symbol :i8 … :u64 — the kernel does not check it; the value is the return register cut to this width) (P026)");
      auto r = opts["ret"];
      if (text(r, "kind") != "SymbolNode" || !integerType(c.spelling(r, true)))
        return bad("`ret:` of " + shape + " is one of :i8 … :i64 / :u8 … :u64 (P026)");
      d->ret = c.spelling(r, true).str();
    } else if (d->kind == "kprobe" || d->kind == "ksyscall") {
      if (d->kind == "ksyscall" && (!ident(d->target) ||
          StringRef(d->target).starts_with("sys_") || StringRef(d->target).starts_with("__")))
        return bad("the target of " + shape + " is a syscall name — a C identifier without the `sys_` / `__` prefix (the wrapper `__x64_sys_<name>` is derived), got " + quote(d->target) + " (P026)");
      auto p = opts.count("params") ? opts["params"] : nullptr;
      if (opts.size() != 1 || text(p, "kind") != "HashNode" || c.array(p, "elements").empty())
        return bad(shape + " needs `params:` with a non-empty Hash literal of register number (1..6) => type (P013)");
      std::set<int64_t> seen;
      for (auto e : c.array(p, "elements")) {
        auto key = c.ref(e, "key"), value = c.ref(e, "value");
        if (text(e, "kind") != "AssocNode" || text(key, "kind") != "IntegerNode")
          return bad("each " + d->kind + " parameter is `n => :type` with n an Integer literal 1..6 (P013)");
        auto number = c.integer(key);
        if (failed(number)) return Dispatch<ProgramDecl>::error();
        if (*number < 1 || *number > 6 || !seen.insert(*number).second)
          return bad("a " + d->kind + " parameter number is 1..6 (the x86_64 argument registers, 1-origin like the schema's n) and appears once (P013)");
        auto t = c.spelling(value, true).str();
        if (text(value, "kind") != "SymbolNode" || (!integerType(t) && !(d->kind == "kprobe" && t == "ptr") && !(d->kind == "ksyscall" && (t == "user_str"||t == "user_str_array"))))
          return bad("a " + d->kind + " parameter type is one of :i8 … :i64 / :u8 … :u64" +
                     (d->kind == "kprobe" ? " or :ptr (a pointer read with `v, st = ctx.read(n, offset, :type)`)" : "") +
                     (d->kind == "ksyscall" ? " or :user_str (a `const char *` — read with ctx.str_arg(n))" : "") + " (P013)");
        d->params.emplace_back(*number, t);
      }
    } else if (d->kind == "tracepoint") {
      auto parts = StringRef(d->target).split('/');
      if (!ident(parts.first) || !ident(parts.second) || parts.second.contains('/'))
        return bad("the target of " + shape + " is a tracefs event `category/event` (two C identifiers and one `/`), got " + quote(d->target) + " (P026)");
      auto fields = opts.count("fields") ? opts["fields"] : nullptr;
      if (opts.size() != 1 || !opts.count("fields"))
        return bad("the options of " + shape + " are exactly `fields:` (P026)");
      if (text(fields, "kind") != "HashNode" || c.array(fields, "elements").empty())
        return bad(shape + " needs `fields:` with a non-empty Hash literal of field name => [offset, :type] (P026)");
      std::set<std::string> names; std::set<int64_t> offsets;
      for (auto e : c.array(fields, "elements")) {
        auto key = c.ref(e, "key"), value = c.ref(e, "value");
        if (text(e, "kind") != "AssocNode" || text(key, "kind") != "SymbolNode" || text(value, "kind") != "ArrayNode")
          return bad("each tracepoint field is `name: [offset, :type]` — a Symbol name and a two-element Array literal (P026)");
        auto name = c.spelling(key, true).str(); auto elements = c.array(value, "elements");
        if (elements.size() == 2 && text(elements[0], "kind") == "IntegerNode" && text(elements[1], "kind") == "ArrayNode") {
          auto array = c.array(elements[1], "elements");
          auto arrayShape = [&] {
            return bad("field " + name + ": a byte array is `" + name +
                ": [offset, [:u8, N]]` (or :i8) with an Integer literal N of 1..64 — the tracefs format's `__u8 " + name + "[N]` (E153)");
          };
          if (array.size() != 2 || text(array[0], "kind") != "SymbolNode" || text(array[1], "kind") != "IntegerNode")
            return arrayShape();
          auto element = c.spelling(array[0], true).str();
          if (element != "u8" && element != "i8") return arrayShape();
          auto count = c.integer(array[1]);
          if (failed(count)) return Dispatch<ProgramDecl>::error();
          if (*count < 1 || *count > 64) return arrayShape();
          auto offset = c.integer(elements[0]);
          if (failed(offset)) return Dispatch<ProgramDecl>::error();
          if (*offset < 8 || *offset > 8192 - *count)
            return bad("field " + name + ": the offset is an Integer ≥ 8 (the first 8 bytes are not readable from BPF) and offset + " + std::to_string(*count) + " ≤ 8192 (E153)");
          if (!ident(name) || !names.insert(name).second || !offsets.insert(*offset).second)
            return bad("field " + name + " at offset " + std::to_string(*offset) + ": field names are C identifiers and neither a name nor an offset appears twice (P026)");
          d->fields.push_back({name, element, *offset, *count});
          continue;
        }
        if (elements.size() != 2 || text(elements[0], "kind") != "IntegerNode" || text(elements[1], "kind") != "SymbolNode")
          return bad("field " + name + ": write `" + name + ": [offset, :type]` — an Integer literal offset and a type Symbol :i8 … :u64 (P026)");
        auto t = c.spelling(elements[1], true).str(); auto type = (t == "user_str"||t == "user_str_array") ? std::optional<IntType>(IntType{64, false}) : integerType(t);
        if (!type) return bad("field " + name + ": the type is one of :i8 … :i64 / :u8 … :u64 (the format's size and signed) or :user_str (a `char *` field — read with ctx.str_field), got :" + t + " (P026)");
        auto offset = c.integer(elements[0]); if (failed(offset)) return Dispatch<ProgramDecl>::error();
        auto bytes = type->bits / 8;
        if (*offset < 8 || *offset % bytes || *offset > 8192 - bytes)
          return bad("field " + name + ": the offset is an Integer ≥ 8 (the first 8 bytes are not readable from BPF), a multiple of the field's " + std::to_string(bytes) + " bytes, and offset + size ≤ 8192 (P026)");
        if (!ident(name) || !names.insert(name).second || !offsets.insert(*offset).second)
          return bad("field " + name + " at offset " + std::to_string(*offset) + ": field names are C identifiers and neither a name nor an offset appears twice (P026)");
        d->fields.push_back({name, t, *offset});
      }
    }
    if (failed(c.known(n, CalleePolicy{"BPF." + d->kind}))) return Dispatch<ProgramDecl>::error();
    auto name = c.spelling(as[0], true);
    for (auto f : c.selectedTop)
      if (text(f, "kind") == "DefNode" && field(f, "strings", "name") == name) d->def = f;
    if (!d->def) return bad("root target must be a declared method");
    auto parameters = c.array(c.ref(d->def, "parameters"), "requireds");
    if (parameters.size() != 1) return bad("a probe program requires one context parameter");
    d->param = field(parameters[0], "strings", "name").str();
    current = d;
    ProgramDecl p; p.kind = d->kind; p.attachTarget = d->target;
    p.contextType = ebpf::ContextType::get(c.ctx, d->kind);
    p.analysisContext = "obj_BPF::" + d->klass; p.payload = d;
    if (d->kind == "kprobe" || d->kind == "kretprobe" || d->kind == "ksyscall") p.arch = "x86_64";
    p.finalizeBody = [d](Consumer &consumer) {
      auto block = consumer.builder.getInsertionBlock();
      if (!block || (!block->empty() && block->back().hasTrait<OpTrait::IsTerminator>()))
        return consumer.error(d->def, "probe finalizer requires an unterminated program block");
      ebpf::VerdictOp::create(consumer.builder, outputLoc(d->def), "done");
      return success();
    };
    return Dispatch<ProgramDecl>::handled(std::move(p));
  }
  DE copySource(Consumer &c, Operation *node) {
    if (text(node, "kind") != "CallNode" || field(node, "strings", "name") != "copy" ||
        !context(c, c.ref(node, "receiver"))) return DE::declined();
    // Other-kind context reads are rejected before querying missing callee
    // evidence (tpa_kprobe). This is the existing kind-specific read path.
    if (current->kind != "tracepoint") return expression(c, node);
    auto bad = [&](Operation *at, const std::string &message) {
      (void)issue(c, at, "SB028", "TracingKind", message); return DE::error();
    };
    CalleePolicy policy{"TracepointCtx#copy"}; policy.requireCallee = false;
    if (failed(c.known(node, policy))) return DE::error();
    auto proof = c.evidence.lookup(c.id(node));
    auto callee = proof.size() == 1 ? text(proof.front(), "callee") : StringRef();
    if (callee.empty())
      return (void)c.error(node, "tracepoint copy requires actual callee evidence"), DE::error();
    if (callee != "TracepointCtx#copy") {
      (void)issue(c, node, "SB011", "ShadowedName", "`copy` resolves to " + callee.str() + ", not BPF::TracepointCtx#copy");
      return DE::error();
    }
    auto args = c.args(node);
    if (args.size() != 1 || text(args[0], "kind") != "SymbolNode")
      return bad(node, "`" + current->param + ".copy(:f)` takes one Symbol literal — a byte array field declared in `BPF.tracepoint … fields:` (E153)");
    auto name = c.spelling(args[0], true).str();
    auto f = llvm::find_if(current->fields, [&](const Field &f) { return f.name == name; });
    if (f == current->fields.end())
      return bad(args[0], "`" + current->param + ".copy(:" + name + ")`: " + name + " is not declared in `BPF.tracepoint … fields:` (declare `" + name + ": [offset, [:u8, N]]` from the tracefs format) (E153)");
    if (!f->count)
      return bad(args[0], "`" + current->param + ".copy(:" + name + ")`: " + name + " is declared :" + f->type + ", not a byte array — read it with `" + current->param + ".field(:" + name + ")` (E153)");
    auto payload = std::make_shared<TracepointRecordAccess>();
    payload->parameter = current->param; payload->definition = current->def;
    payload->field = f->name; payload->element = f->type;
    payload->offset = f->offset; payload->count = f->count;
    auto expr = std::make_shared<ScalarExpr>(); expr->node = node;
    expr->kind = "gprobe.record-copy"; expr->payload = payload;
    return DE::handled(expr);
  }
  // E142/E143: checked user-string reads retain declaration identity, never SSA.
  FailureOr<std::shared_ptr<const UserStringArg>> userString(Consumer &c, Operation *call) {
    bool tp = c.activeKind == "tracepoint";
    if (!current || (c.activeKind != "tracepoint" && c.activeKind != "ksyscall") ||
        c.activeDef != current->def || c.activeKind != current->kind) {
      (void)c.error(call, "tracing user-string check requires the active declaration");
      return failure();
    }
    auto bad = [&](Operation *at, const std::string &message) -> FailureOr<std::shared_ptr<const UserStringArg>> {
      (void)issue(c, at, "SB028", "TracingKind", message); return failure();
    };
    std::string method = "output_str";
    if (tp) for (auto *p = c.parent(call); p; p = c.parent(p)) {
      auto name = field(p, "strings", "name");
      if (text(p, "kind") == "CallNode" && (name == "output_str" || name == "output_str_or_discard")) {
        method = name.str(); break;
      }
    }
    auto readName = tp ? "str_field" : "str_arg";
    if (text(call, "kind") != "CallNode" || field(call, "strings", "name") != readName ||
        !context(c, c.ref(call, "receiver"))) {
      if (tp) return bad(call, "the third argument of " + method + " in a tracepoint program is `" + current->param + ".str_field(:f)` itself (a user string is not a value on the eBPF side — not through a local) (E142)");
      return bad(call, "the third argument of output_str is `" + current->param + ".str_arg(n)` itself (a user string is not a value on the eBPF side — not through a local) (P020)");
    }
    CalleePolicy policy{current->klass + "#" + readName}; policy.requireCallee = false;
    if (failed(c.known(call, policy))) return failure();
    auto actual = text(c.evidence[c.id(call)].front(), "callee");
    if (actual != policy.expected) {
      (void)issue(c, call, "SB011", "ShadowedName", "`" + std::string(readName) + "` resolves to " + actual.str() + ", not BPF::" + policy.expected);
      return failure();
    }
    auto as = c.args(call);
    UserStringArg checked; checked.node = call; checked.def = current->def;
    checked.source = tp ? UserStringSource::Tracepoint : UserStringSource::Ksyscall;
    if (tp) {
      if (as.size() != 1 || text(as[0], "kind") != "SymbolNode")
        return bad(call, "`" + current->param + ".str_field(:f)` takes one Symbol literal — a :user_str field declared in `BPF.tracepoint … fields:` (E142)");
      if (failed(c.known(as[0]))) return failure();
      auto name = c.spelling(as[0], true).str();
      auto f = llvm::find_if(current->fields, [&](const Field &f) { return f.name == name; });
      if (f == current->fields.end())
        return bad(as[0], "`" + current->param + ".str_field(:" + name + ")`: " + name + " is not declared in `BPF.tracepoint … fields:` (declare `" + name + ": [offset, :user_str]` from the tracefs format) (E142)");
      if (f->type != "user_str")
        return bad(as[0], "`" + current->param + ".str_field(:" + name + ")`: " + name + " is declared :" + f->type + " — read it with `" + current->param + ".field(:" + name + ")` (E142)");
      checked.field = f->name; checked.offset = f->offset;
    } else {
      if (as.size() != 1 || text(as[0], "kind") != "IntegerNode")
        return bad(call, "`" + current->param + ".str_arg(n)` takes one Integer literal n — a declared parameter number (P020)");
      auto n = c.integer(as[0]); if (failed(n)) return failure();
      auto p = llvm::find_if(current->params, [&](const auto &p) { return p.first == *n; });
      auto number = std::to_string(*n);
      if (p == current->params.end())
        return bad(as[0], "`" + current->param + ".str_arg(" + number + ")`: " + number + " is not a parameter number declared in `BPF.uprobe … params:` (1..6, 1-origin like the schema's n) (P020)");
      if (p->second != "user_str")
        return bad(call, "`" + current->param + ".str_arg(" + number + ")`: parameter " + number + " is declared :" + p->second + " — read it with `" + current->param + ".arg(" + number + ")` (P020)");
      checked.n = *n;
    }
    return std::shared_ptr<const UserStringArg>(std::make_shared<UserStringArg>(std::move(checked)));
  }
  FailureOr<std::shared_ptr<const UserStringArg>> userArray(Consumer &c,Operation *call) {
    bool tp=c.activeKind=="tracepoint";
    if(!current||(!tp&&c.activeKind!="ksyscall")||c.activeDef!=current->def||c.activeKind!=current->kind) {
      (void)c.error(call,"argv check requires its active tracing declaration");return failure();
    }
    auto bad=[&](Operation *n,const std::string &m)->FailureOr<std::shared_ptr<const UserStringArg>> {
      (void)issue(c,n,"SB028","TracingKind",m);return failure();
    };
    std::string method=tp?"argv_field":"argv_arg";
    std::string form=current->param+"."+method+(tp?"(:f)":"(n)");
    if(text(call,"kind")!="CallNode"||field(call,"strings","name")!=method||!context(c,c.ref(call,"receiver")))
      return bad(call,"the third argument of output_argv is `"+form+"` itself (an argv array is not a value on the eBPF side — not through a local) (E151)");
    CalleePolicy policy{current->klass+"#"+method};policy.requireCallee=false;
    if(failed(c.known(call,policy)))return failure();
    auto actual=text(c.evidence[c.id(call)].front(),"callee");
    if(actual!=policy.expected){(void)issue(c,call,"SB011","ShadowedName","`"+method+"` resolves to "+actual.str()+", not BPF::"+policy.expected);return failure();}
    auto as=c.args(call);UserStringArg checked;checked.node=call;checked.def=current->def;
    checked.valueKind=UserStringValueKind::Array;checked.source=tp?UserStringSource::Tracepoint:UserStringSource::Ksyscall;
    if(tp) {
      if(as.size()!=1||text(as[0],"kind")!="SymbolNode")return bad(call,"`"+form+"` takes one Symbol literal — a :user_str_array field declared in `BPF.tracepoint … fields:` (E151)");
      auto name=c.spelling(as[0],true).str();auto f=llvm::find_if(current->fields,[&](const Field &f){return f.name==name;});
      if(f==current->fields.end())return bad(as[0],"`"+current->param+".argv_field(:"+name+")`: "+name+" is not declared in `BPF.tracepoint … fields:` (E151)");
      if(f->type!="user_str_array")return bad(as[0],"`"+current->param+".argv_field(:"+name+")`: "+name+" is declared :"+f->type+", not :user_str_array (E151)");
      checked.field=name;checked.offset=f->offset;
    } else {
      if(as.size()!=1||text(as[0],"kind")!="IntegerNode")return bad(call,"`"+form+"` takes one Integer literal n — a declared parameter number (P020)");
      auto n=c.integer(as[0]);if(failed(n))return failure();auto number=std::to_string(*n);
      auto p=llvm::find_if(current->params,[&](const auto &p){return p.first==*n;});
      if(p==current->params.end())return bad(as[0],"`"+current->param+".argv_arg("+number+")`: "+number+" is not a parameter number declared in `BPF.uprobe … params:` (1..6, 1-origin like the schema's n) (P020)");
      if(p->second!="user_str_array")return bad(call,"`"+current->param+".argv_arg("+number+")`: parameter "+number+" is declared :"+p->second+", not :user_str_array (E151)");
      checked.n=*n;
    }
    if(text(c.types[c.id(call)].front(),"kind")!="obj_UserStrArray") {
      (void)c.error(call,"argv source lacks its recorded UserStrArray type");return failure();
    }
    return std::shared_ptr<const UserStringArg>(std::make_shared<UserStringArg>(std::move(checked)));
  }
  FailureOr<Value> emitUser(Consumer &c, const UserStringArg &arg, Location loc,bool array=false) {
    bool tp = arg.source == UserStringSource::Tracepoint;
    bool ks = arg.source == UserStringSource::Ksyscall;
    bool valid = arg.valueKind==(array?UserStringValueKind::Array:UserStringValueKind::String) && (tp || ks) && !c.probing && c.contextValue && current && arg.node &&
                 arg.def == current->def && c.activeDef == current->def &&
                 c.activeKind == current->kind && current->kind == (tp ? "tracepoint" : "ksyscall") &&
                 context(c, c.ref(arg.node, "receiver"));
    auto args = arg.node ? c.args(arg.node) : SmallVector<Operation *>{};
    auto type=array?"user_str_array":"user_str";
    if (valid && tp) valid = field(arg.node, "strings", "name") == (array?"argv_field":"str_field") && args.size() == 1 &&
        text(args[0], "kind") == "SymbolNode" && c.spelling(args[0], true) == arg.field &&
        llvm::any_of(current->fields, [&](const Field &f) { return f.name == arg.field && f.offset == arg.offset && f.type == type; });
    if (valid && ks) valid = field(arg.node, "strings", "name") == (array?"argv_arg":"str_arg") && args.size() == 1 &&
        text(args[0], "kind") == "IntegerNode" && text(args[0], "literal_decimal") == std::to_string(arg.n) &&
        llvm::any_of(current->params, [&](const auto &p) { return p.first == arg.n && p.second == type; });
    if (!valid) {
      (void)c.error(arg.node, "tracing user-string emission requires matching checked source/declaration/context metadata"); return failure();
    }
    SmallVector<NamedAttribute> attrs;
    if (tp) {
      attrs.push_back(c.builder.getNamedAttr("field", c.builder.getStringAttr(arg.field)));
      attrs.push_back(c.builder.getNamedAttr("offset", c.builder.getI64IntegerAttr(arg.offset)));
    } else attrs.push_back(c.builder.getNamedAttr("n", c.builder.getI64IntegerAttr(arg.n)));
    Type result=array?Type(ebpf::UserStrArrayType::get(c.ctx)):Type(ebpf::UserStrType::get(c.ctx));
    return operation(c, tp ? "ebpf.tp.field" : "ebpf.ksyscall.arg", result, c.contextValue, attrs, loc);
  }

  DE expression(Consumer &c, Operation *n) {
    if (!context(c, c.ref(n, "receiver"))) return DE::declined();
    auto name = field(n, "strings", "name").str(); auto as = c.args(n);
    auto bad = [&](Operation *at, const std::string &message) {
      (void)issue(c, at, "SB028", "TracingKind", message); return DE::error();
    };
    if (current->kind == "tracepoint" && name == "copy") {
      if (failed(c.known(n, CalleePolicy{"TracepointCtx#copy"}))) return DE::error();
      return bad(n, "`" + current->param + ".copy(:f)` (a byte array field) is not a value — it is accepted only as an array member's argument of `R.output(S.new(…))` or as `r.load.<member> = " + current->param + ".copy(:f)` inside `if r` of a record map's lookup (E153)");
    }
    if((current->kind=="ksyscall"&&name=="argv_arg")||(current->kind=="tracepoint"&&name=="argv_field"))
      return bad(n,"`"+current->param+"."+name+"(…)` is accepted only as the third argument of `R.output_argv(S.new(…), :arg, "+current->param+"."+name+"(…), :status, :index)` — an argv array is not a value on the eBPF side (E151)");
if ((current->kind == "tracepoint" && name == "str_field") ||
    (current->kind == "ksyscall" && name == "str_arg")) {
  CalleePolicy policy{current->klass + "#" + name};
  if (failed(c.known(n, policy))) return DE::error();
  auto arg = current->kind == "tracepoint" ? ":f" : "n";
  return bad(n, "`" + current->param + "." + name + "(" + arg + ")` is accepted only as the third argument of `R.output_str(S.new(…), :field, " + current->param + "." + name + "(" + arg + "), :status)` — a user string is not a value on the eBPF side (" + (current->kind == "tracepoint" ? "E142" : "E143") + ")");
}
bool supported =
        ((current->kind == "kprobe" || current->kind == "ksyscall" ||
          current->kind == "raw_tp") && name == "arg") ||
        (current->kind == "kretprobe" && name == "ret") ||
        (current->kind == "tracepoint" && name == "field") ||
        (current->kind == "kprobe" && name == "read");
if(!supported) {
  std::string reads;
  if(current->kind=="kprobe")reads="`ctx.arg(n)` with n a declared parameter number (1..6)";
  else if(current->kind=="ksyscall")reads="`ctx.arg(n)` with n a declared syscall argument number (1..6 — the syscall convention, the 4th is r10)";
  else if(current->kind=="raw_tp")reads="`ctx.arg(i)` with i an Integer literal 0..11 (the tracepoint's args[i], 0-origin — a raw u64: narrow it with `x & M` / `x >> K` or store it in a u64 map)";
  if(!reads.empty())return bad(n,"the "+current->kind+" context has no `"+name+"` — it reads "+reads+" (P013)");
}
    CalleePolicy policy{current->klass + "#" + name};
    policy.requireCallee = supported;
    if (failed(c.known(n, policy))) return DE::error();
    auto e = std::make_shared<ScalarExpr>(); auto payload = std::make_shared<ProbeRead>();
    e->node = n; e->payload = payload;
    std::string type;
    if (current->kind == "kprobe" && name == "read")
      return bad(n, "`" + current->param + ".read(n, offset, :type)` returns a value and a status — use it only as the statement `v, st = " + current->param + ".read(…)` (the status is read later — a failed read is 0, like a real 0) (P026)");
    if ((current->kind == "kprobe" || current->kind == "ksyscall") && name == "arg") {
      if (as.size() != 1 || text(as[0], "kind") != "IntegerNode")
        return bad(n, "`" + current->param + ".arg(n)` takes one Integer literal n — a declared parameter number (P013)");
      auto number = c.integer(as[0]); if (failed(number)) return DE::error();
      payload->index = *number;
      for (auto &p : current->params) if (p.first == *number) type = p.second;
      auto numberText = std::to_string(*number);
      if (type.empty())
        return bad(as[0], "`" + current->param + ".arg(" + numberText + ")`: " + numberText + " is not a parameter number declared in `BPF." + current->kind + " … params:` (numbers are 1..6, 1-origin like the schema's n) (P013)");
if (type == "user_str_array")
  return bad(n,"`"+current->param+".arg("+numberText+")`: parameter "+numberText+" is declared :user_str_array — read its strings with `"+current->param+".argv_arg("+numberText+")` as the third argument of `R.output_argv` (E151)");
if (type == "user_str")
  return bad(n, "`" + current->param + ".arg(" + numberText + ")`: parameter " + numberText + " is declared :user_str — read the string with `" + current->param + ".str_arg(" + numberText + ")` as the third argument of `R.output_str` (E143)");
e->kind = current->kind == "kprobe" ? "gprobe.arg" : "gprobe.sysarg";
    } else if (current->kind == "raw_tp" && name == "arg") {
      if (as.size() != 1 || text(as[0], "kind") != "IntegerNode")
        return bad(n, "`" + current->param + ".arg(i)` takes one Integer literal i — the tracepoint's args index 0..11 (P026)");
      auto number = c.integer(as[0]); if (failed(number)) return DE::error();
      if (*number < 0 || *number > 11)
        return bad(as[0], "`" + current->param + ".arg(" + std::to_string(*number) + ")`: a raw_tp argument index is 0..11 (args[i] of bpf_raw_tracepoint_args — 0-origin, unlike the 1-origin register numbers of `BPF.kprobe … params:`) (P026)");
      payload->index = *number; type = "u64"; e->kind = "gprobe.rawarg";
    } else if (current->kind == "kretprobe" && name == "ret") {
      if (!as.empty()) return bad(n, "probe return read requires no arguments");
      type = current->ret; e->kind = "gprobe.ret";
    } else if (current->kind == "tracepoint" && name == "field") {
      if (as.size() != 1 || text(as[0], "kind") != "SymbolNode")
        return bad(n, "`" + current->param + ".field(:name)` takes one Symbol literal — a field declared in `BPF.tracepoint … fields:` (P026)");
      auto fieldName = c.spelling(as[0], true).str();
      for (auto &f : current->fields) if (f.name == fieldName) {
        if (f.count)
          return bad(n, "`" + current->param + ".field(:" + fieldName + ")`: " + fieldName + " is declared as a byte array [:" + f.type + ", " + std::to_string(f.count) + "] — copy it with `" + current->param + ".copy(:" + fieldName + ")` into a `[:u8, " + std::to_string(f.count) + "]` member of the event (E153)");
        type = f.type; payload->index = f.offset; payload->field = f.name;
      }
      if (type.empty()) return bad(as[0], "`" + current->param + ".field(:" + fieldName + ")`: " + fieldName + " is not declared in `BPF.tracepoint … fields:` (declare its offset and type from the tracefs format) (P026)");
if (type == "user_str")
  return bad(n, "`" + current->param + ".field(:" + fieldName + ")`: " + fieldName + " is declared :user_str — read the string with `" + current->param + ".str_field(:" + fieldName + ")` as the third argument of `R.output_str` (E142)");
if (type == "user_str_array")
  return bad(n,"`"+current->param+".field(:"+fieldName+")`: "+fieldName+" is declared :user_str_array — read its strings with `"+current->param+".argv_field(:"+fieldName+")` as the third argument of `R.output_argv` (E151)");
e->kind = "gprobe.field";
    } else {
      std::string reads = current->kind == "tracepoint"
          ? "`" + current->param + ".field(:name)` with name a field declared in `BPF.tracepoint … fields:` (its declared type)"
          : current->kind == "kretprobe" ? "`" + current->param + ".ret` (the declared return type — the return register; arguments are not readable on return)"
          : "the context's declared integer fields";
      return bad(n, "the " + current->kind + " context has no `" + name + "` — it reads " + reads + " (P013)");
    }
    // E146: a declared kprobe pointer is its raw signed i64 value, not a dereference.
    auto t = current->kind == "kprobe" && type == "ptr"
                 ? std::optional<IntType>(IntType{64, true}) : integerType(type);
    if (!t) { (void)c.error(n, "probe checked integer type is missing"); return DE::error(); }
    payload->type = *t;
    auto source = e->kind == "gprobe.ret" ? tracing::IntegerSource::KprobeReturn
                 : e->kind == "gprobe.rawarg" ? tracing::IntegerSource::RawArgument
                 : e->kind == "gprobe.field" ? tracing::IntegerSource::TracepointField
                 : tracing::IntegerSource::Argument;
    auto range = tracing::integerRange(t->bits, t->sign, source);
    if (!range) { (void)c.rangeFailure(range.takeError(), n); return DE::error(); }
    e->range = *range;
    return DE::handled(std::move(e));
  }
  Dispatch<Value> emit(Consumer &c, const Expr &e) {
    auto p = std::static_pointer_cast<const ProbeRead>(e->payload);
    if (!p || !c.contextValue) { (void)c.error(e->node, "probe emission lacks checked metadata/context"); return Dispatch<Value>::error(); }
    auto loc = outputLoc(e->node); auto type = c.builder.getIntegerType(p->type.bits);
    SmallVector<NamedAttribute> attrs; StringRef op;
    if (e->kind == "gprobe.ret") op = "ebpf.probe.retval";
    else if (e->kind == "gprobe.rawarg") {
      op = "ebpf.ctx.field";
      attrs.push_back(c.builder.getNamedAttr("field", c.builder.getStringAttr("args")));
      attrs.push_back(c.builder.getNamedAttr("index", c.builder.getI64IntegerAttr(p->index)));
    } else if (e->kind == "gprobe.field") {
      op = "ebpf.tp.field";
      attrs.push_back(c.builder.getNamedAttr("field", c.builder.getStringAttr(p->field)));
      attrs.push_back(c.builder.getNamedAttr("offset", c.builder.getI64IntegerAttr(p->index)));
    } else {
      op = e->kind == "gprobe.sysarg" ? "ebpf.ksyscall.arg" : "ebpf.kprobe.arg";
      int64_t index = p->index;
#ifdef SPINEL_E031_TEST_WRONG_ARG
      // Same-width syscall parameters: schema remains valid while the read
      // changes its meaning (the control must reach IR and ELF comparison).
      if (e->kind == "gprobe.sysarg" && (index == 2 || index == 3))
        index = index == 2 ? 3 : 2;
#endif
      attrs.push_back(c.builder.getNamedAttr("n", c.builder.getI64IntegerAttr(index)));
    }
    return Dispatch<Value>::handled(extend(c, operation(c, op, type, c.contextValue, attrs, loc), p->type, loc));
  }
  DS statement(Consumer &c, ArrayRef<Operation *> list, size_t index, unsigned) {
    auto n = list[index];
    if (!current || c.activeDef != current->def || c.activeKind != current->kind)
      return DS::declined();
    if (text(n, "kind") != "MultiWriteNode") return DS::declined();
    auto call = c.ref(n, "value"); auto left = c.array(n, "lefts");
    auto bad = [&](Operation *at, StringRef code, StringRef label, const std::string &message) {
      (void)issue(c, at, code, label, message); return DS::error();
    };
    if (current->kind != "kprobe" || text(call, "kind") != "CallNode" ||
        field(call, "strings", "name") != "read" || left.size() != 2 ||
        c.ref(n, "rest") || !c.array(n, "rights").empty())
      return bad(n, "SB028", "TracingKind", "a multiple assignment is accepted only as `v, st = " + current->param + ".read(n, offset, :type)` in a kprobe program (two locals — the value and the status) (P026)");
    for (auto target : left)
      if (text(target, "kind") != "LocalVariableTargetNode")
        return bad(target, "SB028", "TracingKind", "`… = " + current->param + ".read(…)` assigns two plain locals (the value and the status) (P026)");
    if (!context(c, c.ref(call, "receiver")))
      return bad(call, "SB011", "ShadowedName", "`read` receiver is not the program context");
    if (failed(c.known(call, CalleePolicy{"KprobeCtx#read"}))) return DS::error();
    auto as = c.args(call);
    if (as.size() != 3 || text(as[0], "kind") != "IntegerNode" || text(as[1], "kind") != "IntegerNode" || text(as[2], "kind") != "SymbolNode")
      return bad(call, "SB028", "TracingKind", "`" + current->param + ".read(n, offset, :type)` takes a parameter number, an offset (Integer literals) and a type Symbol :i8 … :u64 (P026)");
    auto number = c.integer(as[0]), offset = c.integer(as[1]);
    if (failed(number) || failed(offset)) return DS::error();
    bool ptr = llvm::any_of(current->params, [&](auto &p) { return p.first == *number && p.second == "ptr"; });
    if (!ptr) return bad(as[0], "SB028", "TracingKind", "`" + current->param + ".read(" + std::to_string(*number) + ", …)`: parameter " + std::to_string(*number) + " is not declared :ptr in `BPF.kprobe … params:` (P026)");
    if (*offset < 0 || *offset > 4095)
      return bad(as[1], "SB028", "TracingKind", "`" + current->param + ".read(" + std::to_string(*number) + ", " + std::to_string(*offset) + ", …)`: the offset is 0..4095 (P026)");
    auto typeName = c.spelling(as[2], true).str(); auto t = integerType(typeName);
    if (!t) return bad(as[2], "SB028", "TracingKind", "`" + current->param + ".read(…, :" + typeName + ")`: the type is one of :i8 … :i64 / :u8 … :u64 (P026)");
    auto vn = field(left[0], "strings", "name").str(), sn = field(left[1], "strings", "name").str();
    if (sn == "_")
      return bad(left[1], "SB026", "StatusIgnored", "the status of `" + current->param + ".read` is dropped — a failed read returns 0 like a real 0; receive it as `v, st = " + current->param + ".read(…)` and read `st` (e.g. `if st == 0`) (P026)");
    for (auto name : {vn, sn})
      if (name != "_" && (c.locals.count(name) || c.borrows.count(name) || name == current->param))
        return bad(n, "SB028", "TracingKind", "`" + name + "` is already bound — `v, st = " + current->param + ".read(…)` binds two fresh names (P026)");
    unsigned writes = 0, reads = 0; llvm::DenseSet<Operation *> seen;
    std::function<void(Operation *)> walk = [&](Operation *node) {
      if (!node || !seen.insert(node).second) return;
      auto kind = text(node, "kind");
      if (field(node, "strings", "name") == sn) {
        if (kind == "LocalVariableReadNode") ++reads;
        if (kind == "LocalVariableWriteNode" || kind == "LocalVariableOperatorWriteNode" || kind == "LocalVariableOrWriteNode" || kind == "LocalVariableAndWriteNode" || kind == "LocalVariableTargetNode") ++writes;
      }
      if (auto refs = node->getAttrOfType<DictionaryAttr>("refs"))
        for (auto item : refs) walk(c.nodes.lookup(cast<IntegerAttr>(item.getValue()).getInt()));
      if (auto arrays = node->getAttrOfType<DictionaryAttr>("arrays"))
        for (auto item : arrays) for (auto id : cast<ArrayAttr>(item.getValue())) walk(c.nodes.lookup(cast<IntegerAttr>(id).getInt()));
    };
    walk(current->def);
#ifndef SPINEL_E031_TEST_IGNORE_STATUS
    if (writes != 1) return bad(left[1], "SB026", "StatusIgnored", "`" + sn + "` holds the status of `" + current->param + ".read` but is assigned " + std::to_string(writes) + " times — a status local is assigned once (P026)");
    if (!reads) return bad(left[1], "SB026", "StatusIgnored", "`" + sn + "` holds the status of `" + current->param + ".read` but is never read — check it (e.g. `if " + sn + " == 0`): a failed read returns 0 like a real 0 (P026)");
#endif
    if (c.probing) { (void)c.error(n, "E031 read statement cannot emit during Probe"); return DS::error(); }
    auto loc = outputLoc(n); auto i64 = c.builder.getI64Type();
    auto addr = operation(c, "ebpf.kprobe.arg", i64, c.contextValue,
        {c.builder.getNamedAttr("n", c.builder.getI64IntegerAttr(*number))}, loc);
    OperationState rs(loc, "ebpf.kernel.read_scalar"); rs.addOperands(addr);
    rs.addTypes({c.builder.getIntegerType(t->bits), i64});
    rs.addAttribute("offset", c.builder.getI64IntegerAttr(*offset)); auto op = c.builder.create(rs);
    auto range = tracing::integerRange(t->bits, t->sign, tracing::IntegerSource::KernelRead);
    if (!range) { (void)c.rangeFailure(range.takeError(), n); return DS::error(); }
    if (vn != "_") {
      auto e = std::make_shared<ScalarExpr>(); e->node = n; e->kind = "local"; e->name = vn; e->range = *range;
      c.locals[vn] = {e, extend(c, op->getResult(0), *t, loc)};
    }
    auto status = std::make_shared<ScalarExpr>(); status->node = n; status->kind = "local"; status->name = sn;
    status->range = tracing::readStatusRange(); c.locals[sn] = {status, op->getResult(1)};
    return DS::handled({1});
  }
};
static void writeInt(llvm::json::OStream &out, StringRef name) {
  auto t = integerType(name);
  out.object([&] {
    out.attribute("kind", "int"); out.attribute("bits", t->bits);
    out.attribute("signed", t->sign); out.attribute("endianness", "little");
    out.attribute("alignment", t->bits / 8);
  });
}
static Dispatch<ExportFields> exportProgram(Consumer &c, size_t i, bool) {
  if (i >= c.programs.size()) return Dispatch<ExportFields>::error();
  auto &p = c.programs[i]; auto d = std::static_pointer_cast<const ProbeDecl>(p.payload);
  if (!d) return Dispatch<ExportFields>::error();
  ExportFields fields;
  fields.emplace_back("name", p.name); fields.emplace_back("kind", p.kind);
  fields.emplace_back("attach_target", p.attachTarget);
  std::vector<std::string> maps;
  for (auto index : p.maps) maps.push_back(c.maps[index].name);
  fields.emplace_back("maps", ExportValue::write([maps](auto &out) { out.array([&] { for (auto &m : maps) out.value(m); }); }));
  if (!p.arch.empty()) fields.emplace_back("arch", p.arch);
  if (!d->params.empty()) fields.emplace_back("params", ExportValue::write([params=d->params](auto &out) {
    out.array([&] { for (auto &p : params) out.object([&] {
      out.attribute("n", p.first); out.attributeBegin("type");
      if (p.second == "ptr" || p.second == "user_str" || p.second == "user_str_array") out.object([&] { out.attribute("kind", p.second); });
      else writeInt(out, p.second);
      out.attributeEnd();
    }); });
  }));
  if (!d->fields.empty()) fields.emplace_back("fields", ExportValue::write([decls=d->fields](auto &out) {
    out.array([&] { for (auto &f : decls) out.object([&] {
      out.attribute("name", f.name); out.attribute("offset", f.offset);
      out.attributeBegin("type");
      if (f.count) out.object([&] { out.attribute("kind", "array"); out.attribute("elem", f.type); out.attribute("n", f.count); });
      else if (f.type == "user_str" || f.type == "user_str_array") out.object([&] { out.attribute("kind", f.type); });
      else writeInt(out, f.type);
      out.attributeEnd();
    }); });
  }));
  fields.emplace_back("note", "Ruby def " + p.name);
  return Dispatch<ExportFields>::handled(std::move(fields));
}
} // namespace
void diagnoseRejectedTracingStringLocal(Consumer &c,
    llvm::ArrayRef<Operation *> list, size_t index, unsigned depth,
    size_t beforeDiagnostics) {
  // Go assign poisons the failed binding but stmts keeps checking. Only the
  // output-string shape diagnostics below can run without that binding's value.
  if (c.probing || !c.blocking || !c.runDiagnostics || !c.activeDef ||
      index >= list.size() || (c.activeKind != "tracepoint" && c.activeKind != "ksyscall") ||
      c.runDiagnostics->size() != beforeDiagnostics + 1)
    return;
  auto write = list[index]; auto value = c.ref(write, "value");
  auto loc = value ? dyn_cast<FileLineColLoc>(value->getLoc()) : FileLineColLoc();
  const auto &first = c.runDiagnostics->back();
  auto parameters = c.array(c.ref(c.activeDef, "parameters"), "requireds");
  auto receiver = c.ref(value, "receiver");
  if (text(write, "kind") != "LocalVariableWriteNode" || text(value, "kind") != "CallNode" ||
      (field(value, "strings", "name") != (c.activeKind == "tracepoint" ? "str_field" : "str_arg") &&
       field(value, "strings", "name") != (c.activeKind == "tracepoint" ? "argv_field" : "argv_arg")) ||
      parameters.size() != 1 || text(receiver, "kind") != "LocalVariableReadNode" ||
      field(receiver, "strings", "name") != field(parameters.front(), "strings", "name") ||
      !loc || first.verdict != Consumer::DiagnosticVerdict::Rejected || first.rejectedCode != "SB028" ||
      first.line != loc.getLine() || first.col != loc.getColumn())
    return;
  // A name marker only: no Expr, local value, argument type or SSA is invented.
  const std::string poisoned = field(write, "strings", "name").str();
  const bool array=field(value,"strings","name").starts_with("argv_");
  if (poisoned.empty() || poisoned == "_") return;
  const bool initialBlocking = c.blocking;
  auto restoreBlocking = llvm::make_scope_exit([&] { c.blocking = initialBlocking; });
  for (size_t i = index + 1; i < list.size(); ++i) {
    auto node = list[i];
    if (text(node, "kind") != "LocalVariableWriteNode") continue;
    auto call = c.ref(node, "value"); auto method = field(call, "strings", "name");
    if (text(call, "kind") != "CallNode" ||
        (array ? method!="output_argv" : (method != "output_str" && method != "output_str_or_discard"))) continue;
    auto args = c.args(call);
    if (args.size() < 3 || text(args[2], "kind") != "LocalVariableReadNode" ||
        field(args[2], "strings", "name") != poisoned ||
        !llvm::any_of(c.rings, [&](const RingDecl &ring) {
          return ring.constant == c.constant(c.ref(call, "receiver"));
        })) continue;
    ScopeGuard scope(c); // Deliberately never commit a diagnostic-only dispatch.
    auto *block = c.builder.getInsertionBlock();
    if (!block) { (void)c.error(node, "user-string diagnostic continuation has no IR scope"); return; }
    Operation *ir = block->getParentOp();
    while (ir->getParentOp()) ir = ir->getParentOp();
    auto snapshot = [&] {
      std::string text; llvm::raw_string_ostream stream(text); ir->print(stream); return text;
    };
    const auto beforeIR = snapshot();
    const size_t before = c.runDiagnostics->size();
    c.blocking = false;
    auto result = c.dispatchStatement("LocalVariableWriteNode", list, i, depth);
    const bool actualErrors = c.runDiagnostics->size() > before &&
        llvm::all_of(llvm::drop_begin(*c.runDiagnostics, before), [](const Consumer::PendingDiagnostic &d) {
          return d.verdict == Consumer::DiagnosticVerdict::Rejected && !d.rejectedCode.empty();
        });
    if (snapshot() != beforeIR) {
      (void)c.error(node, "user-string diagnostic continuation changed IR/regions/operations"); return;
    }
    if (result.state != Disposition::Error || !actualErrors) {
      (void)c.error(node, "user-string diagnostic continuation requires an actual shape rejection"); return;
    }
  }
}

Dispatch<Expr> checkTracepointRecordCopy(Consumer &c, Operation *node,
    const record::Layout &layout, const record::FieldLayout &target,
    bool, Operation *destination) {
  if (text(node,"kind") != "CallNode" || field(node,"strings","name") != "copy")
    return Dispatch<Expr>::declined();
  auto result = c.dispatchExpression("TracepointRecordAccess", node);
  if (result.state == Disposition::Declined && c.activeKind == "tracepoint" && c.activeDef) {
    auto parameters = c.array(c.ref(c.activeDef, "parameters"), "requireds");
    auto receiver = c.ref(node, "receiver");
    if (parameters.size() == 1 && text(receiver,"kind") == "LocalVariableReadNode" &&
        field(receiver,"strings","name") == field(parameters.front(),"strings","name"))
      return (void)c.error(node,"tracepoint copy check handler is unavailable for the active context"), Dispatch<Expr>::error();
  }
  if (result.state != Disposition::Handled) return result;
  auto expr = *result.value;
  if (expr->kind != "gprobe.record-copy")
    return (void)c.error(node,"tracepoint copy check returned another kind"), Dispatch<Expr>::error();
  auto p = std::static_pointer_cast<const TracepointRecordAccess>(expr->payload);
  auto bad = [&](const std::string &message) {
    (void)c.diagnostic(destination ? destination : node,"SB028","TracingKind",message,true);
    return Dispatch<Expr>::error();
  };
  if (!target.count || target.bits != 8)
    return bad("member " + target.name + " of " + layout.name + " is not an 8-bit array — `" + p->parameter + ".copy(:" + p->field + ")` copies " + std::to_string(p->count) + " bytes into a `[:u8, " + std::to_string(p->count) + "]` member (E153)");
  if (*target.count != p->count)
    return bad("member " + target.name + " of " + layout.name + " has " + std::to_string(*target.count) + " elements but " + p->field + " is a " + std::to_string(p->count) + "-byte array — the copy is a fixed N bytes, declare the same N (E153)");
  return result;
}
LogicalResult emitTracepointRecordCopy(Consumer &c, const Expr &expr,
    Value destination, StringRef member, Location loc) {
  if (!expr || expr->kind != "gprobe.record-copy" || !expr->payload || c.probing ||
      c.activeKind != "tracepoint" || !c.contextValue || !destination)
    return c.error(expr ? expr->node : nullptr,"tracepoint copy emission requires a checked active context and destination");
  auto checked = std::static_pointer_cast<const TracepointRecordAccess>(expr->payload);
  auto fresh = c.dispatchExpression("TracepointRecordAccess", expr->node);
  if (fresh.state != Disposition::Handled)
    return c.error(expr->node,"tracepoint copy emission lost its checked source declaration");
  auto source = std::static_pointer_cast<const TracepointRecordAccess>((*fresh.value)->payload);
  if (checked->definition != c.activeDef || checked->definition != source->definition ||
      checked->parameter != source->parameter || checked->field != source->field ||
      checked->element != source->element || checked->offset != source->offset || checked->count != source->count ||
      c.contextValue.getType() != ebpf::ContextType::get(c.ctx,"tracepoint") ||
      !isa<ebpf::ReservationType,ebpf::BorrowedType>(destination.getType()))
    return c.error(expr->node,"tracepoint copy emission source/declaration/context metadata mismatch");
#ifdef SPINEL_E077_TEST_TP_COPY_DROP
  if (checked->field == "daddr") return success(); // One field in the single-program sensitivity fixture.
#endif
  ebpf::TpFieldCopyOp::create(c.builder,loc,destination,member,c.contextValue,checked->field,checked->offset);
  return success();
}
void registerGroupGProbe(Registry &registry) {
  auto state = std::make_shared<Probe>();
  registry.addExpression("TracepointRecordAccess", [state](Consumer &c, Operation *n) { return state->copySource(c,n); });
  for (auto kind : {"kprobe", "kretprobe", "ksyscall", "raw_tp", "tracepoint"})
    registry.addRoot(kind, [state](Consumer &c, Operation *n) { return state->root(c, n); });
  registry.addExpression("CallNode", [state](Consumer &c, Operation *n) { return state->expression(c, n); });
  registry.addStatement("MultiWriteNode", [state](Consumer &c, ArrayRef<Operation *> list, size_t index, unsigned depth) { return state->statement(c, list, index, depth); });
  for (auto kind : {"gprobe.arg", "gprobe.sysarg", "gprobe.ret", "gprobe.rawarg", "gprobe.field"})
    registry.addEmitter(kind, [state](Consumer &c, const Expr &e) { return state->emit(c, e); });
  for (auto kind : {"kprobe", "kretprobe", "ksyscall", "raw_tp", "tracepoint"})
    registry.addProgramExporter(kind, exportProgram);
registerGroupGUprobe(registry);
registry.uprobe->checkedUserStringArray=[state](Consumer &c,Operation *n){return state->userArray(c,n);};
registry.uprobe->emitUserStringArray=[state](Consumer &c,const UserStringArg &a,Location l){return state->emitUser(c,a,l,true);};
// Save callbacks by value: routing never recursively looks up its wrapper.
auto checkUprobe = registry.uprobe->checkedUserString;
auto emitUprobe = registry.uprobe->emitUserString;
registry.uprobe->checkedUserString = [state, checkUprobe](Consumer &c, Operation *n) -> FailureOr<std::shared_ptr<const UserStringArg>> {
  if (c.activeKind == "tracepoint" || c.activeKind == "ksyscall") return state->userString(c, n);
  if (!checkUprobe) { (void)c.error(n, "uprobe user-string check hook is unavailable"); return failure(); }
  return checkUprobe(c, n);
};
registry.uprobe->emitUserString = [state, emitUprobe](Consumer &c, const UserStringArg &arg, Location loc) -> FailureOr<Value> {
  if (arg.source == UserStringSource::Tracepoint || arg.source == UserStringSource::Ksyscall) return state->emitUser(c, arg, loc);
  if (arg.source != UserStringSource::Uprobe || c.activeKind != "uprobe") {
    (void)c.error(arg.node, "user-string emission source does not match active context"); return failure();
  }
  if (!emitUprobe) { (void)c.error(arg.node, "uprobe user-string emit hook is unavailable"); return failure(); }
  return emitUprobe(c, arg, loc);
};
}
} // namespace spinel::consumer
