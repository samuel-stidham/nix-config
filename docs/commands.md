# Command reference

Every command this configuration provides, in one place. If a command exists in
this repo and is not listed here, that is a bug in this document.

Related: [dev-stack.md](dev-stack.md), [secrets.md](secrets.md), [backup.md](backup.md)

---

## The one you want

```bash
zellij -n servers --layout servers
```

Brings the whole local backend up in one tab. Everything else on this page is
detail.

---

## Local dev stack

| Command | What it does |
| --- | --- |
| `zellij -n servers --layout servers` | Both stacks side by side, session named `servers` so a second launch attaches instead of starting a conflicting copy. |
| `nix run .#services` | MariaDB, PostgreSQL, Redis, MongoDB, SeaweedFS, Meilisearch. Data under `~/.local/share/dev-services`. |
| `nix run .#sites` | php-fpm and **dnsmasq**. Serves `~/sites/<name>` at `<name>.test`. nginx is a systemd service now, see below. |
| `secure_sites` | Generate a one year self signed cert for every folder in `~/sites`. Only for `.test`, which no CA will ever issue for. |
| `systemctl --user status nginx` | The one nginx. Serves `*.test` and `*.home.samuelstidham.me`, and owns port 443. |
| `./scripts/home-certs.sh --staging` | Rehearse the wildcard cert against Let's Encrypt staging. No rate limit spent. |
| `./scripts/home-certs.sh` | Issue or renew `*.home.samuelstidham.me`. The daily timer runs this. |
| `./bootstrap.sh firewall_tailnet_only` | Print the ufw rules that put the services on the tailnet only. |
| `tailscale status` | Both machines, both Connected. |

`sites` is the stack that answers `*.test`. Without it running, only names
hardcoded in `/etc/hosts` resolve.

---

## Home manager

| Command | What it does |
| --- | --- |
| `home-manager switch --flake .#samuelstidham@x86_64-linux` | Apply the configuration. The everyday command. |
| `nix build '.#homeConfigurations."samuelstidham@x86_64-linux".activationPackage'` | Build without activating, to check it compiles. |
| `env HOME_MANAGER_BACKUP_EXT=backup ./result/activate` | Activate a built generation, saving any clobbered file as `<file>.backup`. |
| `nix flake update` | Update every input. |
| `nix flake update nixpkgs` | Update only nixpkgs. |
| `home-manager news` | Release notes for the modules in use. |

> Flakes ignore untracked files. **`git add` a new module before it will
> evaluate**, or Nix will act as though it does not exist.

---

## bootstrap.sh

Reproduces a machine from scratch. Detects the distro family (debian, fedora,
atomic) and dispatches. Run a single section by name, or `all` for everything.

```bash
./bootstrap.sh              # every section, in order
./bootstrap.sh detect       # print what the OS probe found, change nothing
./bootstrap.sh <section>    # run one section
```

| Section | What it does |
| --- | --- |
| `detect` | Print `FAMILY`, `PKG`, `ATOMIC`. Read only, safe anywhere. |
| `install_nix` | Determinate installer. Flakes and the daemon on by default. |
| `apply_home` | Stage the repo and `home-manager switch`. |
| `fish_login_shell` | Register the Nix fish in `/etc/shells` and make it the login shell. |
| `system_layer` | The per distro package set. Podman, openssh, VirtualBox, Steam, headers. |
| `nvidia_driver` | `ubuntu-drivers autoinstall` on debian, `akmod-nvidia` on fedora. Skipped on atomic, the image ships it. |
| `virtualbox_extras` | Oracle Extension Pack (USB 2/3) and adds you to `vboxusers`. |
| `tailscale_net` | Install Tailscale. Auth (`tailscale up`) stays yours to run. |
| `nm_static_ip` | **Prints** the nmcli commands to pin `192.168.1.200` on both wired and WiFi. Does not run them. |
| `vendor_apps` | Chrome and VS Code from vendor repos, or Flathub on atomic. |
| `flatpaks` | Flatseal, Calibre, GIMP, PrismLauncher, Ente Auth. |
| `system_logs` | logrotate size caps and journald retention. Debian only. |
| `doom_emacs` | Clone Doom at a pinned SHA and `doom install`. |
| `lazyvim` | Clone the LazyVim starter at a pinned SHA, restore the locked plugins. |
| `monogame` | MonoGame templates and the mgcb tools through the Nix dotnet SDK. |
| `claude_code` | Official installer. Kept out of Nix so it self updates. |
| `aws_cli` | AWS CLI v2 from AWS's bundled installer. Fresh install or `--update`. |
| `atomic_extras` | Nothing to layer. Scheme is guile from Nix on every distro. |
| `savvy` | Prints a reminder. No Nix package. |

---

## Backups

See [backup.md](backup.md) for the full runbook.

| Command | What it does |
| --- | --- |
| `./scripts/backup.sh init` | Create the restic repository. Once, ever. |
| `./scripts/backup.sh backup` | Snapshot every Tier 1 path. Stops the forgejo stack first for a coherent database, restarts it on any exit. |
| `./scripts/backup.sh mc-backup` | Minecraft only. Refuses if the game is running. |
| `./scripts/backup.sh mc-restore` | Restore the latest Minecraft snapshot in place. Refuses if the game is running. |
| `./scripts/backup.sh snapshots` | List snapshots. |
| `./scripts/backup.sh restore <id> <dir>` | Restore a snapshot to a directory. |
| `./scripts/keep-awake.sh "why"` | Block idle, sleep, and hibernate while a long job runs. Ctrl-C releases. |

---

## Steam

| Command | What it does |
| --- | --- |
| `./scripts/steam-snapshot.sh` | Write every installed appid to `steam/appids.txt`. Commit it. Skips runtimes, Proton, and redistributables. |
| `./scripts/steam-restore.sh` | Queue every appid in that file for install. Steam must be open and logged in. |

---

## Secrets

See [secrets.md](secrets.md) for the architecture.

| Command | What it does |
| --- | --- |
| `safetybox init` | Create the identity and vault. Once, ever. |
| `printf '%s' "$V" \| safetybox set <name> --env-name <VAR>` | Store a secret. Value comes from stdin, never an argument. |
| `safetybox set <name> --env-name <VAR> --revoke-previous` | Rotate: store a new version and disable every older one in the same transaction. |
| `safetybox get <name>` | Prove a secret resolves. Prints metadata, never the value. |
| `safetybox reveal <name>` | The only verb that prints plaintext. |
| `safetybox exec -- <cmd>` | Run a command with every env named secret injected. How `backup.sh` gets its credentials. |
| `safetybox list [prefix]` | List secrets. No identity needed. |
| `safetybox show <name>` | Metadata and full version history. No identity needed. |
| `safetybox disable <name> <ver>` | Take one version out of resolution. |
| `safetybox delete <name>` | Soft delete. `set` revives it. |
| `safetybox purge <name> --yes` | Destroy every envelope. Irreversible. |
| `safetybox rekey` | Rotate the identity, re-encrypt everything to it. |
| `safetybox passwd` | Change the passphrase. The key does not change. |
| `safetybox stale` | List secrets past their expiry. |
| `passage show safetybox/passphrase` | The passphrase that unlocks the vault. |
| `passage insert <name>` | Store a passage secret. Hidden prompt, entered twice. **Never use `-m`, it echoes.** |
| `load-secrets` | Load every `global/*` secret into this shell. Runs automatically on shell start. |
| `unload-secrets` | Erase them from this shell. |
| `./scripts/migrate-passage-to-safetybox.sh` | One time migration of every passage secret into the vault. |

---

## Housekeeping

| Command | What it does |
| --- | --- |
| `./scripts/reorg.sh` | **Dry run.** Print every move and delete for the canonical structure. Changes nothing. |
| `./scripts/reorg.sh --apply` | Actually do it. Guards the 117G Roms delete by verifying WorkDrive has every file first. |

---

## Forgejo and Atlantis

| Command | What it does |
| --- | --- |
| `cd ~/forgejo && podman-compose up -d` | Start Forgejo, the runner, and Atlantis. Needs direnv loaded for the secrets. |
| `cd ~/forgejo && podman-compose down` | Stop the stack. |
| `podman ps` | What is running. |
| `podman logs -f forgejo_atlantis_1` | Follow Atlantis. |
| `systemctl --user enable --now podman.socket` | The rootless socket the forgejo runner needs for its Docker in Docker jobs. |
| `atlantis plan` (PR comment) | Plan manually. Autoplan already fires on any `.tf` change. |
| `atlantis apply` (PR comment) | Apply the reviewed plan. This is the human approval step. |

Atlantis lives at `http://atlantis.test:4141`, Forgejo at
`http://forgejo.test:3000`. Both need the `sites` stack running for dnsmasq to
resolve them.

---

## Graphics

| Command | What it does |
| --- | --- |
| `nix run --impure .#nixGL -- <app>` | Run a Nix built GL or Vulkan app against the system NVIDIA driver. |
| `nix run --impure .#nixGLNvidia -- <app>` | The NVIDIA specific wrapper. |

Most apps never need this. It is only for a Nix built GL app on a non NixOS host.

---

## Fish helpers

Defined in `fish/functions.fish` unless noted.

| Command | What it does |
| --- | --- |
| `servers` | Launch the zellij `servers` layout. |
| `secure_sites` | Self signed certs for every `~/sites` folder. Defined in `home/fish.nix`. |
| `load-secrets` / `unload-secrets` | The vault to environment bridge. `fish/secrets.fish`. |
| `backup` | Personal helper, predates `scripts/backup.sh`. |
| `cleanup` | Housekeeping helper. |
| `copy` | Clipboard helper. |
| `generatetoken` | Token helper. |
| `godot` | Launch Godot. |
| `add_to_path` | Prepend to PATH idempotently. |
| `update_ssh_auth_sock` | Repair `SSH_AUTH_SOCK` in a reattached session. |

There are also 38 aliases and abbreviations in `fish/aliases.fish`.

---

## Flake outputs

| Output | What it is |
| --- | --- |
| `homeConfigurations."samuelstidham@x86_64-linux"` | This machine. |
| `homeConfigurations."samuelstidham@aarch64-darwin"` | The Mac, scaffolded. |
| `packages.<system>.services` | The dev services stack. |
| `packages.<system>.sites` | The `*.test` web stack. |
| `packages.<system>.nixGL` / `.nixGLNvidia` | The GL wrappers. |
