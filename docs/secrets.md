# Secrets

How every secret on this machine is stored, and how a shell gets credentials
without a plaintext file existing anywhere.

Related: [commands.md](commands.md), [backup.md](backup.md), [../SECRETS.md](../SECRETS.md), [../.agents/rules.md](../.agents/rules.md)

---

## The chain

```
1Password  (the only thing carried out of band)
  └─ passage age identity      ~/.passage/identities
       └─ passage store        the ONE entry: safetybox/passphrase
            └─ safetybox vault ~/.local/share/safetybox/vault.db
                 └─ every other secret
```

Read it top down. You carry **one small age key** out of band. It unlocks passage,
which yields the safetybox passphrase, which opens the vault holding everything
else. One thing to protect by hand, everything else derived.

### Out of band roots

These live in **1Password**, mirrored to **KeePassXC** for offline access. Nothing
else needs manual care, and losing any one of them is unrecoverable:

1. **The passage age identity** — unlocks the whole chain.
2. **The restic repository password** — see the warning in [backup.md](backup.md).
3. **The LUKS passphrase** — once the disk is encrypted at the Bazzite install.

---

## safetybox

`safetybox` is the store. It is built from a tagged release in
[parts/safetybox.nix](../parts/safetybox.nix) and installed by
[home/secrets.nix](../home/secrets.nix).

- Values are sealed in **age** envelopes, metadata lives in **SQLite**.
- Vault: `~/.local/share/safetybox/vault.db`
- Identity: `~/.config/safetybox/identity.age`, an X25519 key encrypted with a passphrase.

The useful asymmetry: **write and metadata verbs never ask for the passphrase.**
`set`, `show`, `list`, `disable`, `delete`, and `purge` only need the public
recipient stored in the vault. Only `get`, `reveal`, `exec`, `passwd`, and `rekey`
decrypt.

That is why a script can store a secret unattended, and why `safetybox set` in a
pipeline never prompts.

### Naming

| Prefix | Meaning |
| --- | --- |
| `global/<name>` | Machine wide. Loaded into every shell by `secrets.fish`. |
| `<app>/<name>` | Scoped to one thing, e.g. `forgejo/`, `atlantis/`, `cloudflare/`. |

`--env-name` records the variable name `exec` and `reveal --format` will use. It
must be a valid shell identifier.

```bash
printf '%s' "$VALUE" | safetybox set global/some-token --env-name SOME_TOKEN
```

Values come from **stdin or a no-echo prompt, never from an argument**, so they
never land in shell history or the process table.

### Rotation

```bash
printf '%s' "$NEW" | safetybox set global/aws-access-key-id \
  --env-name AWS_ACCESS_KEY_ID --revoke-previous
```

`--revoke-previous` disables every older enabled version in the same transaction.
Without it, prior versions stay enabled on purpose, so a rotation has an overlap
window. `get` and `reveal` always resolve the **newest enabled** version.

Nothing is destroyed. `show` keeps the full history, disabled versions included,
as an audit trail. `purge` is the only verb that erases envelopes.

---

## passage keeps exactly one job

passage is **not** retired. It holds a single entry, `safetybox/passphrase`, so
automation can unlock the vault non-interactively:

```fish
safetybox reveal --env --prefix global --format fish \
    --passphrase-file (passage show safetybox/passphrase | psub)
```

`psub` hands safetybox a transient fifo, so the passphrase is never a file on
disk.

> Use `passage insert <name>`, never `passage insert -m <name>`. The multiline
> form **echoes what you type**. The plain form is a hidden prompt, entered twice.

### The passage store has its own git hooks

The global `core.hooksPath` runs a conventional-commit linter, which rejects
passage's auto-generated messages ("Add given password for X to store"). So the
passage store points at its own hooks directory:

```
~/.passage/store/.git/config  ->  core.hooksPath = ~/.passage/.githooks
~/.passage/.githooks/pre-commit  ->  the gitleaks hook (kept)
```

gitleaks still runs. Only the commit-msg linter is skipped. Both paths live under
`~/.passage`, so the restic backup carries this fix to a new machine.

---

## How a shell gets credentials

[fish/secrets.fish](../fish/secrets.fish) is sourced from `shellInit`, so it runs
in **every** shell, login or not, from any directory, scripts included.

```fish
load-secrets     # loads every global/* secret with an env name
unload-secrets   # erases them from this shell
```

It runs automatically once per session. The exported `SAFETYBOX_SECRETS_LOADED`
marker means subshells inherit the variables and never pay for a second decrypt.

The whole set decrypts in **one call**. That is the point of `reveal --env`: a
single passphrase read and one identity unlock for the entire batch.

**`secrets.fish` is tracked in this repo, and that is correct.** It contains no
secret values, only the reveal command. It is a reference, not a secret.

### Why there is no ~/.aws/credentials

The AWS CLI credential chain is: command line flags, then **environment
variables**, then the credentials file. Since `secrets.fish` exports
`AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` from the vault into every shell,
a plaintext `~/.aws/credentials` is redundant. Delete it; keep `~/.aws/config` for
`region` and `output`, which are not secret.

---

## Rules

From [.agents/rules.md](../.agents/rules.md), non negotiable:

- **Repos hold references only.** A path like `forgejo/token` is a reference and
  is safe. A token value is not, and never enters any repo.
- **Private keys never enter a repo.** Backed up out of band instead.
- **Never print a secret.** Resolve it into a variable or a pipe.
- **Never `op`.** 1Password's CLI crashes on Ubuntu 24.04 and is not trusted here.
  1Password the app is still the out of band root; only `op` is banned.

### One trap worth naming

**Never put a secrets file through `home.file`.** home-manager copies those into
`/nix/store`, which is **world readable**, so a 0600 file managed that way leaks.
The `source` line belongs in the repo. The secret values belong in the vault.
