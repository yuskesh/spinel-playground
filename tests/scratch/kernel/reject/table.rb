def tick(out)
  t = Core::Table.i64(2) { |i| i * 3 }
  out[0] = t[1]
  0
end
