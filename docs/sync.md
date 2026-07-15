# Sync (Syncthing)

Keeps SNHU work on the MacBook and this machine in step. The Mac is the source of
truth for books; coursework goes both ways.

Configured in [home/syncthing.nix](../home/syncthing.nix). Linux only: this repo
is only applied here, and the Mac is set up through its own GUI.

## The two folders, and why there are two

"The MacBook is the definitive source" and "I can work from both machines" cannot
both be true at once, so they are split rather than fudged:

| folder | path | Mac | Linux | why |
| --- | --- | --- | --- | --- |
| `books` | `~/Documents/Education/Books` | Send Only | **Receive Only** | one definitive copy, this machine reads |
| `snhu` | `~/Documents/Education/SNHU` | Send & Receive | Send & Receive | actively edited on both |

Two-way means simultaneous edits to one file produce a `.sync-conflict-<date>-…`
file next to it rather than a silent winner. That is Syncthing refusing to guess.
Resolve by hand and delete the loser.

## Receive Only does not delete your files

This is the part worth understanding before trusting it.

A Receive Only folder does **not** wipe files that exist only on Linux. It marks
them **Local Additions** and leaves them alone. They are removed only if you press
**Revert Local Changes**, which is the one destructive button in the UI.

A deletion on the *Mac* is a different story: that is a legitimate change and it
**does** propagate here. Staggered versioning (a year, thinning with age) is the
net for exactly that. Recovered files land in `.stversions/` inside the folder.

### Migrating a folder that already has Linux-only content

`~/Documents/Education/Books` currently holds collections that may not exist on
the Mac. Pointing Receive Only at it will flag all of them as Local Additions.
Do **not** press Revert. Push them up first:

1. Set the Linux `books` folder to **Send & Receive** temporarily (GUI).
2. Let it sync, so the Mac gains everything Linux has.
3. Confirm the Mac's copy is complete.
4. Set Linux back to **Receive Only**.

Then the Mac genuinely is the superset, and "source of truth" is true rather than
asserted.

## What is deliberately not synced

The **Calibre library**. `metadata.db` is SQLite; two machines writing it produce
`.sync-conflict` copies *of the database* and a corrupted library. The library
lives once, on StoragePrime. Read it from the Mac with Calibre's content server
instead.

## Transport

Over **Tailscale**. Global discovery and public relays are off, so this machine is
not announced to Syncthing's public infrastructure, and ports 22000/tcp+udp and
21027/udp stay closed. Syncthing is end-to-end encrypted regardless; Tailscale is
about reachability without punching holes.

## Pairing the Mac

Device IDs are public key fingerprints, not secrets. Knowing one lets you *offer*
to sync; the other side must still accept. So the ID belongs in this repo.

This machine's ID:

```
R2C3TB5-U674D3M-PPTH3IL-IEVITP7-KWANVNL-JMB5WID-ICLS4GH-ETAJHQT
```

1. On the Mac, install Syncthing and open its GUI. Actions → Show ID.
2. Put that ID into `macbookId` in [home/syncthing.nix](../home/syncthing.nix)
   and `home-manager switch`. While it is empty the folders exist locally but are
   shared with nothing, which is why the config switches cleanly before the Mac
   exists.
3. On the Mac, add this machine using the ID above, and share `books` (Send Only)
   and `snhu` (Send & Receive) with it. Folder IDs must match: `books`, `snhu`.
4. Accept the folders here.

`overrideDevices` and `overrideFolders` are on, so this file wins: changes made in
the GUI are reverted on the next switch. Edit the nix, not the GUI, except for the
temporary Send & Receive step above.

## Commands

```bash
systemctl --user status syncthing      # is it running
syncthing cli show system              # this machine's ID and state
syncthing cli config folders list      # declared folders
open http://syncthing.test:8384        # the GUI, never a bare host:port
```

The GUI is on `127.0.0.1:8384` and answers to `syncthing.test:8384` because the
dnsmasq in `nix run .#sites` resolves `*.test` to `127.0.0.1`. If the name does
not resolve, that process-compose stack is not running.
