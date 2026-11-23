#!/bin/sh
# Task 2 measurements: what the pinned hosted compiler actually emits for the
# decision 0005 acceptance program, and whether a core object can take over the
# selected method's body without a new ABI.
#
# This is a MEASUREMENT script, not an acceptance gate. It prints what it found
# and fails only if a probe could not be run at all. Every claim in
# docs/native-core/task2-binding-report.md comes from here.
#
# Linux/ELF evidence only. Task 1's Mach-O work is the Mac side's; nothing here
# is evidence about macOS.
#
# usage: tests/native-core/task2-probe.sh [--cc CMD]
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH= cd -- "$here/../.." && pwd)
V="$root/vendor/spinel"
S="$V/bin/spinel"
CC_="${CC:-cc}"
while [ $# -gt 0 ]; do
  case "$1" in
    --cc) CC_=$2; shift 2 ;; --cc=*) CC_=${1#--cc=}; shift ;;
    *) echo "usage: $0 [--cc CMD]" >&2; exit 2 ;;
  esac
done
[ -x "$S" ] || { echo "task2-probe: no vendor/spinel/bin/spinel; see docs/building.md" >&2; exit 2; }
command -v ruby >/dev/null 2>&1 || { echo "task2-probe: no ruby for the oracle" >&2; exit 2; }

w=$(mktemp -d "${TMPDIR:-/tmp}/nc-task2.XXXXXX")
trap 'rm -rf "$w"' EXIT INT TERM
cd "$w"

say() { printf '\n== %s\n' "$1"; }

cat > lower.rb <<'RB'
def lower(a, b)
  a < b ? a : b
end

puts lower(7, 3)
RB

say "1. what the pinned compiler emits for the acceptance program"
"$S" lower.rb --no-line-map -S > lower.c 2>/dev/null
grep -n 'sp_lower' lower.c | sed 's/^/   /'

say "2. the same method as a module singleton, WITH an integer call site,"
echo "   through the existing --ext-entry path (no new mechanism)"
cat > extm2.rb <<'RB'
module M
  def self.lower(a, b)
    a < b ? a : b
  end
end

puts M.lower(7, 3)
RB
"$S" extm2.rb --ext-init nc_init --ext-entry M.lower -c -o ext2.c >/dev/null 2>&1
printf '   exported: %s\n' "$(grep -m1 'sp_M_s_lower' ext2.h)"
"$S" extm2.rb --no-line-map -S > ord2.c 2>/dev/null
printf '   ordinary: %s\n' "$(grep -m1 'sp_M_s_lower' ord2.c | sed 's/^ *//')"

say "3. with NO call site there is nothing to infer from, and the boundary boxes"
cat > extm.rb <<'RB'
module M
  def self.lower(a, b)
    a < b ? a : b
  end
end
RB
"$S" extm.rb --ext-init nc_init --ext-entry M.lower -c -o ext.c >/dev/null 2>&1
printf '   exported: %s\n' "$(grep -m1 'sp_M_s_lower' ext.h)"
echo "   -- so sp_RbVal is the absence of a caller, NOT something --ext-entry forces."

say "4. the minimum value is ordinary. puts carries nil out of band, in an"
echo "   sp_oint beside the value, even for a plain non-nullable local:"
printf 'x = 5\nputs x\n' > t2.rb
"$S" t2.rb --no-line-map -S 2>/dev/null | grep -m1 'putchar' | sed 's/^ */   /'
echo "   so INTPTR_MIN in a plain sp_int prints as itself (default overflow mode):"
printf 'v = ARGV[0].to_i\nputs v - 1\n' > q.rb
"$S" q.rb --cc="$CC_" -o q.bin >/dev/null 2>&1
if "$root/tools/oracle/gate" tests/native-core/task2-probe.sh cruby-min; then
  printf '   v-1 at INT64_MIN+1   spinel=[%s]  cruby=[%s]\n' \
    "$(./q.bin -9223372036854775807 2>&1)" "$(ruby q.rb -9223372036854775807 2>&1)"
else
  printf '   v-1 at INT64_MIN+1   spinel=[%s]\n' "$(./q.bin -9223372036854775807 2>&1)"
fi
echo "   (the pin reserved INTPTR_MIN as nil and printed an empty line here;"
echo "    upstream a07741ff1 moved nil out of band, and decision 0015 makes"
echo "    INT64_MIN an ordinary value, so the two lines should agree)"

say "4b. is the sp_lower symbol really absent? measured, not assumed"
for O in -O0 -O1 -O2 -Os; do
  $CC_ $O -DSP_INT_OVERFLOW_MODE_PROMOTE -I"$V/lib" -c lower.c -o l.o 2>/dev/null || continue
  printf '   %-4s sp_lower symbols of any binding: %s\n' "$O" "$(nm l.o 2>/dev/null | grep -c 'sp_lower' || true)"
done
echo "   (static inline always_inline does not GUARANTEE this; it is what was measured)"

say "4c. D1: the host range is sp_int, INT64_MIN included; one past either end is not"
# The pin made -9223372036854775808 a bigint, because that value was the nil of
# an Integer slot. Upstream a07741ff1 moved nil out of band, and decision 0015
# made INT64_MIN an ordinary value, so it is sp_int like its neighbours.
for lit in 9223372036854775807 -9223372036854775807 -9223372036854775808 \
           9223372036854775808 -9223372036854775809; do
  printf 'def f(a)\n  a\nend\nputs f(%s)\n' "$lit" > lit.rb
  printf '   %-22s -> %s\n' "$lit" \
    "$("$S" lit.rb --no-line-map -S 2>/dev/null | grep -m1 -o 'sp_[A-Za-z]* \*\? \?sp_f(.*);' | head -1)"
done

say "4d. the existing top-level collision guard (mc_top) is live"
for n in lower alloc arena gc str; do
  printf 'def %s(a)\n  a\nend\nputs %s(1)\n' "$n" "$n" > g.rb
  printf '   def %-6s -> %s\n' "$n" \
    "$("$S" g.rb --no-line-map -S 2>/dev/null | grep -m1 -o "sp_[a-z_]*(sp_int lv_a)" | head -1)"
done
printf '   runtime symbols beginning spc_: %s\n' \
  "$(nm --defined-only "$V/lib/libspinel_rt.a" 2>/dev/null | awk '{print $3}' | grep -c '^spc_' || true)"

say "4e. ingress: a root can be called from a hosted method, not only the top level"
cat > ing3.rb <<'RB'
def lower(a, b)
  a < b ? a : b
end

def outer(x)
  lower(x, 3)
end

puts lower(7, 3)
puts outer(9)
RB
"$S" ing3.rb --no-line-map -S 2>/dev/null | grep -n 'sp_lower(' | sed 's/^/   /'
echo "   (the call inside sp_outer is a second ingress; a top-level-only rule misses it)"
echo "   and how ingress must be FOUND -- these resolved to direct calls here:"
printf 'def lower(a,b)\n  a < b ? a : b\nend\nputs send(:lower, 9, 2)\n' > ing1.rb
"$S" ing1.rb --no-line-map -S 2>/dev/null | grep -c 'sp_lower(9LL' | sed 's/^/     send(:lower,9,2) direct calls: /'
printf 'def lower(a,b)\n  a < b ? a : b\nend\nm = method(:lower)\nputs m.call(9, 2)\n' > ing2.rb
"$S" ing2.rb --no-line-map -S 2>/dev/null | grep -c 'sp_lower(9LL' | sed 's/^/     method(:lower).call  direct calls: /'
echo "   measured in THESE programs only; the rule uses the producer's resolved"
echo "   call graph and refuses whatever the producer could not attribute."

say "4f. why the entry check must be limited to externally visible symbols"
cat > realcore.c <<'RB'
typedef long I;
static I clamp_lo(I v, I lo) { return v < lo ? lo : v; }
static const I table[4] = { 1, 2, 3, 4 };
I spc_demo_lower(I a, I b) { return clamp_lo(a < b ? a : b, table[0]); }
RB
for O in -O0 -O2; do
  $CC_ $O -c realcore.c -o rc.o 2>/dev/null || continue
  printf '   %-4s all defined: %s\n' "$O" "$(nm --defined-only rc.o | awk '{print $2" "$3}' | tr '\n' ' ')"
  printf '        externally visible: %s\n' "$(nm --defined-only --extern-only rc.o | awk '{print $3}' | tr '\n' ' ')"
done
echo "   an exact match over ALL defined symbols fails a correct object at -O0"

say "5. hand-built connection probe -- NOT the product path"
echo "   uses a MODULE method and EDITS the generated C by script; both are"
echo "   things a real implementation must not do. It claims linkage only."
# What the probe relies on is linkage, not spelling: the ordinary method is
# declared and defined `static inline`, so it is internal and the probe can turn
# it into one external declaration. The attributes between `static inline` and
# the return type are whatever the codegen writes -- the pin wrote
# __attribute__((always_inline)), upstream writes its portable SP_ALWAYS_INLINE
# -- so they are matched as any tokens, and the same match is made on the
# preprocessed file, where the macro is expanded. Both must find exactly one
# declaration and one definition.
$CC_ -E -P -DSP_INT_OVERFLOW_MODE_PROMOTE -I"$V/lib" ord2.c -o ord2.i
ruby - <<'RB'
sig = 'sp_int sp_M_s_lower\(sp_int lv_a, sp_int lv_b\)'
decl = Regexp.new('^[ \t]*static[ \t]+inline\b([^;{\n]*?)\b' + sig + '[ \t]*;')
defn = Regexp.new('^[ \t]*static[ \t]+inline\b([^;{\n]*?)\b' + sig + '[ \t]*\{')
shape = lambda do |text, form|
  d = text.scan(decl)
  f = text.scan(defn)
  unless d.size == 1 && f.size == 1
    abort "#{form}: #{d.size} static inline declaration(s), #{f.size} definition(s); re-read codegen"
  end
  a = d[0][0].strip
  a.empty? ? "(none)" : a
end
raw = File.read("ord2.c")
puts "   ordinary method is static inline; attributes as written: #{shape.call(raw, "as written")}"
puts "   ordinary method is static inline; attributes expanded:   #{shape.call(File.read("ord2.i"), "preprocessed")}"
s = raw.sub(decl) { "sp_int sp_M_s_lower(sp_int lv_a, sp_int lv_b);" }
m = defn.match(s)
j = s.index("\n}\n", m.begin(0)) + 3
File.write("seam.c", s[0, m.begin(0)] + s[j..])
RB
printf 'typedef long I;\nI sp_M_s_lower(I a, I b){ return a < b ? a : b; }\n' > core.c
printf 'typedef long I;\nI sp_M_s_lower(I a, I b){ return 999; }\n'          > wrong.c
: > missing.c
for f in core wrong missing; do $CC_ -O2 -c $f.c -o $f.o; done
L="-lm"; $CC_ -O2 -c -x c /dev/null -o /dev/null 2>/dev/null && L="-lm -lcrypt"
link() { $CC_ -O2 -DSP_INT_OVERFLOW_MODE_PROMOTE -I"$V/lib" seam.c "$1" "$V/lib/libspinel_rt.a" $L -o "$2" 2>"$3"; }
if link core.o ok.bin ok.err;      then printf '   correct core   -> [%s]   (expect 3)\n' "$(./ok.bin 2>&1)"
else echo "   correct core   -> LINK FAILED"; head -2 ok.err | sed 's/^/     /'; fi
if link wrong.o bad.bin bad.err;   then printf '   wrong core     -> [%s]   (999 = the call routes to the core object)\n' "$(./bad.bin 2>&1)"
else echo "   wrong core     -> LINK FAILED"; fi
if link missing.o no.bin no.err;   then echo "   missing core   -> LINKED ANYWAY, which would be a hosted fallback"
else printf '   missing core   -> link refused: %s\n' "$(grep -m1 -o "undefined reference to .sp_M_s_lower." no.err)"; fi
printf '   core.o undefined symbols: %s\n' "$(nm -u core.o | wc -l)"
printf '   core.o defined symbols:   %s\n' "$(nm --defined-only core.o | awk '{print $3}' | tr '\n' ' ')"
printf '\ntask2-probe: done. Linux/ELF only.\n'
