#!/usr/bin/env bash
#
# migrate-passage-to-safetybox.sh - one-time move of every passage secret into
# the safetybox vault. Run it once, on the machine that still has the passage
# store, after home-manager has built safetybox and you have run `safetybox init`.
#
# It never prints or writes a secret value. Each value flows straight from
# passage's stdout into safetybox's stdin, so nothing lands in a file, the
# terminal, or the shell history. This honors the never-print-a-secret rule.
#
# After it finishes, verify with `safetybox list`. passage is NOT removed: it is
# kept for one job, holding the safetybox passphrase at safetybox/passphrase, so
# automation can unlock the vault non-interactively. Store that passphrase once,
# after `safetybox init`:
#   passage insert safetybox/passphrase   # hidden prompt, entered twice
set -euo pipefail

store="${PASSAGE_STORE:-$HOME/.passage/store}"

if ! command -v passage >/dev/null 2>&1; then
  echo "passage is not on PATH. Run this on the old machine, before removing it." >&2
  exit 1
fi
if ! command -v safetybox >/dev/null 2>&1; then
  echo "safetybox is not on PATH. Run home-manager switch first." >&2
  exit 1
fi
if [ ! -d "$store" ]; then
  echo "No passage store at $store." >&2
  exit 1
fi
# safetybox needs an initialized vault and identity. list exits non-zero if not.
if ! safetybox list >/dev/null 2>&1; then
  echo "No safetybox vault yet. Create one first, it is a state change you run:" >&2
  echo "  safetybox init" >&2
  exit 1
fi

# Walk every .age entry under the store. The name is the path with the store
# prefix and the .age suffix removed, e.g. atlantis/aws-access-key-id.
migrated=0
while IFS= read -r -d '' f; do
  name="${f#"$store"/}"
  name="${name%.age}"
  echo "migrating $name"
  # passage show prints the plaintext, safetybox set reads it from stdin. The
  # value never leaves the pipe.
  passage show "$name" | safetybox set "$name"
  migrated=$((migrated + 1))
done < <(find "$store" -type f -name '*.age' -print0 | sort -z)

echo
echo "Migrated $migrated secrets. Verify them:"
echo "  safetybox list"
echo "Keep passage. It now holds only the safetybox passphrase at safetybox/passphrase."
echo "If you have not stored it yet: passage insert safetybox/passphrase"
