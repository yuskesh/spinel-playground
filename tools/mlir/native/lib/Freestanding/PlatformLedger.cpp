// Read menus.yaml and expand platform-first profiles, porting frozen
// load_menus/load_profile/expand_freestanding. Preserve check order/wording so profiles with
// multiple defects keep the same first refusal stage, as in ProfileReader.cpp.
#include "spinel-mlir/Freestanding/PlatformLedger.h"

#include "ProfileYaml.h"

#include "llvm/ADT/SmallString.h"
#include "llvm/ADT/StringRef.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/Path.h"

#include <algorithm>
#include <optional>
#include <vector>

using namespace llvm;

namespace spinel_mlir::freestanding {

namespace {

// Closed sets, one-to-one with frozen module constants.
const StringRef kTiers[] = {"core", "arena", "full"};
const StringRef kSupplies[] = {"full", "externs-only", "trap-only"};
const StringRef kReservedPrefixes[] = {"edge/", "cloudflare/", "fastly/"};
static_assert(sizeof(kTiers) / sizeof(StringRef) == 3, "");
static_assert(sizeof(kSupplies) / sizeof(StringRef) == 3, "");
static_assert(sizeof(kReservedPrefixes) / sizeof(StringRef) == 3, "");

// Python list representation for diagnostics, e.g. list((a,b)).
std::string pyList(ArrayRef<StringRef> set) {
  std::string out = "[";
  for (size_t i = 0; i < set.size(); ++i) {
    if (i)
      out += ", ";
    out += "'" + set[i].str() + "'";
  }
  return out + "]";
}

// Python string %r representation.
std::string pyRepr(StringRef s) { return "'" + s.str() + "'"; }

// Ledger REPO is three parents above tools/platform/menus.yaml, matching nested dirname. Resolve
// base: relative to it, as os.path.join(REPO, base_rel).
std::string ledgerRepoRoot(StringRef ledgerPath) {
  StringRef d = sys::path::parent_path(ledgerPath);  // tools/platform
  d = sys::path::parent_path(d);                     // tools
  d = sys::path::parent_path(d);                     // REPO
  return d.str();
}

// Ledger path spelling for diagnostics, matching os.path.relpath(menus["_path"], REPO).
std::string ledgerDisplayPath(StringRef ledgerPath) {
  std::string repo = ledgerRepoRoot(ledgerPath);
  StringRef p = ledgerPath;
  if (!repo.empty() && p.starts_with(repo)) {
    p = p.drop_front(repo.size());
    while (p.starts_with("/"))
      p = p.drop_front(1);
  }
  return p.str();
}

// Always sort mapping keys before enumeration; input-dependent iteration must not affect
// diagnostics.
std::vector<std::string> sortedKeys(const YNode &m) {
  std::vector<std::string> keys;
  for (const auto &kv : m.map)
    keys.push_back(kv.first);
  std::sort(keys.begin(), keys.end());
  return keys;
}

// Read and lightly validate the ledger like load_menus. Structural defects are repository bugs and
// set infraError, not Rejection.
std::optional<YNode> loadMenus(StringRef ledgerPath, std::string *infraError) {
  // Default lookup found no ledger. Legacy profiles never come here, so absence does not block
  // every profile.
  if (ledgerPath.empty()) {
    *infraError = "ledger-missing: cannot locate tools/platform/menus.yaml "
                  "(pass --menus <path>)";
    return std::nullopt;
  }
  ErrorOr<std::unique_ptr<MemoryBuffer>> buf =
      MemoryBuffer::getFile(ledgerPath, /*IsText=*/true);
  if (!buf) {
    *infraError = ("ledger-missing: cannot read " + ledgerPath + ": " +
                   buf.getError().message())
                      .str();
    return std::nullopt;
  }

  // Invalid YAML, duplicate keys and nonmapping roots all mean broken ledger. Capture/discard
  // parseProfileYaml profile wording and report the error in ledger terms.
  bool sawReject = false;
  auto sink = [&](const Rejection &) { sawReject = true; };
  std::optional<YNode> root =
      parseProfileYaml(ledgerPath, (*buf)->getBuffer(), sink);
  if (!root || !root->isMap()) {
    *infraError =
        (ledgerPath + ": the ledger needs `capabilities:` and `platforms:`")
            .str();
    (void)sawReject;
    return std::nullopt;
  }

  const YNode *caps = root->find("capabilities");
  const YNode *plats = root->find("platforms");
  if (!caps || !caps->isMap() || !plats || !plats->isMap()) {
    *infraError =
        (ledgerPath + ": the ledger needs `capabilities:` and `platforms:`")
            .str();
    return std::nullopt;
  }

  const YNode *tiers = root->find("tiers");
  bool tiersOk = tiers && tiers->isSeq() && tiers->seq.size() == 3;
  if (tiersOk)
    for (size_t i = 0; i < 3; ++i)
      if (!tiers->seq[i].isScalar() || tiers->seq[i].scalar != kTiers[i])
        tiersOk = false;
  if (!tiersOk) {
    *infraError =
        (ledgerPath + ": `tiers:` must be " + pyList(kTiers) + " (T-1)").str();
    return std::nullopt;
  }

  for (const auto &kv : caps->map) {
    StringRef name = kv.first;
    bool reserved = false;
    for (StringRef p : kReservedPrefixes)
      if (name.starts_with(p))
        reserved = true;
    if (!reserved) {
      *infraError = (ledgerPath + ": capability " + pyRepr(name) +
                     " is outside the reserved namespaces " +
                     pyList(kReservedPrefixes))
                        .str();
      return std::nullopt;
    }
    const YNode *tier = kv.second.isMap() ? kv.second.find("tier") : nullptr;
    if (!tier || !tier->isScalar() || !contains(kTiers, tier->scalar)) {
      *infraError = (ledgerPath + ": capability " + pyRepr(name) +
                     " needs `tier:` in " + pyList(kTiers))
                        .str();
      return std::nullopt;
    }
  }

  for (const auto &kv : plats->map) {
    StringRef name = kv.first;
    const YNode &spec = kv.second;
    const YNode *menu = spec.isMap() ? spec.find("menu") : nullptr;
    const YNode *arch = spec.isMap() ? spec.find("arch") : nullptr;
    if (!menu || !arch) {
      *infraError = (ledgerPath + ": platform " + pyRepr(name) +
                     " needs `arch:` and `menu:`")
                        .str();
      return std::nullopt;
    }
    if (!menu->isSeq())
      continue; // Python examines iterable forms only; empty/null passes through.
    for (const YNode &c : menu->seq) {
      if (!c.isScalar() || !caps->find(c.scalar)) {
        *infraError = (ledgerPath + ": platform " + pyRepr(name) + " menus " +
                       pyRepr(c.isScalar() ? StringRef(c.scalar) : StringRef()) +
                       ", which `capabilities:` does not define")
                          .str();
        return std::nullopt;
      }
    }
  }
  return root;
}

// platforms.<p>.arch menu; absent means empty mapping.
const YNode *archMenuOf(const YNode &menus, StringRef platform) {
  const YNode *plats = menus.find("platforms");
  if (!plats)
    return nullptr;
  const YNode *spec = plats->find(platform);
  if (!spec || !spec->isMap())
    return nullptr;
  const YNode *arch = spec->find("arch");
  return (arch && arch->isMap()) ? arch : nullptr;
}

} // namespace

std::string locateDefaultLedger(const char *argv0) {
  std::string exe = sys::fs::getMainExecutable(
      argv0, reinterpret_cast<void *>(&locateDefaultLedger));
  if (exe.empty())
    return {};
  SmallString<128> dir(sys::path::parent_path(exe));
  while (!dir.empty()) {
    SmallString<128> candidate(dir);
    sys::path::append(candidate, "tools", "platform", "menus.yaml");
    if (sys::fs::exists(candidate))
      return std::string(candidate);
    StringRef parent = sys::path::parent_path(dir);
    if (parent == dir)
      break;
    dir = parent;
  }
  return {};
}

std::unique_ptr<FreestandingProfile>
resolveFreestandingProfile(StringRef profilePath, StringRef yamlText,
                           StringRef ledgerPath, FsDiagnosticFn diag,
                           std::string *infraError) {
  std::optional<YNode> root = parseProfileYaml(profilePath, yamlText, diag);
  if (!root)
    return nullptr;

  // Legacy platform: section or absent key follows the existing path without reading the ledger.
  // Frozen menus loading also waits until the new form is detected.
  const YNode *platNode = root->find("platform");
  if (!platNode || !platNode->isScalar())
    return validateProfile(profilePath, *root, diag);

  std::optional<YNode> menus = loadMenus(ledgerPath, infraError);
  if (!menus)
    return nullptr;

  ProfileBuilder rej(profilePath, diag);
  auto reject = [&](StringRef subject, const Twine &detail) {
    rej.reject(Stage::P0, Category::ProfileError, subject, 0, detail);
    return nullptr;
  };

  // Unknown key: choose sorted-first subject. Frozen Python does not name it, but native Rejection
  // has a subject; use deterministic enumeration ordering.
  static const StringRef kT5Keys[] = {"platform", "arch", "supplies", "externs"};
  std::vector<std::string> unknown;
  for (const auto &kv : root->map)
    if (!contains(kT5Keys, kv.first))
      unknown.push_back(kv.first);
  if (!unknown.empty()) {
    std::sort(unknown.begin(), unknown.end());
    return reject(unknown.front(),
                  "unknown key(s) " + joinSorted(unknown, ", ") +
                      " (a T-5 profile has platform/arch/supplies/externs)");
  }

  // (p) platform
  const std::string plat = platNode->scalar;
  const YNode *plats = menus->find("platforms");
  if (!plats->find(plat))
    return reject("platform",
                  "unknown platform '" + plat + "' -- the ledger (" +
                      ledgerDisplayPath(ledgerPath) + ") knows " +
                      joinSorted(sortedKeys(*plats), ", "));

  // Architecture: derive it if the ledger menu has exactly one.
  const YNode *archMenu = archMenuOf(*menus, plat);
  std::vector<std::string> archNames =
      archMenu ? sortedKeys(*archMenu) : std::vector<std::string>();
  const YNode *archNode = root->find("arch");
  std::string arch;
  if (!archNode || !archNode->isScalar()) {
    if (archNames.size() == 1) {
      arch = archNames.front();
    } else {
      return reject("arch", "platform '" + plat + "' has " +
                                Twine(archNames.size()) + " arch entries (" +
                                (archNames.empty()
                                     ? std::string("-")
                                     : joinSorted(archNames, ", ")) +
                                "); `arch:` cannot be derived and must be "
                                "chosen");
    }
  } else {
    arch = archNode->scalar;
    if (!archMenu || !archMenu->find(arch))
      return reject("arch", "arch '" + arch + "' is not in platform '" + plat +
                                "' menu (" +
                                (archNames.empty()
                                     ? std::string("-")
                                     : joinSorted(archNames, ", ")) +
                                ")");
  }

  // Supplies: missing data.get becomes Python None. Python repr preserves nonscalar lists/mappings,
  // while native uses None; this untested corner is a recorded limitation.
  const YNode *supNode = root->find("supplies");
  const std::string supplies =
      (supNode && supNode->isScalar()) ? supNode->scalar : std::string("None");
  if (!contains(kSupplies, supplies))
    return reject("supplies", "supplies '" + supplies + "' is not one of " +
                                  joinSet(kSupplies, "|"));

  // Externs matter only for supplies: externs-only.
  const YNode *externsNode = root->find("externs");
  const size_t externCount =
      (externsNode && externsNode->isSeq()) ? externsNode->seq.size() : 0;
  if (supplies != "externs-only" && externCount != 0)
    return reject("externs",
                  "`externs:` only means something with supplies: externs-only "
                  "(D-7); supplies: " +
                      supplies + " got " + Twine(externCount) + " entr" +
                      (externCount == 1 ? "y" : "ies"));

  // supplies: full is hosted. Refuse before missing base, matching expand_freestanding order.
  if (supplies == "full")
    return reject("supplies",
                  "supplies: full is the hosted runtime -- not a freestanding "
                  "profile.  Build with spinel-wasm --profile (workers|fastly), "
                  "or say what this module receives (externs-only|trap-only)");

  // (b) base
  const YNode *archEntry = archMenu ? archMenu->find(arch) : nullptr;
  const YNode *baseNode =
      (archEntry && archEntry->isMap()) ? archEntry->find("base") : nullptr;
  if (!baseNode || !baseNode->isScalar() || baseNode->scalar.empty())
    return reject("base", "the ledger has no freestanding base for (" + plat +
                              ", " + arch +
                              ") -- nothing builds a core-tier module for that "
                              "pair today");

  SmallString<192> basePath(ledgerRepoRoot(ledgerPath));
  sys::path::append(basePath, baseNode->scalar);
  ErrorOr<std::unique_ptr<MemoryBuffer>> baseBuf =
      MemoryBuffer::getFile(basePath, /*IsText=*/true);
  if (!baseBuf) {
    *infraError = ("base-missing: cannot read " + StringRef(basePath) + ": " +
                   baseBuf.getError().message())
                      .str();
    return nullptr;
  }
  // Base parse failures name the base path, not an input-profile defect.
  std::optional<YNode> baseRoot =
      parseProfileYaml(basePath, (*baseBuf)->getBuffer(), diag);
  if (!baseRoot)
    return nullptr;

  // Expansion replaces only platform.externs, preserving base target/abi/runtime/platform.type.
  // Generation never branches on platform name, enabling byte comparison with legacy profiles.
  YNode expanded = *baseRoot;
  YNode *platSection = nullptr;
  for (auto &kv : expanded.map)
    if (kv.first == "platform")
      platSection = &kv.second;
  if (!platSection) {
    YNode fresh;
    fresh.kind = YNode::Kind::Mapping;
    expanded.map.emplace_back("platform", std::move(fresh));
    platSection = &expanded.map.back().second;
  }
  if (!platSection->isMap()) {
    // Frozen dict(data.get("platform") or {}) throws on a nonmapping. Native instead passes an
    // empty mapping to legacy validation, which refuses platform.type is required at P1.
    platSection->kind = YNode::Kind::Mapping;
    platSection->seq.clear();
    platSection->scalar.clear();
    platSection->map.clear();
  }
  YNode newExterns;
  newExterns.kind = YNode::Kind::Sequence;
  if (supplies == "externs-only" && externsNode && externsNode->isSeq())
    newExterns.seq = externsNode->seq;
  bool replaced = false;
  for (auto &kv : platSection->map)
    if (kv.first == "externs") {
      kv.second = newExterns;
      replaced = true;
      break;
    }
  if (!replaced)
    platSection->map.emplace_back("externs", std::move(newExterns));

  std::unique_ptr<FreestandingProfile> profile =
      validateProfile(profilePath, expanded, diag);
  if (profile)
    markPlatformFirst(*profile, basePath);
  return profile;
}

} // namespace spinel_mlir::freestanding
