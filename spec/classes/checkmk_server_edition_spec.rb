# frozen_string_literal: true

require 'spec_helper'

# Checkmk 2.5 renamed the free edition package from check-mk-raw to check-mk-community.
describe 'checkmk' do
  let(:facts) do
    {
      os: { family: 'Debian', name: 'Ubuntu', distro: { codename: 'noble' }, release: { major: '24.04', full: '24.04' } },
      fqdn: 'monitoring-01.example.com',
      networking: { fqdn: 'monitoring-01.example.com', hostname: 'monitoring-01' },
    }
  end
  let(:base_params) do
    { 'mode' => 'server', 'cmkadmin_user_password' => 'pw', 'automation_user_password' => 'pw', 'hostname' => 'monitoring-01.example.com', 'site_name' => 'cmk' }
  end

  {
    '2.5.0p18' => 'community',
    '2.5.0' => 'community',
    '2.10.0p1' => 'community',
    '3.0.0' => 'community',
    '2.4.0p1' => 'raw',
    '2.1.0p14' => 'raw',
  }.each do |version, edition|
    context "version #{version}" do
      let(:params) { base_params.merge('version' => version) }

      it { is_expected.to compile }
      it { is_expected.to contain_file("/tmp/check-mk-#{edition}.deb").with_source(%r{/check-mk-#{edition}-#{Regexp.escape(version)}_0\.noble_amd64\.deb\z}) }
      it { is_expected.to contain_package("check-mk-#{edition}-#{version}").with_source("/tmp/check-mk-#{edition}.deb") }
      it { is_expected.to contain_exec('create omd site cmk').that_requires("Package[check-mk-#{edition}-#{version}]") }
    end
  end

  context 'with an explicit download_url' do
    let(:params) { base_params.merge('version' => '2.5.0p18', 'download_url' => 'https://example.com/x.deb') }

    it { is_expected.to contain_file('/tmp/check-mk-community.deb').with_source('https://example.com/x.deb') }
  end
end
