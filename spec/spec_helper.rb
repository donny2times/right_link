require 'rubygems'

# Nanite uses the JSON gem, which -- if used in a project that also uses ActiveRecord -- MUST be loaded after
# ActiveRecord in order to ensure that a monkey patch is correctly applied. Since Nanite is designed to be compatible
# with Rails, we tentatively try to load AR here, in case RightLink specs are ever executed in a context where
# ActiveRecord is also loaded.
require 'active_record' rescue nil

require 'flexmock'
require 'spec'
require 'eventmachine'
require 'fileutils'

require File.expand_path(File.join(File.dirname(__FILE__), '..', 'lib', 'nanite', 'lib', 'nanite'))
require File.expand_path(File.join(File.dirname(__FILE__), '..', 'lib', 'chef', 'lib', 'providers'))
require File.expand_path(File.join(File.dirname(__FILE__), '..', 'lib', 'payload_types', 'lib', 'payload_types'))
require File.expand_path(File.join(File.dirname(__FILE__), '..', 'config', 'right_link_config'))
require File.join(File.dirname(__FILE__), 'nanite_results_mock')

$:.push File.join(File.dirname( __FILE__), '..', 'actors', 'lib')
$:.push File.join(File.dirname( __FILE__), '..', 'agents', 'lib')
$:.push File.join(File.dirname( __FILE__), '..', 'agents', 'lib', 'common')
$:.push File.join(File.dirname( __FILE__), '..', 'agents', 'lib', 'instance')

Nanite::Log.init

config = Spec::Runner.configuration
config.mock_with :flexmock

$VERBOSE = nil # Disable constant redefined warning

module RightScale

  module SpecHelpers

    RIGHT_LINK_SPEC_HELPER_TEMP_PATH = File.expand_path(File.join(RightScale::RightLinkConfig[:platform].filesystem.temp_dir, 'right_link_spec_helper'))

    # Setup instance state for tests
    # Use different identity to reset list of past scripts
    def setup_state(identity = '1')
      cleanup_state
      RightScale::InstanceState.const_set(:STATE_FILE, state_file_path)
      RightScale::InstanceState.const_set(:SCRIPTS_FILE, past_scripts_path)
      RightScale::InstanceState.const_set(:BOOT_LOG_FILE, log_path)
      RightScale::InstanceState.const_set(:OPERATION_LOG_FILE, log_path)
      RightScale::InstanceState.const_set(:DECOMMISSION_LOG_FILE, log_path)
      RightScale::ChefState.const_set(:STATE_FILE, chef_file_path)
      @identity = identity
      @results_factory = RightScale::NaniteResultsMock.new
      mapper_proxy = flexmock('MapperProxy')
      flexmock(Nanite::MapperProxy).should_receive(:instance).and_return(mapper_proxy).by_default      
      mapper_proxy.should_receive(:request).and_yield(@results_factory.success_results)
      mapper_proxy.should_receive(:push)
      tags = flexmock('tags', :results => { :tags => { 'tags' => ['a_tag'] } })
      mapper_proxy.should_receive(:query_tags).and_yield(tags)
      RightScale::InstanceState.init(@identity)
    end

    # Cleanup files generated by instance state
    def cleanup_state
      delete_if_exists(state_file_path)
      delete_if_exists(chef_file_path)
      delete_if_exists(past_scripts_path)
      delete_if_exists(log_path)
    end

    # Path to serialized instance state
    def state_file_path
      File.join(RIGHT_LINK_SPEC_HELPER_TEMP_PATH, '__state.js')
    end

    # Path to serialized instance state
    def chef_file_path
      File.join(RIGHT_LINK_SPEC_HELPER_TEMP_PATH, '__chef.js')
    end

    # Path to saved passed scripts
    def past_scripts_path
      File.join(RIGHT_LINK_SPEC_HELPER_TEMP_PATH, '__past_scripts.js')
    end

    # Path to instance boot logs
    def log_path
      File.join(RIGHT_LINK_SPEC_HELPER_TEMP_PATH, '__nanite.log')
    end

    # Test and delete if exists
    def delete_if_exists(file)
      File.delete(file) if File.file?(file)
    end

    # Setup location of files generated by script execution
    def setup_script_execution
      Dir.glob(File.join(RIGHT_LINK_SPEC_HELPER_TEMP_PATH, '__TestScript*')).should be_empty
      Dir.glob(File.join(RIGHT_LINK_SPEC_HELPER_TEMP_PATH, '[0-9]*')).should be_empty
      RightScale::InstanceConfiguration.const_set('CACHE_PATH', File.join(RIGHT_LINK_SPEC_HELPER_TEMP_PATH, 'cache'))
    end

    # Cleanup files generated by script execution
    def cleanup_script_execution
      FileUtils.rm_rf(RightScale::InstanceConfiguration::CACHE_PATH)
    end
  end
end

require File.expand_path(File.join(__FILE__, '..', '..', 'agents', 'lib', 'common', 'right_link_log'))
module RightScale
  class RightLinkLog
    # Monkey path RightLink logger to not log by default
    # Define env var RS_LOG to override this behavior and have
    # the logger log normally
    alias :original_method_missing :method_missing
    def self.method_missing(m, *args)
      original_method_missing(m, *args) if ENV['RS_LOG']
    end
  end
end

require File.expand_path(File.join(__FILE__, '..', '..', 'agents', 'lib', 'instance', 'instance_state'))
module RightScale
  class InstanceState
    def self.update_logger
      true
    end
  end
end
