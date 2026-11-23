#!/bin/sh
#
# tests/npu/run.sh -- the Ruby to IREE to Neutron NPU lane (decision 0032).
#
#   ZEPHYR_WORKSPACE         the v4.5.0 workspace (the fixture comes from its sample)
#   ZEPHYR_SDK_INSTALL_DIR, IREE_COMPILE, IREE_SRC, IREE_M33_BUILD   the image build
#   NEUTRON_SDK_PYTHON       the real converter, for its one check below
#   NPU_UNCONVERTED_TFLITE   a uint8 TFLite file for that check
#   NPU_CONSOLE_LOG          a console capture of the image this run builds
#   NPU_DEF_CONSOLE_LOG      the same for the image of tests/npu/sides.rb
#   NPU_WORK                 scratch directory (default: a new one under TMPDIR)
#
# The expected values are by hand: the picture is a ship, and class 8 of
# CIFAR-10 is "ship". Nothing is compared with another implementation.
# Exit 0 when everything passed, 1 on a failure, 2 when something was skipped.
set -u
REPO=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
NPU="$REPO/tools/npu/spinel-npu"
pass=0; fail=0; skip=0
ok()  { pass=$((pass + 1)); echo "PASS  $1"; }
bad() { fail=$((fail + 1)); echo "FAIL  $1"; }
skp() { skip=$((skip + 1)); echo "SKIP  $1"; }
finish() {
  echo "npu: $pass passed, $fail failed, $skip skipped"
  [ "$fail" -eq 0 ] || exit 1
  [ "$skip" -eq 0 ] || exit 2
  exit 0
}

SAMPLE=${ZEPHYR_WORKSPACE:-/nonexistent}/zephyr/samples/boards/nxp/tflm_neutron
if [ ! -f "$SAMPLE/src/models/mcxn/model.hpp" ]; then
  skp "ZEPHYR_WORKSPACE has no tflm_neutron sample; nothing can run"
  finish
fi
WORK=${NPU_WORK:-$(mktemp -d "${TMPDIR:-/tmp}/npu.XXXXXX")}
FIX="$WORK/fix"
mkdir -p "$FIX"
ruby "$REPO/tests/npu/make_fixture.rb" "$SAMPLE" "$FIX" || { bad "fixture"; finish; }

# refuse NAME NEEDLE: the program in $FIX/$NAME.rb stops with a message
refuse() {
  log="$WORK/$1.log"
  "$NPU" "$FIX/$1.rb" -o "$WORK/$1" --check-only > "$log" 2>&1; rc=$?
  if [ "$rc" -eq 1 ] && grep -q -- "$2" "$log"; then ok "refused: $1"
  else bad "refused: $1 (exit $rc): $(tail -1 "$log")"; fi
}
# Write $FIX/$1.rb from ship.rb with $2 applied (a Ruby gsub program on `s`).
variant() {
  ruby -e 's = File.read(ARGV[0]); eval(ARGV[2]); File.write(ARGV[1], s)' \
    "$FIX/ship.rb" "$FIX/$1.rb" "$2" || bad "variant $1"
}
HEADLINE='npu_extern :classify'

variant none 's.sub!(/^npu_extern.*?partial: true\n/m, "") or abort'
refuse none 'no npu_extern'
variant two 's.sub!(/^require_relative "npu.gen"/) { %(npu_extern :b, tflite: "cifar.tflite", input: [:i8, 1], output: [:i8, 1]\n) + $& } or abort'
refuse two '2 npu_extern'
variant float 's.sub!("input: [:i8,", "input: [:f32,") or abort'
refuse float 'int8 only'
variant nogen 's.sub!(/^require_relative "npu.gen"\n/, "") or abort'
refuse nogen 'npu.gen'
variant shape 's.sub!("output: [:i8, 1, 12]", "output: [:i8, 1, 10]") or abort'
refuse shape 'the NeutronGraph has'
variant whole 's.sub!(", partial: true", "") or abort'
refuse whole 'partial: true'
variant unknown 's.sub!("partial: true", "partial: true, speed: 1") or abort'
refuse unknown 'bad npu_extern'

# A model that names no NeutronGraph, and converters that are stand-ins.
ruby -e 'b = File.binread(ARGV[0]); b.sub!("NeutronGraph".b, "OtherGraphOp".b) or abort
  File.binwrite(ARGV[1], b); File.binwrite(ARGV[2], "not a model" * 8)' \
  "$FIX/cifar.tflite" "$FIX/plain.tflite" "$FIX/junk.tflite" || bad "plain model"
ruby -e 'b = File.binread(ARGV[0]); b.sub!("NeutronProfile".b, "NeutronProfilf".b) or abort; File.binwrite(ARGV[1], b)' \
  "$FIX/cifar.tflite" "$FIX/names.tflite" || bad "renamed tensor"
# The profile tensor claims 16 bytes, which the lane has no buffer for.
ruby -e 'require ARGV[0]; b = File.binread(ARGV[1]); m = TFLite::Model.new(b)
  idx = m.tensors.index { |t| t.name == "NeutronProfile" } or abort
  p_, n = m.instance_eval { root = ind(0); sg = table_vec(field(root, 2)).first; vec(field(table_vec(field(sg, 0))[idx], 0)) }
  abort unless n == 1; b[p_, 4] = [16].pack("V"); File.binwrite(ARGV[2], b)' \
  "$REPO/tools/npu/tflite.rb" "$FIX/cifar.tflite" "$FIX/profile.tflite" || bad "sized profile"
# The scratch tensor's type no longer says its size is in bytes.
ruby -e 'require ARGV[0]; b = File.binread(ARGV[1]); m = TFLite::Model.new(b)
  idx = m.tensors.index { |t| t.name == "NeutronScratch" } or abort
  o = m.instance_eval { root = ind(0); sg = table_vec(field(root, 2)).first; field(table_vec(field(sg, 0))[idx], 1) }
  abort unless b.getbyte(o) == TFLite::UINT8; b.setbyte(o, 0); File.binwrite(ARGV[2], b)' \
  "$REPO/tools/npu/tflite.rb" "$FIX/cifar.tflite" "$FIX/scratch.tflite" || bad "typed scratch"
fake() {  # NAME VERSION
  cat > "$WORK/$1" <<F
#!/bin/sh
while [ \$# -gt 0 ]; do
  case "\$1" in
    --version) echo "eIQ neutron-converter version $2+0Xfake"; exit 0 ;;
    --input) in=\$2; shift ;;
    --output) out=\$2; shift ;;
  esac
  shift
done
cp "\$in" "\$out"
F
  chmod +x "$WORK/$1"
}
fake same 3.0.0
fake old 2.9.9
variant plain 's.gsub!("cifar.tflite", "plain.tflite")'
NEUTRON_SDK_PYTHON="$WORK/same" refuse plain 'no NeutronGraph'
variant version 's.gsub!("cifar.tflite", "plain.tflite")'
NEUTRON_SDK_PYTHON="$WORK/old" refuse version 'pins 3.0.0'
variant junk 's.gsub!("cifar.tflite", "junk.tflite")'
refuse junk 'cannot read it as TFLite'
variant names 's.gsub!("cifar.tflite", "names.tflite")'
refuse names 'last outputs are'
variant profile 's.gsub!("cifar.tflite", "profile.tflite")'
refuse profile 'both must be empty'
variant scratch 's.gsub!("cifar.tflite", "scratch.tflite")'
refuse scratch 'cannot be read as bytes'

# The declared program is accepted, as a control on every refusal above.
if "$NPU" "$FIX/ship.rb" -o "$WORK/check" --check-only | grep -q '1 NeutronGraph'; then ok "accepted: ship"
else bad "accepted: ship"; fi

# ---- npu_def: refused before the converter runs -----------------------------
dvar() {
  ruby -e 's = File.read(ARGV[0]); eval(ARGV[2]); File.write(ARGV[1], s)' \
    "$REPO/tests/npu/sides.rb" "$FIX/$1.rb" "$2" || bad "variant $1"
}
dvar d_op 's.sub!("max_pool 2", "depthwise_conv2d 2") or abort'
refuse d_op 'not an operator npu_def generates'
dvar d_count 's.sub!("Array.new(9, 100)", "Array.new(8, 100)") or abort'
refuse d_count 'weights, and shape'
dvar d_range 's.sub!("Array.new(9, 100)", "Array.new(9, 200)") or abort'
refuse d_range 'integers from -127'
dvar d_bias 's.sub!("bias: [0] * 8", "bias: [0]") or abort'
refuse d_bias 'int32 values'
dvar d_quant 's.sub!("quant: [0.08, -128]", "quant: [0.0, -128]") or abort'
refuse d_quant 'scale > 0'
dvar d_scale 's.sub!("weight_scale: 0.01", "weight_scale: 0") or abort'
refuse d_scale 'weight_scale'
dvar d_order 's.sub!("  flatten\n", "  flatten\n  max_pool 2\n") or abort'
refuse d_order 'the input is flat'
dvar d_flat 's.sub!("  flatten\n", "") or abort'
refuse d_flat 'call flatten first'
dvar d_empty 's.gsub!(/^  (conv2d|max_pool|flatten|fully_connected).*\n/, "") or abort'
refuse d_empty 'declares no operator'
dvar d_input 's.sub!("input: [:i8, 1, 8, 8, 1]", "input: [:i8, 8, 8, 1]") or abort'
refuse d_input 'input: is'
dvar d_block 's.sub!(/ do\n.*?^end\n/m, "\n") or abort'
refuse d_block 'needs a block'
dvar d_const 's.sub!(/^W1 = .*\n/, "") or abort'
refuse d_const 'bad npu_def'
dvar d_two 's.sub!(/^require_relative "npu.gen"/) { %(npu_extern :b, tflite: "b.tflite", input: [:i8, 1], output: [:i8, 1]\n) + $& } or abort'
refuse d_two '2 npu_extern or npu_def'

dvar d_private 's.sub!("max_pool 2", "ints [1]\n  max_pool 2") or abort'
refuse d_private 'not an operator npu_def generates'
dvar d_inf 's.sub!("weight_scale: 0.01", "weight_scale: Float::INFINITY") or abort'
refuse d_inf 'finite and above 0'
dvar d_tiny 's.sub!("quant: [0.08, -128]", "quant: [1e-60, -128]") or abort'
refuse d_tiny 'scale > 0'
dvar d_product 's.sub!("quant: [1.0 / 256, -128]", "quant: [1e-30, -128]") or abort
  s.sub!("weight_scale: 0.01", "weight_scale: 1e-30") or abort'
refuse d_product 'bias scale'
dvar d_line 's.sub!(/^(W1 = .*)$/) { $1 + "; puts 1" } or abort'
refuse d_line 'shares a line'
dvar d_decl_line 's.sub!(/^end\nrequire_relative/) { "end; puts 1\nrequire_relative" } or abort'
refuse d_decl_line 'shares a line'
dvar d_heredoc 's.sub!(/^W2 = /) { "TEXT = <<~T\n  ab\nT\nW2 = " } or abort
  s.sub!("max_pool 2", "max_pool TEXT.size") or abort'
refuse d_heredoc 'heredoc'

# A constant the program reads stays, with what it reads; W1 alone goes.
dvar d_keep 's.sub!(/^W1 = /) { "STEP = 50\nFACTOR = STEP * 2\nW1 = " } or abort
  s.sub!("Array.new(9, 100)", "Array.new(9, FACTOR)") or abort
  s.sub!(/^puts "done"/) { "puts FACTOR\nputs FACTOR\n" + $& } or abort'
env -u NEUTRON_SDK_PYTHON "$NPU" "$FIX/d_keep.rb" -o "$WORK/d_keep" --check-only > "$WORK/d_keep.log" 2>&1
if grep -q '^STEP = 50$' "$WORK/d_keep/program.rb" && grep -q '^FACTOR = STEP \* 2$' "$WORK/d_keep/program.rb" &&
   ! grep -q '^W1 = ' "$WORK/d_keep/program.rb"; then ok "npu_def: a kept constant keeps what it reads"
else bad "npu_def: a kept constant keeps what it reads"; fi

# The same, when reading a constant twice balances the first step of the search.
cat > "$FIX/d_twice.rb" <<'P'
A = 1
B = A + 1
npu_def :m, input: [:i8, 1, 8, 8, 8], quant: [1.0 / 256, -128] do
  max_pool B
end
require_relative "npu.gen"
puts B
puts B
P
env -u NEUTRON_SDK_PYTHON "$NPU" "$FIX/d_twice.rb" -o "$WORK/d_twice" --check-only > "$WORK/d_twice.log" 2>&1
if grep -q '^A = 1$' "$WORK/d_twice/program.rb" && grep -q '^B = A + 1$' "$WORK/d_twice/program.rb"; then ok "npu_def: a constant read twice keeps what it reads"
else bad "npu_def: a constant read twice keeps what it reads"; fi

# A converter that leaves operators outside the graph; the fixture has some.
cat > "$WORK/partial" <<F
#!/bin/sh
while [ \$# -gt 0 ]; do
  case "\$1" in
    --version) echo "eIQ neutron-converter version 3.0.0+0Xfake"; exit 0 ;;
    --output) out=\$2; shift ;;
  esac
  shift
done
cp "$FIX/cifar.tflite" "\$out"
F
chmod +x "$WORK/partial"
cp "$REPO/tests/npu/sides.rb" "$FIX/d_partial.rb"
NEUTRON_SDK_PYTHON="$WORK/partial" refuse d_partial 'outside the NeutronGraph'

# What the writer wrote, read back through the lane's own reader.
if ruby -e 'require ARGV[0]; require ARGV[1]
  m = TFLiteWrite::Model.new([:i8, 1, 4, 4, 2], [0.5, -1])
  w = (1..18).to_a
  m.conv2d(1, kernel: 3, weights: w, weight_scale: 0.25, bias: [7], quant: [2.0, 3], activation: :relu6, stride: 1)
  m.avg_pool(2)
  m.flatten
  r = TFLite::Model.new(m.to_tflite)
  ops = r.ops.map(&:builtin)
  t = r.tensors
  abort ops.inspect unless ops == [3, 1, 22]
  c = r.ops[0]
  abort "weights" unless r.data(t[c.inputs[1]]).unpack("c*") == w && t[c.inputs[1]].shape == [1, 3, 3, 2]
  abort "bias" unless r.data(t[c.inputs[2]]).unpack("l<*") == [7]
  abort "out" unless t[c.outputs[0]].shape == [1, 2, 2, 1] && t[r.outputs[0]].shape == [1, 1]
  abort "in" unless r.inputs == [0] && t[0].type == TFLite::INT8' \
  "$REPO/tools/npu/tflite_write.rb" "$REPO/tools/npu/tflite.rb" > "$WORK/roundtrip.log" 2>&1
then ok "npu_def: the model reads back"
else bad "npu_def: the model reads back: $(tail -1 "$WORK/roundtrip.log")"; fi

if [ -n "${NEUTRON_SDK_PYTHON:-}" ]; then
  if "$NPU" "$REPO/tests/npu/sides.rb" -o "$WORK/sides-check" --check-only | grep -q '1 NeutronGraph'; then ok "accepted: npu_def"
  else bad "accepted: npu_def"; fi
else
  skp "npu_def: NEUTRON_SDK_PYTHON not set"
fi

# An output directory in the repository: refused before anything is written.
leak="$REPO/tools/npu/leak-check"
"$NPU" "$FIX/ship.rb" -o "$leak" --check-only > "$WORK/leak.log" 2>&1; rc=$?
if [ "$rc" -eq 1 ] && grep -q 'inside this repository' "$WORK/leak.log" && [ ! -e "$leak" ]; then ok "refused: output in the repository"
else bad "refused: output in the repository (exit $rc): $(tail -1 "$WORK/leak.log")"; fi
if git -C "$REPO" check-ignore -q "$REPO/build/npu-out-control" 2>/dev/null; then
  if "$NPU" "$FIX/ship.rb" -o "$REPO/build/npu-out-control" --check-only > /dev/null 2>&1; then ok "accepted: an ignored output directory"
  else bad "accepted: an ignored output directory"; fi
  rm -rf "$REPO/build/npu-out-control"
fi

if [ -n "${NEUTRON_SDK_PYTHON:-}" ] && [ -f "${NPU_UNCONVERTED_TFLITE:-}" ]; then
  cp "$NPU_UNCONVERTED_TFLITE" "$FIX/u8.tflite"
  variant u8 's.gsub!("cifar.tflite", "u8.tflite")'
  refuse u8 'this lane takes exactly one'
  if grep -q 'Number of Neutron graphs' "$WORK/u8/converter.log"; then ok "the real converter ran"
  else bad "the real converter ran"; fi
else
  skp "the real converter: NEUTRON_SDK_PYTHON or NPU_UNCONVERTED_TFLITE not set"
fi

for v in ZEPHYR_SDK_INSTALL_DIR IREE_COMPILE IREE_SRC IREE_M33_BUILD; do
  eval "x=\${$v:-}"
  if [ -z "$x" ]; then skp "image build: $v not set"; finish; fi
done
if "$NPU" "$FIX/ship.rb" -o "$WORK/image" > "$WORK/image.log" 2>&1 && [ -s "$WORK/image/zephyr/zephyr/zephyr.bin" ]; then
  ok "image: $WORK/image/zephyr/zephyr/zephyr.bin"
else
  bad "image: $(tail -3 "$WORK/image.log")"
  finish
fi

if [ -n "${NEUTRON_SDK_PYTHON:-}" ]; then
  if "$NPU" "$REPO/tests/npu/sides.rb" -o "$WORK/sides" > "$WORK/sides.log" 2>&1 && [ -s "$WORK/sides/zephyr/zephyr/zephyr.bin" ]; then
    ok "image: $WORK/sides/zephyr/zephyr/zephyr.bin"
  else
    bad "image: sides: $(tail -3 "$WORK/sides.log")"
  fi
else
  skp "image: sides: NEUTRON_SDK_PYTHON not set"
fi

# board LABEL LOG IMAGE EXTRA_CHECK LINES...: compare a console capture
board() {
  label=$1; capture=$2; image=$3; shift 3
  if [ ! -f "$capture" ] || [ ! -f "$WORK/$image/build.tag" ]; then
    skp "board: $label: no capture or no image"
    return
  fi
  tr -d '\r' < "$capture" > "$WORK/console.$image"
  for line in "spinel-npu: build $(cat "$WORK/$image/build.tag")" "$@" 'done' 'spinel-npu: exit 0'; do
    if grep -qx -- "$line" "$WORK/console.$image"; then ok "board: $label: $line"; else bad "board: $label: $line"; fi
  done
  if grep -Eq '^spinel-npu: collections [0-9]+$' "$WORK/console.$image"; then :; else bad "board: $label: the collection count"; fi
}
board ship "${NPU_CONSOLE_LOG:-}" image 'top1 8' 'changed 1' 'repeat 2000'
if [ -f "${NPU_CONSOLE_LOG:-}" ]; then
  if grep -Eq '^spinel-npu: collections [1-9][0-9]*$' "$WORK/console.image"; then ok "board: ship: the collector ran"; else bad "board: ship: the collector ran"; fi
fi
board sides "${NPU_DEF_CONSOLE_LOG:-}" sides 'left 27 0' 'right 0 27' 'dark 0 0'
finish
