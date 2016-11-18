#!/usr/bin/env ruby

diff_dir = File.dirname(File.expand_path(__FILE__))

f = {
  diffs: File.join(diff_dir,"details.diff"),
  names: File.join(diff_dir,"names.txt"),
  summs: File.join(diff_dir,"summary.txt"),
}

f.each_pair do |k,v|
  puts v.inspect
end
prev_tag = ARGV.shift
release_tag = ARGV.shift

tags = %x{git for-each-ref --sort=taggerdate --format '%(refname) %(taggerdate)' refs/tags|cut -f 1 -d ' '|cut -d '/' -f 3|tail -n2}.split

release_tag ||= tags.last

if ARGV.include?("--head")
  prev_tag = release_tag
  release_tag = 'HEAD'
end

puts "Comparing: #{prev_tag} with #{release_tag}"
%x{git diff -b --name-only #{prev_tag}..#{release_tag} > #{f[:names]}}
%x{git diff -b --summary #{prev_tag}..#{release_tag} > #{f[:summs]}}
%x{git diff -b #{prev_tag}..#{release_tag} > #{f[:diffs]}}

puts "Done, to edit modules:"
puts ""
fh = File.open(f[:summs]) {|fd| fd.read fd.stat.size}
mods = []
fh.each_line do |line|
  next unless line =~ /create mode.*modules/
  mods << line.split.last.strip
end
puts "vim #{mods.join " "}"
