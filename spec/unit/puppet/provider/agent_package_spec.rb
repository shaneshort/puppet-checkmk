# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../support/transaction_helpers'

# These examples drive the real agent_package type and provider through Puppet
# transactions. Only HTTP (WebMock) and `cmk-agent-ctl --version` are stubbed.
RSpec.describe 'agent_package', :transaction do
  let(:state_dir) { Dir.mktmpdir('checkmk-spec-state') }
  let(:pkg_dir) { Dir.mktmpdir('checkmk-spec-pkg') }
  let(:pkg_path) { File.join(pkg_dir, 'check-mk-agent.deb') }
  let(:reference) { "Agent_package[#{pkg_path}]" }
  let(:download_url) { 'http://cmk.example.com/mysite/check_mk/api/1.0/domain-types/agent/actions/download/invoke?os_type=linux_deb' }
  let(:auth_header) { { 'Authorization' => 'Bearer automation s3cret' } }
  let(:server_version) { '2.2.0p12' }
  let(:disposition) { { 'Content-Disposition' => %(attachment; filename="check-mk-agent_#{server_version}-1_all.deb") } }

  before do
    isolate_puppet_state(state_dir)
  end

  after do
    FileUtils.remove_entry(state_dir)
    FileUtils.remove_entry(pkg_dir)
  end

  def build_package(ensure_value: 'present')
    Puppet::Type.type(:agent_package).new(
      title: pkg_path,
      ensure: ensure_value,
      url: 'http://cmk.example.com',
      site_name: 'mysite',
      bearer_token: 's3cret',
      os_type: 'linux_deb',
    )
  end

  def apply_package(noop: false, **args)
    status_of(apply_resources(build_package(**args), noop: noop), reference)
  end

  def stub_head(code = 200, headers: disposition)
    stub_request(:head, download_url).to_return(status: code, headers: headers)
  end

  def stub_download(code = 200, body: 'NEW-DEB-BYTES')
    stub_request(:get, download_url).to_return(status: code, body: body)
  end

  def downloads
    a_request(:get, download_url)
  end

  context 'when the agent is installed and matches the server version' do
    before do
      stub_agent_ctl(server_version)
      stub_head
      stub_download
    end

    it 'reports no change and downloads nothing, on repeated applies' do
      3.times do
        status = apply_package

        expect(status.failed).to be(false)
        expect(status.changed).to be(false)
        expect(status.events).to be_empty
      end
      expect(downloads).not_to have_been_made
      expect(File.exist?(pkg_path)).to be(false)
    end

    it 'reports no change in noop mode' do
      status = apply_package(noop: true)

      expect(status.events).to be_empty
      expect(downloads).not_to have_been_made
    end

    it 'checks the version with the automation bearer token' do
      apply_package

      # Puppet evaluates an in-sync property twice per run; the check is read-only so that is harmless.
      expect(a_request(:head, download_url).with(headers: auth_header)).to have_been_made.at_least_once
      expect(a_request(:head, download_url)).to have_been_made.times(
        WebMock::RequestRegistry.instance.times_executed(WebMock::RequestPattern.new(:head, download_url).with(headers: auth_header)),
      )
    end
  end

  context 'when the agent is not installed' do
    before do
      stub_agent_ctl(nil)
      stub_head
      stub_download
    end

    it 'downloads the package once and writes it to file_name' do
      status = apply_package

      expect(status.failed).to be(false)
      expect(events_of(status)).to eq([['ensure', 'success']])
      expect(File.binread(pkg_path)).to eq('NEW-DEB-BYTES')
      expect(downloads.with(headers: auth_header)).to have_been_made.once
      expect(Dir.children(pkg_dir)).to eq(['check-mk-agent.deb'])
    end

    it 'does not require the version check endpoint' do
      apply_package

      expect(a_request(:head, download_url)).not_to have_been_made
    end

    it 'reports a pending change but downloads nothing in noop mode' do
      status = apply_package(noop: true)

      expect(events_of(status)).to eq([['ensure', 'noop']])
      expect(downloads).not_to have_been_made
      expect(File.exist?(pkg_path)).to be(false)
    end

    it 'treats an unusable cmk-agent-ctl as not installed' do
      stub_agent_ctl(nil)

      expect(events_of(apply_package)).to eq([['ensure', 'success']])
    end

    it 'converges: once installed at the server version a second apply changes nothing' do
      apply_package
      stub_agent_ctl(server_version)
      WebMock.reset!
      stub_head
      stub_download

      expect(apply_package.events).to be_empty
      expect(downloads).not_to have_been_made
    end
  end

  context 'when the server offers a different agent version (upgrade)' do
    before do
      stub_agent_ctl('2.2.0p10')
      stub_head
      stub_download
      File.write(pkg_path, 'OLD-DEB-BYTES')
    end

    it 'downloads the new package and replaces the old file' do
      status = apply_package

      expect(status.failed).to be(false)
      expect(events_of(status)).to eq([['ensure', 'success']])
      expect(File.binread(pkg_path)).to eq('NEW-DEB-BYTES')
      expect(downloads).to have_been_made.once
      expect(Dir.children(pkg_dir)).to eq(['check-mk-agent.deb'])
    end

    it 'reports the pending upgrade but changes nothing in noop mode' do
      status = apply_package(noop: true)

      expect(events_of(status)).to eq([['ensure', 'noop']])
      expect(downloads).not_to have_been_made
      expect(File.binread(pkg_path)).to eq('OLD-DEB-BYTES')
    end

    it 'does not mistake a version prefix for a match (2.2.0p1 vs 2.2.0p12)' do
      stub_agent_ctl('2.2.0p1')

      expect(events_of(apply_package)).to eq([['ensure', 'success']])
    end

    it 'does not mistake a longer version for a match (2.2.0p120 vs 2.2.0p12)' do
      stub_agent_ctl('2.2.0p120')

      expect(events_of(apply_package)).to eq([['ensure', 'success']])
    end
  end

  describe 'version check failures (agent installed)' do
    before do
      stub_agent_ctl(server_version)
      stub_download
      File.write(pkg_path, 'OLD-DEB-BYTES')
    end

    [401, 403, 404, 500].each do |code|
      it "fails, rather than reporting the agent as current, on HTTP #{code}" do
        stub_head(code, headers: {})

        status = apply_package

        expect(status.failed).to be(true)
        expect(logged_messages).to include("Failed to check agent package version: HTTP #{code}")
        expect(logged_messages).not_to include('s3cret')
        expect(downloads).not_to have_been_made
        expect(File.binread(pkg_path)).to eq('OLD-DEB-BYTES')
      end
    end

    it 'fails in noop mode instead of reporting nothing to do' do
      stub_head(500, headers: {})

      expect(apply_package(noop: true).failed).to be(true)
    end

    it 'fails when the response has no usable Content-Disposition filename' do
      stub_head(200, headers: {})

      expect(apply_package.failed).to be(true)
      expect(downloads).not_to have_been_made
    end

    it 'fails when the server cannot be reached' do
      stub_request(:head, download_url).to_raise(Errno::ECONNREFUSED)

      expect(apply_package.failed).to be(true)
      expect(downloads).not_to have_been_made
    end

    it 'fails when the installed version cannot be parsed' do
      stub_agent_ctl(nil, output: "garbled output\n")
      stub_head

      expect(apply_package.failed).to be(true)
    end
  end

  describe 'download failures (agent not installed)' do
    before do
      stub_agent_ctl(nil)
      File.write(pkg_path, 'OLD-DEB-BYTES')
    end

    [401, 403, 404, 500].each do |code|
      it "fails and keeps the previous file on HTTP #{code}, without writing the error body" do
        stub_download(code, body: '<html>error page</html>')

        status = apply_package

        expect(status.failed).to be(true)
        expect(events_of(status)).to include([nil, 'failure'])
        expect(logged_messages).to include("Failed to download agent package: HTTP #{code}")
        expect(logged_messages).not_to include('s3cret')
        expect(File.binread(pkg_path)).to eq('OLD-DEB-BYTES')
        expect(Dir.children(pkg_dir)).to eq(['check-mk-agent.deb'])
      end
    end

    it 'fails when the server cannot be reached, leaving no partial file' do
      stub_request(:get, download_url).to_raise(Errno::ECONNREFUSED)

      expect(apply_package.failed).to be(true)
      expect(File.binread(pkg_path)).to eq('OLD-DEB-BYTES')
      expect(Dir.children(pkg_dir)).to eq(['check-mk-agent.deb'])
    end

    it 'does not leave an empty file behind when there was no previous file' do
      File.delete(pkg_path)
      stub_download(404)

      expect(apply_package.failed).to be(true)
      expect(Dir.children(pkg_dir)).to be_empty
    end

    it 'skips dependent resources, preserving install/registration ordering' do
      stub_download(500)
      dependent = Puppet::Type.type(:notify).new(name: 'install', require: "Agent_package[#{pkg_path}]")

      report = apply_resources(build_package, dependent)

      expect(status_of(report, reference).failed).to be(true)
      expect(status_of(report, 'Notify[install]').skipped).to be(true)
    end
  end

  describe 'ensure => absent' do
    it 'removes the downloaded file' do
      stub_agent_ctl(server_version)
      File.write(pkg_path, 'OLD-DEB-BYTES')

      status = apply_package(ensure_value: 'absent')

      expect(status.failed).to be(false)
      expect(File.exist?(pkg_path)).to be(false)
    end
  end
end
