# @summary Installs CheckMK Agent
class checkmk::install::agent {
  case $facts['os']['family'] {
    'Debian': {
      agent_package { '/tmp/check-mk-agent.deb':
        ensure       => $checkmk::agent_package_ensure,
        url          => "${checkmk::agent_download_protocol}://${checkmk::agent_download_host}",
        bearer_token => $checkmk::automation_user_password,
        site_name    => $checkmk::site_name,
        os_type      => 'linux_deb',
      }

      package { 'check-mk-agent':
        ensure   => installed,
        provider => 'apt',
        source   => '/tmp/check-mk-agent.deb',
        require  => Agent_package['/tmp/check-mk-agent.deb'],
      }

      # `package { ensure => installed }` never upgrades an installed package, so when agent_package
      # downloads a package for a different agent version (an upgrade, or a downgrade to the server's
      # version) it has to be installed explicitly. refreshonly + the `unless` guard means this does
      # nothing on a first install (the package resource has just installed that same version) and
      # nothing on a run where no package was downloaded. --force-confold keeps locally modified
      # configuration files (what Puppet's apt provider does for `configfiles => keep`); without it dpkg
      # stops at the conffile prompt and the install fails even with DEBIAN_FRONTEND=noninteractive.
      exec { 'upgrade checkmk agent':
        command     => 'apt-get install -y --allow-downgrades -o DPkg::Options::=--force-confold /tmp/check-mk-agent.deb',
        provider    => 'shell',
        path        => ['/usr/local/sbin', '/usr/local/bin', '/usr/sbin', '/usr/bin', '/sbin', '/bin'],
        environment => ['DEBIAN_FRONTEND=noninteractive'],
        # lint:ignore:single_quote_string_with_variables (the ${Version} is a dpkg-query format for the shell, not a Puppet variable)
        unless      => 'test "$(dpkg-deb -f /tmp/check-mk-agent.deb Version)" = "$(dpkg-query -W -f=\'${Version}\' check-mk-agent)"',
        # lint:endignore
        refreshonly => true,
        subscribe   => Agent_package['/tmp/check-mk-agent.deb'],
        require     => Package['check-mk-agent'],
      }

      create_host { $checkmk::hostname:
        ensure       => present,
        url          => "${checkmk::agent_download_protocol}://${checkmk::agent_download_host}",
        bearer_token => $checkmk::automation_user_password,
        site_name    => $checkmk::site_name,
        folder       => $checkmk::agent_folder,
        require      => Package['check-mk-agent'],
      }
      Package['check-mk-agent'] -> Create_host[$facts['fqdn']]

      $registration_server = checkmk::registration_server(
        "${checkmk::agent_download_protocol}://${checkmk::agent_download_host}",
        $checkmk::site_name,
      )

      exec { 'register checkmk agent':
        command => "/usr/bin/cmk-agent-ctl register --hostname ${checkmk::hostname} --server ${registration_server} --site ${checkmk::site_name} --user automation --password ${checkmk::automation_user_password} --trust-cert",
        require => [Package['check-mk-agent'], Exec['upgrade checkmk agent'], Create_host[$facts['fqdn']]],
        onlyif  => "/usr/bin/cmk-agent-ctl status --json | grep -q '\"connections\":\\[\\]'",
      }
    }
    default: {
      fail('Unsupported OS family')
    }
  }
}
