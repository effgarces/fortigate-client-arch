#!/usr/bin/env bash
# Removes what install.sh put in place. Leaves the fortivpn group, your
# /etc/strongswan.d/fortigate.conf and anything under /etc/swanctl alone.
set -eu
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
rm -fv /usr/local/sbin/fortigate-otp-helper.sh /usr/local/bin/fortivpn-otp-agent \
       /etc/xdg/autostart/fortivpn-otp-agent.desktop /etc/tmpfiles.d/fortivpn.conf \
       /etc/strongswan.d/eap-gtc-otp.conf
rm -rfv /run/fortivpn
echo "Removed. Log out and in to stop the running agent (or: pkill -f fortivpn-otp-agent)."
