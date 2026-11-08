# frozen_string_literal: true

require 'spec_helper'
require 'English'
require 'open3'
require_relative '../support/transaction_helpers'
require_relative '../support/fake_agent_host'

# Applies the module's real `checkmk::install::agent` manifest as Puppet
# transactions against a simulated host and Checkmk server. Only HTTP
# (WebMock), the command line and the apt package provider are faked, and the
# installed agent version can only change through an install action performed
# by the module itself (see FakeAgentHost).
describe 'checkmk', type: :class, transaction: true do
  let(:hostname) { 'web-01.example.com' }
  let(:facts) { { 'os' => { 'family' => 'Debian' }, 'fqdn' => hostname } }
  let(:params) do
    {
      'mode' => 'agent',
      'automation_user_password' => 's3cret',
      'agent_download_host' => 'cmk.example.com',
      'site_name' => 'mysite',
      'hostname' => hostname,
      'agent_folder' => '/linux',
    }
  end
  # Every example gets its own directory; the manifest's /tmp/check-mk-agent.deb is rewritten onto it.
  let(:package_dir) { Dir.mktmpdir('checkmk-lifecycle-pkg') }
  let(:deb_path) { File.join(package_dir, 'check-mk-agent.deb') }
  let(:host) { FakeAgentHost.new(server_version: '2.2.0p10-1', deb_path: deb_path) }
  let(:api) { 'http://cmk.example.com/mysite/check_mk/api/1.0' }
  let(:agent_ref) { "Agent_package[#{deb_path}]" }
  let(:package_ref) { 'Package[check-mk-agent]' }
  let(:host_ref) { "Create_host[#{hostname}]" }
  let(:register_ref) { 'Exec[register checkmk agent]' }
  let(:upgrade_ref) { 'Exec[upgrade checkmk agent]' }

  let(:catalog) do
    cat = repoint(catalogue, '/tmp/check-mk-agent.deb', deb_path)
    cat.resource('Package', 'check-mk-agent')[:provider] = 'checkmk_fake'
    cat.resources.select { |resource| resource.type == 'Exec' }.each { |resource| resource[:provider] = 'shell' }
    cat
  end

  # Rewrites every reference to the manifest's hard-coded package path (resource title, package source, exec
  # command/guard, relationships) by round-tripping the compiled catalogue through its serialised form.
  def repoint(compiled, from, to)
    data = JSON.parse(compiled.to_data_hash.to_json.gsub(from, to))
    expect(JSON.generate(data)).not_to include(from)
    Puppet::Resource::Catalog.from_data_hash(data)
  end

  def apply(noop: false)
    apply_catalogue(catalog, noop: noop)
  end

  before do
    isolate_puppet_state(Dir.mktmpdir('checkmk-lifecycle'))
    FakeAgentHost.current = host
    allow(Puppet::Util::Execution).to receive(:execute) { |command, options| host.execute(command, options) }

    stub_request(:get, "#{api}/domain-types/internal/actions/discover-receiver/invoke").to_return(status: 200, body: '8000')
    stub_request(:head, %r{#{api}/domain-types/agent/actions/download/invoke}).to_return { { status: 200, headers: { 'Content-Disposition' => host.disposition } } }
    stub_request(:get, %r{#{api}/domain-types/agent/actions/download/invoke}).to_return { { status: 200, body: host.download_body } }
    stub_request(:get, %r{#{api}/objects/host_config/}).to_return { |request| { status: host.hosts.include?(request.uri.path.split('/').last) ? 200 : 404, body: '{}' } }
    stub_request(:post, "#{api}/domain-types/host_config/collections/all").to_return do |request|
      host.hosts << JSON.parse(request.body)['host_name']
      { status: 200, body: '{}' }
    end
  end

  after do
    FakeAgentHost.current = nil
    FileUtils.remove_entry(package_dir) if File.directory?(package_dir)
  end

  context 'agent lifecycle on a fresh node' do
    it 'downloads, installs and registers the agent, then stays quiet on repeat applies and noops' do
      first = apply

      expect(touched(first)).to include(agent_ref, package_ref, host_ref, register_ref)
      expect(host.package_version).to eq('2.2.0p10-1')
      expect(host.registered).to be(true)
      expect(host.downloads).to eq(1)

      2.times { expect(touched(apply)).to be_empty }
      expect(touched(apply(noop: true))).to be_empty
      expect(host.downloads).to eq(1)
      expect(host.installs).to eq(1)
    end

    it 'does not reinstall the package it has just installed' do
      apply

      expect(host.commands.grep(%r{apt-get install})).to be_empty
    end
  end

  context 'agent lifecycle when the server later offers a different agent version' do
    before do
      apply
      host.server_version = '2.2.0p12-1'
    end

    it 'reports the pending upgrade in noop without downloading or installing' do
      report = apply(noop: true)

      expect(touched(report)).to include(agent_ref)
      expect(host.package_version).to eq('2.2.0p10-1')
      expect(host.downloads).to eq(1)
    end

    it 'upgrades the installed agent, then converges: a second apply and noop are quiet' do
      upgrade = apply

      expect(touched(upgrade)).to include(agent_ref, upgrade_ref)
      expect(host.package_version).to eq('2.2.0p12-1')
      expect(host.agent_ctl_version).to eq('2.2.0p12')
      expect(host.downloads).to eq(2)
      expect(host.commands.grep(%r{cmk-agent-ctl register}).size).to eq(1)

      2.times { expect(touched(apply)).to be_empty }
      expect(touched(apply(noop: true))).to be_empty
      expect(host.downloads).to eq(2)
      expect(host.installs).to eq(2)
    end

    it 'converges when the server offers an older version (downgrade)' do
      host.server_version = '2.2.0p8-1'

      expect(touched(apply)).to include(agent_ref, upgrade_ref)
      expect(host.package_version).to eq('2.2.0p8-1')
      expect(touched(apply)).to be_empty
    end

    it 'fails and retries on the next run when the install fails, without registering again' do
      host.fail_install = true
      failed = apply

      expect(status_of(failed, upgrade_ref).failed).to be(true)
      expect(status_of(failed, register_ref).skipped).to be(true)
      expect(host.package_version).to eq('2.2.0p10-1')

      host.fail_install = false
      expect(touched(apply)).to include(agent_ref, upgrade_ref)
      expect(host.package_version).to eq('2.2.0p12-1')
      expect(touched(apply)).to be_empty
    end
  end

  context 'agent lifecycle upgrade guard' do
    # Runs the manifest's real `unless` string in /bin/sh, with dpkg stubs that insist on the exact arguments,
    # so quoting mistakes in the manifest cannot hide behind the fake host.
    def guard_exit_status(deb_version:, installed_version:)
      guard = catalog.resource('Exec', 'upgrade checkmk agent')[:unless]
      Dir.mktmpdir('checkmk-guard') do |bin|
        write_stub(bin, 'dpkg-deb', %([ "$1 $2 $3" = "-f #{deb_path} Version" ] || exit 2; echo "$DEB_VERSION"))
        write_stub(bin, 'dpkg-query', %q([ "$1 $2 $3" = '-W -f=${Version} check-mk-agent' ] || exit 2; printf "%s" "$INSTALLED_VERSION"))
        env = { 'PATH' => "#{bin}:/usr/bin:/bin", 'DEB_VERSION' => deb_version, 'INSTALLED_VERSION' => installed_version }
        system(env, '/bin/sh', '-c', guard)
        $CHILD_STATUS.exitstatus
      end
    end

    def write_stub(dir, name, body)
      path = File.join(dir, name)
      File.write(path, "#!/bin/sh\n#{body}\n")
      File.chmod(0o755, path)
    end

    it 'exits 0 (skip the install) when the downloaded package is already installed' do
      expect(guard_exit_status(deb_version: '2.2.0p12-1', installed_version: '2.2.0p12-1')).to eq(0)
    end

    it 'exits 1 (run the install) when the downloaded package differs from the installed one' do
      expect(guard_exit_status(deb_version: '2.2.0p12-1', installed_version: '2.2.0p10-1')).to eq(1)
    end
  end

  # Real dpkg/apt on the distributions in metadata.json. Needs Docker, so it is opt-in (RUN_DOCKER_SPECS=1);
  # when requested and Docker is unavailable it fails rather than skipping.
  context 'agent lifecycle upgrade of a package with a locally modified config file (real Debian/Ubuntu)' do
    images = ['debian:10', 'debian:11', 'debian:12', 'ubuntu:18.04', 'ubuntu:20.04', 'ubuntu:22.04']

    def install_command
      catalogue.resource('Exec', 'upgrade checkmk agent')[:command].gsub('/tmp/check-mk-agent.deb', '{DEB}')
    end

    # check-mk-agent 2.2.0p10-1 installed, config edited by the admin, server now offers 2.2.0p12-1
    def run_scenario(image, command)
      output, status = Open3.capture2e('docker', 'run', '--rm', '-v', "#{File.expand_path('../support', __dir__)}:/t:ro", image, '/t/conffile_scenario.sh', command)
      raise "docker run failed for #{image}: #{output}" unless status.success?

      match = output.match(%r{exit=(\d+) installed=(\S+) conffile=\[(.*)\]})
      raise "unexpected scenario output for #{image}: #{output}" unless match

      { exit: match[1].to_i, installed: match[2], conffile: match[3], output: output }
    end

    before do
      skip 'set RUN_DOCKER_SPECS=1 to run the real Debian/Ubuntu package tests (needs Docker)' unless ENV['RUN_DOCKER_SPECS']
      raise 'RUN_DOCKER_SPECS is set but Docker is not available' unless system('docker info > /dev/null 2>&1')
    end

    images.each do |image|
      it "#{image}: upgrades and keeps the locally modified config file" do
        result = run_scenario(image, install_command)

        expect(result).to include(exit: 0, installed: '2.2.0p12-1', conffile: 'local-edit=keep-me')
      end

      it "#{image}: control - without the conffile option the same upgrade fails" do
        command = install_command.sub(' -o DPkg::Options::=--force-confold', '')
        expect(command).not_to eq(install_command)

        expect(run_scenario(image, command)[:exit]).not_to eq(0)
      end
    end
  end
end
