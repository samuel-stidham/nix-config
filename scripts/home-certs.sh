#!/usr/bin/env bash
#
# home-certs.sh - a real TLS cert for *.home.samuelstidham.me, via DNS-01.
#
# WHY DNS-01 AND NOT HTTP-01
#
# The home lab names resolve to Tailscale addresses out of 100.64.0.0/10. Those
# are CGNAT: unroutable from the internet, so Let's Encrypt can never connect to
# this machine to answer an HTTP-01 challenge. DNS-01 proves control of the
# domain by writing a TXT record instead, which needs no inbound anything. It is
# also the only challenge type that can issue a WILDCARD.
#
# WHY A WILDCARD
#
# One cert covers forgejo., atlantis., linux., mac., and whatever comes next, so
# adding a service is an nginx vhost rather than a cert run. It is also the
# private option: every hostname in a cert is published permanently to public
# Certificate Transparency logs. Individual certs would tell the world
# "forgejo.home.samuelstidham.me exists". A wildcard publishes
# "*.home.samuelstidham.me" and nothing about what is behind it.
#
# Note it covers exactly one label. forgejo.home.samuelstidham.me matches,
# a.b.home.samuelstidham.me does not.
#
# THE TOKEN IS IP FILTERED
#
# The Cloudflare token in passage is scoped to this zone AND filtered to the
# server, the home IPv4, and the home IPv6 /64. If the home address changes, this
# fails with Cloudflare error 9109, which reads like a permissions problem and is
# not. Fix it by updating the token's client IP filter, not by widening its
# scope. See CLAUDE.md in the samuelstidham repo.
#
# RATE LIMITS ARE REAL
#
# Let's Encrypt allows 5 duplicate certs per week. A loop that re-issues on every
# run will lock you out for days, and the lockout is not overridable. So:
#   - renew, do not re-issue. lego only acts inside --renew-days.
#   - test against --staging first. Staging certs are untrusted by browsers but
#     prove the whole path: token, DNS write, propagation, cleanup.
#
# Usage:
#   ./home-certs.sh --staging     # dry run against LE staging, no rate limit
#   ./home-certs.sh               # issue or renew against production
#   ./home-certs.sh --force       # re-issue even if the cert is still fresh
set -uo pipefail

DOMAIN="${CERT_DOMAIN:-home.samuelstidham.me}"
CERTDIR="${CERT_OUT:-$HOME/.local/share/dev-services/certs}"
LEGO_PATH="${LEGO_PATH:-$HOME/.local/share/lego}"
RENEW_DAYS=30

STAGING=0
FORCE=0
for a in "$@"; do
  case "$a" in
    --staging) STAGING=1 ;;
    --force)   FORCE=1 ;;
    *) echo "unknown argument: $a" >&2; exit 2 ;;
  esac
done

command -v lego >/dev/null 2>&1 || { echo "lego not on PATH" >&2; exit 1; }
command -v passage >/dev/null 2>&1 || { echo "passage not on PATH" >&2; exit 1; }

# The token is read at run time and only ever lives in this process's
# environment, never in a file, argv, or shell history. lego reads it from
# CLOUDFLARE_DNS_API_TOKEN by convention. See .agents/rules.md.
CLOUDFLARE_DNS_API_TOKEN="$(passage show cloudflare/api-token 2>/dev/null)"
export CLOUDFLARE_DNS_API_TOKEN
[ -n "$CLOUDFLARE_DNS_API_TOKEN" ] || { echo "could not read cloudflare/api-token from passage" >&2; exit 1; }

# The ACME account email. Let's Encrypt uses it for expiry warnings only, so it
# is not a secret, but it does not belong hardcoded in a public repo either.
#
# CERT_EMAIL first, so a shell that already has it exported wins and no vault is
# touched. The timer does NOT have it: a systemd user unit gets a minimal
# environment and never sources the shell profile, so anything fish exports is
# invisible here. That is why the vault is the fallback rather than the reverse.
# A renewal that only works when run by hand is not a renewal.
#
# reveal, not get. `safetybox get` prints metadata and its value field always
# reads [REDACTED]. reveal is the single verb that emits plaintext, and it emits
# JSON, hence the jq. Using get here would silently set EMAIL to nothing useful.
EMAIL="${CERT_EMAIL:-}"
if [ -z "$EMAIL" ]; then
  EMAIL="$(safetybox reveal global/acme-email --json \
             --passphrase-file <(passage show safetybox/passphrase) 2>/dev/null \
           | jq -r '.value // empty' 2>/dev/null || true)"
fi
if [ -z "$EMAIL" ]; then
  echo "no ACME email. Set one of:" >&2
  echo "  export CERT_EMAIL=you@example.com" >&2
  echo "  printf '%s' you@example.com | safetybox set global/acme-email --env-name CERT_EMAIL" >&2
  exit 1
fi

# LEGO 5 MOVED EVERY FLAG BELOW THE SUBCOMMAND, and the timer failed daily for
# seventeen days before anyone looked. nixpkgs moved lego from 4.x to 5.5.1 and
# from 2026-10-16 every run died on the first flag:
#
#   Incorrect Usage: flag provided but not defined: -accept-tos
#
# Three things changed, per the v4 to v5 CLI guide at
# go-acme.github.io/lego/migration/cli/, read 2026-11-02. The global flags are
# now flags of `run`, so they go AFTER it. `renew` is gone, `run` renews too,
# and `--days` is `--renew-days`. `--dns.propagation-wait` is
# `--dns.propagation.wait`. The on-disk layout under --path changed as well,
# and the migrate probe below the mkdir handles that.
#
# The failure was LOUD in the journal and SILENT everywhere else. The unit
# failed, systemd marked the user session degraded, and nothing in the serving
# path noticed, because the cert on disk was still valid. It would have stayed
# that way until the cert expired in December and nginx started serving a dead
# cert. Loud is only useful when something reads the journal, and here nothing
# did until a home-manager switch printed the degraded session.
ARGS=(
  --accept-tos
  --email "$EMAIL"
  --dns cloudflare
  --domains "*.${DOMAIN}"
  --path "$LEGO_PATH"
  # Ask Cloudflare's own resolvers whether the TXT landed, rather than trusting
  # the local resolver. systemd-resolved here has split-DNS rules for .test and
  # the tailnet, and a stale negative cache in that path has already caused one
  # NXDOMAIN. Checking authoritative avoids the whole class of problem.
  --dns.resolvers 1.1.1.1:53
  --dns.propagation.wait 30s
)

if [ "$STAGING" = 1 ]; then
  ARGS+=(--server https://acme-staging-v02.api.letsencrypt.org/directory)
  echo "STAGING. The cert will be untrusted, this only proves the path works."
fi

# lego names wildcard output after the literal wildcard, with the * as _.
LEGO_CRT="${LEGO_PATH}/certificates/_.${DOMAIN}.crt"
LEGO_KEY="${LEGO_PATH}/certificates/_.${DOMAIN}.key"

mkdir -p "$CERTDIR" "$LEGO_PATH"

# lego 5 changed the layout under --path and the JSON inside it, and its CLI
# guide says to run `lego migrate` once before any other command. The v4 tree
# keeps each account key under accounts/<server>/<account>/keys/, and v5 drops
# the keys/ directory. Probe for that directory rather than for a lego version,
# so a store that was already migrated, or issued fresh under v5, never runs
# migrate at all. Do not migrate by hand, the guide says the JSON changes too.
#
# migrate has no --yes flag. It prints "Continue? Y/n" and reads the console,
# and under the timer there is no console, so the first attempt on this box
# died with "Could not read from the console error=EOF". The Y on stdin is the
# whole fix. The backup it asks for is the one thing it cannot check, so take
# one before the first run on a new box: cp -a the --path directory aside.
for _keys in "$LEGO_PATH"/accounts/*/*/keys; do
  if [ -d "$_keys" ]; then
    echo "lego 4 layout at ${LEGO_PATH}, running lego migrate once ..."
    printf 'Y\n' | lego migrate --path "$LEGO_PATH" || { echo "lego migrate failed" >&2; exit 1; }
    break
  fi
done

if [ "$FORCE" = 1 ]; then
  echo "re-issuing *.${DOMAIN} now, --force ..."
  lego run "${ARGS[@]}" --renew-force
  rc=$?
elif [ ! -f "$LEGO_CRT" ]; then
  echo "issuing a new cert for *.${DOMAIN} ..."
  lego run "${ARGS[@]}"
  rc=$?
else
  echo "renewing *.${DOMAIN} if it expires within ${RENEW_DAYS} days ..."
  # --renew-days makes this a no-op on a fresh cert, which is what makes it safe
  # to run daily from a timer without touching the rate limit. lego 5 may also
  # sleep a random while before a renewal. Its help says not to disable that for
  # automated runs, so it stays.
  lego run "${ARGS[@]}" --renew-days "$RENEW_DAYS"
  rc=$?
fi

if [ "$rc" -ne 0 ]; then
  echo "lego failed (exit ${rc})." >&2
  echo "If Cloudflare said 9109, the home IP changed and the token's IP filter" >&2
  echo "needs updating. It is not a scope problem." >&2
  exit "$rc"
fi

[ -f "$LEGO_CRT" ] || { echo "lego reported success but ${LEGO_CRT} is missing" >&2; exit 1; }

# Publish where the sites nginx already looks. It picks certs by SNI from this
# directory, so the wildcard is installed under every name it serves. Copies
# rather than symlinks: nginx is started from a process-compose stack that may
# not follow links out of its runtime dir, and these are two small files.
# install, checked. This script drops set -e on purpose to handle its own
# failures, and this block was the one place that ignored a failed install. A full
# disk or bad perms would leave nginx serving the OLD cert while the run still
# printed success below. Check each copy and abort loudly instead.
install -m 0644 "$LEGO_CRT" "${CERTDIR}/${DOMAIN}.crt" || { echo "failed to install ${DOMAIN}.crt into ${CERTDIR}" >&2; exit 1; }
install -m 0600 "$LEGO_KEY" "${CERTDIR}/${DOMAIN}.key" || { echo "failed to install ${DOMAIN}.key into ${CERTDIR}" >&2; exit 1; }

for host in forgejo atlantis linux mac; do
  install -m 0644 "$LEGO_CRT" "${CERTDIR}/${host}.${DOMAIN}.crt" || { echo "failed to install ${host}.${DOMAIN}.crt" >&2; exit 1; }
  install -m 0600 "$LEGO_KEY" "${CERTDIR}/${host}.${DOMAIN}.key" || { echo "failed to install ${host}.${DOMAIN}.key" >&2; exit 1; }
done

# nginx reads the cert once, at start, and holds it open. A renewed file on disk
# changes nothing until it reloads, so without this the cert would quietly expire
# in serving while being perfectly valid on disk. That failure would arrive in
# October as a browser warning with no obvious cause.
#
# Reload, not restart: reload re-reads the cert without dropping connections.
# Only if the unit is actually running, so this stays a no-op on a machine where
# nginx is not up rather than failing the renewal.
if systemctl --user is-active --quiet nginx.service 2>/dev/null; then
  if systemctl --user reload nginx.service 2>/dev/null; then
    echo "reloaded nginx so it serves the new cert"
  else
    echo "WARNING: could not reload nginx. It is still serving the OLD cert." >&2
    echo "Fix with: systemctl --user reload nginx" >&2
  fi
fi

echo "installed into ${CERTDIR}:"
printf '  %s\n' "${DOMAIN}.crt" "${DOMAIN}.key"
# Report from the INSTALLED copy, not $LEGO_CRT. Reading the source would print the
# freshly-issued cert's expiry even where an install had left an older cert in
# place, the exact false-success this function must never print. The installs above
# are now checked, so reaching here means this file is the one nginx serves.
installed="${CERTDIR}/${DOMAIN}.crt"
if command -v openssl >/dev/null 2>&1; then
  echo "cert covers:"
  openssl x509 -in "$installed" -noout -ext subjectAltName 2>/dev/null | tail -n +2 | sed 's/^ */  /'
  echo "expires:"
  openssl x509 -in "$installed" -noout -enddate 2>/dev/null | sed 's/notAfter=/  /'
  echo "issued by:"
  openssl x509 -in "$installed" -noout -issuer 2>/dev/null | sed 's/issuer=/  /'
fi
