#
# Copyright (c) 2009-2011 RightScale Inc
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

require 'right_http_connection'
require 'process_watcher'
require 'socket'
require 'tempfile'
require 'fileutils'

# The daemonize method of AR clashes with the daemonize Chef attribute, we don't need that method so undef it
undef :daemonize if methods.include?('daemonize')

require File.normalize_path(File.join(File.dirname(__FILE__), '..', '..', 'chef', 'ohai_setup'))
require File.normalize_path(File.join(File.dirname(__FILE__), 'cookbook_path_mapping'))
require File.normalize_path(File.join(File.dirname(__FILE__), 'cookbook_repo_retriever'))

class File
  class << self
    unless method_defined?(:world_writable?)
      def world_writable?(filename)
        (File.stat(filename).mode & 0002) != 0
      end
    end
  end
end

module RightScale
  # Bundle sequence, includes installing dependent packages,
  # downloading attachments and running scripts in given bundle.
  # Also downloads cookbooks and run recipes in given bundle.
  # Runs in separate (runner) process.
  class ExecutableSequence
    include EM::Deferrable

    OHAI_RETRY_MIN_DELAY = 20      # Min number of seconds to wait before retrying Ohai to get the hostname
    OHAI_RETRY_MAX_DELAY = 20 * 60 # Max number of seconds to wait before retrying Ohai to get the hostname

    class CookbookDownloadFailure < Exception
      def initialize(tuple)
        scope, resource, name, reason = tuple
        reason = reason.class.name unless reason.is_a?(String)
        super("#{reason} while downloading #{resource}")
      end
    end

    class AttachmentDownloadFailure < Exception
      def initialize(tuple)
        scope, resource, name, reason = tuple
        reason = reason.class.name unless reason.is_a?(String)
        super("#{reason} while downloading #{resource}")
      end
    end

    # Patch to be applied to inputs stored in core
    attr_accessor :inputs_patch

    # Failure title and message if any
    attr_reader :failure_title, :failure_message

    # Initialize sequence
    #
    # === Parameter
    # bundle(RightScale::ExecutableBundle):: Bundle to be run
    def initialize(bundle)
      unless bundle.thread_name =~ RightScale::ExecutableBundle::VALID_THREAD_NAME
        raise ArgumentError, "Invalid thread name #{thread_name}"
      end

      @description            = bundle.to_s
      @thread_name            = bundle.thread_name
      @right_scripts_cookbook = RightScriptsCookbook.new(@thread_name)
      @scripts                = bundle.executables.select { |e| e.is_a?(RightScriptInstantiation) }
      recipes                 = bundle.executables.map { |e| e.is_a?(RecipeInstantiation) ? e : @right_scripts_cookbook.recipe_from_right_script(e) }
      @cookbooks              = bundle.cookbooks
      @downloader             = Downloader.new
      @download_path          = File.join(AgentConfig.cookbook_download_dir, @thread_name)
      @powershell_providers   = nil
      @ohai_retry_delay       = OHAI_RETRY_MIN_DELAY
      @audit                  = AuditStub.instance
      @logger                 = Log
      @repose_class           = ReposeDownloader.select_repose_class
      @cookbook_repo_retriever= CookbookRepoRetriever.new(CookState.cookbooks_path,
                                                          @download_path,
                                                          bundle.dev_cookbooks)

      #Lookup
      @repose_class.discover_repose_servers(bundle.repose_servers)

      # Initializes run list for this sequence (partial converge support)
      @run_list  = []
      @inputs    = { }
      breakpoint = CookState.breakpoint
      recipes.each do |recipe|
        if recipe.nickname == breakpoint
          @audit.append_info("Breakpoint set, running recipes up to < #{breakpoint} >")
          break
        end
        @run_list << recipe.nickname
        ChefState.deep_merge!(@inputs, recipe.attributes)
      end

      # Retrieve node attributes and deep merge in inputs
      @attributes = ChefState.attributes
      ChefState.deep_merge!(@attributes, @inputs)
    end

    # Run given executable bundle
    # Asynchronous, set deferrable object's disposition
    #
    # === Return
    # true:: Always return true
    def run
      @ok = true
      if @run_list.empty?
        # Deliberately avoid auditing anything since we did not run any recipes
        # Still download the cookbooks repos if in dev mode
        checkout_repos
        download_repos if CookState.cookbooks_path
        report_success(nil)
      else
        configure_ohai
        configure_logging
        configure_chef
        download_attachments if @ok
        install_packages if @ok
        checkout_repos if @ok
        download_repos if @ok
        update_cookbook_path if @ok
        setup_powershell_providers if RightScale::Platform.windows?
        check_ohai { |o| converge(o) } if @ok
      end
      true
    rescue Exception => e
      report_failure('Sequence Execution failed', "The following execption occured prior to starting the Chef Process: (#{e.message}) from\n#{e.backtrace.join("\n")}")
    end

    protected

    def configure_ohai
      # Ohai plugins path and logging.
      #
      # note that this was moved to a separate .rb file to ensure that plugins
      # path is not relative to this potentially relocatable source file.
      RightScale::OhaiSetup.configure_ohai
    end

    # Initialize and configure the logger
    def configure_logging
      Chef::Log.logger       = AuditLogger.new
      Chef::Log.logger.level = Log.level_from_sym(Log.level)
    end

    # Configure chef so it can find cookbooks and so its logs go to the audits
    #
    # === Return
    # true:: Always return true
    def configure_chef
      Chef::Config[:custom_exec_exception] = Proc.new { |params|
        failure_reason       = ::RightScale::SubprocessFormatting.reason(params[:status])
        expected_error_codes = Array(params[:args][:returns]).join(' or ')
        ::RightScale::Exceptions::Exec.new("\"#{params[:args][:command]}\" #{failure_reason}, expected #{expected_error_codes}.",
                                           params[:args][:cwd])
      }

      # Chef paths and run mode
      if CookState.use_cookbooks_path?
        Chef::Config[:cookbook_path] = [CookState.cookbooks_path].flatten
        @audit.append_info("Using development cookbooks repositories path:\n\t- #{Chef::Config[:cookbook_path].join("\n\t- ")}")
      end
      Chef::Config[:cookbook_path] << @right_scripts_cookbook.repo_dir unless @right_scripts_cookbook.empty?

      Chef::Config[:solo]                 = true

      # must set file cache path and ensure it exists otherwise evented run_command will fail
      file_cache_path                     = File.join(AgentConfig.cache_dir, 'chef')
      Chef::Config[:file_cache_path]      = file_cache_path
      Chef::Config[:cache_options][:path] = File.join(file_cache_path, 'checksums')
      FileUtils.mkdir_p(Chef::Config[:file_cache_path])
      FileUtils.mkdir_p(Chef::Config[:cache_options][:path])

      # Where backups of chef-managed files should go.  Set to nil to backup to the same directory the file being backed up is in.
      Chef::Config[:file_backup_path] = nil

      true
    end

    # Download attachments, update @ok
    #
    # === Return
    # true:: Always return true
    def download_attachments
      unless @scripts.all? { |s| s.attachments.empty? }
        @audit.create_new_section('Downloading attachments')
        audit_time do
          @scripts.each do |script|
            attach_dir = @right_scripts_cookbook.cache_dir(script)
            script.attachments.each do |a|
              script_file_path = File.join(attach_dir, a.file_name)
              unless a.token.nil?
                @audit.update_status("Downloading #{a.file_name} into #{script_file_path} through Repose")

                begin
                  download_using_repose(a, script_file_path)
                  next
                rescue AttachmentDownloadFailure => e
                  @audit.append_info("Repose download failed: #{e.message}; " +
                                         "falling back to direct download")
                end
              end

              @audit.update_status("Downloading #{a.file_name} into #{script_file_path} directly")
              if @downloader.download(a.url, script_file_path)
                @audit.append_info(@downloader.details)
              else
                report_failure("Failed to download attachment '#{a.file_name}'", @downloader.error)
                return true
              end
            end
          end
        end
      end
      true
    end

    # Download the given attachment using Repose.  Will throw
    # exceptions in case of failure.
    #
    # === Parameters
    # attachment(RightScale::Attachment):: attachment to download
    # script_file_path(String):: destination pathname
    #
    # === Raise
    # AttachmentDownloadFailure:: if some permanent failure occurred downloading the attachment
    # ReposeDownloader::ReposeServerFailure:: if no Repose server could be contacted
    # SystemCallError:: if the file cannot be created
    #
    # === Return
    # always true
    def download_using_repose(attachment, script_file_path)
      begin
        attachment_dir = File.dirname(script_file_path)
        FileUtils.mkdir_p(attachment_dir)
        dl = nil
        if attachment.digest
          dl = @repose_class.new('attachments/1', attachment.digest, attachment.token,
                                 attachment.file_name, AttachmentDownloadFailure, @logger)
        else
          dl = @repose_class.new('attachments', attachment.to_hash, attachment.token,
                                 attachment.file_name, AttachmentDownloadFailure, @logger)
        end
        tempfile = Tempfile.open('attachment', attachment_dir)
        tempfile.binmode
        dl.request do |response|
          response.read_body do |chunk|
            tempfile << chunk
          end
        end
        File.unlink(script_file_path) if File.exists?(script_file_path)
        File.link(tempfile.path, script_file_path)
        tempfile.close!
        return true
      rescue Exception => e
        tempfile.close! unless tempfile.nil?
        raise e
      end
    end

    # Install required software packages, update @ok
    # Always update the apt cache even if there is no package for recipes
    #
    # === Return
    # true:: Always return true
    def install_packages
      packages = []
      @scripts.each { |s| packages.push(s.packages) if s.packages && !s.packages.empty? }
      return true if packages.empty?
      packages = packages.uniq.join(' ')
      @audit.create_new_section("Installing packages: #{packages}")
      success = false
      audit_time do
        success = retry_execution('Installation of packages failed, retrying...') do
          if File.executable? '/usr/bin/yum'
            @audit.append_output(`yum install -y #{packages} 2>&1`)
          elsif File.executable? '/usr/bin/apt-get'
            ENV['DEBIAN_FRONTEND']="noninteractive"
            @audit.append_output(`apt-get install -y #{packages} 2>&1`)
          elsif File.executable? '/usr/bin/zypper'
            @audit.append_output(`zypper --no-gpg-checks -n #{packages} 2>&1`)
          else
            report_failure('Failed to install packages', 'Cannot find yum nor apt-get nor zypper binary in /usr/bin')
            return true # Not much more we can do here
          end
          $?.success?
        end
      end
      report_failure('Failed to install packages', 'Package install exited with bad status') unless success
      true
    end

    # Update the Chef cookbook_path based on the cookbooks in the bundle.
    # Note: Starting with Chef 0.8, the cookbooks repositories list must be traversed in reverse
    # order to preserve the semantic of the dashboard (first repo has priority)
    # Revisit when upgrading to >= 0.9
    #
    # === Return
    # true:: Always return true
    def update_cookbook_path
      @cookbooks.each do |cookbook_sequence|
        local_basedir = File.join(@download_path, cookbook_sequence.hash)
        cookbook_sequence.paths.reverse.each { |path|
          dir = File.expand_path(File.join(local_basedir, path))
          unless Chef::Config[:cookbook_path].include?(dir)
            if File.directory?(dir)
              Chef::Config[:cookbook_path] << dir
            else
              RightScale::Log.info("Excluding #{path} from chef cookbooks_path because it was not downloaded")
            end
          end
        }
      end
      RightScale::Log.info("Updated cookbook_path to: #{Chef::Config[:cookbook_path].join(", ")}")
      true
    end

    # Checkout repositories for selected cookbooks.  Audit progress and errors, do not fail on checkout error.
    #
    # === Return
    # true:: Always return true
    def checkout_repos
      @audit.create_new_section('Checking out cookbooks for development') if @cookbook_repo_retriever.has_cookbooks?
      audit_time do
        # only create a scraper if there are dev cookbooks
        @cookbook_repo_retriever.checkout_cookbook_repos do |state, operation, explanation, exception|
          # audit progress
          case state
            when :begin, :commit
              @audit.append_info("#{state} #{operation} #{explanation}")
            when :abort
              @audit.append_info("Failed #{operation} #{explanation}")
              Log.info(Log.format("Failed #{operation} #{explanation}", exception, :trace))
          end
        end
      end
    end

    # Download required cookbooks from Repose mirror; update @ok.
    # Note: Starting with Chef 0.8, the cookbooks repositories list must be traversed in reverse
    # order to preserve the semantic of the dashboard (first repo has priority)
    #
    # === Return
    # true:: Always return true
    def download_repos
      @audit.create_new_section('Retrieving cookbooks') unless @cookbooks.empty?
      audit_time do
        # first, if @download_path is world writable, stop that nonsense right this second.
        unless RightScale::Platform.windows?
          if File.exists?(@download_path) && File.world_writable?(@download_path)
            Log.warning("Cookbooks download path world writable; fixing.")
            File.chmod(0755, @download_path)
          end
        end

        unless CookState.download_once?
          @audit.append_info("Deleting existing cookbooks")
          # second, wipe out any preexisting cookbooks in the download path
          if File.directory?(@download_path)
            Dir.foreach(@download_path) do |entry|
              FileUtils.remove_entry_secure(File.join(@download_path, entry)) if entry =~ /\A[[:xdigit:]]+\Z/
            end
          end
        end

        @cookbooks.each do |cookbook_sequence|
          cookbook_sequence.positions.each do |position|
            if @cookbook_repo_retriever.should_be_linked?(cookbook_sequence.hash, position.position)
              begin
                @cookbook_repo_retriever.link(cookbook_sequence.hash, position.position)
              rescue Exception => e
                ::RightScale::Log.error("Failed to link #{position.cookbook.name} for development", e)
              end
            else
              # download with repose
              cookbook_path = CookbookPathMapping.repose_path(@download_path, cookbook_sequence.hash, position.position)
              if File.exists?(cookbook_path)
                @audit.append_info("Skipping #{position.cookbook.name}, already there")
              else
                prepare_cookbook(cookbook_path, position.cookbook)
              end
            end
          end
        end
      end

      # record that cookbooks have been downloaded so we do not download them again in Dev mode
      CookState.has_downloaded_cookbooks = true

      true
    rescue Exception => e
      report_failure("Failed to download cookbook", "Cannot continue due to #{e.class.name}: #{e.message}.")
      Log.debug(Log.format("Failed to download cookbook", e, :trace))
    ensure
      OpenSSL::SSL::SSLSocket.hostname_override = nil
    end

    #
    # Download a cookbook from the mirror and extract it to the filesystem.
    #
    # === Parameters
    # root_dir(String):: subdir of basedir into which this cookbook goes
    # cookbook(Cookbook):: cookbook
    #
    # === Raise
    # Propagates exceptions raised by callees, namely CookbookDownloadFailure
    # and ReposeServerFailure
    #
    # === Return
    # true:: always returns true
    def prepare_cookbook(root_dir, cookbook)
      @audit.append_info("Requesting #{cookbook.name}")
      tarball = Tempfile.new("tarball")
      tarball.binmode
      result = request_cookbook(cookbook) do |response|
        response.read_body do |chunk|
          tarball << chunk
        end
      end
      tarball.close

      @audit.append_info("Success; unarchiving cookbook")

      # The local basedir is the faux "repository root" into which we extract all related
      # cookbooks in that set, "related" meaning a set of cookbooks that originally came
      # from the same Chef cookbooks repository as observed by the scraper.
      #
      # Even though we are pulling individually-packaged cookbooks and not the whole repository,
      # we preserve the position of cookbooks in the directory hierarchy such that a given cookbook
      # has the same path relative to the local basedir as the original cookbook had relative to the
      # base directory of its repository.
      #
      # This ensures we will be able to deal with future changes to the Chef merge algorithm,
      # as well as accommodate "naughty" cookbooks that side-load data from the filesystem
      # using relative paths to other cookbooks.
      FileUtils.mkdir_p(root_dir)

      Dir.chdir(root_dir) do
        output, status = ProcessWatcher.run('tar', 'xf', tarball.path)
        unless status.success?
          report_failure("Unknown error: #{SubprocessFormatting.reason(status)}")
          return
        else
          @audit.append_info(output)
        end
      end
      tarball.close(true)
      return true
    end

    # Request a cookbook from the Repose mirror, performing retry as necessary. Block
    # until the cookbook has been downloaded, or until permanent failure has been
    # determined.
    #
    # === Parameters
    # cookbook(RightScale::Cookbook):: the cookbook to download
    #
    # === Block
    # If the request succeeds this method will yield, passing
    # the HTTP response object as its sole argument.
    #
    # === Raise
    # CookbookDownloadFailure:: if a permanent failure happened
    # ReposeServerFailure:: if no Repose server could be contacted
    #
    # === Return
    # true:: always returns true
    def request_cookbook(cookbook, &block)
      @repose_class.new('cookbooks', cookbook.hash, cookbook.token,
                        cookbook.name, CookbookDownloadFailure, @logger).request(&block)
    end

    # Create Powershell providers from cookbook repos
    #
    #
    # === Return
    # true:: Always return true
    def setup_powershell_providers
      dynamic_provider = DynamicPowershellProvider.new
      dynamic_provider.generate_providers(Chef::Config[:cookbook_path])
      @powershell_providers = dynamic_provider.providers
    end

    # Checks whether Ohai is ready and calls given block with it
    # if that's the case otherwise schedules itself to try again
    # indefinitely
    #
    # === Block
    # Given block should take one argument which corresponds to
    # ohai instance
    #
    # === Return
    # true:: Always return true
    def check_ohai(&block)
      ohai = create_ohai
      if ohai[:hostname]
        block.call(ohai)
      else
        Log.warning("Could not determine node name from Ohai, will retry in #{@ohai_retry_delay}s...")
        # Need to execute on defer thread consistent with where ExecutableSequence is running
        # otherwise EM main thread command client activity will block
        EM.add_timer(@ohai_retry_delay) { EM.defer { check_ohai(&block) } }
        @ohai_retry_delay = [2 * @ohai_retry_delay, OHAI_RETRY_MAX_DELAY].min
      end
      true
    end

    # Creates a new ohai and configures it.
    #
    # === Return
    # ohai(Ohai::System):: configured ohai
    def create_ohai
      ohai = Ohai::System.new
      ohai.require_plugin('os')
      ohai.require_plugin('hostname')
      return ohai
    end

    # Chef converge
    #
    # === Parameters
    # ohai(Ohai):: Ohai instance to be used by Chef
    #
    # === Return
    # true:: Always return true
    def converge(ohai)
      begin
        # suppress unnecessary error log output for cases of explictly exiting
        # from converge (rs_shutdown, etc.).
        ::Chef::Client.clear_notifications

        @audit.create_new_section('Converging')
        @audit.append_info("Run list for #{@thread_name.inspect} thread: #{@run_list.join(', ')}")
        attribs = { 'run_list' => @run_list }
        attribs.merge!(@attributes) if @attributes
        c      = Chef::Client.new(attribs)
        c.ohai = ohai
        audit_time do
          # Ensure that Ruby subprocesses invoked by Chef do not inherit our
          # RubyGems/Bundler environment.
          without_bundler_env do
            c.run
          end
        end
      rescue SystemExit => e
        # exit is expected in case where a script has invoked rs_shutdown
        # (command line tool or Chef resource). exit is considered to be
        # unexpected if rs_shutdown has not been called. note that it is
        # possible, but not a 'best practice', for a recipe (but not a
        # RightScript) to call rs_shutdown as an external command line utility
        # without calling exit (i.e. request a deferred reboot) and continue
        # running recipes until the list of recipes is complete. in this case,
        # the shutdown occurs after subsequent recipes have finished. the best
        # practice for a recipe is to use the rs_shutdown chef resource which
        # calls exit when appropriate.
        shutdown_request = RightScale::ShutdownRequestProxy.instance
        if shutdown_request.continue?
          report_failure('Chef converge failed due to rs_shutdown not being called before exit', chef_error(e))
          Log.debug(Log.format("Chef converge failed", e, :trace))
        else
          Log.info("Shutdown requested by script: #{shutdown_request}")
        end
      rescue Exception => e
        report_failure('Chef converge failed', chef_error(e))
        Log.debug(Log.format("Chef converge failed", e, :trace))
      ensure
        # terminate the powershell providers
        # terminate the providers before the node server as the provider term scripts may still use the node server
        if @powershell_providers
          @powershell_providers.each do |p|
            begin
              p.terminate
            rescue Exception => e
              Log.debug(Log.format("Error terminating #{p.inspect}", e, :trace))
            end
          end
        end

        # kill the chef node provider
        RightScale::Windows::ChefNodeServer.instance.stop rescue nil if RightScale::Platform.windows?
      end
      report_success(c.node) if @ok
      true
    end

    # Initialize inputs patch and report success
    #
    # === Parameters
    # node(ChefNode):: Chef node used to converge, can be nil (patch is empty in this case)
    #
    # === Return
    # true:: Always return true
    def report_success(node)
      ChefState.merge_attributes(node.normal_attrs) if node
      patch              = ChefState.create_patch(@inputs, ChefState.attributes)
      # We don't want to send back new attributes (ohai etc.)
      patch[:right_only] = { }
      @inputs_patch      = patch
      EM.next_tick { succeed }
      true
    end

    # Set status with failure message and audit it
    #
    # === Parameters
    # title(String):: Title used to update audit status
    # msg(String):: Failure message
    #
    # === Return
    # true:: Always return true
    def report_failure(title, msg)
      @ok              = false
      @failure_title   = title
      @failure_message = msg
      # note that the errback handler is expected to audit the message based on
      # the preserved title and message and so we don't audit it here.
      EM.next_tick { fail }
      true
    end

    # Wrap chef exception with explanatory information and show
    # context of failure
    #
    # === Parameters
    # e(Exception):: Exception raised while executing Chef recipe
    #
    # === Return
    # msg(String):: Human friendly error message
    def chef_error(e)
      if e.is_a?(::RightScale::Exceptions::Exec)
        msg = "An external command returned an error during the execution of Chef:\n\n"
        msg += e.message
        msg += "\n\nThe command was run from \"#{e.path}\"" if e.path
      elsif e.is_a?(::Chef::Exceptions::ValidationFailed) && (e.message =~ /Option action must be equal to one of:/)
        msg = "[chef] recipe references an action that does not exist.  #{e.message}"
      elsif e.is_a?(::NoMethodError) && (missing_action_match = /undefined method .action_(\S*)' for #<\S*:\S*>/.match(e.message)) && missing_action_match[1]
        msg = "[chef] recipe references the action <#{missing_action_match[1]}> which is missing an implementation"
      else
        msg              = "An error occurred during the execution of Chef. The error message was:\n\n"
        msg              += e.message
        file, line, meth = e.backtrace[0].scan(/(.*):(\d+):in `(\w+)'/).flatten
        line_number      = line.to_i
        if file && line && (line_number.to_s == line)
          dir = AgentConfig.cookbook_download_dir
          if file[0..dir.size - 1] == dir
            path = "[COOKBOOKS]/" + file[dir.size..file.size]
          else
            path = file
          end
          msg += "\n\nThe error occurred line #{line} of #{path}"
          msg += " in method '#{meth}'" if meth
          context = ""
          if File.readable?(file)
            File.open(file, 'r') do |f|
              lines       = f.readlines
              lines_count = lines.size
              if lines_count >= line_number
                upper   = [lines_count, line_number + 2].max
                padding = upper.to_s.size
                context += context_line(lines, line_number - 2, padding)
                context += context_line(lines, line_number - 1, padding)
                context += context_line(lines, line_number, padding, '*')
                context += context_line(lines, line_number + 1, padding)
                context += context_line(lines, line_number + 2, padding)
              end
            end
          end
          msg += " while executing:\n\n#{context}" unless context.empty?
        end
      end
      msg
    end

    # Format a single line for the error context, return empty string
    # if given index is negative or greater than the lines array size
    #
    # === Parameters
    # lines(Array):: Lines of text
    # index(Integer):: Index of line that should be formatted for context
    # padding(Integer):: Number of character to pad line with (includes prefix)
    # prefix(String):: Single character string used to prefix line
    #                  use line number if not specified
    def context_line(lines, index, padding, prefix=nil)
      return '' if index < 1 || index > lines.size
      margin = prefix ? prefix * index.to_s.size : index.to_s
      "#{margin}#{' ' * ([padding - margin.size, 0].max)} #{lines[index - 1]}"
    end

    # Retry executing given block given number of times
    # Block should return true when it succeeds
    #
    # === Parameters
    # retry_message(String):: Message to audit before retrying
    # times(Integer):: Number of times block should be retried before giving up
    #
    # === Block
    # Block to be executed
    #
    # === Return
    # success(Boolean):: true if execution was successful, false otherwise.
    def retry_execution(retry_message, times = AgentConfig.max_packages_install_retries)
      count   = 0
      success = false
      begin
        count   += 1
        success = yield
        @audit.append_info("\n#{retry_message}\n") unless success || count > times
      end while !success && count <= times
      success
    end

    # Audit startup time and duration of given action
    #
    # === Block
    # Block whose execution should be timed
    #
    # === Return
    # res(Object):: Result returned by given block
    def audit_time
      start_time = Time.now
      @audit.append_info("Starting at #{start_time}")
      res = yield
      @audit.append_info("Duration: #{'%.2f' % (Time.now - start_time)} seconds\n\n")
      res
    end

    def without_bundler_env
      original_env = ENV.to_hash
      ENV.delete_if {|k,v| k =~ /^GEM_|^BUNDLE_/}
      if ENV.key?('RUBYOPT')
        ENV['RUBYOPT'] = ENV['RUBYOPT'].split(" ").select {|word| word !~ /bundler/}.join(" ")
      end
      yield
    ensure
      ENV.replace(original_env.to_hash)
    end
  end
end
