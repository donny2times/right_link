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

require File.expand_path(File.join(File.dirname(__FILE__), '..', 'spec_helper'))
require 'json/ext'

describe RightScale::Serializable do

  it 'should serialize using MessagePack' do
    fsi1 = RightScale::SoftwareRepositoryInstantiation.new
    fsi1.name = "Yum::CentOS::Base"
    fsi1.base_urls = ["http://ec2-us-east-mirror.rightscale.com/centos",
                     "http://ec2-us-east-mirror1.rightscale.com/centos",
                     "http://ec2-us-east-mirror2.rightscale.com/centos",
                     "http://ec2-us-east-mirror3.rightscale.com/centos"]

    fsi2 = RightScale::SoftwareRepositoryInstantiation.new
    fsi2.name = "Gems::RubyGems"
    fsi2.base_urls = ["http://ec2-us-east-mirror.rightscale.com/rubygems",
                     "http://ec2-us-east-mirror1.rightscale.com/rubygems",
                     "http://ec2-us-east-mirror2.rightscale.com/rubygems",
                     "http://ec2-us-east-mirror3.rightscale.com/rubygems"]

    b = RightScale::ExecutableBundle.new([fsi1, fsi2], 1234)
    fsi1.to_msgpack
    b.to_msgpack
  end

  it 'should serialize using JSON' do
    fsi1 = RightScale::SoftwareRepositoryInstantiation.new
    fsi1.name = "Yum::CentOS::Base"
    fsi1.base_urls = ["http://ec2-us-east-mirror.rightscale.com/centos",
                     "http://ec2-us-east-mirror1.rightscale.com/centos",
                     "http://ec2-us-east-mirror2.rightscale.com/centos",
                     "http://ec2-us-east-mirror3.rightscale.com/centos"]

    fsi2 = RightScale::SoftwareRepositoryInstantiation.new
    fsi2.name = "Gems::RubyGems"
    fsi2.base_urls = ["http://ec2-us-east-mirror.rightscale.com/rubygems",
                     "http://ec2-us-east-mirror1.rightscale.com/rubygems",
                     "http://ec2-us-east-mirror2.rightscale.com/rubygems",
                     "http://ec2-us-east-mirror3.rightscale.com/rubygems"]

    b = RightScale::ExecutableBundle.new([fsi1, fsi2], 1234)
    fsi1.to_json
    b.to_json
  end

end
