# See README.md. This is scope-qualified.rb with one line added.
module Doom
  module Other
    N = 64
  end

  class Game
    include Math
    Other = 1

    def g_ticker
      init_bank
      @bank[0]
    end

    def init_bank
      @bank = Array.new(Other::N, 0)
    end
  end
end
