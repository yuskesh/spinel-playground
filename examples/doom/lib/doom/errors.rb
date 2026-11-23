# doom/lib/doom/errors.rb
#
# The exception hierarchy. **Broken input is never let through quietly; it always fails
# loudly with an exception from here.** The staged oracle (L0 = lump bytes) means
# something only when "it was read" includes "it was read correctly".
#
# See "the refusal discipline" in the port's conventions.

module Doom
  # The base of every exception this port raises.
  class Error < StandardError
  end

  # The structure of the WAD file (header / directory / lump ranges) is broken.
  class WadError < Error
  end

  # The structure of the picture format (patch) is broken, or it is outside the subset
  # this port accepts (tall patches do not exist in vanilla, so they are not supported).
  class PictureError < Error
  end

  # The dimensions of PLAYPAL / COLORMAP do not match the specification.
  class PaletteError < Error
  end

  # The structure of a level lump (VERTEXES / LINEDEFS / ... / NODES) is broken,
  # or a reference points out of range.
  class LevelError < Error
  end

  # SDL2's interface (window / texture / palette) could not be made,
  # or was given broken arguments.
  # **This is the only exception that talks to the world outside the process.**
  class VideoError < Error
  end
end
