# frozen_string_literal: true

require 'erb'
require 'json'

require 'puppet/resource_api/simple_provider'

# Creates a host in the CheckMK server
#
# The Resource API does not give `get` the resource's url/site/token
# parameters, so the host list cannot be enumerated there. `get` therefore
# returns nothing (hosts are treated as unknown) and the real existence check
# is made in `insync?` (the `custom_insync` feature), which does receive the
# desired parameters. `create` is only reached when the API reported that the
# host does not exist.
#
# Every API, authentication or network error is raised so the resource is
# reported as failed (and dependent resources are skipped) rather than being
# treated as "absent" or "in sync".
class Puppet::Provider::CreateHost::CreateHost < Puppet::ResourceApi::SimpleProvider
  def get(_context, _names = [])
    []
  end

  def insync?(_context, _name, property_name, _is_hash, should_hash)
    return nil unless property_name == :ensure

    exists = host_exists?(should_hash)
    case should_hash[:ensure].to_s
    when 'present'
      exists
    when 'absent'
      raise Puppet::Error, "Cannot remove host #{should_hash[:host_name]}: CheckMK host deletion is not yet implemented" if exists

      true
    end
  end

  def create(_context, _name, should)
    create_host(should)
  end

  def update(_context, _name, should)
    create_host(should)
  end

  def delete(context, _name)
    # TODO: delete the host
    context.warning 'CheckMK Host deletion is not yet implemented'
  end

  private

  def api_uri(should, path)
    URI("#{should[:url]}/#{should[:site_name]}/check_mk/api/1.0/#{path}")
  end

  def auth_headers(should)
    { 'Accept' => 'application/json', 'Authorization' => "Bearer automation #{should[:bearer_token]}" }
  end

  def create_host(should)
    response = Puppet.runtime[:http].post(
      api_uri(should, 'domain-types/host_config/collections/all'),
      { folder: should[:folder], host_name: should[:host_name] }.to_json,
      headers: auth_headers(should).merge('Content-Type' => 'application/json'),
      options: { include_system_store: true },
    )
    return if response.success?

    hint = (response.code == 404) ? ' (unable to add host, is the server configured?)' : ''
    raise Puppet::Error, "Failed to add host #{should[:host_name]}: HTTP #{response.code}#{hint}: #{response.body.to_s.strip[0, 300]}"
  end

  # True when the API has the host, false when it reports the host as not found.
  # Anything else (authentication, server or network errors) is raised.
  def host_exists?(should)
    response = Puppet.runtime[:http].get(
      api_uri(should, "objects/host_config/#{ERB::Util.url_encode(should[:host_name])}"),
      params: { effective_attributes: false },
      headers: auth_headers(should),
      options: { include_system_store: true },
    )
    return true if response.success?
    return false if response.code == 404

    raise Puppet::Error, "Failed to check whether host #{should[:host_name]} exists: HTTP #{response.code}: #{response.body.to_s.strip[0, 300]}"
  end
end
