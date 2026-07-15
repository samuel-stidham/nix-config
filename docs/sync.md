# Sync (Syncthing)

Keeps SNHU work on the MacBook and this machine in step.

Configured in [home/syncthing.nix](../home/syncthing.nix). Linux only: this repo
is applied here and nowhere else, so the Mac's side is set up through its own GUI.

## The folders

| folder | path | type | versioning |
| --- | --- | --- | --- |
| `snhu-coursework` | `~/Sync/snhu-coursework` | Send & Receive | staggered, 1 year |
| `snhu-library` | `~/Sync/snhu-library` | Send & Receive | trashcan, 90 days |

Both are two-way, because both machines are worked from. Simultaneous edits to
one file produce a `.sync-conflict-<date>-…` file next to it rather than a silent
winner. That is Syncthing refusing to guess; resolve it and delete the loser.

Different versioning on purpose. Coursework holds submitted work, so a deletion
arriving from the Mac has to be recoverable, and staggered keeps a thinning year
of history. The library is large PDFs that rarely change, where every historical
revision buys nothing; 90 days of "I deleted that by mistake" is the requirement.

Recovered files live in `.stversions/` inside each folder.

## Reachability: they only find each other on the LAN

`globalAnnounceEnabled` and `relaysEnabled` are both **off**, so this machine is
never announced to Syncthing's public infrastructure and never bounces traffic
through a stranger's relay.

The cost is real and worth stating plainly: discovery is **local only**. Today the
two machines find each other over the LAN, on a link-local address like
`[fe80::…%wlp6s0]:22000`. **When the MacBook leaves the house, sync stops** until
it comes back.

The fix is a static Tailscale address, not re-enabling global discovery. In
[home/syncthing.nix](../home/syncthing.nix), uncomment and fill in:

```nix
devices."Samuels-MacBook-Pro-M4" = {
  id = macbook;
  addresses = [ "tcp://<mac>.<tailnet>.ts.net:22000" ];
};
```

Syncthing is end-to-end encrypted regardless; Tailscale is only about being
reachable without opening 22000/tcp+udp or 21027/udp to the world.

## The repo wins, the GUI loses

`overrideDevices` and `overrideFolders` are **true**, so every `home-manager
switch` rewrites Syncthing's config from this file. Anything added in the GUI and
not written down here is deleted on the next switch.

This has already nearly bitten once. The module used to declare folders named
`snhu` and `books`, invented before the Mac side existed and shared with nothing.
The real `snhu-coursework` and `snhu-library` folders, plus the Mac device, were
one `home-manager switch` away from being wiped. **If you change something in the
GUI, put it in the nix in the same sitting.**

## What is deliberately not synced

The **Calibre library**. `metadata.db` is SQLite; two machines writing it produce
`.sync-conflict` copies *of the database* and a corrupted library. It lives once,
on StoragePrime. Read it from the Mac with Calibre's content server.

`~/Documents/Education/Books` is not synced either. It is source material already
imported into Calibre, not a working set. See
[scripts/education-redundant.sh](../scripts/education-redundant.sh).

## Backups

`~/Sync` **is** in `BACKUP_PATHS` ([scripts/backup.sh](../scripts/backup.sh)).
This matters more than it looks: `~/Documents/Education/SNHU` was deleted once the
work lived in `~/Sync`, so `~/Sync` is now the only local copy. Syncthing is
replication, not backup — a delete propagates to both machines in seconds.

`.stversions` and `.stfolder` are excluded. Version history is a second copy of
everything ever replaced, which is what restic snapshots already are.

## Pairing

Device IDs are public key fingerprints, not secrets. Knowing one lets you *offer*
to sync; the other side must still accept. So they belong in this repo.

| device | ID |
| --- | --- |
| this machine | `R2C3TB5-U674D3M-PPTH3IL-IEVITP7-KWANVNL-JMB5WID-ICLS4GH-ETAJHQT` |
| MacBook Pro M4 | `4IM7O6G-XZONB7G-UUJSTYX-JR7CTR6-QQFE3HD-YTMK6IL-J66BG26-MUOMGQR` |

Folder IDs must match on both sides: `snhu-coursework`, `snhu-library`.

## Commands

```bash
systemctl --user status syncthing      # is it running
syncthing cli show system              # this machine's ID and state
syncthing cli config folders list      # declared folders
syncthing cli config devices list      # paired devices
open http://syncthing.test:8384        # the GUI, never a bare host:port
```

Check the *other* machine actually has your files, which folder status alone does
not tell you:

```bash
API=$(grep -oPm1 '(?<=<apikey>)[^<]+' ~/.local/state/syncthing/config.xml)
MAC=4IM7O6G-XZONB7G-UUJSTYX-JR7CTR6-QQFE3HD-YTMK6IL-J66BG26-MUOMGQR
curl -s -H "X-API-Key: $API" \
  "http://127.0.0.1:8384/rest/db/completion?folder=snhu-coursework&device=$MAC"
```

`completion: 100` with `needBytes: 0` is the only proof the Mac has it. A local
`needFiles: 0` only means *this* machine is up to date.

The GUI is on `127.0.0.1:8384` and answers to `syncthing.test:8384` because the
dnsmasq in `nix run .#sites` resolves `*.test` to `127.0.0.1`. If the name does
not resolve, that process-compose stack is not running.
