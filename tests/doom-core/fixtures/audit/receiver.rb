module Doom
  class Other
    def initialize
      setup_hidden
    end
    def setup_hidden
      7
    end
    def target
      99
    end
  end
  class Game
    def target
      1
    end
    def g_ticker
      Other.new.target
    end
  end
end
