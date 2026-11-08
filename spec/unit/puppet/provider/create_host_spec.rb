# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../support/transaction_helpers'

# These examples drive the real create_host type and provider through Puppet
# transactions. Only HTTP (WebMock) is stubbed.
RSpec.describe 'create_host', :transaction do
  let(:state_dir) { Dir.mktmpdir('checkmk-spec') }
  let(:host_name) { 'memcache-02.example.com' }
  let(:reference) { "Create_host[#{host_name}]" }
  let(:base_url) { 'http://cmk.example.com/mysite/check_mk/api/1.0' }
  let(:exists_url) { "#{base_url}/objects/host_config/#{host_name}?effective_attributes=false" }
  let(:create_url) { "#{base_url}/domain-types/host_config/collections/all" }
  let(:auth_header) { { 'Authorization' => 'Bearer automation s3cret' } }

  before do
    isolate_puppet_state(state_dir)
  end

  after { FileUtils.remove_entry(state_dir) }

  def build_host(ensure_value: 'present', title: host_name)
    Puppet::Type.type(:create_host).new(
      title: title,
      ensure: ensure_value,
      url: 'http://cmk.example.com',
      site_name: 'mysite',
      bearer_token: 's3cret',
      folder: '/linux',
    )
  end

  def apply_host(noop: false, **args)
    status_of(apply_resources(build_host(**args), noop: noop), reference)
  end

  def stub_exists(code, headers: {}, body: '{}')
    stub_request(:get, exists_url).to_return(status: code, body: body, headers: headers)
  end

  def stub_create(code = 200)
    stub_request(:post, create_url).to_return(status: code, body: '{}', headers: { 'Content-Type' => 'application/json' })
  end

  context 'when the host already exists in Checkmk' do
    before { stub_exists(200) }

    it 'reports no change and never creates the host, on repeated applies' do
      stub_create
      3.times do
        status = apply_host

        expect(status.failed).to be(false)
        expect(status.changed).to be(false)
        expect(status.events).to be_empty
      end
      expect(a_request(:post, create_url)).not_to have_been_made
    end

    it 'reports no change in noop mode' do
      status = apply_host(noop: true)

      expect(status.failed).to be(false)
      expect(status.events).to be_empty
    end

    it 'authenticates the existence check with the automation bearer token' do
      apply_host

      expect(a_request(:get, exists_url).with(headers: auth_header)).to have_been_made.once
    end
  end

  context 'when the host does not exist in Checkmk' do
    before { stub_exists(404, headers: { 'Content-Type' => 'application/problem+json' }) }

    it 'creates the host exactly once, with the configured folder and host name' do
      stub_create
      status = apply_host

      expect(status.failed).to be(false)
      expect(events_of(status)).to eq([['ensure', 'success']])
      expect(
        a_request(:post, create_url).with(
          headers: auth_header.merge('Content-Type' => 'application/json'),
          body: { folder: '/linux', host_name: host_name }.to_json,
        ),
      ).to have_been_made.once
    end

    it 'reports a pending change but creates nothing in noop mode' do
      stub_create
      status = apply_host(noop: true)

      expect(status.failed).to be(false)
      expect(events_of(status)).to eq([['ensure', 'noop']])
      expect(a_request(:post, create_url)).not_to have_been_made
    end

    it 'converges: a second apply after creation changes nothing' do
      stub_create
      apply_host
      WebMock.reset!
      stub_exists(200)
      stub_create

      status = apply_host

      expect(status.events).to be_empty
      expect(a_request(:post, create_url)).not_to have_been_made
    end
  end

  describe 'API, authentication and network failures' do
    {
      'unauthorised (401)' => 401,
      'forbidden (403)' => 403,
      'server error (500)' => 500,
    }.each do |label, code|
      it "fails, rather than assuming the host is absent, on #{label}" do
        stub_exists(code, body: '{"title":"nope"}')
        stub_create

        status = apply_host

        expect(status.failed).to be(true)
        expect(logged_messages).to include("HTTP #{code}")
        expect(logged_messages).not_to include('s3cret')
        expect(a_request(:post, create_url)).not_to have_been_made
      end

      it "fails in noop mode instead of reporting a pending create, on #{label}" do
        stub_exists(code)
        stub_create

        status = apply_host(noop: true)

        expect(status.failed).to be(true)
        expect(events_of(status)).not_to include(['ensure', 'noop'])
      end
    end

    it 'fails when the server cannot be reached' do
      stub_request(:get, exists_url).to_raise(Errno::ECONNREFUSED)
      stub_create

      status = apply_host

      expect(status.failed).to be(true)
      expect(a_request(:post, create_url)).not_to have_been_made
    end

    it 'fails when the create request is rejected' do
      stub_exists(404)
      stub_create(500)

      status = apply_host

      expect(status.failed).to be(true)
      expect(events_of(status)).to include([nil, 'failure'])
      expect(logged_messages).to include("Failed to add host #{host_name}: HTTP 500")
      expect(logged_messages).not_to include('s3cret')
    end

    it 'fails when the create endpoint returns 404 (server not configured)' do
      stub_exists(404)
      stub_create(404)

      expect(apply_host.failed).to be(true)
    end

    it 'skips dependent resources when the host cannot be created' do
      stub_exists(404)
      stub_create(500)
      dependent = Puppet::Type.type(:notify).new(name: 'register', require: "Create_host[#{host_name}]")

      report = apply_resources(build_host, dependent)

      expect(status_of(report, reference).failed).to be(true)
      expect(status_of(report, 'Notify[register]').skipped).to be(true)
    end
  end

  describe 'ensure => absent' do
    it 'is in sync when the host does not exist' do
      stub_exists(404)

      expect(apply_host(ensure_value: 'absent').events).to be_empty
    end

    it 'fails loudly while host deletion is unimplemented, instead of reporting success' do
      stub_exists(200)

      expect(apply_host(ensure_value: 'absent').failed).to be(true)
    end
  end
end
