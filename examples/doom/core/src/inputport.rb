# examples/doom/core/src/inputport.rb — the input entry: key state, the scripted keys, the tic command, the demo.
#
# GPL-derived, from `examples/doom/lib/doom/input.rb` (`Doom::KeyState`,
# `Doom::KeyScript`, `Doom::TiccmdBuilder`) and `record.rb`
# (`Doom::DemoWriter#write_tic`), which reproduce doomgeneric's `g_game.c`
# (`G_BuildTiccmd`) and the demo recording of `G_WriteDemoTiccmd`. See
# ../NOTICE.md and ../sources.tsv.
#
# stepcore.rb's convention: a scalar field is `state[xi[X_NAME]]`, through the
# index table `xi` (examples/doom/core/entries/input-slots.tsv names the
# field at each position); a value Full prepares is a one-element buffer; an
# array is a buffer named by its field. A boolean is 0 or 1; `raise` is
# `core_fail(:capacity)`. Written in the port-first pass: nothing here is
# compared with the original yet.
#
# The move tables (SIDEMOVE, FORWARDMOVE, ANGLETURN) are packed constants read
# with a shift, as the kernel admits no data table. The script's line count is
# a scalar, since a helper cannot read a buffer's size.

X_TURNHELD = 0
X_BUTTONS = 1
X_FORWARDMOVE = 2
X_SIDEMOVE = 3
X_ANGLETURN = 4
X_DEMO_N = 5

IN_KEY_STRAFE = 184
IN_KEY_SPEED = 182
IN_KEY_RIGHT = 174
IN_KEY_LEFT = 172
IN_KEY_UP = 173
IN_KEY_DOWN = 175
IN_KEY_STRAFERIGHT = 46
IN_KEY_STRAFELEFT = 44
IN_KEY_FIRE = 157
IN_KEY_USE = 32
IN_SLOWTURNTICS = 6
IN_MAXPLMOVE = 50
IN_BT_ATTACK = 1
IN_BT_USE = 2
IN_BT_CHANGE = 4
IN_BT_WEAPONSHIFT = 3
IN_DEMO_HEADER = 13
# SIDEMOVE [24, 40], FORWARDMOVE [25, 50], ANGLETURN [640, 1280, 320]: 16 bits each.
# ANGLETURN's three do not fit one 32-bit word (decision 0022 §2.5): its first
# two are packed in IN_ANGLETURN_LO and the third, the slow turn's, is
# IN_ANGLETURN_HI.
IN_SIDEMOVE = 0x00280018
IN_FORWARDMOVE = 0x00320019
IN_ANGLETURN_LO = 0x05000280
IN_ANGLETURN_HI = 0x0140

# `KeyState#press`
def dc_in_press(down, code)
  down[code] = 1
  0
end

# `KeyState#clear`
def dc_in_clear(down)
  i = 0
  while i < 256
    down[i] = 0
    i += 1
  end
  0
end

# `KeyScript#apply`: the keys the script holds down at tic t
def dc_in_apply(down, script_code, script_from, script_to, ncode, t)
  dc_in_clear(down)
  i = 0
  while i < ncode
    if t >= script_from[i] && t <= script_to[i]
      dc_in_press(down, script_code[i])
    end
    i += 1
  end
  0
end

# `TiccmdBuilder#build`: the tic command from the keys down
def dc_in_build(state, xi, down)
  strafe = down[IN_KEY_STRAFE] != 0 ? 1 : 0
  speed = down[IN_KEY_SPEED]
  forward = 0
  side = 0
  turn = 0
  state[xi[X_BUTTONS]] = 0

  # the two-step turn acceleration; turnheld carries across frames
  if down[IN_KEY_RIGHT] != 0 || down[IN_KEY_LEFT] != 0
    state[xi[X_TURNHELD]] += 1
  else
    state[xi[X_TURNHELD]] = 0
  end
  tspeed = state[xi[X_TURNHELD]] < IN_SLOWTURNTICS ? 2 : speed
  sidemove = (IN_SIDEMOVE >> (speed * 16)) & 0xffff
  forwardmove = (IN_FORWARDMOVE >> (speed * 16)) & 0xffff
  angleturn = tspeed == 2 ? IN_ANGLETURN_HI : (IN_ANGLETURN_LO >> (tspeed * 16)) & 0xffff

  # each branch ends with a value: the kernel refused the modifier ifs as the
  # branches' last statements (an implicit nil), as stepcore.rb's header warns
  if strafe != 0
    side += sidemove if down[IN_KEY_RIGHT] != 0
    side -= sidemove if down[IN_KEY_LEFT] != 0
    0
  else
    turn -= angleturn if down[IN_KEY_RIGHT] != 0
    turn += angleturn if down[IN_KEY_LEFT] != 0
    0
  end

  forward += forwardmove if down[IN_KEY_UP] != 0
  forward -= forwardmove if down[IN_KEY_DOWN] != 0
  side += sidemove if down[IN_KEY_STRAFERIGHT] != 0
  side -= sidemove if down[IN_KEY_STRAFELEFT] != 0

  state[xi[X_BUTTONS]] = state[xi[X_BUTTONS]] | IN_BT_ATTACK if down[IN_KEY_FIRE] != 0
  state[xi[X_BUTTONS]] = state[xi[X_BUTTONS]] | IN_BT_USE if down[IN_KEY_USE] != 0

  # the weapon keys '1'..'8': only the first one down
  i = 0
  while i < 8
    if down[49 + i] != 0
      state[xi[X_BUTTONS]] = state[xi[X_BUTTONS]] | IN_BT_CHANGE | (i << IN_BT_WEAPONSHIFT)
      break
    end
    i += 1
  end

  forward = IN_MAXPLMOVE if forward > IN_MAXPLMOVE
  forward = -IN_MAXPLMOVE if forward < -IN_MAXPLMOVE
  side = IN_MAXPLMOVE if side > IN_MAXPLMOVE
  side = -IN_MAXPLMOVE if side < -IN_MAXPLMOVE

  state[xi[X_FORWARDMOVE]] = forward
  state[xi[X_SIDEMOVE]] = side
  # `ticcmd_t.angleturn` is a short
  state[xi[X_ANGLETURN]] = ((turn & 0xffff) ^ 0x8000) - 0x8000
  0
end

# `TiccmdBuilder#quantize_angle!`: the recorded byte, and the turn it stands for
def dc_in_quantize_angle(state, xi)
  b = ((state[xi[X_ANGLETURN]] + 128) >> 8) & 0xff
  v = b << 8
  state[xi[X_ANGLETURN]] = v >= 0x8000 ? v - 0x10000 : v
  b
end

# `DemoWriter#write_tic`: one tic's four bytes
def dc_in_write_tic(state, xi, demo_buf, demo_max, forwardmove, sidemove, aturn_byte, buttons)
  n = state[xi[X_DEMO_N]]
  if n >= demo_max[0]
    core_fail(:capacity)
  end
  o = IN_DEMO_HEADER + n * 4
  demo_buf[o] = forwardmove & 0xff
  demo_buf[o + 1] = sidemove & 0xff
  demo_buf[o + 2] = aturn_byte & 0xff
  demo_buf[o + 3] = buttons & 0xff
  state[xi[X_DEMO_N]] = n + 1
  0
end
