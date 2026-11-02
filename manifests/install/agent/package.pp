# @summary Downloads the CheckMK Agent
class checkmk::install::agent::package {
  $package_downloaded = Deferred('checkmk::get_agent_package',
    [
      "${checkmk::agent_download_protocol}://${checkmk::agent_download_host}",
      $checkmk::automation_user_password,
      $checkmk::site_name,
      'linux_deb',
      '/tmp/check-mk-agent.deb',
    ]
  )

  checkmk_status { 'Checkmk agent downloaded':
    message  => $package_downloaded,
    loglevel => debug,
  }
}
