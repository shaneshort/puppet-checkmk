# Changelog

## Unreleased

**Bugfixes**

- Fix catalogue compilation failing on Puppet Server with `Could not autoload puppet/type/agent_package: no such file
  to load -- puppet_x/checkmk/requirements`. Puppet Server (JRuby) does not put a module's `lib/` directory on
  `$LOAD_PATH`, so the types now load their helper with `require_relative`. This broke every node using the module
  after the Resource API requirement check was added; rspec, `puppet apply` and agents all have `lib/` on the path, so
  none of the earlier tests saw it. A regression spec now loads each type in a clean Ruby process without the module on
  the load path. Verified on real Puppet Servers (7.9.2: compiles; 7.1.0 with an old Resource API: explicit
  requirement error).

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
- The types now require `puppet-resource_api` >= 1.8.14 (`custom_insync`; `simple_get_filter` for `agent_package`).
  puppet-agent bundles that from 7.8.0 (and 6.23.0); 6.21-6.22 and 7.0-7.7 bundle 1.8.13. Unsupported versions are
  now rejected with an explicit error when the types load (previously: `Unknown feature detected` followed by
  `wrong number of arguments`). `metadata.json` now requires Puppet `>= 7.8.0 < 8.0.0` (was `>= 6.21.0`); Puppet 6
  was not tested.
- New `Exec['upgrade checkmk agent']` in `checkmk::install::agent`. `package { ensure => installed }` never upgrades
  an installed package, so a downloaded package for a different agent version was never installed and was
  downloaded again on every run. The exec (`refreshonly`, subscribed to `Agent_package`, guarded by a
  `dpkg-deb`/`dpkg-query` version comparison, using `apt-get install --allow-downgrades`) installs it, so the run
  converges. It runs after the `package` resource and before agent registration. If the install fails, the run
  fails, registration is skipped, and the next run retries.

**Testing**

- Replace the stale `get_agent_package` provider spec with specs that drive both types through real Puppet
  transactions, with HTTP (WebMock) and `cmk-agent-ctl --version` stubbed. `webmock` is added as a development
  dependency.
- Add a lifecycle spec that compiles the real `checkmk` class and applies it as Puppet transactions against a
  simulated host and Checkmk server: fresh install, then a server-side upgrade (and downgrade, and a failed
  install), checking the second apply and noop are quiet. The installed version only changes through an install
  action performed by the module. The spec uses the hard-coded `/tmp/check-mk-agent.deb` and skips itself if that
  file already exists.

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