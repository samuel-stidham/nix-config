# Local dev services and *.test sites

Two process-compose stacks run the local development backends. They are separate
so the databases do not need the web layer's system setup. Data lives under
`~/.local/share/dev-services`. Ports are the defaults, which are free on this
machine. Keep Docker dev containers on other host ports so they do not shadow
these.

## The services stack

```bash
nix run ~/nix-config#services
```

This starts the backends as a foreground group. Stop with Ctrl-C.

| Service | Port | Notes |
| --- | --- | --- |
| MariaDB | 3306 | user `root`, no password on first init |
| PostgreSQL | 5432 | |
| Redis | 6379 | |
| MongoDB | 27017 | |
| MinIO | 9000, 9001 | S3-compatible, the RustFS substitute |
| Meilisearch | 7700 | |

MinIO is the local S3. Point an AWS SDK at `http://localhost:9000` in dev, then
swap to real S3 or RustFS in production through config alone. The console is on
`http://localhost:9001`.

## The sites stack

```bash
nix run ~/nix-config#sites
```

This starts nginx, php-fpm, and dnsmasq for `*.test`. It needs the one-time
system setup below, since nginx binds port 80 and the resolver must route `.test`.

Any folder in `~/sites` is served at `<folder>.test`. Create a folder, add code,
and it is live. No per-site config.

### The driver layer

One nginx vhost picks the document root by what exists, covering the common Valet
site types without the bloat.

- `~/sites/<name>/public` exists, so the root is `public`. This covers Laravel,
  Symfony 4 and newer, and Bedrock.
- else `~/sites/<name>/web` exists, so the root is `web`. This covers Symfony 2
  and 3, and older Drupal.
- else the root is the site folder itself. This covers WordPress, plain PHP, and
  static HTML.

The front controller is `index.php`, so framework routing works through
`try_files`. Static sites fall through to `index.html`. That is good enough for
occasional web work. Come back if you want full Valet driver coverage.

### HTTPS for *.test

The sites nginx also listens on 443. It picks a per-site certificate by SNI from
`~/.local/share/dev-services/certs/<host>.crt`. Generate those certs with the
`secure_sites` fish function, which makes a one-year self-signed cert for every
folder in `~/sites`.

```bash
secure_sites          # secure every ~/sites/<name> as <name>.test
```

Run it after adding a site, or once a year to renew. Re-running overwrites.

Once a site has a cert, nginx forces a 301 redirect from HTTP to HTTPS for that
host. A site with no cert still serves over plain HTTP, so unsecured sites are
not broken. The certs are self-signed, so a browser shows a warning until you
trust or import the cert. That is expected for local dev.

### Xdebug

Xdebug 3 is configured on the shared PHP build, so it works in the CLI and behind
nginx. It uses port 9003, not the old 9000 that clashed with php-fpm and MinIO.
The mode is `develop,debug` with `start_with_request = trigger`, so there is no
overhead until you start a session. Point your IDE debug listener at
`127.0.0.1:9003`, and trigger a session with the usual `XDEBUG_TRIGGER` cookie,
query parameter, or environment variable.

### PHP timezone

The shared PHP build sets `date.timezone = America/Kentucky/Monticello` for both
the CLI and the php-fpm behind nginx. Store datetimes as UTC in the database and
let this timezone drive display and offset math. It lives in `parts/php.nix`, so
it is declarative and always present.

## One-time system setup

These are the two system changes the sites stack needs. They are state changes,
so run them yourself with sudo. They are safe to leave in place.

First, let a user process bind port 80, so nginx does not need root. This lowers
the unprivileged port floor to 80.

```bash
echo 'net.ipv4.ip_unprivileged_port_start=80' | sudo tee /etc/sysctl.d/99-unprivileged-port-start.conf
sudo sysctl --system
```

Second, route `.test` lookups to the stack's dnsmasq on `127.0.0.1:5333`. dnsmasq
runs on 5333 to avoid the mDNS port 5353.

```bash
sudo mkdir -p /etc/systemd/resolved.conf.d
printf '[Resolve]\nDNS=127.0.0.1:5333\nDomains=~test\n' | sudo tee /etc/systemd/resolved.conf.d/test.conf
sudo systemctl restart systemd-resolved
```

Verify after the sites stack is running.

```bash
resolvectl query myapp.test      # expect 127.0.0.1
curl -I http://myapp.test        # expect a response from nginx
```

If `resolvectl query` does not return `127.0.0.1`, the resolver did not pick up
the drop-in. Confirm systemd-resolved is the active resolver and that the stack
is running, since dnsmasq only answers while the sites stack is up.

## Rollback

Remove the two files and restart resolved to undo the system setup.

```bash
sudo rm /etc/sysctl.d/99-unprivileged-port-start.conf /etc/systemd/resolved.conf.d/test.conf
sudo sysctl --system
sudo systemctl restart systemd-resolved
```

The stacks themselves leave nothing running once you Ctrl-C them. Their data under
`~/.local/share/dev-services` stays until you delete it.
