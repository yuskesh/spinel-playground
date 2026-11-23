# Marshal round trip: a format the bare-metal lane cannot link (decision 0037)
a = [1, "two", :three, { "k" => 4.5 }, nil, true]
s = Marshal.dump(a)
p Marshal.load(s)
p Marshal.load(s) == a
