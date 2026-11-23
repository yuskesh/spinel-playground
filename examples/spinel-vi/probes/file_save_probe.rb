# spinel-tier: full
# E097 File probe only.  This is not the editor's :w implementation.

target = ARGV[0]
temporary = ARGV[1]
fail_before_rename = ARGV.length > 2 && ARGV[2] == "fail-before-rename"
before = File.read(target)
puts "read=#{before}"

begin
  file = File.open(temporary, "w")
  file.write(before + "|saved")
  file.flush
  synced = file.fsync
  file.close
  if fail_before_rename
    # The gate supplies a path in a nonexistent directory.  File.open above
    # therefore raises before any target mutation; this branch is only a
    # guard against accidentally changing the fixture into a direct truncate.
    puts "save=unexpected"
  else
    File.rename(temporary, target)
    puts "save=ok fsync=#{synced}"
  end
rescue
  puts "save=error"
end

puts "content=#{File.read(target)}"
