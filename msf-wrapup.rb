#!/usr/bin/env ruby

require 'optparse'

diff_dir = File.dirname(File.expand_path(__FILE__))

options = {}
optparse = OptionParser.new do |opts|
  opts.banner = "Usage: $0 [options] "

  options[:msf_path] = ENV['PWD']
  opts.on('-f', '--framework PATH', 'Path to metasploit-framework') do |msfpath|
    options[:msf_path] = msfpath
  end

  opts.on('-u', '--url', 'Show just URLs, no summary') do |url|
    options[:url] = url
  end

  opts.on('--head', 'Compare the last tag with head instead of the last two tags') do
    options[:head] = true
  end

end

optparse.parse!

files = {
  diffs: File.join(diff_dir,"details.diff"),
  names: File.join(diff_dir,"names.txt"),
  summs: File.join(diff_dir,"summary.txt"),
}

prev_tag = ARGV.shift
release_tag = ARGV.shift

tags = %x{git for-each-ref --sort=taggerdate --format '%(refname) %(taggerdate)' refs/tags|cut -f 1 -d ' '|cut -d '/' -f 3|tail -n2}.split

release_tag ||= tags.last

if options[:head]
  prev_tag ||= release_tag
  release_tag = 'HEAD'
else
  prev_tag ||= tags.first
end

prev_date = %x{git log -1 --reverse --format='%aI' #{prev_tag}}.chomp
release_date = %x{git log -1 --reverse --format='%aI' #{release_tag}}.chomp

puts "Comparing: #{prev_tag} with #{release_tag}"
%x{git diff -b --name-only #{prev_tag}..#{release_tag} > #{files[:names]}}
summs = %x{git diff -b --summary #{prev_tag}..#{release_tag} | tee #{files[:summs]}}
%x{git diff -b #{prev_tag}..#{release_tag} > #{files[:diffs]}}

modules = []
optparse.parse!

summs.each_line do |line|
  next unless line =~ /^\s+create mode .* (modules.*)\r?\n$/
  modpath = $1
  next if modpath =~ /modules\/payload/ # Skip payload checks for now
  next if modpath =~ /modules\/encoders/ # Skip encoder checks for now
  modules << modpath
  puts modpath
end

puts

modules.each_with_index do |m,i|
  res = %x{#{options[:msf_path]}/tools/dev/msftidy.rb #{m}}
  next unless res && res.size > 1
  puts res
end

rc_file = "/tmp/modinfo.rc"
msf_spool = "/tmp/modinfo.txt"

File.unlink rc_file rescue nil
File.unlink msf_spool rescue nil

rc_filehandle = File.open(rc_file, "wb")

rc_filehandle.puts "spool /tmp/modinfo.txt"

def msf_modname(modname)
  case modname
  when /exploits/
    type = "exploit"
  when /auxiliary/
    type = "auxiliary"
  when /post/
    type = "post"
  when /encoder/
    type = "encoder"
  when /nops/
    type = "nop"
  end
  type + modname.gsub(/^modules.(exploits|auxiliary|post)/,"").gsub(/\.rb$/,"")
end

def msf_url(modname)
  "https://www.rapid7.com/db/modules/#{msf_modname(modname)}"
end


def sort_and_pluralize_author(author_list)
  return unless author_list.kind_of? Array

  author_list = author_list.sort
  ["todb", "hdm", "egyp7", "egypt", "juan vazquez", "juan", "sinn3r", "wvu", "joev"].each do |msf_author|
    if author_list.include? msf_author
      case msf_author
      when /^juan$/
        author_list.delete msf_author
        author_list.unshift "juan vazquez"
      when /egypt/
        author_list.delete msf_author
        author_list.unshift "egyp7"
      else
        author_list.unshift author_list.delete msf_author
      end
    end
  end

  case author_list.size
  when 0
    author_list = "NOBODY"
  when 1
    author_list = author_list.first
  else
    author_list[-1] = "and #{author_list[-1]}"
    if author_list.length == 2
      author_list = author_list.join(" ")
    else
      author_list = author_list.join(", ")
    end
  end

  return author_list
end

# The preferred order is: Microsoft bulletin, then ZDI reference, then CVE, then OSVDB, then BID, then nothing.
def select_best_reference(ref_list)
  ret = nil
  ref_list.each do |ref|
    case ref
    when /microsoft.com.*bulletin[\x5c\x2f](.*).msp/
      val = $1
      ret = val
    when /zerodayinitiative.com[\x5c\x2f]advisories[\x5c\x2f]([^\x5c\x2f]+)/
      val = $1
      next if ret.to_s =~ /^MS/
      ret = val
    when /cve.mitre.*name=(.*)/, /cvedetails\x2ecom[\x5c\x2f]cve[\x5c\x2f]([^\x5c\x2f]*)/
      val = $1
      next if ret.to_s =~ /^(MS|ZDI)/
      ret = ""
      ret << "CVE-" unless val =~ /^CVE-/
      ret << "#{val}"
    when /osvdb.org[\x5c\x2f](\d+)/
      val = $1
      next if ret.to_s =~ /^(MS|ZDI|CVE)/
      ret = "OSVDB-#{val}"
    when /securityfocus\.com[\x5c\x2f]bid[\x5c\x2f](\d+)/
      val = $1
      next if ret.to_s =~ /^(MS|ZDI|CVE|OSVDB)/
      ret = "BID-#{val}"
    else
      next if ret.to_s =~ /^(MS|ZDI|CVE|OSVDB|BID)/
      ret = "XXX-NOREF"
    end
  end
  return ret
end

# Build out the rc file to get the info from the modules...

modules.each do |mod|
  rc_filehandle.puts "echo BEGIN: #{msf_url(mod)}"
  rc_filehandle.puts "info #{msf_modname(mod)}"
  rc_filehandle.puts "echo END: #{msf_url(mod)}"
end

rc_filehandle.puts "exit"
rc_filehandle.close rescue nil

# Now run msfconsole, which will exit after writing out to a file.

puts "Running the console..."
console_output = %x{./msfconsole -L -r #{rc_file}}
@exploits = {}
@modules = {}
data = {}

console_output.each_line do |line|
  if @module_url
    case line
    when /END: #{@module_url}/
      if @module_url.include?("/exploit/")
        @exploits[@module_url] = data
      else
        @modules[@module_url] = data
      end
      @module_url = nil
      data = {}
    when /^\s+Name: (.*)/
      data[:name] = $1.to_s.chomp
    when /^Provided by:/
      @module_authors = []
    when /^References:/
      @module_references = []
    end

    if @module_references
      case line
      when /^\s*$/
        data[:ref] = select_best_reference(@module_references.dup)
        @module_references = nil
      when /^References:/
        next
      else
        @module_references << line.lstrip.rstrip
      end
    end

    if @module_authors
      case line
      when /^\s*$/
        data[:authors] = sort_and_pluralize_author(@module_authors.dup)
        @module_authors = nil
      when /^Provided by:/
        next
      else
        @module_authors << line.split(/</).first.to_s.lstrip.rstrip
      end
    end

  else
    if line =~ /BEGIN: (.*)/
      @module_url = $1
      @module_authors = nil
      @module_references = nil
    end
  end
end

puts "# New Modules"
puts
{"Exploit modules" => @exploits, "Auxiliary and post modules" => @modules}.each do |type, module_list|

  unless module_list.empty?
    puts "*#{type}* *(#{module_list.length} new)*"
    module_list.each_pair do |db_url,v|
      case v[:ref].to_s
      when "", "XXX-NOREF"
        msg = %Q|  * [#{v[:name]}](#{db_url}) by #{v[:authors]}|
      else
        msg = %Q|  * [#{v[:name]}](#{db_url}) by #{v[:authors]} exploits #{v[:ref]}|
      end
      puts msg
    end
  end

end

puts <<-EOM

# Get it

As always, you can update to the latest Metasploit Framework with `msfupdate`
and you can get more details on the changes since the last blog post from
GitHub:

  * [Pull Requsts #{prev_tag}...#{release_tag}][prs-landed]
  * [Full diff #{prev_tag}...#{release_tag}][diff]

To install fresh, check out the open-source-only [Nightly
Installers][nightly], or the [binary installers][binary] which also include
the commercial editions.

[binary]: https://www.rapid7.com/products/metasploit/download.jsp
[diff]: https://github.com/rapid7/metasploit-framework/compare/#{prev_tag}...#{release_tag}
[prs-landed]: https://github.com/rapid7/metasploit-framework/pulls?q=is:pr+merged:"#{prev_date}+..+#{release_date}"
[nightly]: https://github.com/rapid7/metasploit-framework/wiki/Nightly-Installers

EOM

puts "\n\n"

