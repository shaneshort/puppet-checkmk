# frozen_string_literal: true

require 'digest'
require 'tempfile'
require 'puppet/resource_api/simple_provider'

# Implementation for the agent_package type using the Resource API.
#
# State model:
#
# * `get` reports `present` when `cmk-agent-ctl` is installed and `absent`
#   otherwise. It only discovers what is knowable locally, because the Resource
#   API does not give `get` the resource's url/site/token parameters.
# * `insync?` (the `custom_insync` feature) is where the desired parameters are
#   available. When the agent is installed it asks the Checkmk server which
#   package it would serve (a read-only HEAD request) and reports the resource
#   out of sync if that package is for a different agent version, which is what
#   triggers an upgrade download.
# * `create`/`update` download the package. Both are only reached through the
#   transaction when something really needs to be downloaded, and neither runs
#   in noop mode.
#
# Every API, authentication or network error is raised so the resource is
# reported as failed (and dependent resources are skipped) rather than being
# treated as "absent" or "up to date".
class Puppet::Provider::AgentPackage::AgentPackage < Puppet::ResourceApi::SimpleProvider
  def get(context, names = [])
    return [] if names.empty?

    ensure_value = installed_version(context).nil? ? 'absent' : 'present'
    names.map { |name| { file_name: name, ensure: ensure_value } }
  end

  # Only compares anything when the agent is installed and the package should
  # be present; every other case uses the default ensure comparison.
  def insync?(context, _name, property_name, is_hash, should_hash)
    return nil unless property_name == :ensure
    return nil unless should_hash[:ensure].to_s == 'present' && is_hash[:ensure].to_s == 'present'

    installed = installed_version(context)
    return [false, 'cmk-agent-ctl is no longer installed, downloading package'] if installed.nil?

    offered = offered_package_name(should_hash)
    return true if package_matches_version?(offered, installed)

    [false, "agent package is out of date: installed cmk-agent-ctl #{installed}, server offers #{offered}"]
  end

  def create(context, name, should)
    download(context, name, should)
  end

  def update(context, name, should)
    context.debug 'cmk-agent-ctl is a different version, downloading new package...'
    download(context, name, should)
  end

  def delete(_context, name)
    File.delete(name) if File.exist?(name)
  end

  private

  def agent_ctl
    '/usr/bin/cmk-agent-ctl'
  end

  def download_uri(should)
    URI("#{should[:url]}/#{should[:site_name]}/check_mk/api/1.0/domain-types/agent/actions/download/invoke")
  end

  def request_options(should)
    {
      params: { os_type: should[:os_type] },
      headers: { 'Accept' => 'application/octet-stream', 'Authorization' => "Bearer automation #{should[:bearer_token]}" },
      options: { include_system_store: true },
    }
  end

  # Downloads the package to a temporary file beside the target and only moves
  # it into place once the whole body was received successfully, so a failed
  # download never truncates or replaces an existing file.
  def download(context, name, should)
    tmp = Tempfile.new(['check-mk-agent', '.part'], File.dirname(name))
    moved = false
    begin
      tmp.binmode
      fetch_package(should, tmp)
      tmp.close
      File.chmod(0o644, tmp.path)
      File.rename(tmp.path, name)
      moved = true
      context.debug "Downloaded agent package to #{name} (sha256 #{Digest::SHA256.file(name).hexdigest})"
    ensure
      tmp.close unless tmp.closed?
      tmp.unlink unless moved
    end
  end

  def fetch_package(should, file)
    failure = nil
    Puppet.runtime[:http].get(download_uri(should), **request_options(should)) do |response|
      if response.success?
        response.read_body { |segment| file.write(segment) }
      else
        failure = describe_failure(response)
      end
    end
    raise Puppet::Error, "Failed to download agent package: #{failure}" if failure
    raise Puppet::Error, 'Failed to download agent package: the server returned an empty body' unless file.size.positive?
  end

  # Asks the server which package it would serve, without downloading it.
  def offered_package_name(should)
    response = Puppet.runtime[:http].head(download_uri(should), **request_options(should))
    raise Puppet::Error, "Failed to check agent package version: #{describe_failure(response)}" unless response.success?

    name = response['content-disposition'].to_s[%r{filename="?([^";]+)"?}, 1]
    raise Puppet::Error, 'Failed to check agent package version: the server response had no Content-Disposition filename' if name.nil?

    name
  end

  def describe_failure(response)
    body = +''
    response.read_body { |segment| body << segment } if response.respond_to?(:read_body)
    detail = body.strip[0, 300]
    hint = (response.code == 404) ? ' (agent package not found: check agent_download_host, site_name and os_type)' : ''
    "HTTP #{response.code}#{hint}#{detail.empty? ? '' : ": #{detail}"}"
  rescue StandardError
    "HTTP #{response.code}"
  end

  # The server's package filename embeds the agent version, e.g.
  # check-mk-agent_2.2.0p12-1_all.deb. The version must match as a whole token
  # so that 2.2.0p1 does not match 2.2.0p12.
  def package_matches_version?(package_name, version)
    %r{(?<![0-9A-Za-z.])#{Regexp.escape(version)}(?![0-9A-Za-z]|\.[0-9])}.match?(package_name)
  end

  # The installed cmk-agent-ctl version, or nil when it is not installed/usable.
  def installed_version(context)
    context.debug 'checking if cmk-agent-ctl is installed'
    begin
      output = Puppet::Util::Execution.execute([agent_ctl, '--version'], failonfail: true, combine: false).to_s
    rescue Puppet::ExecutionFailure, SystemCallError => e
      context.debug "cmk-agent-ctl is not installed: #{e.message}"
      return nil
    end

    version = output[%r{\d+(?:\.\d+)+\S*}]
    raise Puppet::Error, "Unable to determine the cmk-agent-ctl version from #{output.strip.inspect}" if version.nil?

    version
  end
end
