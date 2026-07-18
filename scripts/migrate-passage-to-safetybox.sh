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
  # safetybox/passphrase is the one secret passage is deliberately kept for. It
  # is the vault's own unlock key, read by automation via passage show. Sweeping
  # it into the vault would seal the vault's passphrase inside the vault it
  # unlocks. Whether it is present during this walk depends on the order the
  # operator ran init, stored the passphrase, and ran this. Skip it by name so
  # run order can never matter.
  if [ "$name" = "safetybox/passphrase" ]; then
    echo "skipping $name (kept in passage as the vault unlock key)"
    continue
  fi
  echo "migrating $name"
  # passage show prints the plaintext, safetybox set reads it from stdin. The
  # value never leaves the pipe.
  #
  # No --env-name is set here, and it cannot be. A passage path like
  # atlantis/aws-access-key-id carries no shell identifier, so there is nothing
  # to infer one from. A secret with no env name is invisible to `safetybox
  # exec` and `safetybox reveal --env`, which are the verbs that load it into a
  # shell. So these land in the vault present but unloadable. The closing
  # message warns about this. Attaching env names is a deliberate follow-up.
  passage show "$name" | safetybox set "$name"
  migrated=$((migrated + 1))
done < <(find "$store" -type f -name '*.age' -print0 | sort -z)

echo
echo "Migrated $migrated secrets. Verify them:"
echo "  safetybox list"
echo
echo "WARNING: these secrets have no env name yet, so they are invisible to"
echo "'safetybox exec' and 'safetybox reveal --env'. Nothing will load them into"
echo "a shell until you set one per secret. Re-supply the value from passage so"
echo "the value is unchanged and only the env name is added:"
echo "  passage show <name> | safetybox set <name> --env-name <VAR>"
echo "Migration alone is not complete. The secrets exist but do not load."
echo
echo "Keep passage. It now holds only the safetybox passphrase at safetybox/passphrase."
echo "If you have not stored it yet: passage insert safetybox/passphrase"
