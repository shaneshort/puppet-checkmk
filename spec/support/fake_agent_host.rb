# frozen_string_literal: true

require 'puppet/provider/package'

# A simulated Debian agent host plus Checkmk server, used to exercise the whole
# agent lifecycle (download -> install -> register) through real Puppet
# transactions of the module's own manifest.
#
# The installed agent version is state owned by this object and can ONLY be
# changed by an install action (the package provider or the `apt-get install`
# exec), never directly by a test, so a spec cannot "pretend" an upgrade
# happened that the module did not perform.
class FakeAgentHost
  class << self
    attr_accessor :current
  end

  # Version the Checkmk server currently offers (a test input: "the server was upgraded").
  attr_accessor :server_version
  # Make the apt-get install exec fail (simulates a broken/interrupted install).
  attr_accessor :fail_install
  attr_reader :deb_path, :package_version, :registered, :hosts, :commands, :downloads, :installs

  def initialize(server_version:, deb_path:)
    @server_version = server_version
    @deb_path = deb_path
    @package_version = nil
    @registered = false
    @fail_install = false
    @hosts = []
    @commands = []
    @downloads = 0
    @installs = 0
  end

  def installed?
    !@package_version.nil?
  end

  # `cmk-agent-ctl --version` reports the upstream version without the package revision.
  def agent_ctl_version
    @package_version&.sub(%r{-\d+\z}, '')
  end

  def download_body
    @downloads += 1
    "DEB:#{@server_version}"
  end

  def disposition
    %(attachment; filename="check-mk-agent_#{@server_version}_all.deb")
  end

  def deb_version(path)
    File.read(path)[%r{\ADEB:(.+)\z}, 1]
  end

  # The only way the installed version changes.
  def install_from(path)
    version = deb_version(path)
    raise "#{path} is not a downloaded agent package" if version.nil?

    @installs += 1
    @package_version = version
  end

  # Handles every command the module runs, dispatched by Puppet::Util::Execution.execute.
  def execute(command, options = {})
    text = shell_text(command)
    @commands << text
    result = run(text)
    # like the real thing: failonfail raises on a non-zero exit status
    raise Puppet::ExecutionFailure, "Execution of '#{text}' returned #{result.exitstatus}: #{result}" if options[:failonfail] && result.exitstatus != 0

    result
  end

  def run(text)
    case text
    when %r{cmk-agent-ctl --version}
      return output('', 1) unless installed?

      output("cmk-agent-ctl #{agent_ctl_version}\n", 0)
    when %r{apt-get install .*#{Regexp.escape(@deb_path)}}
      return output('E: install failed', 100) if @fail_install

      install_from(@deb_path)
      output('', 0)
    when %r{dpkg-deb -f #{Regexp.escape(@deb_path)} Version}
      # the `unless` guard: exit 0 (=> skip) when the downloaded package is already installed
      output('', (deb_version(@deb_path) == @package_version) ? 0 : 1)
    when %r{cmk-agent-ctl status}
      output('', @registered ? 1 : 0) # onlyif: exit 0 when no connections are registered
    when %r{cmk-agent-ctl register}
      @registered = true
      output('', 0)
    else
      raise "FakeAgentHost: unexpected command #{text.inspect}"
    end
  end

  # `/bin/sh -c <script>` (the shell exec provider) -> the script; any other argv -> its words.
  def shell_text(command)
    return command.to_s unless command.is_a?(Array)

    (command[0, 2] == ['/bin/sh', '-c']) ? command[2].to_s : command.join(' ')
  end

  def output(text, status)
    Puppet::Util::Execution::ProcessOutput.new(text, status)
  end
end

# Stands in for the apt package provider: installs from `source` into the fake host.
Puppet::Type.type(:package).provide(:checkmk_fake, parent: Puppet::Provider::Package) do
  desc 'Fake provider used by the checkmk lifecycle spec'

  def self.instances
    []
  end

  def query
    version = FakeAgentHost.current.package_version
    version ? { name: @resource[:name], ensure: version, provider: :checkmk_fake } : nil
  end

  def install
    FakeAgentHost.current.install_from(@resource[:source])
  end

  def uninstall
    raise 'not supported by the fake provider'
  end
end
