#!/usr/bin/env python3
"""fortivpn-otp-agent - shows the 2FA prompt for the patched strongSwan.

Runs inside YOUR desktop session (start it from the desktop's autostart, not
from a systemd user service: a service can start before the display
variables exist, and then the dialog cannot open).

It watches $FORTIVPN_RUN/otp.request (written by fortigate-otp-helper.sh),
asks for the code with zenity (or kdialog) and writes "<nonce> <code>" into
the FIFO $FORTIVPN_RUN/otp.pipe.  Requests that are older than the helper's
timeout are ignored; a request that is already waiting when the agent starts
is answered.
"""
import errno
import os
import re
import shutil
import subprocess
import sys
import time

RUN = os.environ.get("FORTIVPN_RUN", "/run/fortivpn")
REQ = os.path.join(RUN, "otp.request")
PIPE = os.path.join(RUN, "otp.pipe")
TIMEOUT = int(os.environ.get("OTP_TIMEOUT", "90"))
POLL = float(os.environ.get("OTP_POLL", "0.5"))
REQ_RE = re.compile(r"^REQUEST (\S+)$")
CODE_RE = re.compile(r"^[0-9A-Za-z]{4,16}$")
TITLE = "FortiGate VPN - 2FA"
TEXT = "Enter the code from your email:"


def log(msg):
    print(f"otp-agent: {msg}", file=sys.stderr, flush=True)


def dialog_command():
    if shutil.which("zenity"):
        return ["zenity", "--entry", "--title", TITLE, "--text", TEXT, "--width", "320"]
    if shutil.which("kdialog"):
        return ["kdialog", "--title", TITLE, "--inputbox", TEXT]
    return None


def ask_code(deadline):
    cmd = dialog_command()
    if not cmd:
        log("neither zenity nor kdialog is installed (pacman -S zenity)")
        return None
    try:
        res = subprocess.run(cmd, capture_output=True, text=True,
                             timeout=max(5, deadline - time.time()))
    except subprocess.TimeoutExpired:
        log("prompt timed out")
        return None
    except OSError as e:
        log(f"cannot run {cmd[0]}: {e}")
        return None
    if res.returncode != 0:
        err = res.stderr.strip().splitlines()
        # a plain cancel prints nothing; anything else is a real failure
        if err:
            log(f"{cmd[0]} failed (exit {res.returncode}): {err[0]}  "
                f"[DISPLAY={os.environ.get('DISPLAY')} "
                f"WAYLAND_DISPLAY={os.environ.get('WAYLAND_DISPLAY')}]")
        else:
            log("prompt cancelled")
        return None
    code = "".join(ch for ch in res.stdout if ch.isalnum())
    if not CODE_RE.match(code):
        log("that does not look like a code (4-16 letters/digits), ignoring")
        return None
    return code


def deliver(nonce, code, deadline):
    """Write to the FIFO; wait (politely) until the helper is reading it."""
    while time.time() < deadline:
        try:
            fd = os.open(PIPE, os.O_WRONLY | os.O_NONBLOCK)
        except OSError as e:
            if e.errno in (errno.ENXIO, errno.EINTR):   # nobody reading yet
                time.sleep(0.2)
                continue
            log(f"cannot open {PIPE}: {e}")
            return False
        try:
            os.write(fd, f"{nonce} {code}\n".encode())
        finally:
            os.close(fd)
        return True
    log("the helper stopped waiting before the code was delivered")
    return False


def main():
    log(f"started; watching {REQ}")
    handled = set()
    last_err = None
    while True:
        try:
            st = os.stat(REQ)
            with open(REQ) as f:
                text = f.read().strip()
            last_err = None
        except OSError as e:
            if str(e) != last_err:      # say why, once, instead of retrying silently
                last_err = str(e)
                log(f"cannot read {REQ}: {e} -- is this user in the 'fortivpn' group "
                    f"in THIS session (run 'id')? did systemd-tmpfiles create {RUN}?")
            time.sleep(POLL * 2)
            continue
        m = REQ_RE.match(text)
        if m and m.group(1) not in handled:
            nonce = m.group(1)
            handled.add(nonce)
            deadline = st.st_mtime + TIMEOUT
            if time.time() > deadline:
                log(f"ignoring stale request {nonce}")
            else:
                log(f"code requested ({nonce})")
                code = ask_code(deadline)
                if code and deliver(nonce, code, deadline + 2):
                    log(f"code delivered ({code[:2]}...)")
        time.sleep(POLL)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
