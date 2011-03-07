require 'rubygems'
require 'bundler'
require 'rake'
require 'spec/rake/spectask'
require 'fileutils'

# Usage (rake --tasks):
#
# rake autotest           # Run autotest
# rake autotest:rcov      # Run RCov when autotest successful
# rake spec               # Run all specs in all specs directories
# rake spec:clobber_rcov  # Remove rcov products for rcov
# rake spec:doc           # Print Specdoc for all specs
# rake spec:rcov          # Run all specs all specs directories with RCov

RIGHT_BOT_ROOT = File.dirname(__FILE__)

# allows for debugging of order of spec files by reading a specific ordering of
# files from a text file, if present. all too frequently, success or failure
# depends on the order in which tests execute.
RAKE_SPEC_ORDER_FILE_PATH = ::File.join(RIGHT_BOT_ROOT, "rake_spec_order_list.txt")

# Setup path to spec files and spec options
#
# === Parameters
# t<Spec::Rake::SpecTask>:: Task instance to be configured
#
# === Return
# t<Spec::Rake::SpecTask>:: Configured task
def setup_spec(t)
  t.spec_opts = ['--options', "\"#{RIGHT_BOT_ROOT}/spec/spec.opts\""]
  t.spec_files = FileList["#{RIGHT_BOT_ROOT}/**/spec/**/*_spec.rb"].reject {|path| path =~ /vendor/}

  # optionally read or write spec order for debugging purposes. use a stubbed
  # file with the text "FILL ME" to get the spec ordering for the current
  # machine.
  if ::File.file?(RAKE_SPEC_ORDER_FILE_PATH)
    if ::File.read(RAKE_SPEC_ORDER_FILE_PATH).chomp == "FILL ME"
      ::File.open(RAKE_SPEC_ORDER_FILE_PATH, "w") do |f|
        f.puts t.spec_files.to_a.join("\n")
      end
    else
      t.spec_files = FileList.new
      ::File.open(RAKE_SPEC_ORDER_FILE_PATH, "r") do |f|
        while (line = f.gets) do
          line = line.chomp
          (t.spec_files << line) if not line.empty?
        end
      end
    end
  end
  t
end

# Setup environment variables for autotest and check installation
#
# === Return
# true:: Autotest setup is OK
# false:: Otherwise
def setup_auto_test
  ENV['RSPEC']    = 'true'     # allows autotest to discover rspec
  ENV['AUTOTEST'] = 'true'  # allows autotest to run w/ color on linux
#  $:.push(File.join(File.dirname(__FILE__), 'spec'))
  system((RUBY_PLATFORM =~ /mswin|mingw/ ? 'autotest.bat' : 'autotest'), *ARGV) ||
  $stderr.puts('Unable to find autotest. Please install ZenTest or fix your PATH') && false
end

# Default to running unit tests
task :default => :spec

# List of tasks
desc 'Run all specs in all specs directories'
Spec::Rake::SpecTask.new(:spec) do |t|
  setup_spec(t)
end

namespace :spec do
  desc 'Run all specs all specs directories with RCov'
  Spec::Rake::SpecTask.new(:rcov) do |t|
    setup_spec(t)
    t.rcov = true
    t.rcov_opts = lambda { IO.readlines("#{RIGHT_BOT_ROOT}/spec/rcov.opts").map {|l| l.chomp.split ' '}.flatten }
  end

  desc 'Print Specdoc for all specs (excluding plugin specs)'
  Spec::Rake::SpecTask.new(:doc) do |t|
    setup_spec(t)
    t.spec_opts = ['--format', 'specdoc', '--dry-run']
  end
end

desc 'Run autotest'
task :autotest do
  setup_auto_test
end

namespace :autotest do
  desc 'Run RCov when autotest successful'
  task :rcov do
    ENV['RCOV'] = 'true'
    setup_auto_test
  end
end

# Currently only need to build for Windows.
if !!(RUBY_PLATFORM =~ /mswin/)
  desc "Builds any binaries local to right_net or right_link"
  task :build do
    ms_build_path = "#{ENV['WINDIR']}\\Microsoft.NET\\Framework\\v3.5\\msbuild.exe"
    Dir.chdir(File.join(RIGHT_BOT_ROOT, 'chef', 'lib', 'windows', 'ChefNodeCmdlet')) do
      # note that we can build C# components using msbuild instead of needing to
      # have Developer Studio installed.
      build_command = "#{ms_build_path} ChefNodeCmdlet.sln /t:clean,build /p:configuration=Release > ChefNodeCmdlet.build.txt 2>&1"
      puts "#{build_command}"
      `#{build_command}`
    end
  end
end
