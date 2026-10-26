#!/usr/bin/env bash
# Arch/CachyOS installer for the token-prompt side of the patched strongSwan.
# usage: sudo ./install.sh [username]      (defaults to the user who ran sudo)
#
# Installs: the OTP helper (called by charon), the prompt agent (autostarted in
# your desktop session), the /run/fortivpn handoff directory and the
# strongswan.d settings.  It does NOT touch /etc/swanctl, and it does NOT give
# any group access to strongSwan's control socket (use sudo for swanctl).
set -eu
# root is only required for a real install (DESTDIR is used by the tests, which run unprivileged)
[ -n "${DESTDIR:-}" ] || [ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"
U="${1:-${SUDO_USER:-}}"
[ -n "$U" ] || { echo "usage: sudo ./install.sh <username>" >&2; exit 1; }
D="${DESTDIR:-}"     # DESTDIR is only used by the tests

if [ -z "$D" ]; then
  pacman -S --needed zenity python
  getent group fortivpn >/dev/null || groupadd --system fortivpn
  id -nG "$U" | tr ' ' '\n' | grep -qx fortivpn || usermod -aG fortivpn "$U"
fi

install -Dm755 "$HERE/files/fortigate-otp-helper.sh"   "$D/usr/local/sbin/fortigate-otp-helper.sh"
install -Dm755 "$HERE/files/fortivpn-otp-agent.py"     "$D/usr/local/bin/fortivpn-otp-agent"
install -Dm644 "$HERE/files/fortivpn-otp-agent.desktop" "$D/etc/xdg/autostart/fortivpn-otp-agent.desktop"
install -Dm644 "$HERE/files/fortivpn.tmpfiles.conf"    "$D/etc/tmpfiles.d/fortivpn.conf"
install -Dm644 "$HERE/files/eap-gtc-otp.conf"          "$D/etc/strongswan.d/eap-gtc-otp.conf"
# keep an existing fortigate.conf: you may have tuned it
[ -e "$D/etc/strongswan.d/fortigate.conf" ] || \
  install -Dm644 "$HERE/files/fortigate.conf"          "$D/etc/strongswan.d/fortigate.conf"
# an older setup used a systemd user service; it fails (no display yet at login)
rm -f "$D/etc/systemd/user/fortivpn-otp-agent.service"

if [ -z "$D" ]; then
  systemd-tmpfiles --create /etc/tmpfiles.d/fortivpn.conf
  grep -Eq '^\s*include\s+strongswan\.d/\*\.conf' /etc/strongswan.conf 2>/dev/null || \
    echo "WARNING: /etc/strongswan.conf does not include strongswan.d/*.conf - add: include strongswan.d/*.conf"
  so="$(pacman -Ql strongswan 2>/dev/null | awk '/eap-gtc\.so$/ {print $2; exit}')"
  if [ -z "$so" ]; then
    echo "WARNING: could not find strongswan's eap-gtc plugin - is strongswan installed?"
  elif ! grep -aq otp_helper "$so"; then
    echo "WARNING: the installed strongswan is NOT the patched build (no otp_helper in $so)."
    echo "         Install the package from strongswan-fortigate-arch first."
  fi
  echo
  echo "Done. Next:"
  echo "  1. If you used an older setup: as your user run"
  echo "       systemctl --user disable --now fortivpn-otp-agent"
  echo "  2. Log out and in again (new group; the agent starts with your session)."
  echo "  3. sudo systemctl restart strongswan"
  echo "  Check: pgrep -af fortivpn-otp-agent    (exactly one process)"
fi
