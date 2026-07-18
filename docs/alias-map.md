# Alias map

Every shell shortcut this config defines, and what it runs. The aliases live in
`fish/aliases.fish`. The package-manager verbs are functions in
`fish/functions.fish`, because they dispatch per distro.

The rule behind the naming is that no alias shadows a system command. A standard
command like `grep`, `ls`, or `cat` always means the standard command, in every
shell and every script, so a script that calls `grep` never silently gets `rg`.
The modern tools are reached by their own short names instead. The eza shortcuts
follow one pattern: swap the leading `l` for an `e`.

## General

| alias | runs | note |
| --- | --- | --- |
| `g` | `git` | |
| `c` | `$VEDITOR` | VS Code |
| `v` | `nvim` | neovim, also your `$EDITOR` |
| `quit` | `exit` | |
| `p3` | `python3` | `python` stays the real python |
| `nugetclean` | `dotnet nuget locals --clear all` | |

## Listing with eza

Swap the leading `l` for an `e`. `ls`, `ll`, `la` stay fish's real-`ls` defaults.

| alias | runs | replaces |
| --- | --- | --- |
| `es` | `eza`, plain, git, icons | `ls` |
| `e` | `eza -F` | `l` |
| `el` | `eza -algF`, long and all | `ll` |
| `ea` | `eza -a`, all | `la` |
| `em` | `eza -lbg --sort=modified`, dirs by time | `lm` |
| `efm` | `eza -albgf --sort=modified`, files by time | `lfm` |
| `eam` | `eza -algF --sort=modified`, all by time | `lam` |
| `et` | `eza -aT --level=2`, tree | `lt` |
| `exl` | `eza -lbhHigUmuSa@`, extended | `lx` |

`exl`, not `ex`, because `/usr/bin/ex` is the real ex line editor.

## Modern tools, by their own names

| alias | runs | note |
| --- | --- | --- |
| `b` | `bat`, styled | `cat` stays real cat |
| `gr` | `rg --color=auto` | ripgrep, replaces `grep` and `egrep` |
| `gf` | `rg -F --color=auto` | fixed-string search, replaces `fgrep` |
| `dr` | `dir --color=auto` | `dir` stays real |
| `vd` | `vdir --color=auto` | `vdir` stays real |
| `ipc` | `ip -color=auto` | `ip` stays real |

## Navigation

| alias | runs |
| --- | --- |
| `..` | `cd ..` |
| `...` | `cd ../..` |
| `....` | `cd ../../..` |
| `.....` | `cd ../../../..` |
| `......` | `cd ../../../../..` |

## System and misc

| alias | runs |
| --- | --- |
| `hw` | `hwinfo --short` |
| `psmem` | `ps auxf` sorted by memory |
| `psmem10` | `psmem`, top ten |
| `tarnow` | `tar -acf` |
| `untar` | `tar -zxvf` |
| `wg` | `wget -c`, resume by default. `wget` stays the real wget |

## Applications

| alias | runs |
| --- | --- |
| `foundry` | launches FoundryVTT in the background |
| `gd` | Godot, backgrounded and detached (a function in functions.fish, not an alias, so `godot` stays the real binary) |

## Package-manager verbs

These are functions, not aliases, because they dispatch per distro across apt,
dnf, rpm-ostree, and zypper. They live in `fish/functions.fish`.

| verb | does |
| --- | --- |
| `upd` | update and upgrade all system packages |
| `rmpkg` | remove one or more packages |
| `cleanup` | remove orphans and clear the package cache |
| `grubup` | regenerate the bootloader config |
