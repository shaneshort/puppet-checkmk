# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'rbconfig'
require 'puppet_x/checkmk/requirements'

RSpec.describe PuppetX::Checkmk::Requirements do
  describe '.verify_resource_api!' do
    ['1.8.14', '1.8.16', '1.9.2', '2.0.0'].each do |version|
      it "accepts puppet-resource_api #{version}" do
        expect { described_class.verify_resource_api!(version) }.not_to raise_error
      end
    end

    ['1.8.13', '1.8.0', '1.5.0'].each do |version|
      it "rejects puppet-resource_api #{version} with an explanation" do
        expect { described_class.verify_resource_api!(version) }.to raise_error(
          Puppet::Error, %r{requires puppet-resource_api >= 1\.8\.14 but #{Regexp.escape(version)} is loaded.*7\.8\.0}
        )
      end
    end

    it 'accepts the puppet-resource_api that is actually loaded' do
      expect { described_class.verify_resource_api! }.not_to raise_error
    end
  end

  ['agent_package', 'create_host'].each do |type|
    it "makes the #{type} type refuse to load on an unsupported puppet-resource_api" do
      allow(described_class).to receive(:verify_resource_api!).and_raise(Puppet::Error, 'unsupported')

      expect { load File.expand_path("../../../../lib/puppet/type/#{type}.rb", __dir__) }.to raise_error(Puppet::Error, 'unsupported')
    end
  end

  # Puppet Server runs module Ruby code in JRuby and does not add a module's lib/ directory to $LOAD_PATH, so the type
  # files must locate the helper relative to themselves. (Rspec, `puppet apply` and agents all do have lib/ on the path,
  # which is how this once slipped through.) A clean Ruby process reproduces the Puppet Server condition.
  %w[agent_package create_host].each do |type|
    it "loads the #{type} type when the module's lib directory is not on $LOAD_PATH" do
      lib = File.expand_path('../../../../lib', __dir__)
      script = <<~RUBY
        require 'puppet'
        Puppet.initialize_settings
        module_lib = #{lib.inspect}
        abort "setup error: module lib is on $LOAD_PATH" if $LOAD_PATH.any? { |entry| File.expand_path(entry) == module_lib }
        load File.join(module_lib, 'puppet', 'type', #{type.inspect} + '.rb')
        puts 'TYPE LOADED'
      RUBY

      output, = Open3.capture2e(RbConfig.ruby, '-e', script)

      expect(output).to include('TYPE LOADED'), output
    end
  end
end
