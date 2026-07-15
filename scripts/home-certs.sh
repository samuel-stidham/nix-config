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
#   - renew, do not re-issue. lego only acts inside --days.
#   - test against --staging first. Staging certs are untrusted by browsers but
#     prove the whole path: token, DNS write, propagation, cleanup.
#
# Usage:
#   ./home-certs.sh --staging     # dry run against LE staging, no rate limit
#   ./home-certs.sh               # issue or renew against production
#   ./home-certs.sh --force       # re-issue even if the cert is still fresh
set -uo pipefail

DOMAIN="${CERT_DOMAIN:-home.samuelstidham.me}"
EMAIL="${CERT_EMAIL:-dqfan2012@gmail.com}"
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
  --dns.propagation-wait 30s
)

if [ "$STAGING" = 1 ]; then
  ARGS+=(--server https://acme-staging-v02.api.letsencrypt.org/directory)
  echo "STAGING. The cert will be untrusted, this only proves the path works."
fi

# lego names wildcard output after the literal wildcard, with the * as _.
LEGO_CRT="${LEGO_PATH}/certificates/_.${DOMAIN}.crt"
LEGO_KEY="${LEGO_PATH}/certificates/_.${DOMAIN}.key"

mkdir -p "$CERTDIR" "$LEGO_PATH"

if [ "$FORCE" = 1 ] || [ ! -f "$LEGO_CRT" ]; then
  echo "issuing a new cert for *.${DOMAIN} ..."
  lego "${ARGS[@]}" run
  rc=$?
else
  echo "renewing *.${DOMAIN} if it expires within ${RENEW_DAYS} days ..."
  # --days makes this a no-op on a fresh cert, which is what makes it safe to
  # run daily from a timer without touching the rate limit.
  lego "${ARGS[@]}" renew --days "$RENEW_DAYS"
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
install -m 0644 "$LEGO_CRT" "${CERTDIR}/${DOMAIN}.crt"
install -m 0600 "$LEGO_KEY" "${CERTDIR}/${DOMAIN}.key"

for host in forgejo atlantis linux mac; do
  install -m 0644 "$LEGO_CRT" "${CERTDIR}/${host}.${DOMAIN}.crt"
  install -m 0600 "$LEGO_KEY" "${CERTDIR}/${host}.${DOMAIN}.key"
done

echo "installed into ${CERTDIR}:"
printf '  %s\n' "${DOMAIN}.crt" "${DOMAIN}.key"
if command -v openssl >/dev/null 2>&1; then
  echo "cert covers:"
  openssl x509 -in "$LEGO_CRT" -noout -ext subjectAltName 2>/dev/null | tail -n +2 | sed 's/^ */  /'
  echo "expires:"
  openssl x509 -in "$LEGO_CRT" -noout -enddate 2>/dev/null | sed 's/notAfter=/  /'
  echo "issued by:"
  openssl x509 -in "$LEGO_CRT" -noout -issuer 2>/dev/null | sed 's/issuer=/  /'
fi
