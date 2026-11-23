# See README.md. These two differ only in the line below.
module Doom
  module Other
    N = 64
  end

  class Game
    include Math
    def g_ticker
      init_bank
      @bank[0]
    end

    def init_bank
      @bank = Array.new(N, 0)
    end
  end
end
