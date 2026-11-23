# See README.md. The three files differ only in the line below.
module Doom
  class Game
    def g_ticker
      init_bank
      @bank[0]
    end

    def init_bank
      n = 64
      @bank = Array.new(n, 0)
    end
  end
end
