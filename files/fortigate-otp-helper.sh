#!/usr/bin/env bash
# otp_helper for the patched strongSwan eap-gtc plugin.
# charon runs this when the gateway asks for the second factor; whatever it
# prints on stdout (first line) is sent to the gateway as the answer.
#
# It cannot show a window itself (charon runs as root, outside your desktop),
# so it posts a request and waits for fortivpn-otp-agent, which runs in your
# session, to hand back the code through a FIFO.
set -u
RUN="${FORTIVPN_RUN:-/run/fortivpn}"
PIPE="$RUN/otp.pipe"
REQ="$RUN/otp.request"
TIMEOUT="${OTP_TIMEOUT:-90}"
log() { printf 'otp-helper: %s\n' "$*" >&2; }

# normally created at boot by systemd-tmpfiles; recreate if it is missing
mkdir -p "$RUN" 2>/dev/null || true
if [ ! -p "$PIPE" ]; then
  rm -f "$PIPE"
  mkfifo -m 660 "$PIPE" || { log "cannot create $PIPE"; exit 1; }
  chgrp fortivpn "$PIPE" 2>/dev/null || true
fi

nonce="$(date +%s)-$$-$RANDOM"
printf 'REQUEST %s\n' "$nonce" > "$REQ" 2>/dev/null || { log "cannot write $REQ"; exit 1; }
chgrp fortivpn "$REQ" 2>/dev/null || true
chmod 660 "$REQ" 2>/dev/null || true
log "request posted, waiting up to ${TIMEOUT}s for the code"

deadline=$((SECONDS + TIMEOUT))
while [ "$SECONDS" -lt "$deadline" ]; do
  line="$(timeout "$((deadline - SECONDS))" head -n1 "$PIPE" 2>/dev/null)" || line=""
  if [ -z "$line" ]; then sleep 0.1; continue; fi
  got="${line%% *}"
  code="$(printf '%s' "${line#* }" | tr -cd '[:alnum:]')"
  if [ "$got" = "$nonce" ] && [[ "$code" =~ ^[0-9A-Za-z]{4,16}$ ]]; then
    log "received a code (${code:0:2}...)"
    printf '%s\n' "$code"
    exit 0
  fi
  log "ignored an answer for a different request"
done
log "timed out waiting for the code"
exit 1
