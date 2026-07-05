# Hardening rules

These rules are absolute for this repo and for every repo on this machine. They
protect secrets and identity. Read them every time.

## Repos hold references only

A repo holds references, paths, and at most encrypted blobs. A repo never holds a
plaintext secret value. A passage path like `forgejo/token` is a reference and is
safe. A token value is not, and never goes in a repo.

## Private keys never enter a repo

No private key, age or ssh, ever enters any repo. Keys live outside version
control and are backed up out of band. See the backup section in `../SECRETS.md`.

## Never op

Do not use 1Password or its `op` CLI for hardened secrets on this machine. It
crashes on Ubuntu 24.04, so it is not trusted here. The secret store is passage
with age. See `../SECRETS.md`.

## Never print a secret

Never print, echo, or log a secret value or a private key. When a command would
reveal one, resolve it into a variable or a throwaway shell instead. The scanning
setup in `../SCANNING.md` redacts by default for this reason.

## Two phases

ANALYZE is read-only. PERFORM changes state and runs only when the phase is named.
Propose state-changing commands for me to run rather than running them.
