# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'webmock'
require 'webmock/rspec/matchers'

# Helpers for driving the agent_package / create_host types through real Puppet
# transactions (catalog.apply) so that the Resource API type layer, property
# insync checks, noop handling and flush behaviour are all exercised.
#
# Only the outside world is stubbed: HTTP via WebMock (the real
# Puppet::HTTP::Client still runs) and the `cmk-agent-ctl --version` command.
module TransactionHelpers
  AGENT_CTL = '/usr/bin/cmk-agent-ctl'

  # Points Puppet's state files at a scratch directory so catalog.apply can run.
  def isolate_puppet_state(dir)
    Puppet[:vardir] = dir
    Puppet[:statedir] = dir
    Puppet[:statefile] = File.join(dir, 'state.yaml')
    Puppet[:transactionstorefile] = File.join(dir, 'transactionstore.yaml')
    Puppet[:lastrunfile] = File.join(dir, 'last_run_summary.yaml')
    Puppet[:graphdir] = dir
    Puppet[:resourcefile] = File.join(dir, 'resources.txt')
    Puppet[:classfile] = File.join(dir, 'classes.txt')
  end

  # Applies a catalog built from the given resources and returns the report.
  # @param resources [Array<Puppet::Type>]
  def apply_resources(*resources, noop: false)
    Puppet[:noop] = noop
    catalog = Puppet::Resource::Catalog.new
    resources.each { |resource| catalog.add_resource(resource) }
    catalog.apply.report
  end

  # Applies an already compiled (rspec-puppet) catalogue as a real transaction.
  # A fresh RAL catalogue is built every time, like a new agent run.
  def apply_catalogue(catalogue, noop: false)
    Puppet[:noop] = noop
    ral = catalogue.to_ral
    # Puppet ignores `noop` for catalogues that are not a host configuration, so be explicit.
    ral.host_config = true
    ral.apply.report
  end

  # References of every resource that reported an event, a change or a failure.
  def touched(report)
    report.resource_statuses.select { |_ref, status| status.changed || status.failed || !status.events.empty? }.keys
  end

  def status_of(report, reference)
    report.resource_statuses.fetch(reference)
  end

  # Stubs `cmk-agent-ctl --version`. A nil version simulates a missing binary.
  def stub_agent_ctl(version, output: nil)
    allow(Puppet::Util::Execution).to receive(:execute).and_call_original
    allow(Puppet::Util::Execution).to receive(:execute).with([AGENT_CTL, '--version'], any_args) do
      raise Puppet::ExecutionFailure, 'Could not execute posix command: No such file or directory' if version.nil? && output.nil?

      Puppet::Util::Execution::ProcessOutput.new(output || "cmk-agent-ctl #{version}\n", 0)
    end
  end

  def events_of(status)
    status.events.map { |event| [event.property, event.status] }
  end

  # Everything Puppet logged during the example (collected by puppetlabs_spec_helper).
  def logged_messages
    @logs.map { |log| log.message.to_s }.join("\n")
  end
end

# WebMock is only active for :transaction examples so it cannot interfere with
# other specs (e.g. catalogue compilation, which calls a function that makes
# its own, failure-tolerant, HTTP request).
RSpec.configure do |config|
  config.include WebMock::API, :transaction
  config.include WebMock::Matchers, :transaction
  config.include TransactionHelpers, :transaction

  config.before(:each, :transaction) do
    WebMock.enable!
    WebMock.disable_net_connect!
  end

  config.after(:each, :transaction) do
    WebMock.reset!
    WebMock.disable!
    Puppet[:noop] = false
  end
end
