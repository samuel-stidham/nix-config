# Secrets and git identity

This is the plan for a hardened, local, reproducible setup for secrets and git
identity. It was seeded once from a one-time bootstrap prompt. That prompt is not
standing rules. The standing rule lives in `.agents/rules.md`. Do not read the
seed prompt again on later runs.

The ANALYZE pass ran on 2026-07-05 and changed nothing. It only read state. It
never printed a secret value or a private key.

## Architecture

The store is passage, the age based variant of pass. Secrets are age encrypted
files keyed by path, for example `forgejo/token`. The store is git backed,
encrypted at rest, scriptable, and headless. Confirmed `passage` 1.7.4 and `age`
1.3.1 on the channel.

The encryption backend is age. passage wins over plain pass because age aligns
with agenix and sops-nix. One age identity can serve interactive secrets now and
a declarative Nix route later.

The injector is direnv, already enabled in the flake through `home/theme.nix`. A
per-project `.envrc` resolves a passage reference at shell entry and exports it
for that shell only. Nothing is written to disk in plaintext.

The root of trust is the age identity that unlocks the store. It cannot live in
any repo. It is the one out-of-band secret the whole scheme depends on. See the
backup section.

## Fallbacks, not the default

These are noted as fallbacks only. Do not build around them.

The Secret Service API through gnome-keyring and `secret-tool` could serve as a
session layer. `gnome-keyring-daemon` is present, but `secret-tool` is not
installed. This stays a fallback.

sops-nix or agenix could hold encrypted secrets committed to the repo. That is
the declarative Nix route. It is a deliberate choice for later, not a default.
The same age identity feeds it when you choose it.

## What the ANALYZE pass found

The hardened stack was mostly absent and must come from Nix. Present before:
apt `pass` at `/usr/bin/pass` and `gnome-keyring-daemon`. Absent before: passage,
age, rage, gopass, secret-tool, gitleaks, and trufflehog. All are on the channel.

Now codified. `home/secrets.nix` adds passage, age, gitleaks, and trufflehog to
the flake, and wires the global gitleaks pre-commit hook through
`core.hooksPath`. These apply on the next `home-manager switch`. So the
`secrets-install` programs and the global scanner guard are in the config, ready.
The remaining phases below cover the age identity, the store, and the migration,
which are stateful and stay gated on your go-ahead.

No Forgejo token was found on Linux. The search of `~/.config`, `~/.gitconfig`,
`~/.gitconfig-snhu`, and `~/fish` found no Forgejo credential or remote. So the
token currently lives only in the Mac Keychain, from which you inject it into
Forgejo. On Linux it is not set up yet. The migration creates `forgejo/token` in
passage and injects it through direnv.

No git credential helper is configured, and no `.envrc` files exist under
`~/code` yet. direnv is enabled in the flake but not yet resolving any secret.

## Per-secret migration

Each secret becomes a passage path, resolved by direnv at shell entry. The table
starts with the Forgejo token, the one secret the inventory surfaced. Add a row
for each new secret as you migrate it. No value appears here, only references.

| Secret | Current source | Target passage path | .envrc reference | Injection command |
| --- | --- | --- | --- | --- |
| Forgejo API token | Mac Keychain, not on Linux | `forgejo/token` | `export FORGEJO_TOKEN="$(passage show forgejo/token)"` | `passage insert -m forgejo/token` to store, direnv exports on entry |

The `.envrc` pattern is one line per secret. direnv exports it for that shell
only, and nothing lands in a file. Run `direnv allow` once per project to trust
its `.envrc`.

```
# .envrc in a project that needs the Forgejo token
export FORGEJO_TOKEN="$(passage show forgejo/token)"
```

## Git identity plan

The ANALYZE pass read `~/.ssh/config` and the git config. The real setup differs
from the seed prompt in one way. The aliases are `github.com` for personal and
`github.com-snhu` for snhu. There is no `github.com-personal` alias. The plan
keeps `github.com` as the personal default and can add `github.com-personal` for
symmetry if you want it.

### SSH identities, found

| Host alias | HostName | User | IdentityFile |
| --- | --- | --- | --- |
| `github.com` | github.com | git | `~/.ssh/id_ed25519_github_personal` |
| `github.com-snhu` | github.com | git | `~/.ssh/id_ed25519_snhu` |

home-manager manages this config through `programs.ssh.matchBlocks`, one block
per alias pointing at its `IdentityFile`. The config is managed. The private keys
are not, and never enter any repo.

### Git identity by location, found and planned

Found now: the global identity is `Samuel Stidham` and `dqfan2012@gmail.com`, the
personal identity. Two `includeIf` rules exist. Both point at `~/.gitconfig-snhu`,
which sets `samuel.stidham@snhu.edu`.

- `gitdir:~/code/snhu-projects/ -> ~/.gitconfig-snhu`
- `gitdir:~/nix-config/ -> ~/.gitconfig-snhu`

So the `~/nix-config` snhu override already exists. It was not missing. The remote
is the only piece not set yet.

Now managed through home-manager `programs.git` in `home/secrets.nix`, which
mirrors this exactly and adds the global hooks path. Planned refinements:

- Under `~/code/personal-projects` the personal identity already applies as the
  default. An explicit rule can be added for symmetry.
- For `~/nix-config` set the remote to
  `git@github.com-snhu:samuel-stidham/nix-config`, so it pushes through the snhu
  key. The identity override is already in place.

### Commit signing

Signing is already configured, and it is GPG, not SSH. The base config sets
`user.signingkey = 693484A30BCFADFA` and `commit.gpgsign = true`, so every commit
signs by default. `home/secrets.nix` keeps this exactly, so nothing regresses.

One mismatch to decide. `~/.gitconfig-snhu` sets only the snhu email, no signing
key. So commits in `~/code/snhu-projects` and `~/nix-config` sign with the
personal GPG key while showing the snhu email. Two ways to fix it, your choice in
the `ssh-git-identity` phase. Add an snhu signing key to `~/.gitconfig-snhu`, or
move the whole scheme to SSH signing with one key per identity. SSH signing aligns
with the SSH keys you already have.

### Verify before any push

In `~/nix-config`, confirm the resolved identity before the first push:

```
git -C ~/nix-config config user.email      # expect samuel.stidham@snhu.edu
git -C ~/nix-config config user.signingkey # expect the snhu ssh key
```

## Backup and reproducibility

Three things live outside every repo and are backed up out of band. Losing the
age identity means losing every secret, so treat it with the most care.

- The age identity that unlocks passage, at `~/.passage/identities`. This is the
  root of trust. Back it up out of band, for example to the Mac Keychain or an
  encrypted offline drive. Restore it first on a fresh install.
- The passage store repo, at `~/.passage/store`. It is a git repo of encrypted
  files. Push it to a private remote. It is safe at rest, since every file is age
  encrypted, but keep the remote private anyway.
- The SSH private keys, `~/.ssh/id_ed25519_github_personal` and
  `~/.ssh/id_ed25519_snhu`. Back them up the same way as the age identity. They
  never enter a repo.

On a fresh install the order is restore the age identity, clone the passage store,
clone this flake and switch, then restore the SSH keys. The same age identity can
later feed agenix or sops-nix with no new key.

## Phases

Nothing runs until you name a phase and tell me to start it. Each phase changes
state, so each has a rollback note. Run one at a time.

### 1. secrets-install

Codified already in `home/secrets.nix`, which adds passage, age, gitleaks, and
trufflehog. It applies on the next `home-manager switch`. This only adds tools and
the git config. Rollback: `home-manager` generations, switch back to the prior
one.

### 2. age-identity

Create or import the age identity at `~/.passage/identities`, then back it up out
of band at once. Command to propose:
`age-keygen -o ~/.passage/identities`. Rollback: if you created a fresh identity
and have no secrets yet, delete the file and redo. If you imported an existing
one, restore it from the backup.

### 3. passage-init

Initialize the passage store as a git repo, with the age recipient set from the
identity's public key. Rollback: remove `~/.passage/store` and redo. No secrets
exist yet, so nothing is lost.

### 4. secrets-migrate

Migrate each secret into passage, starting with `forgejo/token`. Rollback: the
store is git, so revert the commit that added a secret. The secret in the Mac
Keychain stays as the source of truth until this is verified.

### 5. direnv-wire

Add a per-project `.envrc` that resolves the passage reference, and run
`direnv allow`. Rollback: remove the `.envrc` and run `direnv deny`.

### 6. ssh-git-identity

Have home-manager manage `~/.ssh/config` and the git `includeIf` rules, set the
`~/nix-config` remote and snhu override, and add SSH signing. Rollback:
`home-manager` generations. Keep a copy of the current `~/.ssh/config` and
`~/.gitconfig` first.

### 7. scanners-wire

Codified already in `home/secrets.nix`. gitleaks and trufflehog are installed, and
the global pre-commit guard runs in every repo through `core.hooksPath`. It
applies on the next switch. See `SCANNING.md`. Rollback: `home-manager`
generations, which removes the managed hook and the hooks path.

### 8. secrets-verify

Resolve a secret into a throwaway shell without printing it, and trip the
pre-commit hook with a dummy secret to prove it blocks. Rollback: none needed,
this phase only verifies.
