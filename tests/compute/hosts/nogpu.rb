begin
  Scale.open(4)
  check("no GPU is reported", "opened", "an error")
rescue => e
  check("no GPU is reported", e.message.size > 0, true)
  puts "reported: #{e.message}"
end
