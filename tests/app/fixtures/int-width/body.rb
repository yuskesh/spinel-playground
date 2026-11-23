def tick(state)
  twice = double(state)
  state[0] = twice / 2 + tag("A") - 65
  0
end

def double(state)
  state[0] + state[0]
end

def tag(bytes)
  bytes[0]
end
