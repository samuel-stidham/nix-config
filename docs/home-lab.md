# The home lab

Forgejo and Atlantis, reachable from any device on the tailnet, with real
certificates and no open ports. This is the layer that makes CI/CD usable from
the MacBook instead of only from the desk it runs on.

## The two naming schemes

| name | resolves via | → | certificate | works offline |
| --- | --- | --- | --- | --- |
| `<site>.test` | dnsmasq in `nix run .#sites` | `127.0.0.1` | self-signed, warns | **yes** |
| `<name>.home.samuelstidham.me` | Cloudflare, public DNS | `100.68.26.36` | real wildcard | no |

Both are served by the same nginx and, for dev sites, the same files in
`~/sites/<name>`. They are not redundant.

`.test` stays because it needs no internet at all. On a plane, it still works. No
certificate authority will ever issue for `.test`, so it is self-signed forever.

`.home.samuelstidham.me` exists because it does the two things `.test` cannot: it
carries a real certificate, and it is reachable from the MacBook. `127.0.0.1`
means nothing on another machine.

## Tailscale

Every device gets an address out of `100.64.0.0/10`. That range is CGNAT and is
**not routable on the public internet**. That single fact is what makes this whole
design safe rather than reckless.

| machine | tailnet address |
| --- | --- |
| this desktop | `100.68.26.36` |
| MacBook Pro M4 | `100.116.77.69` |

Both must be on the tailnet under **`samuelstidham7@gmail.com`**, not the usual
`dqfan2012@gmail.com`. Signing a machine in with the wrong account silently
creates a second tailnet. Everything looks connected, the machine gets a `100.x`
address, and the peers never see each other. Check
https://login.tailscale.com/admin/machines, both must appear in one list.

`bootstrap.sh tailscale_net` installs it. Authenticating is a state change and is
yours to run: `sudo tailscale up`.

## DNS

Managed by OpenTofu in the `samuelstidham` repo, `infra/dns.tf`, applied through
Atlantis. Not the dashboard. The same two records were hand made twice and were
wrong both times, pointing at a tailnet that does not exist.

```
*.home.samuelstidham.me     A   100.68.26.36     DNS only
mac.home.samuelstidham.me   A   100.116.77.69    DNS only
```

The wildcard is why adding a dev site is just `mkdir ~/sites/blog`. The name
resolves, the certificate already covers it, and nginx matches it with a regex
vhost. No record, no cert run, no PR.

`mac.home` is the only exception, and it must stay exact. A more specific name
beats a wildcard (RFC 4592), and that record is the only thing keeping `mac.home`
off the desktop's address. **Its absence does not fail loudly.** Delete it and
`mac.home` silently resolves to `100.68.26.36`, the wrong machine, because the
wildcard answers. There is no NXDOMAIN to notice.

`proxied` must stay **false**, the grey cloud. This is not a preference. Orange
cloud cannot work here and fails two independent ways: Cloudflare's edge has no
route to a CGNAT address (**error 522**), and a CNAME to a MagicDNS name would not
resolve for its resolvers at all (**error 1016**), since `*.ts.net` answers only
inside the tailnet.

A records rather than CNAMEs to the `.ts.net` names, on purpose. A CNAME makes
every lookup depend on MagicDNS chasing the target across a split-DNS scope. That
is fragile and produced a cached NXDOMAIN during setup. An A record needs no DNS
cooperation from Tailscale, only routing.

These records are public and that is fine. The addresses are unroutable, so
knowing them buys nothing. Verified from a phone on the same WiFi with Tailscale
off: the name resolved, nothing loaded.

## The certificate

A Let's Encrypt wildcard for `*.home.samuelstidham.me`, from
[scripts/home-certs.sh](../scripts/home-certs.sh), renewed daily by the timer in
[home/home-certs.nix](../home/home-certs.nix).

**DNS-01, because HTTP-01 is impossible here.** HTTP-01 needs Let's Encrypt to
connect to this machine. It cannot reach a CGNAT address any more than an attacker
can. The property that makes this safe also rules out the normal path. DNS-01
proves control by writing a TXT record, and it is the only challenge that can
issue a wildcard.

**The wildcard is the private option, not just the convenient one.** Every hostname
in a certificate is published permanently to public Certificate Transparency logs.
Individual certificates would announce `forgejo.home.samuelstidham.me` to anyone
looking. A wildcard announces nothing about what runs behind it.

The Cloudflare token comes from `passage cloudflare/api-token` at run time. It is
**IP filtered** to this house, so a changed home address fails as Cloudflare
**error 9109**, which reads like a permissions problem and is not. Fix the token's
client IP filter, do not widen its scope.

The ACME email comes from `CERT_EMAIL`, falling back to safetybox
`global/acme-email`. That order matters. A systemd user unit never sources the
fish profile, so anything `secrets.fish` exports is invisible to the timer.

```bash
./scripts/home-certs.sh --staging    # prove the path, no rate limit spent
./scripts/home-certs.sh              # issue or renew
./scripts/home-certs.sh --force      # reissue even if fresh
```

**Always `--staging` first when changing anything.** Let's Encrypt allows five
duplicate certificates per week and the lockout is not negotiable. Staging proves
the token, the DNS write, propagation, and cleanup for free.

The renewal reloads nginx. Without that the file on disk would be fresh and the
certificate being served would be expired, which is a failure that arrives in
three months with no obvious cause.

## nginx

One nginx, in [home/web.nix](../home/web.nix), as a **systemd user service**.

It used to live in the `sites` process-compose stack, started by hand. That was
fine when it only served dev sites. It is not fine now that it fronts Forgejo:
HTTPS to the git server cannot depend on a terminal being open. php-fpm stayed in
the dev stack, so a dev site returns **502** when that stack is down. That is the
honest answer, and Forgejo is unaffected.

**Port 443 has exactly one owner.** A listener on `0.0.0.0:443` blocks every
specific-address bind on the machine. Verified, not assumed:

```python
s.bind(("100.68.26.36", 443))
# OSError: [Errno 98] Address already in use
```

So splitting by address does not work, and one nginx serves everything. It tells
the services apart by SNI, which is what turns Tailscale's one MagicDNS name per
machine into as many service names as we want.

Three things in that config are load bearing and non-obvious:

`X-Forwarded-Proto https`, or Forgejo believes the request arrived over plain
http and redirects https clients back to http, which loops.

The `$connection_upgrade` map plus `proxy_http_version 1.1`, or websockets never
upgrade. Atlantis streams live plan output to `/jobs/<id>` over one, so the page
loads and stays blank forever, which reads as Atlantis being broken.

`proxy_request_buffering off` and `proxy_buffering off`, or nginx spools an entire
git push to disk before forwarding a byte. On a large push that is a long silence
that reads as a hang. `client_max_body_size 0` removes the size limit but not the
buffering. Verified with a 58MB push that took two seconds.

## Forgejo's canonical URL

```
FORGEJO__server__ROOT_URL=https://forgejo.home.samuelstidham.me/
FORGEJO__server__SSH_DOMAIN=forgejo.home.samuelstidham.me
FORGEJO__server__SSH_PORT=222
```

Forgejo serves whatever name it is reached by, but builds every link, redirect,
clone URL and webhook payload from `ROOT_URL`. Set it wrong and the UI warns while
clone URLs point somewhere the MacBook cannot resolve.

**`ROOT_URL` is coupled to Atlantis's `--repo-allowlist`.** Atlantis matches the
repo host out of the webhook payload, and Forgejo builds that payload from
`ROOT_URL`. Change one without the other and Atlantis silently ignores every pull
request as not allowlisted. There is no error. It just stops working.

`--gitea-base-url` deliberately stays `http://forgejo.test:3000`. That is how
Atlantis reaches Forgejo's API from inside the container. It is a private path
between two containers on this box, and has no reason to leave for the tailnet,
get TLS terminated, and come back.

`forgejo.test:3000` still works, so existing local clones are unaffected.

## The firewall

`bootstrap.sh firewall_tailnet_only` prints the rules. They are a state change and
can lock you out of ssh, so they are yours to run.

The services were never reachable from the internet. The real exposure was the
LAN: Forgejo and Atlantis bound every interface, so anything on the WiFi reached
`http://192.168.1.200:4141` with no TLS and no auth.

Deny inbound by default and allow `tailscale0`. Not per-port rules on the LAN
NICs: there are two of them, `wlp6s0` and `enp7s0`, and the static IP follows
whichever is live, so naming interfaces to block is whack-a-mole.

**A default deny policy is only a default.** Blanket `ALLOW 3000/tcp Anywhere`
rules sat above it and were the entire reason the LAN could reach Forgejo.
Enabling a firewall means nothing without auditing what is already permitted.

**You cannot test this from this machine.** Traffic to your own LAN address routes
over loopback:

```
$ ip route get 192.168.1.200
local 192.168.1.200 dev lo ...
```

ufw allows loopback unconditionally, so it answers 200 whether the LAN is blocked
or not. Use a phone with WiFi on and Tailscale off, or you are testing nothing.

## Commands

```bash
systemctl --user status nginx           # the one that serves everything
systemctl --user reload nginx           # after a cert change
systemctl --user list-timers home-certs # daily renewal check
./scripts/home-certs.sh --staging       # safe rehearsal
tailscale status                        # both machines, both Connected
tailscale ping 100.116.77.69            # reachability to the mac
```

Check what the certificate actually covers and when it dies:

```bash
openssl x509 -in ~/.local/share/dev-services/certs/home.samuelstidham.me.crt \
  -noout -ext subjectAltName -enddate -issuer
```

`issuer` containing `(STAGING)` means a rehearsal cert is being served. It is
untrusted by browsers. Re-run without `--staging`.
