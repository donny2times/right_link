#
# Copyright (c) 2009 RightScale Inc
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

module RightScale

  # Commands exposed by instance agent
  # To add a new command, simply add it to the COMMANDS hash and define its implementation in
  # a method called '<command name>_command'
  class InstanceCommands

    # List of command names associated with description
    # The commands should be implemented in methods in this class named '<name>_command'
    # where <name> is the name of the command.
    COMMANDS = {
      :list                     => 'List all available commands with their description',
      :run_recipe               => 'Run recipe with id given in options[:id] and optionally JSON given in options[:json]',
      :run_right_script         => 'Run RightScript with id given in options[:id] and arguments given in hash options[:arguments] (e.g. { \'application\' => \'text:Mephisto\' })',
      :send_request             => 'Send request to remote agent',
      :send_push                => 'Send push to remote agent',
      :set_log_level            => 'Set log level to options[:level]',
      :get_log_level            => 'Get log level',
      :decommission             => 'Run instance decommission bundle synchronously',
      :terminate                => 'Terminate agent',
      :get_tags                 => 'Retrieve instance tags',
      :add_tag                  => 'Add given tag',
      :remove_tag               => 'Remove given tag',
      :audit_update_status      => 'Update last audit title',
      :audit_create_new_section => 'Create new audit section',
      :audit_append_output      => 'Append process output to audit',
      :audit_append_info        => 'Append info message to audit',
      :audit_append_error       => 'Append error message to audit',
      :set_inputs_patch         => 'Set inputs patch post execution',
      :close_connection         => 'Close persistent connection (used for auditing)'
    }

    # Build hash of commands associating command names with block
    #
    # === Parameters
    # agent_identity(String):: Serialized instance agent identity
    # scheduler(InstanceScheduler):: Scheduler used by decommission command
    #
    # === Return
    # cmds(Hash):: Hash of command blocks keyed by command names
    def self.get(agent_identity, scheduler)
      cmds = {}
      target = new(agent_identity, scheduler)
      COMMANDS.each { |k, _| cmds[k] = lambda { |opts, conn| opts[:conn] = conn; target.send("#{k.to_s}_command", opts) } }
      cmds
    end

    # Set token id used to send core requests
    #
    # === Parameter
    # agent_identity(String):: Serialized instance agent identity
    # scheduler(InstanceScheduler):: Scheduler used by decommission command
    def initialize(agent_identity, scheduler)
      @agent_identity = agent_identity
      @scheduler = scheduler
    end

    protected

    # List command implementation
    #
    # === Parameters
    # opts[:conn](EM::Connection):: Connection used to send reply
    #
    # === Return
    # true:: Always return true
    def list_command(opts)
      usage = "Agent exposes the following commands:\n"
      COMMANDS.reject { |k, _| k == :list || k.to_s =~ /test/ }.each do |c|
        c.each { |k, v| usage += " - #{k.to_s}: #{v}\n" }
      end
      CommandIO.instance.reply(opts[:conn], usage)
    end

    # Run recipe command implementation
    #
    # === Parameters
    # opts[:conn](EM::Connection):: Connection used to send reply
    # opts[:options](Hash):: Pass-through options sent to forwarder
    #
    # === Return
    # true:: Always return true
    def run_recipe_command(opts)
      if opts[:target_id] || opts[:target_tags]
        # Use target to route in send_push
        send_push('/instance_scheduler/execute', opts[:conn], opts[:options])
      else
        send_request('/forwarder/schedule_recipe', opts[:conn], opts[:options])
      end
    end

    # Run RightScript command implementation
    #
    # === Parameters
    # opts[:conn](EM::Connection):: Connection used to send reply
    # opts[:options](Hash):: Pass-through options sent to forwarder
    #
    # === Return
    # true:: Always return true
    def run_right_script_command(opts)
      if opts[:target_id] || opts[:target_tags]
        # Use target to route in send_push
        send_push('/instance_scheduler/execute', opts[:conn], opts[:options])
      else
        send_request('/forwarder/schedule_right_script', opts[:conn], opts[:options])
      end
    end

    # Send request to remote agent
    #
    # === Parameters
    # opts[:conn](EM::Connection):: Connection used to send reply
    # opts[:type](String):: Request type
    # opts[:payload](String):: Request payload
    # opts[:options](Hash):: Request options
    #
    # === Return
    # true:: Always return true
    def send_request_command(opts)
      send_request(opts[:type], opts[:conn], opts[:payload], opts[:options])
    end

    # Send push to remote agent
    #
    # === Parameters
    # opts[:conn](EM::Connection):: Connection used to send reply
    # opts[:type](String):: Request type
    # opts[:payload](String):: Request payload
    # opts[:options](Hash):: Request options
    #
    # === Return
    # true:: Always return true
    def send_push_command(opts)
      opts[:agent_identity] = @agent_identity
      RequestForwarder.instance.push(opts[:type], opts[:payload], opts[:options])
      CommandIO.instance.reply(opts[:conn], 'OK')
      true
    end
    
    # Set log level command
    #
    # === Parameters
    # opts[:conn](EM::Connection):: Connection used to send reply
    # opts[:level](Symbol):: One of :debug, :info, :warn, :error or :fatal
    #
    # === Return
    # true:: Always return true
    def set_log_level_command(opts)
      RightLinkLog.level = opts[:level] if [ :debug, :info, :warn, :error, :fatal ].include?(opts[:level])
      CommandIO.instance.reply(opts[:conn], RightLinkLog.level)
    end

    # Get log level command
    #
    # === Parameters
    # opts[:conn](EM::Connection):: Connection used to send reply
    #
    # === Return
    # true:: Always return true
    def get_log_level_command(opts)
      CommandIO.instance.reply(opts[:conn], RightLinkLog.level)
    end

    # Decommission command
    #
    # === Parameters
    # opts[:conn](EM::Connection):: Connection used to send reply
    #
    # === Return
    # true
    def decommission_command(opts)
      @scheduler.run_decommission { CommandIO.instance.reply(opts[:conn], 'Decommissioned') }
    end

    # Terminate command
    #
    # === Parameters
    # opts[:conn](EM::Connection):: Connection used to send reply
    #
    # === Return
    # true
    def terminate_command(opts)
      CommandIO.instance.reply(opts[:conn], 'Terminating')
      @scheduler.terminate
    end

    # Get tags command
    #
    # === Parameters
    # opts[:conn](EM::Connection):: Connection used to send reply
    #
    # === Return
    # true
    def get_tags_command(opts)
      AgentTagsManager.instance.tags { |t| CommandIO.instance.reply(opts[:conn], t) }
    end

    # Add given tag
    #
    # === Parameters
    # opts[:conn](EM::Connection):: Connection used to send reply
    # opts[:tag](String):: Tag to be added
    #
    # === Return
    # true
    def add_tag_command(opts)
      AgentTagsManager.instance.add_tags(opts[:tag])
      CommandIO.instance.reply(opts[:conn], "Request to add tag '#{opts[:tag]}' sent successfully.")
    end

    # Remove given tag
    #
    # === Parameters
    # opts[:conn](EM::Connection):: Connection used to send reply
    # opts[:tag](String):: Tag to be removed
    #
    # === Return
    # true
    def remove_tag_command(opts)
      AgentTagsManager.instance.remove_tags(opts[:tag])
      CommandIO.instance.reply(opts[:conn], "Request to remove tag '#{opts[:tag]}' sent successfully.")
    end

    def query_tags_command(opts)
      send_request('/mapper/query_tags', opts[:conn], opts[:query]) do |r|
        # ....
        CommandIO.instance.reply(opts[:conn], '...')
      end
    end

    # Update audit summary
    #
    # === Parameters
    # opts[:conn](EM::Connection):: Connection used to send reply
    # opts[:title](Hash):: Chef attributes hash
    #
    # === Return
    # true:: Always return true
    def audit_update_status_command(opts)
      AuditCookStub.instance.forward_audit(:update_status, opts[:content], opts[:options])
      CommandIO.instance.reply(opts[:conn], 'OK', close_after_writing=false)
    end

    # Update audit summary
    #
    # === Parameters
    # opts[:conn](EM::Connection):: Connection used to send reply
    # opts[:title](Hash):: Chef attributes hash
    #
    # === Return
    # true:: Always return true
    def audit_create_new_section_command(opts)
      AuditCookStub.instance.forward_audit(:create_new_section, opts[:content], opts[:options])
      CommandIO.instance.reply(opts[:conn], 'OK', close_after_writing=false)
    end

    # Update audit summary
    #
    # === Parameters
    # opts[:conn](EM::Connection):: Connection used to send reply
    # opts[:title](Hash):: Chef attributes hash
    #
    # === Return
    # true:: Always return true
    def audit_append_output_command(opts)
      AuditCookStub.instance.forward_audit(:append_output, opts[:content], opts[:options])
      CommandIO.instance.reply(opts[:conn], 'OK', close_after_writing=false)
    end

    # Update audit summary
    #
    # === Parameters
    # opts[:conn](EM::Connection):: Connection used to send reply
    # opts[:title](Hash):: Chef attributes hash
    #
    # === Return
    # true:: Always return true
    def audit_append_info_command(opts)
      AuditCookStub.instance.forward_audit(:append_info, opts[:content], opts[:options])
      CommandIO.instance.reply(opts[:conn], 'OK', close_after_writing=false)
    end

    # Update audit summary
    #
    # === Parameters
    # opts[:conn](EM::Connection):: Connection used to send reply
    # opts[:title](Hash):: Chef attributes hash
    #
    # === Return
    # true:: Always return true
    def audit_append_error_command(opts)
      AuditCookStub.instance.forward_audit(:append_error, opts[:content], opts[:options])
      CommandIO.instance.reply(opts[:conn], 'OK', close_after_writing=false)
    end

    # Update inputs patch to be sent back to core after cook process finishes
    #
    # === Parameters
    # opts[:conn](EM::Connection):: Connection used to send reply
    # opts[:patch](Hash):: Patch to be forwarded to core
    #
    # === Return
    # true:: Always return true
    def set_inputs_patch_command(opts)
      RightScale::RequestForwarder.instance.push('/updater/update_inputs', { :agent_identity => @agent_identity,
                                                                             :patch          => opts[:patch] })
      CommandIO.instance.reply(opts[:conn], 'OK')
    end

    # Close connection
    def close_connection_command(opts)
      CommandIO.instance.reply(opts[:conn], 'OK')
    end

    # Helper method that sends given request and report status through command IO
    #
    # === Parameters
    # request(String):: Request that should be sent
    # conn(EM::Connection):: Connection used to send reply
    # options(Hash):: Request options
    #
    # === Return
    # true:: Always return true
    def send_request(request, conn, payload, options={})
      payload[:agent_identity] = @agent_identity
      RequestForwarder.instance.request(request, payload, options) do |r|
        reply = JSON.dump(r) rescue '\"Failed to serialize response\"'
        CommandIO.instance.reply(conn, reply)
      end
      true
    end

    def send_push('....')
      #...
    end

  end

end
