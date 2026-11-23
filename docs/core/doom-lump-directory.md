# The WAD directory as per-entry arrays

**Status: DECIDED and implemented** (`tools/doom/core-representations.tsv`;
checked by `tests/doom-core/lump-directory.rb` and the directory controls in
`tests/doom-core/state.sh`). The three singletons are REPLACED by
the three per-entry arrays below; they are not kept beside them as permanently
unsupported fields that describe nothing. This makes an existing buffer
representation concrete. It adds no CORE type, no status and no alias
exception, it is not a change to 0007's public contract, and it is not a
judgement that task 5 is met.

| replaced | by |
|---|---|
| `Lump@@name` → `lump_name` | `wad_lump_name` |
| `Lump@@pos` → `lump_pos` | `wad_lump_pos` |
| `Lump@@size` → `lump_size` | `wad_lump_size` |

The replacement keeps comparison coverage of every entry; see below.

## What was wrong with the old schema

The schema declared `lump_name`, `lump_pos` and `lump_size` as three single
prepared fields. `Doom::Lump` is one WAD directory entry **per lump**. Neither
side had one object to read them from, and the reference reported all three
unreachable (`byclass Lump=3`). So that shape could not describe what the
original holds, whatever producer was written.

`tools/doom/core-fields.tsv` already states the rule for the directory itself:

> `Wad@@lumps` — full-only. CORE receives buffers, not object references, and
> what it needs from a lump — a position and a size — Full passes as scalars or
> prepares as a table.

This proposal is that table.

## Measured on doom1.wad

| | |
|---|---|
| entries, `Wad#count` | 1264 |
| zero-size markers (`size == 0`) | 19 |
| duplicate names | 81 (1183 distinct) |
| lower-case directory names | 0 |

Two of those, concretely. `THINGS` appears at indices 7, 18, 29, 40, 51, 62,
73, 84 and 95 — one per map — and `index_of("THINGS")` is 95, the last. The map
marker `E1M1` at index 6 has size 0 and **pos 67500**: a marker's position is
not zero, it is whatever the file holds.

**1264 is this IWAD's count, not a constant.** The schema names only
`table:lumps` and `table:lumpnamebytes`; the catalog resolves them from the
real `Wad#count` and from `8 * Wad#count`, per configuration. No length is
written as 1264 and no expression is written inline in the schema. The count is
checked **before** it is multiplied: a non-negative Integer no larger than
`U64_MAX / 8`, the byte-length bound `state-schema.rb` and `Session` already
apply. (A check after the product, `(n * 8) / 8 == n`, holds for every Ruby
integer and refuses nothing.)

## Who reads each field in the CORE closure

From the audit's inventory, `readers` column:

| field | readers | used as |
|---|---|---|
| `pos` | `Hud#draw`, `Hud#draw_patch`, `Renderer#draw_masked_texture_column`, `StatusBar#copy_rect_from_backing`, `StatusBar#draw_patch`, `StatusBar#update_num`, `Wad#zone_window_into` | an offset into the WAD data buffer |
| `size` | `Renderer#draw_masked_texture_column`, `Wad#zone_header_byte`, `Wad#zone_window_into` | a bound on that offset |
| `name` | `StatusBar#draw_patch` | **only** inside the out-of-range error message (`statusbar.rb:508`) |

Every reader reaches a lump **by index** (`@wad.lump(lumpnum)`), never by name.

## The representation

| field | count | element | holds |
|---|---|---|---|
| `wad_lump_pos` | `table:lumps` | i64 | `wad.lump(i).pos` for every `i` |
| `wad_lump_size` | `table:lumps` | i64 | `wad.lump(i).size` for every `i` |
| `wad_lump_name` | `table:lumpnamebytes` | u8 | entry `i`'s NAME at `8*i`, zero-padded to 8 bytes |

Index `i` is the lump number the readers already pass, so no reader changes
how it addresses an entry. `pos` and `size` are `i32` in the file; `i64` holds
every value the directory can carry, and the element domain check refuses one
that does not fit rather than wrapping it.

### Name bytes: the NAME, which is not the raw slot

`Wad#parse_directory` reads a name with `Bytes.name8`: up to 8 bytes, **stopping
at the first NUL**. The bytes after that NUL are not part of the name.

An earlier version of this section said the array stores "the bytes as the file
has them, NUL-padded". Those are two different things, and review measured the
difference on a synthetic WAD:

    raw 8-byte slot    61 62 00 58 79 5a 00 51     ab\0XyZ\0Q
    Bytes.name8        "ab"                        2 bytes
    stored             61 62 00 00 00 00 00 00     the name, zero-padded

So each entry stores **`Lump.name` — the bytes `Bytes.name8` read — followed by
zero bytes to 8.** The post-NUL payload is not stored and not compared as part
of the name; the raw directory, payload included, is separate information that
lives with the WAD data. Case is preserved: the directory is not folded
(`Bytes.name8_upper` is for PNAMES), and a name lookup is case-sensitive.
Nothing is upcased or trimmed.

### Zero-size markers

A `size == 0` entry is a namespace marker (`S_START`, `F_END`, …).
`parse_directory` validates `pos` only when `size > 0`, so a marker's `pos` is
whatever the file holds and means nothing. It is still a **defined** cell: the
proposal carries it as read and compares it as read. It does not zero it, skip
it, or treat it as undefined — `E1M1`'s 67500 would become a 0 nobody measured.

### Duplicate names

`parse_directory` assigns `@index[name] = i` in file order, so for a repeated
name the **last** entry wins (as vanilla). That is a property of the
**name → index lookup**, which runs in Full's preparation (`index_of`,
`num_for_name`, `bytes_by_name`). It is not a property of the per-entry arrays:
all 1264 entries, duplicates included, keep their own `pos`, `size` and name at
their own index. A CORE reader receives an index Full already resolved.

## Comparing against the original

For the same WAD and configuration:

1. `Wad#count` on both sides is the same number, and each array's length is
   exactly that count (`8 * count` for names) — refused by length otherwise.
2. For every `i` in `0...count`: `pos[i]`, `size[i]` and the 8 name bytes at
   `8*i` equal `wad.lump(i).pos`, `.size` and `.name` zero-padded to 8 bytes.
3. Controls, each named:
   * a **duplicate name**: all nine `THINGS` entries present at their own
     indices, and the name lookup resolving to 95, the last;
   * a **marker**: `E1M1`'s `pos` compared as 67500, not zeroed;
   * the **last entry**, index `count - 1`, compared like every other;
   * a **missing entry** and a **wrong length**, each refused by name;
   * one cell broken before the session, named with its field and index.

   As implemented: the missing entry is the IWAD with its `DSPISTOL` directory
   entry removed (file length kept), refused as `wad_lump_name: Full produced
   10104 byte(s) and the layout declares 10112`; the wrong length is a layout
   giving `wad_lump_pos` 1263 entries; the broken cells are `wad_lump_pos[6]`
   (E1M1, 67500) and `wad_lump_name[10104]` (the last entry, `F_END`); and a
   withheld `wad_lump_size` is refused by the session.

   doom1.wad has no lower-case directory name and no slot with bytes after its
   NUL, so neither case can be tested on it. A small synthetic WAD, **generated
   by the tracked test script** rather than stored as a binary file, supplies
   both: a lower-case name, which must be stored lower case, and a
   slot like `ab\0XyZ\0Q`, whose stored name must be `ab` zero-padded rather
   than the raw slot.

## Settled on review

* The arrays **replace** the singletons.
* The name array is **kept**. That its only CORE reader is an error message is
  noted, and dropping it on that ground is a separate optimisation that is not
  being made now.
