# nix-config

My Nix home-manager configuration. It targets a non-NixOS Linux host and is
scaffolded for a Mac later. Nix owns the development tooling and the local dev
services. The distro's own package manager keeps the system layer, which is the
kernel, Cinnamon, the NVIDIA driver, and the core libraries.

The machine I run it on is Ubuntu. `bootstrap.sh` also supports Linux Mint and
Pop!_OS on apt, and the Fedora and openSUSE families including Bazzite. Those
other bodies were built by reading each distro's package index and resolving the
names in containers, not by installing on them, so treat them as supported but
untested. There is no Fedora, openSUSE, or Bazzite machine here to verify on. Base
Debian is dropped: it removed VirtualBox from its archive, so a base-Debian box
cannot reproduce this machine. RHEL, CentOS, Rocky, and Alma are dropped too,
because Red Hat removed btrfs in RHEL 8 and this repo's storage is btrfs end to end.

This is a personal config, not a general template. Paths and the username are
hardcoded to my machine, so fork and adjust before you use it.

## Highlights

- Every language toolchain I use, pinned and reproducible.
- Neovim and Doom Emacs, with a Catppuccin Frappe theme across the shell.
- A local dev services stack, run with one command.
- A `*.test` site server with a small driver layer, for local web work.
- Global secret scanning and a hardened, per-directory git identity.

## Requirements

- Nix with the `nix-command` and `flakes` features enabled.
- A non-NixOS host. This applies as standalone home-manager, not NixOS.
- The distro package manager stays for the system layer. That is apt, dnf,
  rpm-ostree, or zypper by family.

## Layout

- `flake.nix` ties everything together with flake-parts. It exposes the home
  configurations and the runnable packages.
- `home/` holds the home-manager modules, one per concern. `languages.nix`,
  `cli.nix`, `apps.nix`, `emacs.nix`, `theme.nix`, `fonts.nix`, `terminals.nix`,
  `jdks.nix`, `python.nix`, `fish.nix`, and `secrets.nix`.
- `parts/php.nix` is the shared PHP 8.5 build, used by the CLI and by php-fpm.
- `doom/` is the Doom Emacs user config, with evil mode for vim keybindings.
- `bootstrap.sh` installs Nix and everything Nix does not own, for a fresh
  machine. It detects the distro family and dispatches across the apt (Ubuntu,
  Mint, Pop), Fedora, and openSUSE families, including Bazzite. Only the apt path
  on this Ubuntu box is tested here.
- `scripts/` holds the runbook scripts: `backup.sh` (restic), `reorg.sh`,
  `steam-snapshot.sh` / `steam-restore.sh`, `migrate-passage-to-safetybox.sh`,
  and `keep-awake.sh`.
- `docs/` holds the deep documentation, see below.
- `.agents/` holds the agent rules for this repo. `SECRETS.md`, `SCANNING.md`,
  `PUBLISHING.md`, and `SITES.md` hold the plans and the runbooks.

## Documentation

- [docs/dev-stack.md](docs/dev-stack.md) — the local dev stack, the `servers`
  zellij layout, and how `*.test` resolution actually works.
- [docs/secrets.md](docs/secrets.md) — safetybox, passage, and how every shell
  gets its credentials without a plaintext file.
- [docs/backup.md](docs/backup.md) — the restic backup and restore runbook, what
  is backed up and what is deliberately not.
- [docs/sync.md](docs/sync.md) — Syncthing between the MacBook and this machine:
  SNHU coursework and library, why the Calibre library is not synced, and how the
  two reach each other over Tailscale.
- [docs/home-lab.md](docs/home-lab.md) — Forgejo and Atlantis on the tailnet: the
  wildcard DNS and certificate, the one nginx that owns port 443, and why none of
  it is reachable from the internet.

## Usage

### Apply the home configuration

```bash
nix build '.#homeConfigurations."samuelstidham@x86_64-linux".activationPackage'
env HOME_MANAGER_BACKUP_EXT=backup ./result/activate
```

The backup flag saves any file the switch would overwrite as `<file>.backup`.

### Run the whole dev stack at once

```bash
zellij -n servers --layout servers
```

This is the everyday command. It opens the `servers` zellij layout, which runs
both stacks side by side in one tab plus two free shells, and names the session
`servers` so a second launch attaches instead of starting a conflicting copy.
The layout is defined in `home/terminals.nix`.

Think of it as the Laravel Herd equivalent: one command, whole backend up.

### Run the local dev services

```bash
nix run .#services
```

This starts MariaDB, PostgreSQL, Redis, MongoDB, SeaweedFS, and Meilisearch as a
foreground process group. Data persists under `~/.local/share/dev-services`. See
`SITES.md` for ports and details.

### Serve local `*.test` sites

```bash
nix run .#sites
```

This serves any folder in `~/sites` at `<folder>.test` through php-fpm and
dnsmasq. It needs a one-time system setup, which is in `SITES.md`.

nginx is not in this stack. It runs as a systemd user service, because it also
fronts Forgejo. Every site therefore answers at `<folder>.home.samuelstidham.me`
too, on a real certificate and reachable from the MacBook. See
[docs/home-lab.md](docs/home-lab.md).

`sites` is also what runs **dnsmasq**, which answers `*.test`. Without it only
the names hardcoded in `/etc/hosts` resolve, so start this stack before expecting
`atlantis.test` or any `<folder>.test` name to work in a browser.

### Run a Nix GL app against the NVIDIA driver

```bash
nix run --impure .#legacyPackages.x86_64-linux.nixGL -- <app>
```

Most apps do not need this. It is only for a Nix-built GL or Vulkan app. nixGL
lives under `legacyPackages`, not `packages`, so `nix flake check` stays clean, at
the cost of the longer attribute path above.

## Flake outputs

- `homeConfigurations."samuelstidham@x86_64-linux"` and the `aarch64-darwin`
  variant.
- `packages.<system>.services` and `packages.<system>.sites`, the two dev stacks.
- `legacyPackages.<system>.nixGL` and `legacyPackages.<system>.nixGLNvidia`, kept
  out of `packages` so `nix flake check` does not choke on nixGL's impurity.

## Secrets and scanning

No secret value ever lives in this repo. It holds references and encrypted blobs
only. The design is passage with an age backend, injected per project through
direnv. `gitleaks` runs as a global pre-commit hook in every repo, and
`trufflehog` is the deep pre-publish auditor. The full plan is in `SECRETS.md`,
the scanner setup is in `SCANNING.md`, and the pre-publish checklist is in
`PUBLISHING.md`. Run that checklist before flipping any repo public.

## Reproduce on a fresh machine

`bootstrap.sh` installs Nix, applies this flake, then installs every item Nix
does not own. Read it before running it, since it uses sudo, apt, and network
installers.

## What Nix does not own

The system layer stays on the distro's own package manager. That is apt, dnf,
rpm-ostree, or zypper by family. It owns the kernel, Cinnamon, the NVIDIA driver,
and the core libraries. Electron and Chromium apps use each vendor's own repo, a
`.deb` on apt or an rpm repo on dnf, and Flatpak on an atomic base. Desktop apps
use Flatpak.
