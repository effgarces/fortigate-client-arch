#!/usr/bin/env bash
# Tests the helper <-> agent handoff and the installer with a stub dialog.
set -u
cd "$(dirname "$0")/.."
ROOT="$PWD"
T="$(mktemp -d)"; PIDS=""
cleanup() { for p in $PIDS; do kill "$p" 2>/dev/null || true; done; rm -rf "$T"; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; [ -f "$T/agent.log" ] && sed 's/^/  agent: /' "$T/agent.log" >&2; exit 1; }
pass() { echo "ok   $*"; }

export FORTIVPN_RUN="$T/run" OTP_TIMEOUT=6 OTP_POLL=0.2 ZEN_LOG="$T/zen.log"
mkdir -p "$T/bin"
cat > "$T/bin/zenity" <<'STUB'
#!/bin/sh
echo called >> "$ZEN_LOG"
case "${ZEN_MODE:-ok}" in
  ok) echo "${ZEN_CODE:-482913}" ;;
  cancel) exit 1 ;;
  nodisplay) echo "Gtk-WARNING **: cannot open display:" >&2; exit 1 ;;
esac
STUB
chmod +x "$T/bin/zenity"

fresh() {   # new runtime dir, no agent
  for p in $PIDS; do kill "$p" 2>/dev/null || true; done; PIDS=""
  rm -rf "$T/run" "$ZEN_LOG" "$T/agent.log"; mkdir -p "$T/run"
  mkfifo "$T/run/otp.pipe"; : > "$T/run/otp.request"
}
start_agent() {
  PATH="$T/bin:$PATH" python3 -I "$ROOT/files/fortivpn-otp-agent.py" 2>"$T/agent.log" & PIDS="$PIDS $!"
}
helper() { "$ROOT/files/fortigate-otp-helper.sh" 2>"$T/helper.log"; }

# 1 normal
fresh; start_agent; sleep 0.5
out="$(helper)" || fail "helper failed"
[ "$out" = 482913 ] || fail "wrong code: '$out'"
pass "agent running first: code reaches the helper"

# 2 agent started AFTER the request was posted (the bug of the first agent)
fresh; helper > "$T/out" & hp=$!; sleep 1; start_agent; wait "$hp" || fail "late agent: helper failed"
[ "$(cat "$T/out")" = 482913 ] || fail "late agent: wrong code"
pass "request already waiting when the agent starts is answered"

# 3 cancel -> helper times out with non-zero
fresh; export ZEN_MODE=cancel OTP_TIMEOUT=3; start_agent; sleep 0.5
helper >/dev/null && fail "helper should fail after cancel"
grep -q "prompt cancelled" "$T/agent.log" || fail "cancel not logged"
pass "cancelled prompt: helper exits non-zero, agent logs it"

# 4 dialog cannot open (the systemd-service symptom): reported, not 'cancelled'
fresh; export ZEN_MODE=nodisplay OTP_TIMEOUT=3; start_agent; sleep 0.5
helper >/dev/null && fail "helper should fail without display"
grep -q "cannot open display" "$T/agent.log" || fail "display error not logged"
pass "display failure is reported with its reason"
unset ZEN_MODE; export OTP_TIMEOUT=6

# 5 stale request is ignored
fresh; printf 'REQUEST old-1\n' > "$T/run/otp.request"; touch -d '10 minutes ago' "$T/run/otp.request"
start_agent; sleep 1.2
[ ! -e "$ZEN_LOG" ] || fail "stale request opened a dialog"
grep -q "stale" "$T/agent.log" || fail "stale not logged"
pass "stale request ignored"

# 6 a code for another request is ignored; the right one still arrives
fresh; helper > "$T/out" & hp=$!; sleep 1
timeout 3 sh -c "echo 'bogus 111111' > '$T/run/otp.pipe'" || true
sleep 0.5; start_agent; wait "$hp" || fail "wrong-nonce: helper failed"
[ "$(cat "$T/out")" = 482913 ] || fail "wrong-nonce: took the wrong code ($(cat "$T/out"))"
grep -q "different request" "$T/helper.log" || fail "wrong-nonce not logged"
pass "answer for a different request is rejected"

# 7 missing FIFO is recreated
fresh; rm -f "$T/run/otp.pipe"; OTP_TIMEOUT=2 helper >/dev/null && fail "should time out"
[ -p "$T/run/otp.pipe" ] || fail "FIFO not recreated"
pass "helper recreates a missing FIFO"

# 8 installer (staging directory)
D="$T/stage"; DESTDIR="$D" ./install.sh tester >/dev/null || fail "install.sh failed"
for f in usr/local/sbin/fortigate-otp-helper.sh usr/local/bin/fortivpn-otp-agent \
         etc/xdg/autostart/fortivpn-otp-agent.desktop etc/tmpfiles.d/fortivpn.conf \
         etc/strongswan.d/eap-gtc-otp.conf etc/strongswan.d/fortigate.conf; do
  [ -f "$D/$f" ] || fail "missing $f"
done
[ -x "$D/usr/local/sbin/fortigate-otp-helper.sh" ] && [ -x "$D/usr/local/bin/fortivpn-otp-agent" ] || fail "not executable"
grep -q "otp_helper = /usr/local/sbin/fortigate-otp-helper.sh" "$D/etc/strongswan.d/eap-gtc-otp.conf" || fail "helper path"
echo "# tuned" >> "$D/etc/strongswan.d/fortigate.conf"; DESTDIR="$D" ./install.sh tester >/dev/null
grep -q "# tuned" "$D/etc/strongswan.d/fortigate.conf" || fail "fortigate.conf overwritten"
pass "installer: files, modes, helper path, keeps a tuned fortigate.conf"
echo "all tests passed"
