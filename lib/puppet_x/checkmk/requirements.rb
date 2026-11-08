# frozen_string_literal: true

module PuppetX; end # rubocop:disable Style/Documentation
module PuppetX::Checkmk; end # rubocop:disable Style/Documentation

# Runtime requirements of the module's Resource API types.
module PuppetX::Checkmk::Requirements
  # The `custom_insync` feature used by agent_package and create_host arrived in puppet-resource_api 1.8.14.
  # (Older versions only print "Unknown feature detected" and then fail obscurely when the resource is applied.)
  # puppet-agent bundles 1.8.14 or later from 6.23.0 and from 7.8.0.
  def self.minimum_resource_api
    '1.8.14'
  end

  # Raises a clear error unless the loaded puppet-resource_api is new enough.
  # @param version [String, nil] the version to check; defaults to the loaded puppet-resource_api
  def self.verify_resource_api!(version = nil)
    require 'puppet/resource_api/version'
    version ||= Puppet::ResourceApi::VERSION
    return if Gem::Version.new(version) >= Gem::Version.new(minimum_resource_api)

    raise Puppet::Error,
          "zaben-checkmk requires puppet-resource_api >= #{minimum_resource_api} but #{version} is loaded. " \
          'Use puppet-agent >= 7.8.0 (or >= 6.23.0), or install a newer puppet-resource_api gem.'
  end
end
