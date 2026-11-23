// Read/validate freestanding YAML. P1 covers sections/keys/ranges; P2 one extern entry. Match
// frozen FsProfile.__init__ check order so multiple-defect profiles retain the same first refusal
// and A/B stage.
#include "spinel-mlir/Freestanding/Profile.h"

#include "ProfileYaml.h"

#include "llvm/ADT/STLExtras.h"
#include "llvm/ADT/StringSwitch.h"
#include "llvm/ADT/SmallString.h"
#include "llvm/ADT/StringExtras.h"
#include "llvm/ADT/StringSet.h"
#include "llvm/Support/SourceMgr.h"
#include "llvm/Support/YAMLParser.h"
#include "llvm/Support/raw_ostream.h"

#include <algorithm>

using namespace llvm;

namespace spinel_mlir::freestanding {

// Closed sets matching the initial measured contract.
static const StringRef kBoundaryScalars[] = {"i8", "i16", "i32", "i64",
                                             "u8", "u16", "u32",
                                             "f32", "f64"};
static const StringRef kBufferElems[] = {"i8", "i16", "i32", "i64",
                                         "u8", "u16", "u32", "f32", "f64"};
static const StringRef kBufferDirs[] = {"in", "out", "inout"};
static const StringRef kOverflow[] = {"trap", "wrap"};
static const StringRef kBounds[] = {"trap", "unchecked"};
static const StringRef kExternTypes[] = {"i32", "u32", "i64", "f32", "f64"};
static const StringRef kExternReserved[] = {
    "freestanding_def", "gets", "loop", "p", "print",
    "puts", "raise", "require", "require_relative"};

ArrayRef<StringRef> boundaryScalarTypes() { return kBoundaryScalars; }
ArrayRef<StringRef> bufferElementTypes() { return kBufferElems; }
ArrayRef<StringRef> bufferDirections() { return kBufferDirs; }

StringRef cScalarType(StringRef fsType) {
  // Nine boundary scalar types. New unhandled members return empty; callers must refuse that
  // explicitly by name.
  return StringSwitch<StringRef>(fsType)
      .Case("i8", "int8_t")
      .Case("i16", "int16_t")
      .Case("i32", "int32_t")
      .Case("i64", "int64_t")
      .Case("u8", "uint8_t")
      .Case("u16", "uint16_t")
      .Case("u32", "uint32_t")
      .Case("f32", "float")
      .Case("f64", "double")
      .Default(StringRef());
}

bool isCIdentifier(StringRef s) {
  if (s.empty())
    return false;
  if (!(isAlpha(s[0]) || s[0] == '_'))
    return false;
  return llvm::all_of(s, [](char c) { return isAlnum(c) || c == '_'; });
}
ArrayRef<StringRef> overflowModes() { return kOverflow; }
ArrayRef<StringRef> boundsModes() { return kBounds; }
ArrayRef<StringRef> externTypes() { return kExternTypes; }
ArrayRef<StringRef> externReservedNames() { return kExternReserved; }

// Fix cardinality: silent expansion would turn formerly refused forms into acceptance.
static_assert(sizeof(kBoundaryScalars) / sizeof(StringRef) == 9, "");
static_assert(sizeof(kBufferElems) / sizeof(StringRef) == 9, "");
static_assert(sizeof(kBufferDirs) / sizeof(StringRef) == 3, "");
static_assert(sizeof(kOverflow) / sizeof(StringRef) == 2, "");
static_assert(sizeof(kBounds) / sizeof(StringRef) == 2, "");
static_assert(sizeof(kExternTypes) / sizeof(StringRef) == 5, "");
static_assert(sizeof(kExternReserved) / sizeof(StringRef) == 9, "");

const FsExtern *FreestandingProfile::findExtern(StringRef name) const {
  for (const FsExtern &e : externs_)
    if (e.name == name)
      return &e;
  return nullptr;
}

void markPlatformFirst(FreestandingProfile &p, StringRef basePath) {
  p.platformFirst_ = true;
  p.basePath_ = basePath.str();
}

std::string joinSorted(std::vector<std::string> names, StringRef sep) {
  std::sort(names.begin(), names.end());
  std::string out;
  for (size_t i = 0; i < names.size(); ++i) {
    if (i)
      out += sep.str();
    out += names[i];
  }
  return out;
}

YNode convert(yaml::Node *node, const std::string &path, std::string *dup) {
  YNode out;
  if (!node)
    return out;
  if (auto *s = dyn_cast<yaml::ScalarNode>(node)) {
    SmallString<64> storage;
    out.kind = YNode::Kind::Scalar;
    out.scalar = s->getValue(storage).str();
    return out;
  }
  if (auto *s = dyn_cast<yaml::BlockScalarNode>(node)) {
    out.kind = YNode::Kind::Scalar;
    out.scalar = s->getValue().str();
    return out;
  }
  if (auto *seq = dyn_cast<yaml::SequenceNode>(node)) {
    out.kind = YNode::Kind::Sequence;
    for (yaml::Node &e : *seq)
      out.seq.push_back(convert(&e, path.empty() ? std::string("[]")
                                                 : path + "[]",
                                dup));
    return out;
  }
  if (auto *map = dyn_cast<yaml::MappingNode>(node)) {
    out.kind = YNode::Kind::Mapping;
    for (yaml::KeyValueNode &kv : *map) {
      YNode key = convert(kv.getKey(), path, dup);
      // Copy the entire value before advancing the streaming iterator.
      std::string child =
          key.isScalar() ? (path.empty() ? key.scalar : path + "." + key.scalar)
                         : path;
      YNode value = convert(kv.getValue(), child, dup);
      if (!key.isScalar())
        return YNode();
      // Record the first duplicate mapping key and continue walking. Do not construct a last-wins
      // tree; refusal makes value selection irrelevant.
      if (dup && dup->empty() && out.find(key.scalar))
        *dup = child;
      out.map.emplace_back(key.scalar, std::move(value));
    }
    return out;
  }
  // null/alias/other remain Bad for explicit caller refusal.
  return out;
}

// Before P0: text to tree.
std::optional<YNode> parseProfileYaml(StringRef path, StringRef yamlText,
                                      FsDiagnosticFn diag) {
  ProfileBuilder b(path, diag);
  SourceMgr sm;
  // Capture parse errors instead of leaking stderr; name the failure below.
  sm.setDiagHandler([](const SMDiagnostic &, void *) {}, nullptr);
  yaml::Stream stream(yamlText, sm);
  yaml::document_iterator doc = stream.begin();
  YNode root;
  std::string dupKey;
  if (doc != stream.end() && doc->getRoot()) {
    root = convert(doc->getRoot(), "", &dupKey);
    ++doc;
    if (doc != stream.end()) {
      b.reject(Stage::P1, Category::UnknownProfileKey, "profile", 0,
               "exactly one YAML document is required");
      return std::nullopt;
    }
  }
  if (!dupKey.empty()) {
    b.reject(Stage::P1, Category::UnknownProfileKey, dupKey, 0,
             "duplicate key '" + dupKey +
                 "' -- a profile key is written once (the frozen Python takes "
                 "the last one, so a duplicate silently changes policy)");
    return std::nullopt;
  }
  if (!root.isMap()) {
    b.reject(Stage::P1, Category::UnknownProfileKey, "", 0,
             "a profile is a YAML mapping with target/abi/runtime/platform");
    return std::nullopt;
  }
  return root;
}

namespace {

bool isRubyMethodName(StringRef s) {
  if (s.empty())
    return false;
  if (!((s[0] >= 'a' && s[0] <= 'z') || s[0] == '_'))
    return false;
  return llvm::all_of(s, [](char c) {
    return (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_';
  });
}

// Section to key/required mapping, one-to-one with frozen FS_PROFILE_SCHEMA.
struct SchemaKey { StringRef key; bool required; };
struct SchemaSection { StringRef name; ArrayRef<SchemaKey> keys; };

const SchemaKey kTargetKeys[] = {
    {"triple", true}, {"cpu", false}, {"data_layout", false}, {"cflags", false}};
const SchemaKey kAbiKeys[] = {{"boundary", true},
                              {"int_width", true},
                              {"overflow", true},
                              {"trap_hook", true}};
const SchemaKey kRuntimeKeys[] = {
    {"libc", true}, {"libm", true}, {"compiler_rt", true}};
const SchemaKey kPlatformKeys[] = {{"type", true}, {"externs", false}};
const SchemaSection kSchema[] = {{"target", kTargetKeys},
                                 {"abi", kAbiKeys},
                                 {"runtime", kRuntimeKeys},
                                 {"platform", kPlatformKeys}};
static_assert(sizeof(kSchema) / sizeof(SchemaSection) == 4, "");

std::string keyList(ArrayRef<SchemaKey> keys) {
  std::vector<std::string> names;
  for (const SchemaKey &k : keys)
    names.push_back(k.key.str());
  std::sort(names.begin(), names.end());
  std::string out;
  for (size_t i = 0; i < names.size(); ++i) {
    if (i)
      out += ", ";
    out += names[i];
  }
  return out;
}

} // namespace

// ---- Stage P2: one extern entry ----------------------------------------------
static bool readExtern(ProfileBuilder &b, const YNode &entry,
                       StringSet<> &seenNames, StringSet<> &seenSymbols,
                       StringRef trapHook, StringRef platformType,
                       FsExtern &out) {
  // Unknown key: omit subject because frozen code fails before reading name. The 2026-08-31
  // decision preserves that omission.
  static const StringRef kEntryKeys[] = {"name", "symbol", "params", "returns"};
  std::vector<std::string> unknown;
  for (const auto &kv : entry.map)
    if (!contains(kEntryKeys, kv.first))
      unknown.push_back(kv.first);
  if (!unknown.empty()) {
    std::sort(unknown.begin(), unknown.end());
    std::string list;
    for (size_t i = 0; i < unknown.size(); ++i) {
      if (i) list += ", ";
      list += unknown[i];
    }
    return b.reject(Stage::P2, Category::UnknownProfileKey, "", 0,
                    "platform.externs: unknown key(s) " + list +
                        " (known: name, symbol, params, returns)");
  }

  // (2) name
  const YNode *nameNode = entry.find("name");
  std::string name = (nameNode && nameNode->isScalar()) ? nameNode->scalar : "";
  if (!isRubyMethodName(name))
    return b.reject(Stage::P2, Category::UndeclaredPlatformExtern, name, 0,
                    "platform.externs: name '" + name +
                        "' is not a Ruby method name");
  if (contains(kExternReserved, name))
    return b.reject(Stage::P2, Category::UndeclaredPlatformExtern, name, 0,
                    "platform.externs: '" + name +
                        "' is reserved (the synthesized driver could not stub "
                        "it without shadowing a builtin)");

  // Symbol: platform.type none has no default namespace.
  std::string symbol;
  const YNode *symNode = entry.find("symbol");
  if (!symNode) {
    if (platformType == "none")
      return b.reject(Stage::P2, Category::UndeclaredPlatformExtern, name, 0,
                      "platform.externs: '" + name +
                          "' needs an explicit `symbol:` under platform.type "
                          "none (there is no platform namespace to default "
                          "into)");
    symbol = ("spinel_" + platformType + "_" + name).str();
  } else if (symNode->isScalar()) {
    symbol = symNode->scalar;
  } else {
    return b.reject(Stage::P2, Category::UndeclaredPlatformExtern, name, 0,
                    "platform.externs: '" + name + "' symbol: is not a scalar");
  }
  if (!isCIdentifier(symbol))
    return b.reject(Stage::P2, Category::UndeclaredPlatformExtern, name, 0,
                    "platform.externs: symbol '" + symbol +
                        "' is not a C identifier");

  // (4) params
  const YNode *paramsNode = entry.find("params");
  if (!paramsNode || !paramsNode->isSeq())
    return b.reject(Stage::P2, Category::BadExternType, name, 0,
                    "platform.externs: '" + name +
                        "' needs `params:` (a list of " +
                        joinSet(kExternTypes, "/") + "; use [] for none)");
  int pos = 0;
  for (const YNode &e : paramsNode->seq) {
    ++pos;
    FsParam param;
    if (e.isSeq()) {
      // buffer entry: [<elem>_buf, <dir>]
      if (e.seq.size() != 2 || !e.seq[0].isScalar() || !e.seq[1].isScalar())
        return b.reject(Stage::P2, Category::BufferElemMismatch, name, pos,
                        "platform.externs: '" + name +
                            "': a buffer parameter is written [<elem>_buf, "
                            "<dir>] -- two entries, e.g. [f64_buf, in] -- not " +
                            Twine(e.seq.size()));
      StringRef tag = e.seq[0].scalar;
      StringRef dir = e.seq[1].scalar;
      if (!tag.ends_with("_buf") || !contains(kBufferElems, tag.drop_back(4)))
        return b.reject(Stage::P2, Category::BufferElemMismatch, name, pos,
                        "platform.externs: '" + name + "': '" + tag +
                            "' is not a buffer element type");
      if (!contains(kBufferDirs, dir))
        return b.reject(Stage::P2, Category::BufferDirectionViolation, name,
                        pos,
                        "platform.externs: '" + name + "': '" + dir +
                            "' is not a buffer direction (" +
                            joinSet(kBufferDirs, "/") + ")");
      param.kind = FsParam::Kind::Buffer;
      param.type = tag.drop_back(4).str();
      param.direction = dir.str();
    } else if (e.isScalar()) {
      StringRef t = e.scalar;
      if (t == "len") {
        param.kind = FsParam::Kind::Len;
        param.type = "i32";
      } else if (!contains(kExternTypes, t)) {
        return b.reject(Stage::P2, Category::BadExternType, name, pos,
                        "platform.externs: '" + name + "' parameter type '" + t +
                            "' is not one of " + joinSet(kExternTypes, "/"));
      } else {
        param.kind = FsParam::Kind::Scalar;
        param.type = t.str();
      }
    } else {
      return b.reject(Stage::P2, Category::BadExternType, name, pos,
                      "platform.externs: '" + name +
                          "' parameter is neither a scalar nor a buffer entry");
    }
    out.params.push_back(param);
  }

  // Length governance uses declaration-side rules in the same order.
  for (size_t i = 0; i < out.params.size(); ++i) {
    if (out.params[i].kind != FsParam::Kind::Len)
      continue;
    if (i == 0 || out.params[i - 1].kind != FsParam::Kind::Buffer)
      return b.reject(Stage::P2, Category::BufferLenGovernance, name,
                      static_cast<int>(i + 1),
                      "platform.externs: '" + name +
                          "': `len` must come directly after a buffer entry -- "
                          "it names THAT buffer's length");
    size_t j = i;
    while (j > 0 && out.params[j - 1].kind == FsParam::Kind::Buffer &&
           out.params[j - 1].lenIndex < 0) {
      out.params[j - 1].lenIndex = static_cast<int>(i);
      --j;
    }
    out.params[i].bufIndex = static_cast<int>(j);
  }
  for (size_t i = 0; i < out.params.size(); ++i) {
    if (out.params[i].kind == FsParam::Kind::Buffer &&
        out.params[i].lenIndex < 0)
      return b.reject(Stage::P2, Category::BufferLenGovernance, name,
                      static_cast<int>(i + 1),
                      "platform.externs: '" + name + "': buffer parameter " +
                          Twine(i + 1) +
                          " has no `len` after it. An extern buffer must be "
                          "paired with a length");
  }

  // (6) returns
  const YNode *retNode = entry.find("returns");
  if (retNode && retNode->isSeq())
    return b.reject(Stage::P2, Category::BadExternType, name, 0,
                    "platform.externs: '" + name +
                        "': a buffer cannot be RETURNED by a platform extern -- "
                        "the caller owns the memory");
  if (!retNode || !retNode->isScalar())
    return b.reject(Stage::P2, Category::BadExternType, name, 0,
                    "platform.externs: '" + name +
                        "' needs `returns:` -- a platform extern has no void in "
                        "v1");
  const std::string &returns = retNode->scalar;
  if (!contains(kExternTypes, returns))
    return b.reject(Stage::P2, Category::BadExternType, name, 0,
                    "platform.externs: '" + name + "' return type '" + returns +
                        "' is not one of " + joinSet(kExternTypes, "/"));

  // Duplicate names are declaration conflicts; duplicate symbols/trap-hook collisions govern the
  // undefined-symbol allowlist. Keep classifications separate.
  if (!seenNames.insert(name).second)
    return b.reject(Stage::P2, Category::UndeclaredPlatformExtern, name, 0,
                    "platform.externs: name '" + name + "' is declared twice");
  if (symbol == trapHook || !seenSymbols.insert(symbol).second)
    return b.reject(Stage::P2, Category::UndefAllowlistViolation, symbol, 0,
                    "platform.externs: symbol '" + symbol +
                        "' is declared twice (or collides with the trap hook)");

  out.name = name;
  out.symbol = symbol;
  out.returns = returns;
  return true;
}

std::unique_ptr<FreestandingProfile>
validateProfile(StringRef path, const YNode &root, FsDiagnosticFn diag) {
  ProfileBuilder b(path, diag);

  // P1: sections and keys.
  const YNode *sections[4];
  for (size_t i = 0; i < 4; ++i) {
    const SchemaSection &sec = kSchema[i];
    sections[i] = root.find(sec.name);
    if (!sections[i] || !sections[i]->isMap()) {
      b.reject(Stage::P1, Category::UnknownProfileKey, sec.name, 0,
               "missing the `" + sec.name + ":` section");
      return nullptr;
    }
    std::vector<std::string> unknown;
    for (const auto &kv : sections[i]->map) {
      bool known = false;
      for (const SchemaKey &k : sec.keys)
        if (k.key == kv.first)
          known = true;
      if (!known)
        unknown.push_back(kv.first);
    }
    if (!unknown.empty()) {
      std::sort(unknown.begin(), unknown.end());
      std::string list;
      for (size_t j = 0; j < unknown.size(); ++j) {
        if (j) list += ", ";
        list += unknown[j];
      }
      b.reject(Stage::P1, Category::UnknownProfileKey, sec.name, 0,
               "unknown key(s) in " + sec.name + ": " + list + " (known: " +
                   keyList(sec.keys) + ")");
      return nullptr;
    }
    for (const SchemaKey &k : sec.keys)
      if (k.required && !sections[i]->find(k.key)) {
        b.reject(Stage::P1, Category::UnknownProfileKey, sec.name, 0,
                 sec.name + "." + k.key + " is required");
        return nullptr;
      }
  }

  auto scalarOf = [](const YNode *sec, StringRef key) -> std::string {
    const YNode *n = sec->find(key);
    return (n && n->isScalar()) ? n->scalar : std::string();
  };

  FreestandingProfile &p = b.p();
  // target
  p.triple_ = scalarOf(sections[0], "triple");
  p.cpu_ = scalarOf(sections[0], "cpu");
  p.dataLayout_ = scalarOf(sections[0], "data_layout");
  if (const YNode *cf = sections[0]->find("cflags"))
    if (cf->isSeq())
      for (const YNode &f : cf->seq)
        if (f.isScalar())
          p.cflags_.push_back(f.scalar);

  // ABI checks follow frozen order: boundary, int_width, overflow.
  p.boundary_ = scalarOf(sections[1], "boundary");
  if (p.boundary_ != "c-abi") {
    b.reject(Stage::P1, Category::AbiWidthMismatch, "abi.boundary", 0,
             "abi.boundary must be `c-abi` (the only boundary P003 defines)");
    return nullptr;
  }
  p.intWidth_ = scalarOf(sections[1], "int_width");
  if (p.intWidth_ != "i32-internal" && p.intWidth_ != "i64-internal") {
    b.reject(Stage::P1, Category::AbiWidthMismatch, "abi.int_width", 0,
             "abi.int_width must be `i32-internal` or `i64-internal`");
    return nullptr;
  }
  p.overflow_ = scalarOf(sections[1], "overflow");
  if (p.overflow_ == "raise") {
    b.reject(Stage::P1, Category::AbiWidthMismatch, "abi.overflow", 0,
             // Frozen Python wording verbatim.
             "abi.overflow: raise is not available on a freestanding target. "
             "sp_raise_cls longjmps to a setjmp handler and copies the message "
             "onto the string heap (spinel_rt.h:6685); there is neither. The "
             "policies are `trap` (default) and `wrap` (P003 decision record "
             "D-2).");
    return nullptr;
  }
  if (!contains(kOverflow, p.overflow_)) {
    b.reject(Stage::P1, Category::AbiWidthMismatch, "abi.overflow", 0,
             "abi.overflow: " + p.overflow_ + " is not one of " +
                 joinSet(kOverflow, "/"));
    return nullptr;
  }
  p.trapHook_ = scalarOf(sections[1], "trap_hook");
  if (!isCIdentifier(p.trapHook_)) {
    b.reject(Stage::P1, Category::UndefAllowlistViolation, "abi.trap_hook", 0,
             "abi.trap_hook must be a C identifier");
    return nullptr;
  }

  // runtime
  static const StringRef kLibc[] = {"none", "zephyr-minimal", "picolibc"};
  static const StringRef kLibm[] = {"none", "picolibc"};
  static const StringRef kCrt[] = {"allow", "deny"};
  struct RtKey { StringRef key; ArrayRef<StringRef> allowed; std::string *dst; };
  RtKey rt[] = {{"libc", kLibc, &p.libc_},
                {"libm", kLibm, &p.libm_},
                {"compiler_rt", kCrt, &p.compilerRt_}};
  for (RtKey &k : rt) {
    *k.dst = scalarOf(sections[2], k.key);
    if (!contains(k.allowed, *k.dst)) {
      b.reject(Stage::P1, Category::UnknownProfileKey,
               ("runtime." + k.key).str(), 0,
               "runtime." + k.key + ": " + *k.dst + " is not one of " +
                   joinSet(k.allowed, "/"));
      return nullptr;
    }
  }

  // platform
  p.platformType_ = scalarOf(sections[3], "type");
  if (p.platformType_ != "zephyr" && p.platformType_ != "none") {
    b.reject(Stage::P1, Category::UnknownProfileKey, "platform.type", 0,
             "platform.type must be `zephyr` or `none`");
    return nullptr;
  }

  StringSet<> seenNames, seenSymbols;
  if (const YNode *ext = sections[3]->find("externs")) {
    if (!ext->isSeq()) {
      b.reject(Stage::P1, Category::UnknownProfileKey, "platform.externs", 0,
               "platform.externs must be a list");
      return nullptr;
    }
    for (const YNode &e : ext->seq) {
      if (e.isScalar()) {
        // Bare strings allow linking only. Repeating the trap hook in this list is not a collision:
        // hooks are already permitted. A callable extern using its symbol would take it over and is
        // a collision. Shipped cortex-m33-zephyr/riscv32-zephyr use externs: [spinel_trap],
        // accepted by frozen Python. Initially treating bare strings as callables made native
        // reject two of three legacy profiles. Duplicate symbols remain refused.
        if (!seenSymbols.insert(e.scalar).second) {
          b.reject(Stage::P2, Category::UndefAllowlistViolation, e.scalar, 0,
                   "platform.externs: symbol '" + e.scalar +
                       "' is declared twice (or collides with the trap hook)");
          return nullptr;
        }
        p.allowed_.push_back(e.scalar);
        continue;
      }
      if (!e.isMap()) {
        b.reject(Stage::P2, Category::UnknownProfileKey, "", 0,
                 "platform.externs entries are either a symbol name or a "
                 "mapping {name, symbol, params, returns}");
        return nullptr;
      }
      FsExtern decl;
      if (!readExtern(b, e, seenNames, seenSymbols, p.trapHook_,
                      p.platformType_, decl))
        return nullptr;
      p.allowed_.push_back(decl.symbol);
      p.externs_.push_back(std::move(decl));
    }
  }
  // The trap hook itself is allowed; profiles need not repeat it.
  if (!llvm::is_contained(p.allowed_, p.trapHook_))
    p.allowed_.push_back(p.trapHook_);

  return b.take();
}

std::unique_ptr<FreestandingProfile>
readFreestandingProfile(StringRef path, StringRef yamlText,
                        FsDiagnosticFn diag) {
  std::optional<YNode> root = parseProfileYaml(path, yamlText, diag);
  if (!root)
    return nullptr;

  // This entry refuses platform-first form, which needs the ledger. resolveFreestandingProfile
  // handles expansion; preserve this reader behavior for its sixty cases/pins.
  if (const YNode *pv = root->find("platform"))
    if (pv->isScalar()) {
      ProfileBuilder b(path, diag);
      b.reject(Stage::P1, Category::UnknownProfileKey, "platform", 0,
               "the platform-first (T-5) profile form is not read by the native "
               "CP1 checker; pass the pre-T5 form (E162 CP1-4)");
      return nullptr;
    }

  return validateProfile(path, *root, diag);
}

} // namespace spinel_mlir::freestanding
