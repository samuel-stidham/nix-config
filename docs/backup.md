# Backup and restore

The runbook. What is backed up, what deliberately is not, and how to get it back.

Related: [commands.md](commands.md), [secrets.md](secrets.md), and
"Machine File Structure" in the obsidian scratchpad vault, which is the living
inventory this file implements.

---

## The idea

`~` is about 995G, but almost none of it matters. The old move was: zip a
terabyte, wait hours uploading to Drive, reinstall, download, unzip. That was
moving 1TB to rescue a few hundred megabytes.

The rule now: **classify once, back up only Tier 1, rebuild the rest.** A machine
move becomes `restic restore` plus `bootstrap.sh` plus `home-manager switch`.

There are two drives and only one of them matters for migration:

- **`/` (nvme, 3.6T)** is the only drive a reinstall rewrites.
- **WorkDrive (7.3T)** and **StoragePrime (10.9T)** are never touched. Parking
  cold bulk there survives an OS wipe for free, with no upload and no download.

So there is a tier above backup: do not keep it on the nvme.

> WorkDrive surviving a *reinstall* is not the same as surviving a *drive
> failure*. Parking data there removes the migration cost, not the risk.

---

## The repository

```
s3:s3.us-east-1.amazonaws.com/samuelstidham-restic
```

Provisioned as code by the `infra-backups` OpenTofu repo (bucket, SSE, public
access block, lifecycle, and a scoped IAM user). It is **separate** from
`samuelstidham-backups`, which is the website's Litestream and archive bucket.

restic encrypts client side, so S3 never sees plaintext.

### What it costs

| | |
| --- | --- |
| First backup | ~86G |
| Storage | 86 x $0.023/GB = **~$2/month** |
| Upload | free, S3 does not charge for data in |
| Requests | ~$0.09 one time |
| Full restore | ~free, the first 100G/month of egress is free |

Not Standard-IA despite being half price: it has a 30 day minimum storage
duration, and restic `prune` deletes data early, so early delete fees would eat
the savings.

---

## What is backed up

`BACKUP_PATHS` in [scripts/backup.sh](../scripts/backup.sh):

| Path | Why |
| --- | --- |
| `~/Code` | All source. 475M. The whole point. |
| `~/Documents` | Education, Employment, Vital, obsidian-vaults. |
| `~/Calibre Library` | Library and `metadata.db`. Never cloud-sync it, SQLite corrupts. |
| `~/forgejo` | Critical infra. See the database note below. |
| `~/sites` | The `*.test` project roots. |
| `~/.local/share/PrismLauncher/instances` | Worlds, JourneyMap, **and the exact mod versions**. |
| `~/snap/firefox/.../firefox` | The Firefox profile. See below. |
| `~/Desktop` | Safety net. Should be near empty after the reorg. |
| safetybox vault + identity, `~/.passage` | The secret chain. Encrypted at rest already. |
| `~/.ssh`, `~/.gnupg` | Keys. |

Excluded even inside those paths: `Documents/Minecraft Backup` (18G, superseded),
`node_modules`, `.terraform`, `target`.

### The Firefox profile is Tier 1, and it is easy to miss

Firefox Sync carries bookmarks, history, and the *list* of add-ons. It does **not**
carry each extension's configuration. Simple Tab Groups' groups, the
Multi-Account Container assignments, and uBlock's settings exist **only** in the
profile directory.

Backing the profile up is what makes Firefox return identical, and it replaces the
entire per-extension export/import dance.

On Bazzite the path changes to the Flatpak location, so override it:

```bash
FIREFOX_PROFILE=~/.var/app/org.mozilla.firefox/.mozilla/firefox ./scripts/backup.sh backup
```

> **`~/snap` must never be deleted.** It holds that profile. An earlier draft of
> the plan listed it as "de-snapped already, delete", which would have destroyed
> it.

### Minecraft mods are backed up on purpose

A world is bound to the *exact mod versions* it was played with. Pulling "the
modpack" again later gets whatever is current, and a mod update can break or
corrupt the save. Keeping the 53G of instances instead of just `saves/` costs
about **$1.20/month**. That is noise against the worlds opening.

### Forgejo: the stack is stopped first

`backup` runs `podman-compose down` before restic and restarts it on any exit via
a `trap`.

Forgejo keeps its metadata in a **live SQLite database**: users, issues, PRs,
webhooks, Actions secrets, and the push mirror config. The git repos are mirrored
to GitHub, but **none of that metadata is**, so the database is the irreplaceable
part. Copying it while Forgejo writes can capture a torn write that restores to a
corrupt Forgejo. Stopping the stack makes the files coherent by definition. This
box is single user, so the downtime is free.

---

## What is NOT backed up

Rebuilt instead, which is faster than restoring it:

| Path | How it comes back |
| --- | --- |
| `~/.local/share/Steam` (581G) | `scripts/steam-restore.sh`, from the 48 appids in `steam/appids.txt`. |
| `~/.local/share/JetBrains` (51G) | jetbrains-toolbox. |
| `~/.local/share/flatpak` (8.4G) | `bootstrap.sh flatpaks`. |
| `~/VirtualBox VMs` (13G) | Rebuildable. |
| Toolchain caches (`~/go`, `~/.gradle`, `~/.cabal`, `~/.julia`, ...) | Nix and a first build. |
| `WorkDrive/Roms` (117G) | Lives on WorkDrive. Accepted risk, not backed up. |

---

## Commands

```bash
./scripts/backup.sh init                 # once, ever
./scripts/backup.sh backup               # the full Tier 1 snapshot
./scripts/backup.sh mc-backup            # Minecraft only, refuses if it is running
./scripts/backup.sh mc-restore           # restore Minecraft in place
./scripts/backup.sh snapshots            # list
./scripts/backup.sh restore <id> <dir>   # restore a snapshot to a directory
./scripts/backup.sh forget               # DRY RUN: show what would age out
./scripts/backup.sh forget --apply       # actually forget, then prune
./scripts/keep-awake.sh "restic run"     # block sleep during a long run
```

### forget

`forget` is the only irreversible command here, so it is a dry run by default and
needs `--apply` to remove anything. The policy is
`--keep-last 3 --keep-daily 7 --keep-weekly 4 --keep-monthly 12`.

Two things about it are worth knowing before you expect it to free space.

`forget` on its own only drops the snapshot *pointer*, it frees nothing. `--prune`
is what deletes the unreferenced blobs, which is why `--apply` passes both. If
`forget` removes no snapshots, restic skips prune and nothing is reclaimed.

Snapshots are grouped by host *and path set*, and the policy applies per group.
Change `BACKUP_PATHS` and the next snapshot lands in a brand new group, where it
is the "last snapshot" and is kept forever regardless of age. That is why the
first snapshot, taken while the Calibre library still lived in `~`, is retained
even though newer ones exist: its path list is different, so it is a group of one.

The policy keeps more than feels necessary on purpose. Dedup makes history nearly
free: a 92 GiB backup added 405 MiB to the repo, because every unchanged blob is
shared with earlier snapshots. A year of monthlies costs a rounding error.

Credentials come from the vault through `safetybox exec`, so nothing is exported
into your shell and no AWS profile is needed.

The first run is the expensive one. Every run after is incremental: restic dedups
on content, so it only ships changed blocks. It is also safe to interrupt, a
killed run resumes without re-uploading what already landed.

---

## Restore

restic stores **absolute paths**. `restore --target /` puts every file back
exactly where it was at backup time.

That has a consequence worth understanding: **a restore reproduces the structure
that existed when the snapshot was taken, not the structure you wish you had.**
Reorganize first, back up second, and the restore reproduces the clean layout.

```bash
./scripts/backup.sh snapshots                    # find the id
./scripts/backup.sh restore <id> /tmp/verify     # restore somewhere harmless first
```

Always restore to a scratch directory before restoring in place. A backup you
have never restored from is not a backup yet, it is a hypothesis.

### Disaster recovery, in order

1. **1Password** on the phone gives you the passage age identity, the restic
   repository password, and the LUKS passphrase.
2. Install the OS. Enable **LUKS** at install time.
3. Put the passage identity at `~/.passage/identities`.
4. `restic restore` the latest snapshot.
5. That returns `vault.db`, `identity.age`, and the passage store, so
   `passage show safetybox/passphrase` works and the vault opens.
6. `bootstrap.sh` and `home-manager switch` rebuild everything in Tier 2.
7. `steam-restore.sh` re-downloads the games.

> ### The circular dependency to avoid
>
> The restic password **cannot live only in the safetybox vault**, because the
> vault is inside the restic repository that the password unlocks. You would need
> the backup to open the backup. That is why it lives in 1Password, out of band,
> alongside the passage identity and the LUKS passphrase.
