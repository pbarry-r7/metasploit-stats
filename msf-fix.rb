#!/usr/bin/env ruby

require 'optparse'

diff_dir = File.dirname(File.expand_path(__FILE__))

options = {}
optparse = OptionParser.new do |opts|
  opts.banner = "Usage: $0 [options] "

  options[:infile] = File.join(diff_dir, "summary.txt")
  opts.on('-i', '--infile PATH', 'Path to summary.txt generated by msf-diff.rb') do |fname|
    options[:infile] = fname
  end

  options[:msf_path] = ENV['PWD']
  opts.on('-f', '--framework PATH', 'Path to metasploit-framework') do |msfpath|
    options[:msf_path] = msfpath
  end

  opts.on('-d', '--debug', 'Debug output') do |debug|
    options[:debug] = debug
  end

  opts.on('-u', '--url', 'Show just URLs, no summary') do |url|
    options[:url] = url
  end

end

modules = []
optparse.parse!

debug = options[:debug]


File.open(options[:infile], "rb").each_line do |line|
  next unless line =~ /^\s+create mode .* (modules.*)\r?\n$/
  modpath = $1
  next if modpath =~ /modules\/payload/ # Skip payload checks for now
  next if modpath =~ /modules\/encoders/ # Skip encoder checks for now
  modules << modpath
end

modules.each_with_index do |m,i|
  puts "%2d: %s" % [i,m] if debug
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
  end
  type + modname.gsub(/^modules.(exploits|auxiliary|post)/,"").gsub(/\.rb$/,"")
end

def msf_url(modname)
  pre = "http://www.rapid7.com/db/modules/"
  pre + msf_modname(modname)
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
    author_list = author_list.join(", ")
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
      ret = "CVE-#{val}"
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
    end
  end
end

{"Exploit modules" => @exploits, "Auxiliary and post modules" => @modules}.each do |type, data|
  unless data.empty?
    puts "<p><em>#{type}</em></p>"
    puts "<ul>"
    data.each_pair do |k,v|
      case v[:ref].to_s
      when "", "XXX-NOREF"
        msg = %Q|<li><a href="#{k}">#{v[:name]}</a> by #{v[:authors]}</li>|
      else
        msg = %Q|<li><a href="#{k}">#{v[:name]}</a> by #{v[:authors]} exploits #{v[:ref]}</li>|
      end
      puts msg
    end
    puts "</ul>"
    puts "<p></p>\n"
  end
end


puts "\n\n\n"
{"exploit" => @exploits, "other module" => @modules}.each do |type, data|
  unless data.empty?
    puts "* #{data.count} new #{type}#{data.count == 1 ? '' : 's'}"
    data.each_pair do |k,v|
      puts "  * [#{v[:name]}](#{k})"
    end
  end
end
puts "As always, you can update to the latest Metasploit Framework with a simple msfupdate and the full diff is available on GitHub: "
