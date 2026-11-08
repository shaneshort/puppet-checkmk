# Changelog

## Unreleased

**Bugfixes**

- `agent_package` and `create_host` no longer report a change on every run. Their providers returned the resource
  as `name`, but the types use `file_name`/`host_name` as their namevar, so the Resource API never matched the
  current state and always treated the resource as `absent`. A repeat run (or noop) on a host that is already
  registered, with the agent already installed, now reports nothing.
- `agent_package` no longer re-downloads the package on every run. The download now only happens when the agent
  is not installed, or when the installed `cmk-agent-ctl` version differs from the package the server offers
  (this upgrade path could previously never run, because Puppet treats `present` -> `present` as in sync).
- `create_host` now checks the Checkmk API for the host (read-only, also in noop) instead of always reporting it
  as `present`, and only POSTs when the API says the host is not found.
- Downloads are written to a temporary file and moved into place only after a complete, successful response, so a
  failed download no longer truncates the existing package or saves an HTTP error page as the package.
- Version matching no longer treats a version prefix as a match (`2.2.0p1` vs `2.2.0p12`).

**Behaviour changes**

- API, authentication and network errors now **fail the resource** (and skip dependent resources such as package
  installation and agent registration) instead of logging a warning and reporting success. This includes 404s
  from the download/create endpoints and refused connections. While the Checkmk server is not yet reachable
  (e.g. first bootstrap), the Puppet run reports errors until it is.
- `create_host` with `ensure => absent` fails if the host exists (host deletion is still not implemented),
  instead of logging a warning and reporting success.
- Puppet evaluates an in-sync property twice per run, so an installed agent triggers up to two read-only HEAD
  requests per run, and `create_host` one GET.
- The types now require `puppet-resource_api` >= 1.8.14 (`custom_insync`, and `simple_get_filter` for
  `agent_package`). This is bundled with Puppet 7.25.
- Known limitation (unchanged): when the server offers a newer agent, the new package is downloaded, but the
  `package { 'check-mk-agent': ensure => installed }` resource does not upgrade an installed package, so the
  download repeats each run until the installed version matches the server.

**Testing**

- Replace the stale `get_agent_package` provider spec with specs that drive both types through real Puppet
  transactions, with HTTP (WebMock) and `cmk-agent-ctl --version` stubbed. `webmock` is added as a development
  dependency.

## Release 0.3.3

**Bugfixes**

- Remove puppetlabs/stdlib dependency which was causing type validation error in some environments

## Release 0.3.2

**Bugfixes**

- Remove Stdlib::HTTPSUrl validation due to "unresolved type" errors

## Release 0.3.1

**Bugfixes**

- Use Puppets HTTP Client (causing certificate validation issues)

## Release 0.3.0

**Refactor**

- Move to using Puppet Providers instead of Functions.

**Bugfixes**

- Handle 404 errors and display a warning
- Add validation on site_name as this is being used to create a unix user

## Release 0.2.1

**Bugfixes**

- Fixes and occasional issue where passwords were attempting to be set before the site is created.

## Release 0.2.0

**Features**

- Add ability to set cmkadmin and automation admin account passwords. It is now a requirement for `cmkadmin_user_password` to be set when `mode => 'server'` is used.
- Add ability to only require `version` to be defined, a common URL will be used, but if `download_url` is given, this will be used instead.

**Bugfixes**

- Raise `Puppet::Error` instead of `function_fail` to correctly alert in the Puppet.

**Known Issues**

- `--trust-cert` option is being used during the CheckMK registration process, this isn't an issue where the CheckMK server is using HTTPS as this is skipped ([werk #14715](https://checkmk.com/werk/14715)).
  This can be a potential security issue if the CheckMK server is only configured for HTTP connections.

## Release 0.1.0

Initial release of the module!