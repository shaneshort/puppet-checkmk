# checkmk

## Description

Provisions the [CheckMK](https://checkmk.com/) server and client.

## Usage

To set up a CheckMK server:
```puppet
class { '::checkmk':
  mode                     => 'server',
  version                  => '2.1.0p14',
  sha256_hash              => '8804c0291e897f6185b147613a5fc86d61c0bcf73eaac5b11d90afe58af10c9f', # SHA256 hash of requested version, this can be found at: https://checkmk.com/download
  cmkadmin_user_password   => 'changeme123', # Password for the `cmkadmin` user
  automation_user_password => 'changeme456', # Password for the `automation` user
}
```
This will provision a CheckMK server with default configuration. This can be accessed from: `http://<server-ip>/default`.
To login, use the `cmkadmin` credentials.

To set up a CheckMK agent:
```puppet
class { '::checkmk':
  mode                    => 'agent',
  agent_download_protocol => 'http', # The protocol that should be used when talking to the CheckMK server
  agent_download_host     => 'checkmk.example.com', # The hostname or IP address of the CheckMK server
}
```

All configurations can be set using Hiera.
```yaml
---
checkmk::mode: 'server'
checkmk::download_url: 'https://download.checkmk.com/checkmk/2.1.0p14/check-mk-raw-2.1.0p14_0.jammy_amd64.deb'
checkmk::sha256_hash: '8804c0291e897f6185b147613a5fc86d61c0bcf73eaac5b11d90afe58af10c9f'
checkmk::cmkadmin_user_password: 'changeme123'
checkmk::automation_user_password: 'changeme456'
```

## Requirements

Puppet (agent and server) 7.8.0 or later. The `agent_package` and `create_host` types need puppet-resource_api 1.8.14 or later,
which puppet-agent bundles from 7.8.0 (and from 6.23.0). Older versions are rejected with an explicit error when the types load.

## Limitations

Currently only tested and supported Debian based systems.
Only the Raw version of CheckMK has been tested but this module may work with the paid server versions.

## Development

To contribute to this module, please fork the repository and submit a pull request.
All commits should be squashed into a single commit and the commit message should follow the [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/) specification.

### Testing

Run the following commands to test the module in your local environment:
```bash
bundle install
bundle exec rake spec
bundle exex rake beaker
```