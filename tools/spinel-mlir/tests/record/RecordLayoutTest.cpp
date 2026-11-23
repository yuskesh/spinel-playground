#include "spinel/Analysis/RecordLayout.h"
#include <cstdio>
using namespace spinel::record;
static int failures;
static void check(bool value, const char *name) {
  if (!value) { std::fprintf(stderr, "FAIL %s\n", name); ++failures; }
}
static Outcome run(const char *name, std::vector<FieldSpec> fields) {
  std::vector<std::string> members;
  for (const auto &f : fields) members.push_back(f.name);
  return layout(name, members, fields);
}
int main() {
  auto hist=run("Hist", {{"hist","u32",8},{"n","u64",{}}});
  check(!hist.issue && hist.layout.size==40 && hist.layout.alignment==8 &&
        hist.layout.fields[1].offset==32, "E003 Hist array size/offset");
  auto w=run("W", {{"u64","u64",{}},{"i64","i64",{}},
    {"u32","u32",{}},{"i32","i32",{}},{"u16","u16",{}},
    {"i16","i16",{}},{"u8","u8",{}},{"i8","i8",{}},{"_pad0","u16",{}}});
  check(!w.issue && w.layout.size==32 && w.layout.fields[7].offset==29 &&
        w.layout.fields[7].isSigned && w.layout.fields[8].padding,
        "E003 W widths/sign/explicit padding");
  auto p=run("P",{{"a","u8",{}},{"_pad0","u8",{}},{"b","i16",{}}});
  check(!p.issue && p.layout.size==4 && p.layout.fields[2].offset==2,
        "E003 P middle padding");
  auto middle=run("S",{{"a","u8",{}},{"n","u32",{}}});
  check(middle.issue && middle.issue->message==
    "record S has 3 implicit padding byte(s) before member n (offset 1, alignment 4) — declare them before n: `_pad0: :u8`, `_pad1: :u16` (P006 §1)",
    "SB024 middle padding exact reason");
  auto tail=run("S",{{"a","u64",{}},{"n","u32",{}}});
  check(tail.issue && tail.issue->message==
    "record S has 4 implicit trailing padding byte(s) (size 12, alignment 8) — declare them at the end: `_pad0: :u32` (P006 §1)",
    "SB024 trailing padding exact reason");
  auto order=layout("S",{"a","b"},{{"b","u16",{}},{"a","u16",{}}});
  check(order.issue && order.issue->message==
    "the members of BPF.record(S, …) (b, a) must be the Struct's members in the same order (a, b) (P006 §1)",
    "SB024 order exact reason");
  for (int64_t n : {0,65}) {
    auto bad=run("Hist",{{"hist","u32",n}});
    check(bad.issue && bad.issue->site==Site::Count && bad.issue->message==
      "member hist: the array length must be a literal 1..64 (bpf-mlir's record arrays) (P016)",
      "SB024 array boundary");
  }
  auto padArray=run("S",{{"_pad0","u8",4}});
  check(padArray.issue && padArray.issue->site==Site::Member,
        "padding arrays rejected before no-named-members");
  auto type=run("S",{{"a","u12",{}}});
  check(type.issue && type.issue->site==Site::Type && type.issue->message==
    "member a: the type must be :u8 … :u64 or :i8 … :i64, got :u12",
    "SB024 unsupported width");
  auto onlyPad=run("S",{{"_pad0","u32",{}}});
  check(onlyPad.issue && onlyPad.issue->message=="record S has no named member",
        "record must have named member");
  return failures ? 1 : 0;
}
