# frozen_string_literal: true

require 'puppet/resource_api'
# Relative, not via $LOAD_PATH: Puppet Server does not put a module's lib/ directory on the load path.
require_relative '../../puppet_x/checkmk/requirements'

PuppetX::Checkmk::Requirements.verify_resource_api!

Puppet::ResourceApi.register_type(
  name: 'create_host',
  docs: <<-EOS,
    @summary Creates a Host in the CheckMK server
    @example
      create_host { 'test.example.com':
        ensure       => 'present',
        url          => 'http://127.0.0.1',
        site_name    => 'default',
        bearer_token => 'testing123',
        folder       => 'linux',
      }

    This type provides Puppet with the capabilities to create the Host in CheckMK from the CheckMK server API.

    The host's existence is checked against the CheckMK API on every run (read-only, also in noop mode). The host
    is only created when the API reports it as not found; any other API, authentication or network error fails the
    resource. `ensure => absent` is not implemented and fails if the host exists.

    Requires puppet-resource_api >= 1.8.14 (puppet-agent >= 7.8.0) (`custom_insync` feature).
  EOS
  features: ['custom_insync'],
  attributes: {
    ensure: {
      type: 'Enum[present, absent]',
      desc: 'Whether this agent package should be present or absent on the target system.',
      default: 'present',
    },
    host_name: {
      type: 'String',
      desc: 'The hostname of the server to add into CheckMK.',
      behaviour: :namevar,
    },
    url: {
      type: 'String',
      desc: 'The URL for the CheckMK server.',
      behaviour: :parameter,
    },
    bearer_token: {
      type: 'String',
      desc: 'The password for the `automation` user.',
      behaviour: :parameter,
    },
    site_name: {
      type: 'String',
      desc: 'The site name on the CheckMK Server.',
      behaviour: :parameter,
      default: 'default',
    },
    folder: {
      type: 'String',
      desc: 'The folder to add the host to.',
      behaviour: :parameter,
    }
  },
)
