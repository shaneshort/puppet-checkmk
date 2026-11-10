# @summary Installs CheckMK Server
class checkmk::install::server {
  if $checkmk::cmkadmin_user_password == undef {
    fail("cmkadmin_user_password must be defined when `mode => 'server'` is used")
  }

  case $facts['os']['family'] {
    'Debian': {
      # Checkmk 2.5 renamed the free edition package from `check-mk-raw` to `check-mk-community`.
      # Only versions that clearly parse as older than 2.5 use `raw`; everything else is `community`.
      $version_parts = $checkmk::version.match(/^(\d+)\.(\d+)/)
      $edition = ($version_parts and versioncmp("${version_parts[1]}.${version_parts[2]}", '2.5') < 0) ? {
        true    => 'raw',
        default => 'community',
      }

      if $checkmk::download_url {
        $download_url = $checkmk::download_url
      } else {
        $download_url = "https://download.checkmk.com/checkmk/${checkmk::version}/check-mk-${edition}-${checkmk::version}_0.${facts['os']['distro']['codename']}_amd64.deb"
      }

      file { "/tmp/check-mk-${edition}.deb":
        ensure         => file,
        source         => $download_url,
        checksum       => 'sha256',
        checksum_value => $checkmk::sha256_hash,
      }

      package { "check-mk-${edition}-${checkmk::version}":
        ensure   => installed,
        provider => 'apt',
        source   => "/tmp/check-mk-${edition}.deb",
        require  => File["/tmp/check-mk-${edition}.deb"],
      }

      exec { "create omd site ${checkmk::site_name}":
        command => "/usr/bin/omd create ${checkmk::site_name}",
        creates => "/opt/omd/sites/${checkmk::site_name}",
        require => Package["check-mk-${edition}-${checkmk::version}"],
      }

      exec { 'checkmk_cmkadmin_password':
        command     => "/usr/bin/htpasswd -b /opt/omd/sites/${checkmk::site_name}/etc/htpasswd cmkadmin ${checkmk::cmkadmin_user_password}",
        refreshonly => true,
        require     => Exec["create omd site ${checkmk::site_name}"],
        subscribe   => Exec["create omd site ${checkmk::site_name}"],
      }

      file { "/opt/omd/sites/${checkmk::site_name}/var/check_mk/web/automation/automation.secret":
        ensure  => file,
        # OMD creates this file owned by the site user (same name as the site) and Checkmk flags any other
        # owner or mode as incorrect, so keep it that way.
        owner   => $checkmk::site_name,
        group   => $checkmk::site_name,
        mode    => '0660',
        content => inline_epp('<%= $automation_user_password %>', { 'automation_user_password' => $checkmk::automation_user_password }), # Sensitive.new($checkmk::automation_user_password)
        require => Exec["create omd site ${checkmk::site_name}"],
      }

      exec { "start odm site ${checkmk::site_name}":
        command => "/usr/bin/omd start ${checkmk::site_name}",
        require => Exec["create omd site ${checkmk::site_name}"],
        unless  => "/usr/bin/omd status ${checkmk::site_name}",
      }
    }
    default: {
      fail('Unsupported OS family')
    }
  }
}
