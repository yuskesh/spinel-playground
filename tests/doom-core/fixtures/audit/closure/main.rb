require_relative "dep"

module Doom
  class Game
    def g_ticker
      Other.new.target
    end
  end
end
