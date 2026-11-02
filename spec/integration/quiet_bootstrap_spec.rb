# frozen_string_literal: true

require 'puppet'
require 'puppet/pops/evaluator/deferred_resolver'
require 'net/http'
require 'tmpdir'
require 'fileutils'

# Exercise real manifests, Deferred functions and transactions, replacing only
# the external API, installed-agent command and package destination.
describe 'Checkmk bootstrap reporting' do
  before do
    dir = @dir = Dir.mktmpdir('checkmk-reporting')
    module_root = File.expand_path('../..', __dir__)
    FileUtils.mkdir_p(File.join(dir, 'checkmk/manifests/install'))
    File.symlink(File.join(module_root, 'manifests/install/agent'), File.join(dir, 'checkmk/manifests/install/agent'))
    File.symlink(File.join(module_root, 'lib'), File.join(dir, 'checkmk/lib'))
    unless Puppet.settings.global_defaults_initialized?
      Puppet.initialize_settings(['--vardir', File.join(dir, 'var'), '--confdir', File.join(dir, 'etc'),
                                  '--codedir', File.join(dir, 'code'), '--logdir', File.join(dir, 'log'),
                                  '--rundir', File.join(dir, 'run')])
    end
    @settings = %i[vardir confdir log_level code].to_h { |key| [key, Puppet[key]] }
    Puppet[:vardir] = File.join(dir, 'var')
    Puppet[:confdir] = File.join(dir, 'etc')
    Puppet[:log_level] = 'debug'
    # Keep agent transactions (including lazy Deferred resolution), without
    # managing Puppet's own state directory or its OS-specific permissions.
    allow(Puppet::Util::Storage).to receive(:load)
    allow(Puppet::Util::Storage).to receive(:store)
    File.write(File.join(dir, 'checkmk/manifests/init.pp'), <<~PP)
      class checkmk {
        $agent_download_protocol = 'http'
        $agent_download_host = 'checkmk.invalid'
        $automation_user_password = 'test-only'
        $site_name = 'default'
        $agent_folder = '/'
        $hostname = 'test.example.com'
        include checkmk::install::agent::create_host
        include checkmk::install::agent::package
      }
    PP
    Puppet[:code] = 'include checkmk'
    @environment = Puppet::Node::Environment.create(:testing, [dir])
    @requests = []
    @host_exists = true
    @installed = true
    @version = "cmk-agent-ctl 2.1.0p14\n"
    connection = double('HTTP connection')
    allow(Net::HTTP).to receive(:start).with('checkmk.invalid', 80).and_yield(connection)
    allow(connection).to receive(:request) do |request, &block|
      @requests << [request.method, request.path]
      code = request.path.include?('/objects/host_config/') && !@host_exists ? '404' : '200'
      response = double('HTTP response', code: code, body: 'agent-package')
      allow(response).to receive(:[]).with('content-disposition').and_return('attachment; filename="check-mk-agent_2.1.0p14-1_all.deb"')
      allow(response).to receive(:read_body).and_yield('agent-package')
      @host_exists = true if request.method == 'POST'
      block ? block.call(response) : response
    end
    allow_any_instance_of(Puppet::Functions::Function).to receive(:system).with('/usr/bin/cmk-agent-ctl --version > /dev/null 2>&1') { @installed }
    allow_any_instance_of(Puppet::Functions::Function).to receive(:`).with('/usr/bin/cmk-agent-ctl --version') { @version }
    allow_any_instance_of(Puppet::Functions::Function).to receive(:open).with('/tmp/check-mk-agent.deb', 'wb') { File.open(File.join(@dir, 'agent.deb'), 'wb') }
  end

  after do
    @settings.each { |key, value| Puppet[key] = value } if @settings
    FileUtils.remove_entry(@dir)
  end

  def apply_bootstrap(preprocess)
    node = Puppet::Node.new('test.example.com', environment: @environment)
    catalog = Puppet::Parser::Compiler.compile(node)
    Puppet::Pops::Evaluator::DeferredResolver.resolve_and_replace(Puppet::Node::Facts.new(node.name, {}), catalog, @environment, preprocess)
    catalog.to_ral.apply.report
  end

  [true, false].each do |preprocess|
    context "with preprocess_deferred=#{preprocess}" do
      it 'checks existing hosts and versions on every run without reporting changes' do
        2.times do
          report = apply_bootstrap(preprocess)
          expect(report.resource_statuses.values.select(&:failed)).to be_empty
          expect(report.resource_statuses.values.select(&:changed)).to be_empty
          messages = report.logs.map(&:message)
          expect(messages).to include('CheckMK host already exists', 'cmk-agent-ctl version is the same')
        end
        expect(@requests.count { |method, path| method == 'GET' && path.include?('/objects/host_config/') }).to eq(2)
        expect(@requests.count { |method, _path| method == 'HEAD' }).to eq(2)
        expect(@requests.none? { |method, _path| method == 'POST' }).to be true
        expect(File.exist?(File.join(@dir, 'agent.deb'))).to be false
      end

      it 'still creates missing hosts and downloads missing agents' do
        @host_exists = false
        @installed = false
        report = apply_bootstrap(preprocess)
        expect(report.resource_statuses.values.select(&:failed)).to be_empty
        expect(@host_exists).to be true
        expect(File.read(File.join(@dir, 'agent.deb'))).to eq('agent-package')
      end

      it 'does not hide unexpected API failures' do
        allow(Net::HTTP).to receive(:start).and_raise(Puppet::Error, 'simulated API failure')
        expect { apply_bootstrap(preprocess) }.to raise_error(Puppet::Error, /simulated API failure/)
      end

      it 'still downloads a newer agent package' do
        @version = "cmk-agent-ctl 2.1.0p13\n"
        report = apply_bootstrap(preprocess)
        expect(report.resource_statuses.values.select(&:failed)).to be_empty
        expect(File.read(File.join(@dir, 'agent.deb'))).to eq('agent-package')
      end
    end
  end
end
