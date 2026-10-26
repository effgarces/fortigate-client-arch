# fortigate-client-arch

The client side for logging in to a **FortiGate IKEv2 VPN with an emailed
second factor** using plain strongSwan on Arch Linux / CachyOS:

- the **token prompt**: a small window that asks for the code the gateway
  emails you, and hands it to strongSwan;
- the `strongswan.d` settings that switch the FortiGate behaviour on;
- an example `swanctl.conf` and a troubleshooting guide from a real setup.

It needs a **patched strongSwan** that understands the FortiGate login (stock
strongSwan stops at the second factor with `EAP Success/Failure has data`).
Build or download that package with
[strongswan-fortigate-arch](https://github.com/effgarces/strongswan-fortigate-arch).
This repository contains no strongSwan code and no third-party patches.

## How the prompt works

```
gateway asks for the token
  -> patched eap-gtc runs   fortigate-otp-helper.sh           (as root, inside charon)
     helper writes          /run/fortivpn/otp.request         ("REQUEST <nonce>")
  -> fortivpn-otp-agent     (your desktop session) sees it, opens a window
     you type the code -> agent writes "<nonce> <code>" into /run/fortivpn/otp.pipe
  -> helper prints the code, charon sends it to the gateway
```

The agent must run **inside your desktop session** (it is started by desktop
autostart, not by systemd: a user service can start before the display
variables exist, and then no window can open). Anyone in the `fortivpn` group
can feed codes to the helper, so only add users you trust.

## Install

```bash
# 1. the patched strongswan package from strongswan-fortigate-arch (Releases)
sudo pacman -U strongswan-<version>-x86_64.pkg.tar.zst

# 2. this repo
git clone https://github.com/effgarces/fortigate-client-arch && cd fortigate-client-arch
sudo ./install.sh            # installs zenity, creates the group, adds you to it

# 3. log out and in again (new group; the agent starts with your session)
sudo systemctl restart strongswan
pgrep -af fortivpn-otp-agent    # exactly one process
```

Then copy `examples/swanctl.conf` to `/etc/swanctl/conf.d/fortigate.conf`,
fill in your values, `chmod 600` it, and:

```bash
sudo swanctl --load-all
sudo swanctl --initiate --child fortigate      # a window asks for the emailed code
sudo swanctl --list-sas
sudo swanctl --terminate --ike fortigate       # disconnect
```

To keep `pacman -Syu` from replacing the patched package, add
`IgnorePkg = strongswan` to `/etc/pacman.conf` (and install new releases yourself).

An older setup (systemd user service, `fortivpn-nm` scripts): `install.sh`
uses the same file names, so it replaces them in place. Also run
`systemctl --user disable --now fortivpn-otp-agent` once.

`sudo ./uninstall.sh` removes everything the installer added.

## Settings (`/etc/strongswan.d/fortigate.conf`)

Start with `fortigate_auth_key = skp`. If the gateway rejects the final
authentication after you type the code, try `msk` (or remove the line), then
`psk`. The log line `FortiGate: AUTH keyed from ...` shows which is in use.
The other options (`fortigate_suppress_eap_only`, `fortigate_send_forticlient_vid`,
`fortigate_fct_file`) make strongSwan look more like FortiClient; leave them
off unless the gateway insists, and check your organisation allows it.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Gateway never answers after the first `IKE_AUTH` | Do not authenticate yourself with the PSK: `local { auth = eap-mschapv2 }` only; the PSK is only for `remote`. |
| `no EAP key found for hosts ... - 'USER'` | The secret section name must start with `eap` and its `id` must equal `eap_id`. (`type = ...` is not a swanctl option.) |
| `EAP Success/Failure has data` | The strongSwan in use is not the patched build. `install.sh` warns about it. |
| Log stops at `EAP-GTC: invoking OTP helper`, no window | Agent not running in this session, or missing group: `pgrep -af fortivpn-otp-agent`, `id` (needs `fortivpn`; log out/in), `journalctl -u strongswan -e \| grep otp-helper`. Start `fortivpn-otp-agent` in a terminal to see why. |
| Agent says `zenity failed ... cannot open display` | It was started without a display (e.g. as a systemd service). Use the desktop autostart entry installed here. |
| No window, helper says `cannot write /run/fortivpn/otp.request` | `sudo systemd-tmpfiles --create /etc/tmpfiles.d/fortivpn.conf` |
| `resolvconf ... Could not activate remote peer 'org.freedesktop.network1'`, `adding DNS server failed` | Harmless: the gateway pushed DNS servers and strongSwan's `resolve` plugin could not install them. Silence it with `load = no` in `/etc/strongswan.d/charon/resolve.conf`. |
| Tunnel up but a server is unreachable | It is probably not in `remote_ts`; add it and reconnect. |
| `TS_UNACCEPTABLE` | The gateway refuses a network you proposed; ask for the exact list. |

## Tests

`tests/run.sh` checks the helper/agent handoff (normal, agent starting late, cancel,
display failure, stale and wrong-nonce requests) and the installer, using a stub
dialog, so it needs no desktop. It runs in CI.

## License

MIT (see `LICENSE`). The helper and agent are written for this repository;
they are compatible in purpose with the helper scripts in other FortiGate/strongSwan
projects but share no code with them.
