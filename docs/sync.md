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
winner. That is Syncthing refusing to guess. Resolve it and delete the loser.

Different versioning on purpose. Coursework holds submitted work, so a deletion
arriving from the Mac has to be recoverable, and staggered keeps a thinning year
of history. The library is large PDFs that rarely change, where every historical
revision buys nothing. 90 days of "I deleted that by mistake" is the requirement.

Recovered files live in `.stversions/` inside each folder.

## Reachability: Tailscale, not public discovery

`globalAnnounceEnabled` and `relaysEnabled` are both **off**, so this machine is
never announced to Syncthing's public infrastructure and never bounces traffic
through a stranger's relay. That is only affordable because Tailscale provides
reachability instead.

The MacBook is pinned to its tailnet address:

```nix
addresses = [ "dynamic" "tcp://100.116.77.69:22000" ];
```

Both entries, in that order, on purpose. `dynamic` is local discovery, which wins
at home and keeps working if Tailscale is down. The static tailnet address is what
covers everywhere else. Without it, discovery would be **LAN only** and sync would
stop the moment the MacBook left the house.

The IP rather than the MagicDNS name (`samuels-macbook-pro-m4.tailc1fe6c.ts.net`):
Tailscale assigns `100.116.77.69` permanently to that device, and an IP does not
have to resolve inside Syncthing's own process. There is no speed cost. Tailscale
picks the direct LAN path when both machines are home, so a `tailscale ping`
answers in ~12ms via `192.168.1.47`, not through a relay.

Syncthing is end-to-end encrypted regardless. Tailscale is only about being
reachable without opening 22000/tcp+udp or 21027/udp to the world.

### The tailnet

Both machines must be on the **same** tailnet, which is under
**`samuelstidham7@gmail.com`**, not the usual `dqfan2012@gmail.com`. Signing a
machine in with the wrong account silently creates a *second* tailnet. Everything
looks connected, the machine gets a `100.x` address, and the two never see each
other. Check https://login.tailscale.com/admin/machines, both must be in one list.

| machine | tailnet address |
| --- | --- |
| this machine | `100.68.26.36` |
| MacBook Pro M4 | `100.116.77.69` |

Tailscale's MagicDNS coexists with the `*.test` setup: `resolvectl` keeps
`Global: ~test` pointed at the dnsmasq from `nix run .#sites` and confines
Tailscale to `tailc1fe6c.ts.net` on the `tailscale0` link. If `.test` names ever
break after a `tailscale up`, that is the cause, and `sudo tailscale up
--accept-dns=false` is the escape hatch.

### Verifying it

```bash
tailscale status                        # both machines, both Connected
tailscale ping 100.116.77.69            # pong = reachable
```

Being connected over `[fe80::…%wlp6s0]` is **not** a problem: Syncthing keeps a
working connection rather than churning it, and link-local is the fast path at
home. The tailnet address is the fallback. The only real test of the away case is
opening the laptop somewhere else.

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

The **Calibre library**. `metadata.db` is SQLite. Two machines writing it produce
`.sync-conflict` copies *of the database* and a corrupted library. It lives once,
on StoragePrime. Read it from the Mac with Calibre's content server.

`~/Documents/Education/Books` is not synced either. It is source material already
imported into Calibre, not a working set. See
[scripts/education-redundant.sh](../scripts/education-redundant.sh).

## Backups

`~/Sync` **is** in `BACKUP_PATHS` ([scripts/backup.sh](../scripts/backup.sh)).
This matters more than it looks: `~/Documents/Education/SNHU` was deleted once the
work lived in `~/Sync`, so `~/Sync` is now the only local copy. Syncthing is
replication, not backup. A delete propagates to both machines in seconds.

`.stversions` and `.stfolder` are excluded. Version history is a second copy of
everything ever replaced, which is what restic snapshots already are.

## Pairing

Device IDs are public key fingerprints, not secrets. Knowing one lets you *offer*
to sync, and the other side must still accept. So they belong in this repo.

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
