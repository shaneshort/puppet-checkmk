# frozen_string_literal: true

require 'spec_helper'
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
end
