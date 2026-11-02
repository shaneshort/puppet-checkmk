# @summary Downloads the CheckMK Agent
class checkmk::install::agent::create_host {
  $host_created = Deferred('checkmk::create_host',
    [
      "${checkmk::agent_download_protocol}://${checkmk::agent_download_host}",
      $checkmk::automation_user_password,
      $checkmk::site_name,
      $checkmk::agent_folder,
      $checkmk::hostname,
    ]
  )

  checkmk_status { 'Checkmk host created':
    message  => $host_created,
    loglevel => debug,
  }
}
