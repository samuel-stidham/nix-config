# =========================
# General Aliases
# =========================

alias g git
alias c '$VEDITOR'   # VS Code
alias v nvim         # neovim, also your $EDITOR
alias quit exit
alias p3 python3   # `python` stays the real python
# vim is NOT aliased, it stays the real vim. The default editor is nvim through
# $EDITOR in env.fish, which is what git and friends use. Launch it with `nvim`.

# Dotnet NuGet cleanup
alias nugetclean 'dotnet nuget locals --clear all'

# =========================
# eza listing shortcuts
# =========================
#
# THE RULE: no alias here shadows a system command or a conventional shortcut.
# `ls` stays the real ls, and the ll/la/l conventions are left free too. Every eza
# alias swaps the leading `l` for an `e`, so it collides with nothing. An alias
# that replaces a command with a different tool is invisible and breaks any script
# that calls the real one, which is the whole reason for the prefix.
#
# --color=auto, never --color=always. `always` emits SGR escapes even into a pipe.
# `auto` self-gates on a tty and is eza's own default.
alias es 'eza --color=auto --git --group-directories-first --sort=type --icons'
alias e 'eza -F --color=auto --git --group-directories-first --sort=type --icons'
alias el 'eza -algF --color=auto --git --group-directories-first --sort=type --icons --time-style=iso'
alias ea 'eza -a --color=auto --git --group-directories-first --sort=type --icons'

# Custom eza aliases. `exl`, not `ex`: /usr/bin/ex is the real ex line editor, so
# the extended listing breaks the l-to-e pattern by a letter to avoid shadowing it.
alias em 'eza -lbg --git --sort=modified' # only directories, sort by modified
alias efm 'eza -albgf --git --sort=modified' # only files, sort by modified
alias eam 'eza -algF --color=auto --git --group-directories-first --sort=modified --icons --time-style=iso' # show all, sort by modified
alias et 'eza -aT --level=2' # show tree and all files to two levels
alias exl 'eza -lbhHigUmuSa@ --color=auto --git --group-directories-first --sort=type --icons --time-style=iso' # extended eza

# =========================
# Other Useful Aliases (from Garuda defaults and your zsh config)
# =========================
# `cat` stays real cat. bat is `b`, so a script that pipes cat is never surprised
# by bat's decorations or its pager.
alias b 'bat --style header --style snip --style changes --style header'

alias .. 'cd ..'
alias ... 'cd ../..'
alias .... 'cd ../../..'
alias ..... 'cd ../../../..'
alias ...... 'cd ../../../../..'

alias hw 'hwinfo --short'
alias ipc 'ip -color=auto'   # colored ip. `ip` itself stays the real command.
alias psmem 'ps auxf | sort -nr -k 4'
alias psmem10 'ps auxf | sort -nr -k 4 | head -10'
alias tarnow 'tar -acf '
alias untar 'tar -zxvf '
# wg, not wget: `wget` stays the real wget so a script that calls it gets stock
# behavior, per the no-shadow rule. `wg` is wget with resume-by-default (-c).
alias wg 'wget -c '

# The package-management verbs grubup, rmpkg, upd, and cleanup live in
# functions.fish, not here. Each dispatches per distro with a switch, so each is
# a function rather than an alias. __pkg_manager there is the probe they share.

# =========================
# Application and Service Shortcuts
# =========================

# FoundryVTT launcher is the `foundry` function in functions.fish, backgrounded
# and detached. It cannot be an alias: fish appends $argv after the body, so a
# trailing-`&` alias becomes `... & $argv` and errors on the empty expansion.

# Godot launcher is the `gd` function in functions.fish, backgrounded and
# detached. It is deliberately NOT an alias to `godot`, which stays the real
# binary per the no-shadow rule.

# MailHog (if installed via Go)
# alias mailhog "$HOME/go/bin/MailHog"

# =========================
# grep and dir shortcuts, NOTHING shadowed
# =========================
#
# grep stays the real grep, everywhere. rg is a DIFFERENT tool: recursive, honors
# gitignore, different regex. Shadowing grep with it silently breaks any script or
# fish function that calls grep, so rg is reached as `gr`, a new name. The real
# grep is always the real grep.
#
# --color=auto, not --color=always: `auto` gates on a tty and stays clean in a pipe.
alias gr 'rg --color=auto'      # ripgrep, replaces the old `grep` and `egrep`
alias gf 'rg -F --color=auto'   # fixed-string search, replaces the old `fgrep`
alias dr 'dir --color=auto'     # colored coreutils dir. `dir` itself stays real.
alias vd 'vdir --color=auto'    # colored coreutils vdir. `vdir` itself stays real.
