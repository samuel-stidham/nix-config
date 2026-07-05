# nix-config

My Nix home-manager configuration. It runs on a non-NixOS Ubuntu machine and is
scaffolded for a Mac later. Nix owns the development tooling and the local dev
services. apt keeps the system layer, which is the kernel, Cinnamon, the NVIDIA
driver, and the core libraries.

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
- apt stays for the system layer.

## Layout

- `flake.nix` ties everything together with flake-parts. It exposes the home
  configurations and the runnable packages.
- `home/` holds the home-manager modules, one per concern. `languages.nix`,
  `cli.nix`, `apps.nix`, `emacs.nix`, `theme.nix`, `fonts.nix`, `terminals.nix`,
  `jdks.nix`, `python.nix`, `fish.nix`, and `secrets.nix`.
- `parts/php.nix` is the shared PHP 8.5 build, used by the CLI and by php-fpm.
- `doom/` is the Doom Emacs user config, with evil mode for vim keybindings.
- `bootstrap.sh` installs Nix and everything Nix does not own, for a fresh
  machine.
- `.agents/` holds the agent rules for this repo. `SECRETS.md`, `SCANNING.md`,
  `PUBLISHING.md`, and `SITES.md` hold the plans and the runbooks.

## Usage

### Apply the home configuration

```bash
nix build '.#homeConfigurations."samuelstidham@x86_64-linux".activationPackage'
env HOME_MANAGER_BACKUP_EXT=backup ./result/activate
```

The backup flag saves any file the switch would overwrite as `<file>.backup`.

### Run the local dev services

```bash
nix run .#services
```

This starts MariaDB, PostgreSQL, Redis, MongoDB, MinIO, and Meilisearch as a
foreground process group. Data persists under `~/.local/share/dev-services`. See
`SITES.md` for ports and details.

### Serve local `*.test` sites

```bash
nix run .#sites
```

This serves any folder in `~/sites` at `<folder>.test` through nginx, php-fpm,
and dnsmasq. It needs a one-time system setup, which is in `SITES.md`.

### Run a Nix GL app against the NVIDIA driver

```bash
nix run --impure .#nixGL -- <app>
```

Most apps do not need this. It is only for a Nix-built GL or Vulkan app.

## Flake outputs

- `homeConfigurations."samuelstidham@x86_64-linux"` and the `aarch64-darwin`
  variant.
- `packages.<system>.services` and `packages.<system>.sites`, the two dev stacks.
- `packages.<system>.nixGL` and `packages.<system>.nixGLNvidia`.

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

The system layer stays on apt. That is the kernel, Cinnamon, the NVIDIA driver,
and the core libraries. Electron and Chromium apps use their vendor `.deb`, since
the shipped AppArmor profile makes the sandbox work. Desktop apps use Flatpak.
