# tests/doom-core/harness/artifacts.sh — the frame lane's built artifacts.
#
# Three things the compiled, session and adapter routes load, and ONE place
# that knows how each is made:
#
#   dc_entry_units DIR              the source units and the manifest, copied in
#   dc_entries DIR UNITDIR [FLAGS]  every entry packed and compiled into DIR
#   dc_core_entries DIR [FLAGS]     decision 0008's three entries, packed from
#                                   examples/doom/core/entries/units.tsv and
#                                   compiled into DIR
#   dc_source_lib DIR OUT           those objects linked into one shared object
#   dc_session_catalog DIR WAD      the catalog DEMO1's map measures
#   dc_session_schema DIR AUDITDIR  the schema the audit emits for that catalog
#   dc_session_layout DIR           the buffers and slots generated from it
#   dc_adapter_generate SKDIR ADDIR the adapter generated for every entry
#   dc_adapter_link SKDIR ADDIR OUT those sources compiled and linked
#   dc_route_adapter DIR ADDIR      the adapter for dc_core_entries' three entries
#
# IT IS SOURCED, NOT COPIED. tests/doom-core/tick.sh sources this file and calls
# these, and so does anything else that needs the same artifacts, because a
# build recipe that exists twice drifts, and the copy nobody regates is the one
# that is wrong. Sourcing it defines functions and does nothing else.
#
# WHAT IT READS FROM ITS CALLER, all of them the names tick.sh already uses:
# RUBY, ROOT, PACK, READER, KERNEL, CC_BIN, SENTRIES, SRCFIX, and ADAPTER_BIN
# for the adapter pair alone. It resolves none of them and defaults none of
# them: a caller that has not set one is told which, rather than building with
# something it did not choose. dc_artifacts_ready checks the first eight, which
# is every name the compiled and session routes need; ADAPTER_BIN is NOT among
# them because tick.sh chooses it at the adapter section and not before, and a
# gate that demanded it earlier would refuse a caller that is only building
# entries.
#
# DC_FAILURE_SITES=1 (a debugging aid) builds dc_core_entries' kernels with
# --failure-sites, each writing stage/ENTRY/sites.tsv, and dc_route_adapter's
# adapters to match: a failed entry then prints its failure site, which
# tools/doom/failure-site.rb turns into the maintained file and line. Off,
# both build what they always did.
#
# EVERY LOCAL NAME IS PREFIXED dc_. These run in the caller's variable scope --
# POSIX sh has no `local` -- and tick.sh uses `d`, `u`, `e`, `rc` and `c` itself.
#
# WHAT EACH ANSWERS. dc_entry_units, dc_entries, dc_source_lib,
# dc_session_layout, dc_adapter_generate and dc_adapter_link answer nonzero on
# failure and leave their diagnosis in a file beside what they were building.
# dc_session_catalog and dc_session_schema always answer 0, as the lane's checks
# read what they wrote rather than their status: the catalog is judged by the
# map it printed and the schema by comparison with the committed one.

# Refuse to run with a name the caller never set.
dc_artifacts_ready() {
  for dc_v in RUBY ROOT PACK READER KERNEL CC_BIN SENTRIES SRCFIX; do
    eval "dc_val=\${$dc_v:-}"
    [ -n "$dc_val" ] || { echo "artifacts.sh: $dc_v is not set; the caller chooses it" >&2; return 1; }
  done
}

# The units the entries are packed from, and the manifest that lists them.
dc_entry_units() { # dir
  mkdir -p "$1/unit" || return 1
  cp "$ROOT/examples/doom/core/src/source.rb" "$ROOT/examples/doom/core/src/zone.rb" "$ROOT/examples/doom/core/src/executor.rb" \
    "$ROOT/examples/doom/core/src/jobs.rb" "$ROOT/examples/doom/core/src/checks.rb" \
    "$ROOT/examples/doom/core/src/planespan.rb" "$ROOT/examples/doom/core/src/planes.rb" "$ROOT/examples/doom/core/src/fixed.rb" \
    "$ROOT/examples/doom/core/src/statusbar.rb" "$ROOT/examples/doom/core/src/hud.rb" \
    "$ROOT/examples/doom/core/src/leaves.rb" "$ROOT/examples/doom/core/src/segs.rb" "$ROOT/examples/doom/core/src/stepcore.rb" "$ROOT/examples/doom/core/src/stepwork.rb" "$ROOT/examples/doom/core/src/stepmap.rb" "$ROOT/examples/doom/core/src/stepspec.rb" "$ROOT/examples/doom/core/src/stepaux.rb" "$ROOT/examples/doom/core/src/stepknot.rb" "$ROOT/examples/doom/core/src/stepplay.rb" "$ROOT/examples/doom/core/src/rvcopies.rb" "$ROOT/examples/doom/core/src/rview.rb" "$ROOT/examples/doom/core/src/rvgpu.rb" "$ROOT/examples/doom/core/src/inputport.rb" "$SRCFIX/src/entries.rb" "$1/unit/" || return 1
  cp "$SRCFIX/manifest.tsv" "$1/manifest.tsv"
}

# Pack the units and build every entry into dir. Extra arguments are passed to
# clang after `--`, which is how the sanitised build is made.
dc_entries() { # dir unit-dir [clang flags]
  dc_d=$1; dc_u=$2; shift 2
  mkdir -p "$dc_d/stage/src"
  # A buffer argument out of order is a wrong field the kernel cannot see:
  # refuse any step or render-spine call that hands a buffer on under another name.
  "$RUBY" "$ROOT/tools/doom/buffer-names.rb" "$dc_u"/step*.rb "$dc_u"/rv*.rb "$dc_u/entries.rb" > "$dc_d/buffer-names.err" 2>&1 || return 1
  "$RUBY" "$PACK" --manifest "$dc_d/manifest.tsv" --root "$dc_u" --reader "$READER" \
    --output "$dc_d/stage/src/packed.rb" --map "$dc_d/map.tsv" > "$dc_d/pack.err" 2>&1 || return 1
  for dc_e in $SENTRIES; do
    cp "$SRCFIX/$dc_e.contract" "$dc_d/stage/$dc_e.contract"
    if [ $# -gt 0 ]; then
      "$KERNEL" "$dc_d/stage/$dc_e.contract" --root "$dc_d/stage" --typedump "$READER" --int64-allow "$ROOT/tools/core/int64-allow.tsv" -o "$dc_d/$dc_e.o" --header "$dc_d/$dc_e.h" \
        --clang "$CC_BIN" -- "$@" > "$dc_d/$dc_e.err" 2>&1 || return 1
    else
      "$KERNEL" "$dc_d/stage/$dc_e.contract" --root "$dc_d/stage" --typedump "$READER" --int64-allow "$ROOT/tools/core/int64-allow.tsv" -o "$dc_d/$dc_e.o" --header "$dc_d/$dc_e.h" \
        --clang "$CC_BIN" > "$dc_d/$dc_e.err" 2>&1 || return 1
    fi
  done
}

# The three entries the program calls (tests/doom-core/verify.sh builds them
# here): their units (entries/units.tsv) copied,
# the buffer names checked, and each entry packed on its own at the width its
# `#width` line gives (decision 0022 §2.6) into stage/ENTRY/src/packed.rb,
# with its map at stage/ENTRY/map.tsv, and compiled there from its committed
# contract. Extra arguments are passed to clang after `--`.
dc_core_entries() { # dir [clang flags]
  dc_d=$1; shift
  dc_c="$ROOT/examples/doom/core"
  mkdir -p "$dc_d/unit" "$dc_d/stage" || return 1
  for dc_f in $(grep -v '^#' "$dc_c/entries/units.tsv" | cut -f1); do
    cp "$dc_c/src/$dc_f" "$dc_d/unit/" || return 1
  done
  cp "$dc_c/entries/units.tsv" "$dc_d/manifest.tsv"
  "$RUBY" "$ROOT/tools/doom/buffer-names.rb" "$dc_d/unit"/step*.rb "$dc_d/unit"/rv*.rb "$dc_d/unit/inputport.rb" \
    "$dc_d/unit/doomentry.rb" > "$dc_d/buffer-names.err" 2>&1 || return 1
  for dc_e in doom_core_input doom_core_step doom_core_render; do
    mkdir -p "$dc_d/stage/$dc_e/src" || return 1
    "$RUBY" "$PACK" --manifest "$dc_d/manifest.tsv" --root "$dc_d/unit" --reader "$READER" --entry "$dc_e" \
      --output "$dc_d/stage/$dc_e/src/packed.rb" --map "$dc_d/stage/$dc_e/map.tsv" > "$dc_d/pack-$dc_e.err" 2>&1 || return 1
    cp "$dc_c/entries/$dc_e.contract" "$dc_d/stage/$dc_e/$dc_e.contract"
    "$KERNEL" "$dc_d/stage/$dc_e/$dc_e.contract" --root "$dc_d/stage/$dc_e" --typedump "$READER" --int64-allow "$ROOT/tools/core/int64-allow.tsv" -o "$dc_d/$dc_e.o" \
      --header "$dc_d/$dc_e.h" ${DC_FAILURE_SITES:+--failure-sites "$dc_d/stage/$dc_e/sites.tsv"} \
      --clang "$CC_BIN" ${1:+--} "$@" > "$dc_d/$dc_e.err" 2>&1 || return 1
  done
  # the kernel that built them, for a later run that reuses this directory
  # (tools/doom/objects-kernel.rb)
  "$RUBY" -rdigest -e 'puts Digest::SHA256.file(ARGV[0]).hexdigest' "$KERNEL" > "$dc_d/kernel.sha256" || return 1
}

dc_source_lib() { # entry-dir out
  "$CC_BIN" -shared -o "$2" "$1"/*.o
}

# THE STEPS ARE THE STEPS tick.sh ALREADY CHECKS. It reports on the catalog, the
# emitted schema and the generated layout separately, and on the adapter's
# generation separately from its link, so each is its own function here. A
# coarser split would have made sourcing this file change how many checks
# tick.sh reports, which is not an extraction.

# The catalog a demo's map measures.
dc_session_catalog() { # dir wad [demo] -- the demo's map; DEMO1 when not named
  dc_d=$1; dc_wad=$2; dc_demo=${3:-DEMO1}
  mkdir -p "$dc_d" || return 1
  "$RUBY" -e '
        $VERBOSE = nil
        require_relative ARGV[0]
        wad = Doom::Wad.new(ARGV[1])
        map = Doom::Demo.new(wad, ARGV[3], "").mapname
        require "tmpdir"
        Dir.mktmpdir("cat-script") do |d|
          sp = File.join(d, "s.txt")
          File.write(sp, "0 10 forward\n")
          Doom::Core::Resources.write_catalog(Doom::Core::Resources.catalog(wad: wad, map: map, width: 320, height: 200, script: sp), ARGV[2])
        end
        print map
      ' "$ROOT/examples/doom/core/full/resources" "$dc_wad" "$dc_d/catalog.tsv" "$dc_demo" > "$dc_d/map.txt" 2> "$dc_d/catalog.err" || true
}

# The schema the audit's inventory emits for that catalog.
dc_session_schema() { # dir audit-dir
  "$RUBY" "$ROOT/tools/doom/emit-schema.rb" --inventory "$2/state-use.tsv" --setup-writes "$2/setup-writes.tsv" \
    --schema "$1/state.tsv" --access "$1/access.tsv" --prepared "$1/prepared.tsv" \
    --catalog "$1/catalog.tsv" > "$1/emit.err" 2>&1 || true
}

# The buffers and slots generated from the committed schema and that catalog.
dc_session_layout() { # dir
  cat "$1/catalog.tsv" "$1/prepared.tsv" > "$1/full-catalog.tsv" || return 1
  "$RUBY" "$ROOT/tools/doom/state-schema.rb" --schema "$ROOT/examples/doom/core/state.tsv" \
    --access "$ROOT/examples/doom/core/access.tsv" --catalog "$1/full-catalog.tsv" --output "$1/gen" > "$1/gen.err" 2>&1
}

# The adapter generated for every entry, each run leaving its own registry copy
# so a caller can check that all of them generated the same file.
dc_adapter_generate() { # entry-dir adapter-dir
  dc_sk=$1; dc_ad=$2
  [ -n "${ADAPTER_BIN:-}" ] || { echo "artifacts.sh: ADAPTER_BIN is not set; the caller chooses it" >&2; return 1; }
  mkdir -p "$dc_ad/obj" || return 1
  dc_rc=0
  for dc_e in $SENTRIES; do
    cp "$dc_sk/$dc_e.h" "$dc_ad/spinel_core_dc_sp_$dc_e.h"
    "$ADAPTER_BIN" "$dc_sk/stage/$dc_e.contract" --root "$dc_sk/stage" --typedump "$READER" --outdir "$dc_ad" \
      --core-header "spinel_core_dc_sp_$dc_e.h" > "$dc_ad/$dc_e.gen" 2>&1 || dc_rc=$?
    cp "$dc_ad/spinel_adapter_registry.c" "$dc_ad/registry-$dc_e.c"
  done
  return "$dc_rc"
}

# The adapter for decision 0008's three entries, as dc_adapter_generate does it
# for the source entries: one run per contract into one directory, each leaving
# its copy of the shared registry.
dc_route_adapter() { # entry-dir adapter-dir
  dc_sk=$1; dc_ad=$2
  [ -n "${ADAPTER_BIN:-}" ] || { echo "artifacts.sh: ADAPTER_BIN is not set; the caller chooses it" >&2; return 1; }
  mkdir -p "$dc_ad/obj" || return 1
  dc_rc=0
  for dc_e in doom_core_input doom_core_step doom_core_render; do
    cp "$dc_sk/$dc_e.h" "$dc_ad/spinel_core_$dc_e.h"
    "$ADAPTER_BIN" "$dc_sk/stage/$dc_e/$dc_e.contract" --root "$dc_sk/stage/$dc_e" --typedump "$READER" --outdir "$dc_ad" \
      --core-header "spinel_core_$dc_e.h" ${DC_FAILURE_SITES:+--failure-sites} > "$dc_ad/$dc_e.gen" 2>&1 || dc_rc=$?
    cp "$dc_ad/spinel_adapter_registry.c" "$dc_ad/registry-$dc_e.c"
  done
  return "$dc_rc"
}

# Those sources compiled and linked with the kernel tool's objects.
dc_adapter_link() { # entry-dir adapter-dir out
  dc_sk=$1; dc_ad=$2; dc_out=$3
  dc_rc=0
  for dc_c in "$dc_ad"/spinel_adapter_*.c; do
    "$CC_BIN" -std=c11 -O1 -fPIC -I"$dc_ad" -c "$dc_c" -o "$dc_ad/obj/$(basename "$dc_c" .c).o" >> "$dc_ad/cc.err" 2>&1 || dc_rc=$?
  done
  "$CC_BIN" -shared -o "$dc_out" "$dc_ad/obj"/*.o "$dc_sk"/*.o -lpthread >> "$dc_ad/cc.err" 2>&1 || dc_rc=$?
  return "$dc_rc"
}
