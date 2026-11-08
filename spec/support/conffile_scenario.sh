#!/bin/sh
# usage: scenario.sh '<install command with {DEB} placeholder>'
# Simulates: check-mk-agent 2.2.0p10-1 installed, admin edited its conffile, server now offers 2.2.0p12-1
CMD="$1"
export DEBIAN_FRONTEND=noninteractive
mk() { d=/tmp/build-$1; rm -rf $d; mkdir -p $d/DEBIAN $d/etc/fakeagent; echo "$2" > $d/etc/fakeagent/agent.conf
  printf 'Package: check-mk-agent\nVersion: %s\nArchitecture: all\nMaintainer: t <t@example.com>\nDescription: fake\n' "$1" > $d/DEBIAN/control
  echo /etc/fakeagent/agent.conf > $d/DEBIAN/conffiles; dpkg-deb --build $d /tmp/pkg-$1.deb >/dev/null; }
mk 2.2.0p10-1 "shipped=v10"; mk 2.2.0p12-1 "shipped=v12"
apt-get install -y /tmp/pkg-2.2.0p10-1.deb >/dev/null 2>&1 || { echo "SETUP FAILED"; exit 99; }
echo "local-edit=keep-me" > /etc/fakeagent/agent.conf
RUN=$(echo "$CMD" | sed "s#{DEB}#/tmp/pkg-2.2.0p12-1.deb#")
sh -c "$RUN" </dev/null >/tmp/out.log 2>&1; rc=$?
echo "exit=$rc installed=$(dpkg-query -W -f='${Version}' check-mk-agent) conffile=[$(cat /etc/fakeagent/agent.conf)]"
[ $rc -ne 0 ] && tail -3 /tmp/out.log | sed 's/^/   log: /'
exit 0
