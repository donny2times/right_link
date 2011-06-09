#
# Copyright (c) 2011 RightScale Inc
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

require File.join(File.dirname(__FILE__), 'spec_helper')

module RightScale

  class MetadataFormatterSpec

    METADATA = {'ABC' => ['easy', 123], :simple => "do re mi", 'abc_123' => {'baby' => [:you, :me, :girl] }}
    PREFIXED_METADATA = {'ABC' => ['easy', 123], :Ec2_simple => "do re mi", 'rs_abc_123' => {'baby' => [:you, :me, :girl] }}

  end

end

describe RightScale::MetadataFormatter do

  it 'should format metadata using the default prefix' do
    formatter = ::RightScale::MetadataFormatter.new
    result = formatter.format_metadata(::RightScale::MetadataFormatterSpec::METADATA)
    result.should == {"RS_ABC"=>["easy", 123], "RS_SIMPLE"=>"do re mi", "RS_ABC_123_BABY"=>[:you, :me, :girl]}
  end

  it 'should format metadata using a custom prefix and preserve both custom and default prefix' do
    formatter = ::RightScale::MetadataFormatter.new(:formatted_path_prefix => "EC2_")
    result = formatter.format_metadata(::RightScale::MetadataFormatterSpec::PREFIXED_METADATA)
    result.should == {"EC2_ABC"=>["easy", 123], "EC2_SIMPLE"=>"do re mi", "RS_ABC_123_BABY"=>[:you, :me, :girl]}
  end

  it 'should support override of format_metadata' do
    overridden_formatter = ::RightScale::MetadataFormatter.new(
      :format_metadata_override => lambda do |formatter, metadata|
        formatter.should == overridden_formatter
        metadata.invert
      end
    )
    result = overridden_formatter.format_metadata(::RightScale::MetadataFormatterSpec::METADATA)
    result.should == {"do re mi"=>:simple, {"baby"=>[:you, :me, :girl]}=>"abc_123", ["easy", 123]=>"ABC"}
  end

end
