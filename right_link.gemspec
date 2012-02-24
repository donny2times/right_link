# -*- mode: ruby; encoding: utf-8 -*-

Gem::Specification.new do |s|
  s.name        = "right_link"
  s.version     = '0.3'
  s.platform    = Gem::Platform::RUBY
  
  s.authors     = ['RightScale']
  s.email       = 'support@rightscale.com'
  s.homepage    = 'https://github.com/rightscale/right_link'
  s.summary     = %q{Reusable foundation code.}
  s.description = %q{A toolkit of useful, reusable foundation code created by RightScale.}
  
  s.required_rubygems_version = ">= 1.8.7"
  
  s.files = Dir.glob('Gemfile') +
            Dir.glob('Gemfile.lock') +
            Dir.glob('init/*') +
            Dir.glob('actors/*.rb') +
            Dir.glob('bin/*.rb') +
            Dir.glob('bin/*.sh') +
            Dir.glob('lib/**/*.rb') +
            Dir.glob('lib/chef/**/*.rb') +
            Dir.glob('lib/clouds/**/*.rb') +
            Dir.glob('lib/repo_conf_generators/**/*.rb') +
            Dir.glob('scripts/*') +
            Dir.glob('lib/instance/cook/*.crt')
end