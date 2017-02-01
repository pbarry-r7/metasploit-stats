#!/usr/bin/env ruby

=begin

Before using this script for the very first time, do:

1. Add an environment variable 'MSFDIR' to set Metasploit Framework's local path. For example, on
   OS X, add this line to ~/.bash_profile:
   export MSFDIR="/Users/wchen/rapid7/msf"
2. gem install git
3. gem install octokit
4. gem install nokogiri
5. gem install redcarpet

Every time before you use this script, you should:

1. cd to your Metasploit repo, and git pull upstream-master and make sure it is up to date.

When using the script, you need to know:

1. The starting release tag. For example: 4.11.0
2. The ending release tag. For example: 4.12.5. This is optional.

And then you can use the script to find all the landed PRs and release notes between
those two tags:

$ ruby get_release_notes.rb 4.11.0 4.12.5

If you don't provide the ending tag, the script should find all the PRs starting from the
first tag until the most recent.

After the release notes are collected, the script should automatically save the info
in a file as release_notes_[starting tag]_[end tag].html, under the same directory as
the script.

=end

begin
  require 'git'
  require 'octokit'
  require 'nokogiri'
  require 'redcarpet'
rescue LoadError => e
  failed_gem = e.message.split.last
  fail "#{failed_gem} not installed: please run 'gem install #{failed_gem}'"
end

# The local repo to collect "Land" messages from
REPO                  = ENV['MSFDIR']

# Metasploit-Framework account
GITHUB_REPO_OWNER     = 'rapid7'

# Repo to collect release notes from.
GITHUB_REPO_NAME      = "#{GITHUB_REPO_OWNER}/metasploit-framework"

class ReleaseNotes

  attr_accessor :git
  attr_accessor :git_client

  def initialize(token=nil)
    unless REPO
      fail "You need to set a 'MSFDIR' environment variable before using this script. " +
           "And this path should point to your local Metasploit Framework repository."
    end

    # You can choose to use your own oauth token by doing this:
    # 1. Go to your Github account
    # 2. Click on Settings -> Personal access tokens -> Generate new token.
    # 3. Save the new token as an environment variable.
    #    For example, for OS X, open ~/.bash_profile, and then add this line:
    #    export GITHUB_OAUTH_TOKEN="Your token here"
    #
    # Or, if you are feeling lazy, you can't skip doing all that, just use the hardcoded one (mine)
    token = token.nil? && ENV.has_key?('GITHUB_OAUTH_TOKEN') ? ENV['GITHUB_OAUTH_TOKEN'] : '88a9266779a6ec6c26d6dde3b7da883a0c2e7f44'

    @git = Git.open(REPO)
    @git_client = Octokit::Client.new(access_token: token)
  end

  def get_landed_messages(start_tag, end_tag=nil)
    messages = []

    begin
      if end_tag
        messages = git.log(9000).between(start_tag, end_tag).select { |c|
          c.message =~ /^Land/i || c.message =~ /^See #\d+/i || c.message =~ /^Fix #\d+/i
        }
      else
        messages = git.log(9000).between(start_tag).select { |c|
          c.message =~ /^Land/i || c.message =~ /^See #\d+/i || c.message =~ /^Fix #\d+/i
        }
      end
    rescue Git::GitExecuteError => e
      case e.message
      when /unknown revision or path/
        puts 'Unknown revision or path not in the working tree'
        puts "Make sure you:"
        puts "1. git pull upstream-master"
        puts "2. Have the correct release tags (do git tag on your branch to double check)"
        exit
      else
        raise e
      end
    end

    messages
  end

  def get_landed_pr_numbers(land_messages)
    land_messages.map { |c|
      (c.message.scan(/^Land.#(\d+)/).flatten.first || 0).to_i
    }.reject { |n| n == 0}.sort.reverse
  end

  def get_pr_comments(pr)
    git_client.issue_comments(GITHUB_REPO_NAME, pr)
  end

  def get_pr_milestone(pr)
    pr = git_client.issue(GITHUB_REPO_NAME, pr)
    pr.milestone ? pr.milestone.title : 'No milestone'
  end

  def get_release_notes_comment(comments)
    comments.each do |comment|
      if is_release_notes_title?(comment)
        notes = (comment[:body].scan(/[[:space:]]*\#{1,3} Release Notes(.+)/im).flatten.first || '').strip
        return notes
      end
    end

    nil
  end

  def is_release_notes_title?(comment)
    /[[:space:]]*\#{1,3} Release Notes/i === comment[:body]
  end

end

def print_landed_subjects(messages)
  messages.each do |m|
    subject = m.message.scan(/^(Land.+)/i).flatten.first
    puts subject if subject
  end
end

def create_html_output(opts)
  prs = opts[:notes]
  fname = opts[:fname]

  md = Redcarpet::Markdown.new(Redcarpet::Render::HTML)

  builder = Nokogiri::HTML::Builder.new do |doc|
    doc.html {
      doc.body {
        doc.table(border: '0px') {
          prs.each_pair do |pr_num, pr|
            comment = md.render(pr[:comment])
            comment.gsub!(/<\/*p>/,'')
            comment.gsub!(/\n/, '<br>')

            doc.tr {
              doc.td(valign: 'top', nowrap: true) {
                doc.li
                doc.text 'PR '
                doc.a "##{pr_num}", href: "https://github.com/#{GITHUB_REPO_NAME}/pull/#{pr_num}"
              }
              doc.td(valign: 'top') { doc.text '-' }
              doc.td {
                doc.cdata comment
              }
            }
          end
        }
      }
    }
  end

  File.open(fname, 'wb') do |f|
    f.write(builder.to_html)
  end

  puts
  puts "Release notes saved as: #{fname}"
end

def main(args)
  n = ReleaseNotes.new
  messages = n.get_landed_messages(args[:start_tag], args[:end_tag])
  puts 'Found the following landed PRs:'
  print_landed_subjects(messages)
  puts

  puts 'Release Notes:'
  pr_numbers = n.get_landed_pr_numbers(messages)
  fname = "release_notes_#{args[:start_tag]}"
  fname << "_#{args[:end_tag]}" if args[:end_tag]
  fname << '.html'

  notes = {}
  pr_numbers.each do |pr_num|
    milestone = n.get_pr_milestone(pr_num)
    comments = n.get_pr_comments(pr_num)
    release_note_comment = n.get_release_notes_comment(comments) || 'Not written.'
    notes[pr_num] = {
      comment: release_note_comment,
      milestone: milestone
    }
    puts "PR ##{pr_num} (#{milestone}) - #{release_note_comment}".gsub(/\r\n/, ' ')
  end

  create_html_output(fname: fname, notes: notes)
end

def init_args
  opts = {}
  opts[:start_tag] = ARGV.shift
  opts[:end_tag]   = ARGV.shift
  opts
end

if __FILE__ == $PROGRAM_NAME
  args = init_args

  unless args[:start_tag]
    fail 'You need to specify at least one tag.'
  end

  main(args)
end
