# tests

A behavior gate for this repo. The rule this enforces is simple. A
behavior-preserving refactor may change how the config reads, never what it does
on this machine. These tests capture what it does, so you can prove the two apart.

The technique is a golden master, also called a characterization test. You
capture the observable behavior once on a known-good tree, then diff every later
change against it. An empty diff is the pass. A non-empty diff is either a change
you meant, which you approve and recapture, or a regression, which you fix.

## Running it

```
tests/run.sh            # fast checks: detect + fish snapshot
tests/run.sh --full     # also the home-manager output check, which builds Nix
```

Run it before a change and after, and compare. If you are starting fresh, or you
just approved an intended behavior change, recapture the goldens first.

```
tests/fish-snapshot.sh capture
tests/hm-output.sh capture
```

## What each check covers

`detect.sh` drives `bootstrap.sh` `detect_os` against synthetic `os-release`
files and asserts the family, package manager, and atomic flag for twenty-two
distro fixtures. It runs with no root and no virtual machine, because `detect_os` reads
`OS_RELEASE_FILE` and `OSTREE_MARKER`, which default to the real paths but here
point at fixtures. It is the regression net for the detection rewrite. SUSE must
resolve, and every RHEL-like must fail closed to unknown.

`fish-snapshot.sh` sources the fish tree in the same order `home/fish.nix`
`shellInit` uses, then dumps the realized shell: every function and alias name,
every exported variable, `PATH` in order, and the hand-written function bodies.
That dump is the observable behavior of the shell. It runs under `env -i` so the
calling shell cannot leak in, never sources `secrets.fish`, and masks Nix store
hashes so a pure rebuild does not read as drift. The golden lives at
`golden/fish-snapshot.txt` and is specific to this machine and its fish universal
variables.

## The home-manager output check

`hm-output.sh` is the strongest guarantee, because the generated output is a pure
function of the flake. It builds the activation package and captures five views,
with store hashes masked. The package set is the `home.packages` closure by name
and version, which catches any package added, removed, or bumped. The systemd
units are every generated user service and timer verbatim, which catches a changed
`ExecStart`, path, or schedule. The generated `config.fish` fixes the sourcing
order. The git config and its per-account identity files fix commit identity, GPG
signing, and the hooks path. The `~/.ssh/config` fixes the host blocks and agent
behavior. It is slow, and because the repo carries untracked files it builds from a
throwaway git worktree copy, so it is opt-in through `run.sh --full` rather than
part of the default run.

## What this cannot cover

The fedora and suse code paths cannot be exercised on this machine at all. Those
are verified through container smoke tests and by reading package databases, not
here.
